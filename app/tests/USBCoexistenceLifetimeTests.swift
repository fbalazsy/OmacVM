import Foundation
func coexistenceLifetimeTests(root:USBScan.Entry,receipt:USBRootGuardReceipt) throws {
    func done(_ body: (@escaping (Bool)->Void)->Void) -> Bool {
        let s = DispatchSemaphore(value:0); var value=false
        body { value=$0; s.signal() }; precondition(s.wait(timeout:.now()+3) == .success); return value
    }
    let peer=CoexistencePeer(root:root,descriptor:receipt.descriptor)
    let initial=try USBCoexistenceStatus(wire:peer.wire)
    let ledger=USBCoexistenceLedger()
    func owner(_ auto:Bool) -> USBCoexistenceCoordinator {
        USBCoexistenceCoordinator(transport:peer,launcher:initial.launcher,qemu:initial.qemu,launch:initial.launch,ledger:ledger,automaticTimers:auto,taskMatches:{_ in true},guardFactory:{ r,revoke in USBRootGuard(driver:peer.driver,receipt:r,lifetime:5,onRevoke:revoke) })
    }
    let c=owner(true), second=owner(false)
    precondition(done { c.attach(target:initial.target,descriptor:receipt.descriptor,deviceID:"lifetime",completion:$0) })
    precondition(!done { second.attach(target:initial.target,descriptor:receipt.descriptor,deviceID:"duplicate-root",completion:$0) })
    Thread.sleep(forTimeInterval:6.2)
    // A synchronous queue barrier via renewNow ensures the preceding timer work
    // is complete before reading the fake's log.
    precondition(done { c.renewNow(completion:$0) })
    precondition(peer.commands.filter{$0 == "renew"}.count >= 5 && peer.driver.closed == 0)
    precondition(peer.commands.filter{$0 == "prepare"}.count == 1)
    precondition(done { c.detach(completion:$0) })
    print("PASS production 1s timer survives 5s guard lifetime; one root owner")

    let stoppingPeer=CoexistencePeer(root:root,descriptor:receipt.descriptor)
    let stopping=USBCoexistenceCoordinator(transport:stoppingPeer,launcher:initial.launcher,qemu:initial.qemu,launch:initial.launch,ledger:USBCoexistenceLedger(),automaticTimers:false,taskMatches:{_ in true},guardFactory:{r,revoke in USBRootGuard(driver:stoppingPeer.driver,receipt:r,lifetime:5,onRevoke:revoke) })
    stoppingPeer.sequenceHook = { op in if op == "commit" { stopping.stop() } }
    precondition(!done { stopping.attach(target:initial.target,descriptor:receipt.descriptor,deviceID:"stop",completion:$0) })
    precondition(stoppingPeer.driver.closed == 1 && stoppingPeer.commands.last == "release")
    print("PASS launcher stop during commit drains before close/release")
}
