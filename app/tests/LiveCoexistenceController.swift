import Foundation
import Darwin
#if !COEXISTENCE_DI
import OmacVMUSB
#endif

private final class LiveCoexistenceAsker: USBAsker {
    func ask(_ question:USBQuestion,answer:@escaping (USBAnswer)->Void) { preconditionFailure("controller must use explicit non-GUI selection") }
    func cancel() {}
    func notice(title:String,text:String) { print("SESSION_NOTICE \(title): \(text)"); fflush(stdout) }
}
private final class LiveCoexistenceClock: USBClock {
    let queue:DispatchQueue
    init(queue:DispatchQueue) { self.queue = queue }
    func after(_ seconds:Double,_ run:@escaping ()->Void) { queue.asyncAfter(deadline:.now()+seconds) { run() } }
}

// Queue-confined mutable state. Only stdin reading and waitUntilExit run outside
// queue; both enqueue results. This controller never transfers a guard to them.
final class LiveCoexistenceController: @unchecked Sendable {
    private let process: Process?
    private let transport: USBQMPTransport
    private let qemu: USBCoexistenceTask
    private let childMatches: () -> Bool
    private let factory: () -> USBCoexistenceCoordinator
    private let launch: String
    private let queue = DispatchQueue(label:"live-coexistence-control")
    private var selected: USBDevice?
    private lazy var machine: USBQMPMachine = {
        let m = USBQMPMachine(transport:transport,coexistenceFactory:{ [weak self] _ in self?.factory() },deliver:{ [weak self] body in self?.queue.async { body() } })
        m.onCoexistencePhase = { [weak self] value,device in
            guard let self, self.selected == device else { return }
            self.phase = value
            self.session.coexistencePhase(value,device:device)
            self.emit("GENERATION=\(self.generation) PHASE=\(value.rawValue) QEMU_PID=\(self.qemu.pid)")
        }
        return m
    }()
    private lazy var session: USBSession = {
        let s = USBSession(vmName:"owned-child",memory:USBMemory(),machine:machine,asker:LiveCoexistenceAsker(),clock:LiveCoexistenceClock(queue:queue),save:{ _ in },log:{ [weak self] in self?.emit($0) })
        s.inFront = false // only explicit controller selection, no GUI/auto answer
        s.onChange = { [weak self, weak s] in
            guard let self, let s, let d = self.selected else { return }
            self.emit("SESSION generation=\(self.generation) state=\(String(describing:s.plugs[d.location]?.state))")
        }
        return s
    }()
    private var phase = USBCoexistenceCoordinator.Phase.retired
    private var bulk: USBDevice?
    private var bulkUncertain = false
    private var generation = 0
    init(process:Process,transport:USBQMPTransport,launcher:USBCoexistenceTask,qemu:USBCoexistenceTask,launch:String) {
        self.process = process; self.transport = transport; self.qemu = qemu; self.launch = launch
        childMatches = { process.isRunning && (try? USBCoexistenceTask.measure(qemu.pid)) == qemu }
        let ledger = USBCoexistenceLedger()
        factory = { USBCoexistenceCoordinator(transport:transport,launcher:launcher,qemu:qemu,launch:launch,ledger:ledger) }
    }
    // Inert DI gate: does not start stdin, Process, registry or native APIs.
    init(transport:USBQMPTransport,qemu:USBCoexistenceTask,launch:String,childMatches:@escaping ()->Bool,factory:@escaping ()->USBCoexistenceCoordinator) {
        process = nil; self.transport = transport; self.qemu = qemu; self.launch = launch
        self.childMatches = childMatches; self.factory = factory
    }
    func submit(_ data:Data) { queue.sync { handle(data) } }
    var state: String { queue.sync {
        if bulk != nil { return "bulk" }
        if phase == .native && selected.map({ session.plugs[$0.location]?.state != .connected }) == true { return "connecting" }
        return phase.rawValue
    } }
    var sessionStates: [UInt32:USBSession.State] { queue.sync { session.plugs.mapValues(\.state) } }
    private func emit(_ text:String) { print(text); fflush(stdout) }
    private func attach(_ target:USBCoexistenceTarget,_ descriptor:Data) {
        guard (phase == .retired || phase == .refused), bulk == nil,
              childMatches() else {
            emit("CONTROL_REFUSED ownership pending or child gone"); return
        }
        guard let candidate = try? USBCoexistenceCandidate(target:target,descriptor:descriptor) else {
            emit("CONTROL_REFUSED descriptor mismatch"); return
        }
        if let old = selected { session.unplugged(location:old.location,rootID:old.coexistenceRootID) }
        generation += 1
        // Location 1 is a harness-local session slot, not a measured USB port.
        // Native selection uses only Target's exact root/interface/HID IDs.
        var device = USBDevice(id:.init(vendor:target.vendor,product:target.product),name:"parent-selected HID",deviceClass:0,interfaces:[.init(number:0,interfaceClass:3,users:[])],serial:String(decoding:target.serial,as:UTF8.self),location:1)
        device.coexistence = candidate; device.coexistenceRootID = target.root
        selected = device; phase = .preparing
        session.plugged(device)
        session.connectNow(location:device.location)
    }
    private func detach(_ retry:Bool) {
        if let device = bulk {
            guard !bulkUncertain else { emit("CONTROL_REFUSED uncertain bulk add; inspect parent QMP"); return }
            let ok = USBQMP.detach(location:device.location,over:transport)
            if ok { bulk = nil }
            emit("BULK_RELEASED=\(ok)"); return
        }
        guard let d = selected else { emit("NO_ACTIVE_LEASE"); return }
        if phase == .native || (retry && (phase == .uncertain || phase == .revoking)) {
            session.disconnectNow(location:d.location)
        } else if phase == .preparing || phase == .acquiring || phase == .committing {
            session.unplugged(location:d.location,rootID:d.coexistenceRootID)
        } else { emit("CONTROL_REFUSED use explicit retry for pending release") }
    }
    private func boundedFile(_ path:String) throws -> Data {
        try LiveControl.readFile(path)
    }
    private func handle(_ data:Data) {
        do {
            switch try LiveControl.parse(data) {
            case .attach(let t,let d):
                let target = try USBCoexistenceTarget(wire:USBCoexistenceCodec.decode(boundedFile(t)))
                let descriptor = try boundedFile(d)
                guard target.descriptorHash == USBCoexistenceTarget.hash(descriptor) else { throw USBCoexistenceError.identity }
                attach(target,descriptor)
            case .bulk(let v,let p,let l,let a):
                guard (phase == .retired || phase == .refused), bulk == nil,
                      childMatches() else {
                    emit("CONTROL_REFUSED old lease not retired or child gone"); return
                }
                let device = USBDevice(id:.init(vendor:v,product:p),name:"parent-selected bulk",deviceClass:0,interfaces:[],location:l,address:a)
                bulk = device // retain even if the ordinary add reply is ambiguous
                let result = USBQMP.attach(device,over:transport)
                bulkUncertain = result != .attached
                emit("BULK_ATTACHED=\(result == .attached) QEMU_PID=\(qemu.pid)")
            case .detach: detach(false)
            case .retry: detach(true)
            case .status: emit("CONTROL_STATUS generation=\(generation) phase=\(phase.rawValue) bulk=\(bulk != nil) QEMU_PID=\(qemu.pid) LAUNCH=\(launch)")
            }
        } catch { emit("CONTROL_ERROR \(error)") }
    }
    private func readStdin() {
        var line = Data(), overflow = false
        while true {
            var byte:UInt8 = 0
            let n = Darwin.read(STDIN_FILENO,&byte,1)
            if n == 0 { emit("CONTROL_EOF ownership retained"); return }
            if n < 0 { if errno == EINTR { continue }; emit("CONTROL_READ_ERROR ownership retained"); return }
            if byte != 10 {
                if line.count < 4096 { line.append(byte) } else { overflow = true }
                continue
            }
            let input = line, invalid = overflow; line.removeAll(keepingCapacity:true); overflow = false
            // Synchronous submission bounds the pending command count to one.
            queue.sync {
                if invalid { emit("CONTROL_ERROR oversized line") } else { handle(input) }
            }
        }
    }
    func start(target:USBCoexistenceTarget,descriptor:Data,duration:Double) {
        queue.async {
            self.attach(target,descriptor)
            let first = self.generation
            self.queue.asyncAfter(deadline:.now()+duration) {
                if self.generation == first && self.bulk == nil { self.detach(false) }
            }
        }
        DispatchQueue.global().async { self.readStdin() }
        DispatchQueue.global().async {
            guard let process = self.process else { return }
            process.waitUntilExit()
            self.queue.async {
                if (self.phase == .retired || self.phase == .refused) && self.bulk == nil {
                    self.emit("OWNED_QEMU_EXIT no retained lease"); exit(0)
                }
                self.emit("OWNED_QEMU_EXIT_UNKNOWN ownership retained; no synthetic drain ACK")
            }
        }
    }
}
