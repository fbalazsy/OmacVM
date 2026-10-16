import Foundation

// Replay of hw/usb/host-coexistence-qmp.inc coex_cancel/commit/release.
// The separate actual-QMP fixture checks those production handlers. Inert boundary,
// NOT execution of QEMU or proof of its native drain. No-ticket is explicit.
func coexistenceInteropTests(root:USBScan.Entry,receipt:USBRootGuardReceipt,selection:String,finishProcess:Bool = true) throws {
    final class Peer: USBQMPTransport {
        let inner:CoexistencePeer
        let mode:String
        var unknown = false
        var cleanupID: String?
        // This peer never admits a native ticket, unlike normal lifecycle peers.
        let nativeTicketEver = false
        func neverstartedACK() {
            if cleanupID != nil && !nativeTicketEver && inner.wire["state"] as? String == "revoking" &&
                inner.wire["handles"] as? String == "0" && inner.wire["transfers"] as? String == "0" &&
                inner.wire["callbacks"] as? String == "0" && inner.wire["uncertain"] as? Bool == false {
                inner.wire["state"] = "guard-release"
            }
        }
        private let lock = NSLock()
        private var history:[[String:Any]] = []
        var trace:[[String:Any]] { lock.lock(); defer { lock.unlock() }; return history }
        init(_ mode:String,root:USBScan.Entry,descriptor:Data) { self.mode = mode; inner = CoexistencePeer(root:root,descriptor:descriptor) }
        func execute(_ command:String,_ arguments:[String:Any]?) throws -> [String:Any] {
            let op = command.replacingOccurrences(of:"x-omacvm-usb-coexistence-",with:"")
            lock.lock(); history.append(["command":command,"arguments":arguments ?? [:]]); lock.unlock()
            if unknown && (op == "prepare" || op == "status") { throw USBCoexistenceError.uncertain }
            if op == "status" || op == "prepare" { neverstartedACK(); return inner.wire }
            let args = arguments ?? [:]
            let call = try USBCoexistenceCodec.object(args["call"],"lease sequence")
            precondition(NSDictionary(dictionary:call["lease"] as! [String:Any]).isEqual(to:inner.wire["lease"] as! [String:Any]))
            let next = try USBCoexistenceCodec.u64(call["sequence"]), previous = try USBCoexistenceCodec.u64(inner.wire["sequence"])
            precondition(next == previous + 1)
            if op == "commit" {
                precondition(mode == "failed-native-adoption")
                precondition(args["guard-open"] as? String == "nonseizing-success")
                cleanupID = args["guard-client-id"] as? String
                inner.wire["guard-client-id"] = cleanupID
                inner.wire["state"] = "revoking"
                // coex_commit stores identity BEFORE reservation; a reservation
                // refusal does NOT advance sequence, and coex_status can ACK.
                throw USBCoexistenceError.rejected("COEX_IDENTITY")
            }
            if op == "revoke" {
                let extended = Set(args.keys) == Set(["call","reason","published","guard-client-id","guard-task"])
                guard extended || Set(args.keys) == Set(["call","reason"]) else { throw USBCoexistenceError.schema }
                if extended {
                    precondition(NSDictionary(dictionary:args["published"] as! [String:Any]).isEqual(to:inner.wire["published"] as! [String:Any]))
                    let lease = inner.wire["lease"] as! [String:Any], owner = lease["launcher"] as! [String:Any]
                    precondition(NSDictionary(dictionary:args["guard-task"] as! [String:Any]).isEqual(to:owner["task"] as! [String:Any]))
                    let id = String(try USBCoexistenceCodec.u64(args["guard-client-id"]))
                    guard cleanupID == nil || cleanupID == id else { throw USBCoexistenceError.identity }
                    cleanupID = id; inner.wire["guard-client-id"] = id
                }
                precondition(inner.driver.successfulCloses == 0,"held guard must not close before native-neverstarted ACK")
                inner.wire["state"] = "revoking"
            }
            if op == "release" {
                _ = try USBCoexistenceCodec.object(args,"call guard-client-id guard-closed")
                guard inner.wire["state"] as? String == "guard-release", cleanupID != nil,
                      args["guard-client-id"] as? String == cleanupID,
                      try USBCoexistenceCodec.bool(args["guard-closed"]) else { throw USBCoexistenceError.uncertain }
                if cleanupID != "0" { precondition(inner.driver.successfulCloses == 1) }
                // Inert exact-root cache-only witness, separate from zero counters.
                precondition(inner.driver.released == 1 || cleanupID == "0")
                inner.wire["state"] = "retired"
            }
            inner.wire["sequence"] = call["sequence"]
            neverstartedACK()
            return inner.wire
        }
    }
    // Observe completions without replacing the actual production machine.
    final class Observer: USBMachine {
        let machine:USBQMPMachine
        let attached = DispatchSemaphore(value:0), released = DispatchSemaphore(value:0)
        var result:USBAttachResult?
        init(_ machine:USBQMPMachine) { self.machine = machine }
        func attach(_ d:USBDevice,done:@escaping (USBAttachResult)->Void) {
            machine.attach(d) { self.result = $0; done($0); self.attached.signal() }
        }
        func detach(_ d:USBDevice,done:@escaping (Bool)->Void) {
            machine.detach(d) { done($0); self.released.signal() }
        }
        func retryRelease(_ d:USBDevice,done:@escaping (Bool)->Void) {
            machine.retryRelease(d) { done($0); self.released.signal() }
        }
        func isAttached(_ d:USBDevice,done:@escaping (Bool)->Void) { machine.isAttached(d,done:done) }
    }
    let cases = ["acquire-refusal","precommit-held","unknown-prepare","failed-native-adoption"]
    guard selection == "all" || cases.contains(selection) else { throw USBCoexistenceError.schema }
    var results:[[String:Any]] = []
    for mode in cases where selection == "all" || selection == mode {
        let peer = Peer(mode,root:root,descriptor:receipt.descriptor)
        let initial = try USBCoexistenceStatus(wire:peer.inner.wire)
        let ledger = USBCoexistenceLedger()
        if mode == "acquire-refusal" { peer.inner.driver.fail = "snapshot1" }
        if mode == "precommit-held" { peer.inner.driver.fail = "snapshot4" }
        peer.unknown = mode == "unknown-prepare"
        let ui = DispatchQueue(label:"interop-session")
        var phase = USBCoexistenceCoordinator.Phase.idle
        let machine = USBQMPMachine(transport:peer,coexistenceFactory:{ _ in
            USBCoexistenceCoordinator(transport:peer,launcher:initial.launcher,qemu:initial.qemu,launch:initial.launch,ledger:ledger,automaticTimers:false,taskMatches:{ _ in true },guardFactory:{ r,revoke in
                USBRootGuard(driver:peer.inner.driver,receipt:r,lifetime:30,pollInterval:10,onRevoke:revoke)
            })
        },deliver:{ work in ui.async { work() } })
        let observer = Observer(machine)
        let session = USBSession(vmName:"interop",memory:USBMemory(),machine:observer,asker:CoexistenceAsker(),clock:CoexistenceClock(),save:{ _ in },log:{ _ in })
        machine.onCoexistencePhase = { p,d in phase = p; session.coexistencePhase(p,device:d) }
        var device = USBDevice(id:.init(vendor:1234,product:5678),name:"interop",deviceClass:0,interfaces:[.init(number:0,interfaceClass:3,users:[])],location:1)
        device.coexistence = USBCoexistenceCandidate.resolve(root,qemuPID:initial.qemu.pid)!
        device.coexistenceRootID = initial.target.root
        ui.sync { session.plugged(device) }
        precondition(observer.attached.wait(timeout:.now()+3) == .success)
        precondition(observer.result != .attached)
        if mode == "unknown-prepare" {
            precondition(peer.inner.driver.opens == 0,"unknown prepare must never acquire")
            peer.unknown = false
        }
        let needsRetry = ui.sync { phase != .retired }
        if needsRetry {
            ui.sync { session.disconnectNow(location:1) }
            precondition(observer.released.wait(timeout:.now()+3) == .success)
        }
        let sessionState = ui.sync { String(describing:session.plugs[1]?.state) }
        let held = !ledger.claim(root:initial.target.root,owner:UUID())
        let passed = phase == .retired && !held
        let closes = peer.inner.driver.successfulCloses
        if passed { precondition(closes == (["precommit-held","failed-native-adoption"].contains(mode) ? 1 : 0)) }
        else { precondition(closes == 0,"unacknowledged cleanup must retain held guard") }
        let prepareCount = peer.trace.filter { ($0["command"] as? String)?.hasSuffix("-prepare") == true }.count
        precondition(prepareCount == 1,"never replay prepare")
        if mode == "precommit-held" { precondition(!peer.trace.contains { ($0["command"] as? String)?.hasSuffix("-commit") == true },"revoked guard cannot authorize native commit") }
        results.append(["case":mode,"expected-phase":"retired","actual-phase":phase.rawValue,"session-state":sessionState,"passed":passed,"root-retained":held,"guard-open-attempts":peer.inner.driver.opens,"guard-close-calls":peer.inner.driver.closed,"last-status":peer.inner.wire,"trace":peer.trace])
        print("\(passed ? "PASS" : "FAIL") INTEROP \(mode): expected retired, actual \(phase.rawValue); guard closes=\(closes), root retained=\(held)")
    }
    if let output = ProcessInfo.processInfo.environment["COEX_INTEROP_OUTPUT"] {
        try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output))
    }
    let passed = results.allSatisfy { $0["passed"] as? Bool == true }
    if finishProcess { exit(passed ? 0 : 1) }
    precondition(passed)
}
