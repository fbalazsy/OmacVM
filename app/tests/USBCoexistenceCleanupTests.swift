import Foundation

// Final-wire adversarial controls. These peers are inert, not QEMU execution.
func coexistenceCleanupTests(root:USBScan.Entry,receipt:USBRootGuardReceipt) throws {
    final class Peer:USBQMPTransport {
        let inner:CoexistencePeer
        let mode:String
        var cleanup:String?
        private let lock = NSRecursiveLock()
        private var history:[String] = []
        var commands:[String] { lock.lock(); defer { lock.unlock() }; return history }
        var handoffs:[[String:Any]] = []
        var draining = true
        func completeDrain() {
            lock.lock(); defer { lock.unlock() }
            draining = true; inner.wire["callbacks"] = "0"
        }
        init(_ mode:String,root:USBScan.Entry,descriptor:Data) {
            self.mode = mode; inner = CoexistencePeer(root:root,descriptor:descriptor)
            inner.driver.fail = mode == "unsolicited-zero" ? "snapshot1" : "snapshot4"
            if mode == "failed-acquire-close" { inner.driver.fail = "close" }
        }
        func ack() {
            if cleanup != nil && draining && inner.wire["state"] as? String == "revoking" {
                inner.wire["state"] = mode == "poison" ? "uncertain" : "guard-release"
                inner.wire["uncertain"] = mode == "poison"
                if mode == "wrong-guard" { inner.wire["guard-client-id"] = "0" }
            }
        }
        func execute(_ command:String,_ args:[String:Any]?) throws -> [String:Any] {
            lock.lock(); defer { lock.unlock() }
            let op = command.replacingOccurrences(of:"x-omacvm-usb-coexistence-",with:"")
            history.append(op)
            if op == "prepare" { return inner.wire }
            if op == "status" { ack(); return inner.wire }
            let a = args!, call = try USBCoexistenceCodec.object(a["call"],"lease sequence")
            let n = try USBCoexistenceCodec.u64(call["sequence"]), old = try USBCoexistenceCodec.u64(inner.wire["sequence"])
            precondition(n == old + 1,"no replay or sequence guessing")
            if op == "commit" { preconditionFailure("locally revoked guard must never COMMIT") }
            if op == "revoke" {
                _ = try USBCoexistenceCodec.object(a,"call reason published guard-client-id guard-task")
                precondition(inner.driver.successfulCloses == 0)
                let id = String(try USBCoexistenceCodec.u64(a["guard-client-id"]))
                precondition(cleanup == nil || cleanup == id)
                cleanup = id; handoffs.append(a); inner.wire["guard-client-id"] = id
                inner.wire["state"] = "revoking"
                if mode == "held-ordinary" { draining = false; inner.wire["callbacks"] = "1" }
                if mode == "unsolicited-zero" {
                    // Untrusted/malformed receipt: ACK sequence did NOT accept
                    // our explicit no-guard handoff. Never permission to release.
                    inner.wire["state"] = "guard-release"
                    throw USBCoexistenceError.uncertain
                }
            }
            if op == "release" {
                precondition(inner.wire["state"] as? String == "guard-release")
                precondition(a["guard-client-id"] as? String == cleanup)
                precondition(inner.driver.successfulCloses == 1)
                inner.wire["state"] = "retired"
            }
            inner.wire["sequence"] = call["sequence"]; ack()
            if (op == "revoke" && mode == "lost-revoke") || (op == "release" && mode == "lost-release") { throw USBCoexistenceError.uncertain }
            return inner.wire
        }
    }
    func wait(_ body:(@escaping(Bool)->Void)->Void) -> Bool {
        let sem = DispatchSemaphore(value:0); var result = false
        body { result = $0; sem.signal() }; precondition(sem.wait(timeout:.now()+3) == .success); return result
    }
    for mode in ["held-ordinary","poison","lost-revoke","lost-release","wrong-guard","unsolicited-zero","failed-acquire-close","requesting-close-precommit"] {
        let peer = Peer(mode,root:root,descriptor:receipt.descriptor), initial = try USBCoexistenceStatus(wire:peer.inner.wire), ledger = USBCoexistenceLedger()
        if mode == "failed-acquire-close" {
            peer.inner.driver.snapshotHook = { n,node in if n == 3 { node.complete = false } }
        }
        if mode == "requesting-close-precommit" {
            peer.inner.driver.fail = nil
            peer.inner.driver.snapshotHook = { n,_ in if n == 4 { peer.inner.driver.event?(.requestingClose) } }
        }
        let c = USBCoexistenceCoordinator(transport:peer,launcher:initial.launcher,qemu:initial.qemu,launch:initial.launch,ledger:ledger,automaticTimers:false,taskMatches:{_ in true},guardFactory:{ r,revoke in USBRootGuard(driver:peer.inner.driver,receipt:r,lifetime:30,pollInterval:10,onRevoke:revoke) })
        let retired = DispatchSemaphore(value:0)
        c.onPhase = { if $0 == .retired { retired.signal() } }
        precondition(!wait { c.attach(target:initial.target,descriptor:receipt.descriptor,deviceID:"cleanup",completion:$0) })
        if mode == "held-ordinary" {
            precondition(peer.inner.driver.closed == 0 && !peer.commands.contains("release"))
            peer.completeDrain()
            _ = wait { c.detach(completion:$0) }
            precondition(retired.wait(timeout:.now()+3) == .success)
        }
        if mode == "failed-acquire-close" {
            precondition(peer.handoffs.first?["guard-client-id"] as? String == "5","failed local close must retain exact guard, never ID0")
            precondition(!peer.commands.contains("release"))
            peer.inner.driver.fail = nil
            _ = wait { c.detach(completion:$0) }
            precondition(retired.wait(timeout:.now()+3) == .success)
        }
        let negative = ["poison","wrong-guard","unsolicited-zero"].contains(mode)
        precondition(ledger.claim(root:1,owner:UUID()) != negative)
        if negative { precondition(peer.inner.driver.successfulCloses == 0 && !peer.commands.contains("release")) }
        else {
            precondition(peer.commands.filter { $0 == "revoke" }.count == 1)
            precondition(peer.commands.filter { $0 == "release" }.count == 1)
        }
        precondition(!peer.commands.contains("commit"))
        print("PASS cleanup final-wire \(mode): exact handoff, ACK/close/release ordering and STATUS-only lost reply")
    }
}
