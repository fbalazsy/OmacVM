import Foundation
import IOKit

// Calls the production IOKit adapter's logical boundary, never any IOKit API.
func coexistencePhysicalLossTests(root: USBScan.Entry, receipt: USBRootGuardReceipt) throws {
    func done<T>(_ body: (@escaping (T)->Void)->Void) -> T {
        let sem = DispatchSemaphore(value:0); var result:T?
        body { result = $0; sem.signal() }
        precondition(sem.wait(timeout:.now()+3) == .success); return result!
    }
    try coexistenceRegistryIterationTests()
    for mode in ["empty", "error", "null", "invalid", "present", "wrong-id", "duplicate", "invalid-after-child"] {
        var released:[UInt32] = [], reads = 0
        let lookup = USBRootGuardRegistryLookup(iterate:{
            (mode == "error" ? kIOReturnError : 0, mode == "null" ? 0 : 10)
        }, next:{ _ in
            reads += 1
            if mode == "present" || mode == "wrong-id" || mode == "invalid-after-child" { return reads == 1 ? 20 : 0 }
            if mode == "duplicate" { return reads <= 2 ? UInt32(19 + reads) : 0 }
            return 0
        }, valid:{ _ in mode != "invalid" && (mode != "invalid-after-child" || reads == 0) }, identity:{ _ in
            mode == "wrong-id" ? 999 : 1
        }, release:{ released.append($0) })
        let observed = lookup.presence(1)
        // A different, readable ID is an ordinary unrelated registry entry now,
        // not a malformed exact-service match. It must not imply presence.
        precondition(observed == (["empty","wrong-id"].contains(mode) ? .absent : (mode == "present" ? .present : .unknown)), mode)
        precondition(!released.contains(0) && Set(released).count == released.count)
        if mode == "present" || mode == "wrong-id" || mode == "invalid-after-child" { precondition(Set(released) == Set([10,20])) }
        if mode == "duplicate" { precondition(Set(released) == Set([10,20,21])) }
        print("PASS registry absence checked iterator boundary \(mode)")
    }
    do {
        let peer = CoexistencePeer(root:root,descriptor:receipt.descriptor)
        peer.drainedCommit = true
        let initial = try USBCoexistenceStatus(wire:peer.wire)
        var probes:[UInt64] = []
        let boundary = USBRootGuardCloseBoundary(close:{ 0 },presence:{ probes.append($0); return .absent })
        peer.driver.drainedClose = { try boundary.closeAfterDrain(rootID:$0,clientIDs:$1) }
        let c = USBCoexistenceCoordinator(transport:peer,launcher:initial.launcher,qemu:initial.qemu,launch:initial.launch,ledger:USBCoexistenceLedger(),automaticTimers:false,taskMatches:{ _ in true },guardFactory:{ r,revoke in USBRootGuard(driver:peer.driver,receipt:r,lifetime:30,onRevoke:revoke) })
        precondition(!done { c.attach(target:initial.target,descriptor:receipt.descriptor,deviceID:"already-drained",completion:$0) })
        precondition(Set(probes) == Set([1,5,6]), "native ID retained by drain ACK before local observation must be checked")
        print("PASS commit already drained retains native ID for physical-loss disposal")
    }
    for mode in ["qemu-death", "launcher-death"] {
        let peer = CoexistencePeer(root:root,descriptor:receipt.descriptor)
        let initial = try USBCoexistenceStatus(wire:peer.wire)
        let ledger = USBCoexistenceLedger()
        var alive = true
        let c = USBCoexistenceCoordinator(transport:peer,launcher:initial.launcher,qemu:initial.qemu,launch:initial.launch,ledger:ledger,automaticTimers:false,taskMatches:{ task in
            alive || task.pid != (mode == "qemu-death" ? initial.qemu.pid : initial.launcher.pid)
        },guardFactory:{ r,revoke in USBRootGuard(driver:peer.driver,receipt:r,lifetime:30,onRevoke:revoke) })
        precondition(done { c.attach(target:initial.target,descriptor:receipt.descriptor,deviceID:mode,completion:$0) })
        alive = false; peer.uncertainDrain = true; peer.failStatus = true
        precondition(!done { c.renewNow(completion:$0) })
        precondition(!done { c.detach(completion:$0) })
        precondition(peer.driver.closed == 0 && peer.driver.released == 0 && !ledger.claim(root:1,owner:UUID()))
        print("PASS physical loss \(mode) without matching drain remains quarantined")
    }
    for error in [kIOReturnError,kIOReturnNoDevice] {
        var calls = 0, result = error
        let boundary = USBRootGuardCloseBoundary(close:{ calls += 1; return result },presence:{ _ in .absent })
        do { try boundary.closeAfterDrain(rootID:1,clientIDs:[4,5,6]); preconditionFailure("kernel error converted to closed") } catch {}
        result = 0
        try boundary.closeAfterDrain(rootID:1,clientIDs:[4,5,6])
        precondition(calls == 2)
        print("PASS physical loss kernel close error \(error) requires successful explicit retry")
    }
    for mode in ["gone", "unknown", "present", "client-present", "generic-error", "no-device-error", "stale-ack", "revoking-zero-counts"] {
        let peer = CoexistencePeer(root:root,descriptor:receipt.descriptor)
        let initial = try USBCoexistenceStatus(wire:peer.wire)
        var probes:[UInt64] = [], disposed = 0
        let boundary = USBRootGuardCloseBoundary(close:{ mode == "generic-error" ? kIOReturnError : (mode == "no-device-error" ? kIOReturnNoDevice : KERN_SUCCESS) }, presence:{ id in
            probes.append(id)
            if mode == "unknown" { return .unknown }
            if mode == "present" || (mode == "client-present" && id == 5) { return .present }
            return .absent
        })
        peer.driver.drainedClose = { rootID, clients in
            let disposition = try boundary.closeAfterDrain(rootID:rootID,clientIDs:clients)
            disposed += 1
            return disposition
        }
        let ledger = USBCoexistenceLedger()
        let c = USBCoexistenceCoordinator(transport:peer,launcher:initial.launcher,qemu:initial.qemu,launch:initial.launch,ledger:ledger,automaticTimers:false,taskMatches:{ _ in true },guardFactory:{ r, revoke in
            USBRootGuard(driver:peer.driver,receipt:r,lifetime:30,pollInterval:10,onRevoke:revoke)
        })
        precondition(done { c.attach(target:initial.target,descriptor:receipt.descriptor,deviceID:"physical-loss",completion:$0) })
        peer.corruptEpoch = mode == "stale-ack"
        peer.pendingDrain = mode == "revoking-zero-counts"
        let released:Bool = done { c.detach(completion:$0) }
        precondition(released == (mode == "gone" || mode == "present"), "physical loss \(mode)")
        if released {
            precondition(Set(probes) == (mode == "gone" ? Set([1,5,6]) : Set([1])) && disposed == 1)
            precondition(peer.driver.released == 1 && ledger.claim(root:1,owner:UUID()))
        } else {
            precondition(disposed == 0 && peer.driver.released == 0 && !peer.commands.contains("release"))
            precondition(!ledger.claim(root:1,owner:UUID()))
            if mode == "stale-ack" || mode == "revoking-zero-counts" { precondition(probes.isEmpty && peer.driver.closed == 0) }
        }
        print("PASS physical loss production close boundary/coordinator \(mode)")
    }
}
