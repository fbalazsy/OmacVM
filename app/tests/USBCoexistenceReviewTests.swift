import Foundation

// Adversarial review regressions: fake drivers/transports only.
func coexistenceReviewTests(root: USBScan.Entry, receipt: USBRootGuardReceipt) throws {
    var failures = 0
    func check(_ ok: Bool, _ name: String) {
        print("\(ok ? "PASS" : "FAIL") REVIEW \(name)")
        if !ok { failures += 1 }
    }
    func wait<T>(_ body: (@escaping (T)->Void)->Void) -> T {
        let sem = DispatchSemaphore(value:0); var value:T?
        body { value = $0; sem.signal() }
        precondition(sem.wait(timeout:.now()+3) == .success)
        return value!
    }
    func device() -> USBDevice {
        var d = USBDevice(id:.init(vendor:1234,product:5678),name:"board",deviceClass:0,interfaces:[.init(number:0,interfaceClass:3,users:["IOHIDDevice"])],location:1)
        d.coexistence = USBCoexistenceCandidate.resolve(root,qemuPID:200)!
        return d
    }
    // Autonomous native-close failure can reach STATUS before local guard loss.
    // Exercise the real session/machine/coordinator; only QMP/kernel are inert.
    do {
        final class Peer: USBQMPTransport {
            let inner: CoexistencePeer
            private let lock = NSLock()
            private var drainAllowed = false
            init(_ inner: CoexistencePeer) { self.inner = inner }
            func allowMatchingDrain() { lock.lock(); drainAllowed = true; lock.unlock() }
            func execute(_ command:String,_ args:[String:Any]?) throws -> [String:Any] {
                lock.lock(); defer { lock.unlock() }
                if command.hasSuffix("-renew") {
                    // Runtime revoked and native Close failed. Mutator reply is
                    // lost; canonical STATUS accepts the same generation/sequence.
                    inner.wire["state"] = "uncertain"; inner.wire["uncertain"] = true
                    inner.lostRenew = true
                }
                if command.hasSuffix("-status") && drainAllowed {
                    inner.wire["state"] = "guard-release"; inner.wire["uncertain"] = false
                }
                return try inner.execute(command,args)
            }
        }
        let native = CoexistencePeer(root:root,descriptor:receipt.descriptor)
        let initial = try USBCoexistenceStatus(wire:native.wire)
        let peer = Peer(native), ledger = USBCoexistenceLedger()
        let ui = DispatchQueue(label:"uncertain-renew-session")
        var coordinator: USBCoexistenceCoordinator!, owner: USBRootGuard!, ticket: USBRootGuardTicket!
        let machine = USBQMPMachine(transport:peer,coexistenceFactory:{ _ in
            coordinator = USBCoexistenceCoordinator(transport:peer,launcher:initial.launcher,qemu:initial.qemu,launch:initial.launch,ledger:ledger,automaticTimers:true,taskMatches:{ _ in true },guardFactory:{ r,revoke in
                ticket = USBRootGuardTicket(binding:r.binding,guardClientID:native.guardID)
                owner = USBRootGuard(driver:native.driver,receipt:r,lifetime:30,pollInterval:10,onRevoke:revoke)
                return owner
            })
            return coordinator
        },deliver:{ work in ui.async { work() } })
        let d = device()
        let session = USBSession(vmName:"uncertain-renew",memory:USBMemory(),machine:machine,asker:CoexistenceAsker(),clock:CoexistenceClock(),save:{ _ in },log:{ _ in })
        var phase = USBCoexistenceCoordinator.Phase.idle
        machine.onCoexistencePhase = { p,d in phase = p; session.coexistencePhase(p,device:d) }
        func until(_ seconds:Double,_ predicate:()->Bool) -> Bool {
            let end = ProcessInfo.processInfo.systemUptime + seconds
            while !ui.sync(execute:predicate) && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval:0.005) }
            return ui.sync(execute:predicate)
        }
        ui.sync { session.plugged(d) }
        precondition(until(3) { phase == .native && session.plugs[1]?.state == .connected })
        let renewed:Bool = wait { coordinator.renewNow(completion:$0) }
        check(!renewed && native.commands.contains("status"),"uncertain renewal resolves canonical STATUS before guard callback")
        check(until(0.3) { phase == .uncertain && session.plugs[1]?.state == .coexistencePending },"uncertain canonical receipt cannot leave native/Connected")
        let guardRenewed:Bool = wait { owner.renew(ticket,completion:$0) }
        let guardCommitted:Bool = wait { owner.beginCommit(ticket,completion:$0) }
        check(!guardRenewed && !guardCommitted,"uncertain canonical receipt revokes local guard renewal/commit")
        check(native.driver.closed == 0 && native.driver.released == 0 && !ledger.claim(root:1,owner:UUID()) && !native.commands.contains("release"),"uncertain receipt retains quarantine without Close or release")
        native.driver.signal(.lost)
        let _:Bool = wait { coordinator.renewNow(completion:$0) }
        check(until(0.3) { phase == .uncertain && session.plugs[1]?.state == .coexistencePending },"late guard callback cannot restore native/Connected")
        peer.allowMatchingDrain()
        check(until(3) { phase == .retired },"only matching canonical drain permits terminal cleanup")
        check(native.driver.closed == 1 && native.driver.released == 1 && ledger.claim(root:1,owner:UUID()),"matching drain closes guard exactly once and retires root")
    }
    // No prepare and no root claim happened: a second attempt must be possible.
    do {
        let peer = CoexistencePeer(root:root,descriptor:receipt.descriptor)
        let initial = try USBCoexistenceStatus(wire:peer.wire)
        let ledger = USBCoexistenceLedger(); let previousOwner = UUID()
        precondition(ledger.claim(root:initial.target.root,owner:previousOwner))
        let machine = USBQMPMachine(transport:peer,coexistenceFactory:{ _ in
            USBCoexistenceCoordinator(transport:peer,launcher:initial.launcher,qemu:initial.qemu,launch:initial.launch,ledger:ledger,automaticTimers:false,taskMatches:{ _ in true },guardFactory:{ r, revoke in
                USBRootGuard(driver:peer.driver,receipt:r,lifetime:5,onRevoke:revoke)
            })
        },deliver:{$0()})
        var phases: [USBCoexistenceCoordinator.Phase] = []
        machine.onCoexistencePhase = { phase, _ in phases.append(phase) }
        let first: USBAttachResult = wait { machine.attach(device(),done:$0) }
        precondition(first != .attached && peer.commands.isEmpty)
        check(phases == [.refused],"typed no-ownership refusal precedes failed completion")
        check(!ledger.claim(root:initial.target.root,owner:UUID()),"preflight refusal does not release foreign global owner")
        ledger.retire(root:initial.target.root,owner:previousOwner)
        let second: USBAttachResult = wait { machine.attach(device(),done:$0) }
        check(second == .attached,"preflight no-ownership failure must not poison machine location; second=\(second) commands=\(peer.commands)")
        if second == .attached { let _: Bool = wait { machine.detach(device(),done:$0) } }
    }
    // RootGuard supports retry with the SAME confirmed drain ticket. Coordinator must too.
    do {
        let peer = CoexistencePeer(root:root,descriptor:receipt.descriptor)
        let initial = try USBCoexistenceStatus(wire:peer.wire)
        let c = USBCoexistenceCoordinator(transport:peer,launcher:initial.launcher,qemu:initial.qemu,launch:initial.launch,ledger:USBCoexistenceLedger(),automaticTimers:true,taskMatches:{_ in true},guardFactory:{ r,revoke in
            USBRootGuard(driver:peer.driver,receipt:r,lifetime:5,onRevoke:revoke)
        })
        precondition(wait { c.attach(target:initial.target,descriptor:receipt.descriptor,deviceID:"review",completion:$0) })
        peer.driver.fail = "close"
        precondition(!wait { c.detach(completion:$0) })
        Thread.sleep(forTimeInterval:1.2)
        check(peer.driver.closed == 1 && !peer.commands.contains("release"),"timer never retries failed guard close or drops guard")
        let automatic: Bool = wait { c.detach(retryClose:false,completion:$0) }
        check(!automatic && peer.driver.closed == 1,"non-user detach never retries failed close")
        peer.driver.fail = ""
        let retry: Bool = wait { c.detach(completion:$0) }
        check(retry,"explicit retry after transient close failure must release same drained generation; closeCalls=\(peer.driver.closed) commands=\(peer.commands)")
    }
    // Publication while old generation drains must be retained, not discarded.
    do {
        let machine = CoexistenceSessionMachine()
        let session = USBSession(vmName:"review",memory:USBMemory(),machine:machine,asker:CoexistenceAsker(),clock:CoexistenceClock(),save:{_ in},log:{_ in})
        let old = device(); session.plugged(old); machine.answer?(.attached)
        session.unplugged(location:1)
        var replacement = old; replacement.coexistence = nil; replacement.interfaces = []; replacement.name = "replacement"
        session.plugged(replacement)
        machine.release?(true)
        check(session.plugs[1]?.device == replacement,"replacement published during drain survives confirmed release; plugPresent=\(session.plugs[1] != nil) attaches=\(machine.attaches)")
    }
    // The production machine queues retired notification before failed completion.
    do {
        let machine = CoexistenceSessionMachine()
        let session = USBSession(vmName:"review",memory:USBMemory(),machine:machine,asker:CoexistenceAsker(),clock:CoexistenceClock(),save:{_ in},log:{_ in})
        let d = device(); session.plugged(d)
        session.coexistencePhase(.retired,device:d)
        machine.answer?(.failed("definitive rejection; cleanup already retired"))
        check(session.plugs[1]?.state == .onMac(remembered:false),"confirmed retirement must not become phantom release pending on failed attach completion; state=\(String(describing:session.plugs[1]?.state))")
    }
    for mode in ["phase-first", "callback-first", "unplug-replacement", "latest", "connecting", "own-publication", "retry-ui", "old-removal-after-new"] {
        let machine = CoexistenceSessionMachine()
        var memory = USBMemory()
        var replacement = device(); replacement.coexistence = nil; replacement.interfaces = []; replacement.name = "replacement"; replacement.coexistenceRootID = 22
        memory.remember(replacement,.mac)
        let session = USBSession(vmName:"review",memory:memory,machine:machine,asker:CoexistenceAsker(),clock:CoexistenceClock(),save:{_ in},log:{_ in})
        let old = device()
        // Candidate and ordinary replacement share VID/PID: force the first attach explicitly.
        session.plugged(old); session.connectNow(location:1)
        if mode != "connecting" { machine.answer?(.attached) }
        if mode == "own-publication" {
            var own = old; own.coexistence = nil; own.coexistenceRootID = old.coexistence!.target.root
            session.plugged(own)
            check(session.plugs[1]?.device == old && machine.release == nil,"own client publication preserves owner, not replacement")
            continue
        }
        if mode == "retry-ui" {
            session.disconnectNow(location:1); machine.release?(false)
            let rows = USBListRows.make(memory:memory,devices:[old],states:session.plugs.mapValues(\.state),vmName:"review")
            check((rows.remembered + rows.plugged).contains{$0.canDisconnect && !$0.canConnect},"pending release UI exposes only explicit Disconnect retry")
            session.disconnectNow(location:1); machine.release?(true)
            check(session.plugs[1]?.state == .onMac(remembered:false),"pending release retry reaches confirmed retirement")
            continue
        }
        if mode != "connecting" { session.unplugged(location:1) }
        session.plugged(replacement)
        if mode == "connecting" {
            machine.answer?(.attached)
            check(machine.release != nil,"replacement during attach initiates cleanup after callback")
        }
        if mode == "old-removal-after-new" { session.unplugged(location:1, rootID:old.coexistence!.target.root) }
        if mode == "latest" { replacement.name = "latest"; session.plugged(replacement) }
        if mode == "unplug-replacement" { session.unplugged(location:1) }
        let completion = machine.release
        if mode != "callback-first" { session.coexistencePhase(.retired,device:old) }
        completion?(true)
        session.coexistencePhase(.retired,device:old)
        if mode == "old-removal-after-new" { session.unplugged(location:1,rootID:old.coexistence!.target.root) }
        let expected = mode == "unplug-replacement" ? nil : replacement
        check(session.plugs[1]?.device == expected,"replacement cleanup ordering \(mode)")
        if expected != nil { check(session.plugs[1]?.state == .onMac(remembered:true),"replacement uses own Mac plan \(mode)") }
    }
    for mode in ["lost", "wrong-owner", "ambiguous", "stale-epoch"] {
        let peer = CoexistencePeer(root:root,descriptor:receipt.descriptor)
        let initial = try USBCoexistenceStatus(wire:peer.wire)
        let ledger = USBCoexistenceLedger()
        if mode == "stale-epoch" {
            let owner = UUID()
            precondition(ledger.reserve(root:1,owner:owner,qemuLaunch:initial.qemuLaunch,epoch:1))
            ledger.retire(root:1,owner:owner)
        }
        peer.failPrepare = true
        peer.failStatus = mode == "ambiguous"
        if mode == "wrong-owner" {
            var lease = peer.wire["lease"] as! [String:Any]
            var owner = lease["launcher"] as! [String:Any]
            owner["launch"] = String(repeating:"c",count:32); lease["launcher"] = owner; peer.wire["lease"] = lease
        }
        var lookup = false
        peer.argumentsHook = { op, args in
            if op == "status" && args?["lease"] == nil {
                lookup = Set(args!.keys) == Set(["launcher","target"])
            }
        }
        let c = USBCoexistenceCoordinator(transport:peer,launcher:initial.launcher,qemu:initial.qemu,launch:initial.launch,ledger:ledger,automaticTimers:false,taskMatches:{_ in true},guardFactory:{r,revoke in USBRootGuard(driver:peer.driver,receipt:r,lifetime:5,onRevoke:revoke)})
        let ok: Bool = wait { c.attach(target:initial.target,descriptor:receipt.descriptor,deviceID:"lookup",completion:$0) }
        check(lookup && ok == (mode == "lost") && peer.commands.filter{$0 == "prepare"}.count == 1,"lost prepare owner lookup \(mode), no mutator replay")
        if ok { let _:Bool = wait { c.detach(completion:$0) } }
        else { check(peer.driver.opens == 0 && !ledger.claim(root:1,owner:UUID()),"invalid lookup retains uncertain root \(mode)") }
    }
    print("REVIEW failures=\(failures)")
    if failures != 0 { exit(1) }
}
