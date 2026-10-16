import Foundation
func coexistenceFailureTests(root:USBScan.Entry,receipt:USBRootGuardReceipt) throws {
    func done(_ body: (@escaping (Bool)->Void)->Void) -> Bool {
        let s = DispatchSemaphore(value:0); var value = false
        body { value = $0; s.signal() }; precondition(s.wait(timeout:.now()+3) == .success); return value
    }
    for mode in ["reject","lost-all","epoch","uncertain","lost-release","lost-renew","prepare-timeout","death","close-failure","guard-replaced"] {
        let peer = CoexistencePeer(root:root,descriptor:receipt.descriptor)
        let initial = try USBCoexistenceStatus(wire:peer.wire)
        let ledger = USBCoexistenceLedger()
        var alive = true
        let c = USBCoexistenceCoordinator(transport:peer,launcher:initial.launcher,qemu:initial.qemu,launch:initial.launch,ledger:ledger,automaticTimers:false,taskMatches:{ _ in alive },guardFactory:{ r, revoke in
            USBRootGuard(driver:peer.driver,receipt:r,lifetime:5,onRevoke:revoke)
        })
        peer.rejectCommit = mode == "reject"
        peer.lostCommit = mode == "lost-all"; peer.failStatus = mode == "lost-all"
        peer.corruptEpoch = mode == "epoch"
        peer.uncertainDrain = mode == "uncertain"
        peer.failPrepare = mode == "prepare-timeout"
        if mode == "prepare-timeout" { peer.failStatus = true }
        let attached = done { c.attach(target:initial.target,descriptor:receipt.descriptor,deviceID:"fixture",completion:$0) }
        if ["reject","lost-all","epoch","prepare-timeout"].contains(mode) {
            precondition(!attached)
            precondition(peer.commands.filter { $0 == "commit" }.count <= 1)
            if mode == "reject" { precondition(peer.driver.closed == 1 && peer.commands.last == "release") }
            else { precondition(peer.driver.closed == 0 && !peer.commands.contains("release")) }
        } else {
            precondition(attached)
            if mode == "lost-renew" { peer.lostRenew = true; precondition(done { c.renewNow(completion:$0) }); precondition(peer.commands.filter{$0 == "renew"}.count == 1) }
            if mode == "death" { alive = false; peer.failStatus = true; peer.sequenceHook = { op in if op == "revoke" { peer.uncertainDrain = true } } }
            if mode == "close-failure" { peer.driver.fail = "close" }
            if mode == "guard-replaced" { peer.sequenceHook = { op in if op == "revoke" { peer.wire["guard-client-id"] = "0" } } }
            peer.lostRelease = mode == "lost-release"
            let released = done { c.detach(completion:$0) }
            if ["uncertain","death","close-failure","guard-replaced"].contains(mode) {
                precondition(!released && !peer.commands.contains("release"))
                let count = peer.commands.filter{$0 == "revoke"}.count
                precondition(!done { c.detach(completion:$0) })
                precondition(peer.commands.filter{$0 == "revoke"}.count == count, "uncertain cleanup must not replay revocation")
                if mode == "close-failure" { precondition(peer.driver.closed == 2, "explicit retry may retry close, but never replay revoke") }
            } else { precondition(released) }
        }
        print("PASS coordinator failure \(mode)")
    }
}
