import Foundation

// Inert kernel/task/transport only; real guard queue + coordinator + close boundary.
func coexistenceGuardGoneTests(root: USBScan.Entry, receipt: USBRootGuardReceipt) throws {
    func done<T>(_ operation: (@escaping (T)->Void)->Void) -> T {
        let sem = DispatchSemaphore(value:0); var value:T?
        operation { value = $0; sem.signal() }
        precondition(sem.wait(timeout:.now()+3) == .success); return value!
    }
    for mode in ["gone", "root-live", "guard-live", "native-live", "unknown", "generic-error", "missing-native", "zero-native", "duplicate-native", "not-drained"] {
        var closes = 0, releases = 0, probes:[UInt64] = []
        let boundary = USBRootGuardCloseBoundary(close:{ closes += 1; return mode == "generic-error" ? -1 : -536870208 },presence:{ id in
            probes.append(id)
            if mode == "unknown" { return .unknown }
            if (mode == "root-live" && id == 1) || (mode == "guard-live" && id == 5) || (mode == "native-live" && id == 6) { return .present }
            return .absent
        },dispose:{ releases += 1 })
        let clients:[UInt64] = mode == "missing-native" ? [5] : (mode == "zero-native" ? [5,0] : (mode == "duplicate-native" ? [5,5] : [5,6]))
        let result = try? boundary.closeAfterDrain(rootID:1,clientIDs:clients,allowGone:mode != "not-drained")
        precondition(result == (mode == "gone" ? .disposedGone : nil),mode)
        precondition(releases == (mode == "gone" ? 1 : 0))
        if mode == "gone" {
            precondition(probes == [1,5,6,1,5,6])
            precondition((try? boundary.closeAfterDrain(rootID:1,clientIDs:[5,6])) == .disposedGone)
            precondition(closes == 1 && releases == 1)
        }
        print("PASS v5 guard disposal exact boundary \(mode)")
    }
    do {
        var closes = 0, releases = 0, postUnknown = true
        let boundary = USBRootGuardCloseBoundary(close:{ closes += 1; return -536870208 },presence:{ _ in
            releases > 0 && postUnknown ? .unknown : .absent
        },dispose:{ releases += 1 })
        do { try boundary.closeAfterDrain(rootID:1,clientIDs:[5,6]); preconditionFailure("post-release unknown must quarantine") }
        catch { precondition(error as? USBRootGuardError == .disposalProofPending) }
        precondition((try? boundary.closeAfterDrain(rootID:1,clientIDs:[5,7])) == nil)
        postUnknown = false
        precondition((try? boundary.closeAfterDrain(rootID:1,clientIDs:[5,6])) == .disposedGone)
        precondition(closes == 1 && releases == 1)
        print("PASS v5 disposed logical proof-pending retries only exact IDs without second Close/Release")
    }
    for mode in ["gone", "held-ack", "stale-epoch", "lost-release", "lost-release-status", "lost-release-unapplied", "post-unknown", "live-native"] {
        let peer = CoexistencePeer(root:root,descriptor:receipt.descriptor)
        let initial = try USBCoexistenceStatus(wire:peer.wire)
        var closes = 0, postUnknown = mode == "post-unknown", releasePayloads:[[String:Any]] = []
        let boundary = USBRootGuardCloseBoundary(close:{ closes += 1; return -536870208 },presence:{ id in
            if mode == "live-native" && id == 6 { return .present }
            return peer.driver.released > 0 && postUnknown ? .unknown : .absent
        },dispose:{
            precondition(peer.wire["state"] as? String == "guard-release")
            precondition(peer.driver.queue != nil)
            peer.driver.release()
        })
        peer.driver.drainedClose = { try boundary.closeAfterDrain(rootID:$0,clientIDs:$1,allowGone:peer.driver.drainAllowsGone) }
        peer.argumentsHook = { op,args in
            if op == "release" {
                let args = args!
                precondition(Set(args.keys) == Set(["call","guard-client-id","guard-closed","guard-disposed-gone"]))
                precondition(args["guard-client-id"] as? String == "5" && args["guard-closed"] as? Bool == false && args["guard-disposed-gone"] as? Bool == true)
                releasePayloads.append(args)
                if mode == "lost-release-status" { peer.failStatus = true }
            }
        }
        let ledger = USBCoexistenceLedger()
        let coordinator = USBCoexistenceCoordinator(transport:peer,launcher:initial.launcher,qemu:initial.qemu,launch:initial.launch,ledger:ledger,automaticTimers:false,taskMatches:{ _ in true },guardFactory:{ r,revoke in
            USBRootGuard(driver:peer.driver,receipt:r,lifetime:30,pollInterval:10,onRevoke:revoke)
        })
        precondition(done { coordinator.attach(target:initial.target,descriptor:receipt.descriptor,deviceID:"v5-gone",completion:$0) })
        peer.pendingDrain = mode == "held-ack"
        peer.corruptEpoch = mode == "stale-epoch"
        peer.lostRelease = mode == "lost-release" || mode == "lost-release-status"
        peer.loseReleaseBeforeApply = mode == "lost-release-unapplied"
        let result:Bool = done { coordinator.detach(completion:$0) }
        let immediately = mode == "gone" || mode == "lost-release"
        precondition(result == immediately,mode)
        if mode == "held-ack" {
            precondition(closes == 0 && peer.driver.released == 0 && releasePayloads.isEmpty)
            peer.pendingDrain = false; peer.wire["state"] = "guard-release"
            // The guard's already-queued revoke callback may have started STATUS
            // recovery. Wait through it instead of requiring a concurrent detach
            // to win the coordinator's single-mutator slot.
            var retired = false
            for _ in 0..<20 {
                if done({ coordinator.detach(completion:$0) }) { retired = true; break }
                Thread.sleep(forTimeInterval:0.01)
            }
            precondition(retired)
        } else if mode == "post-unknown" {
            precondition(closes == 1 && peer.driver.released == 1 && releasePayloads.isEmpty)
            precondition(!ledger.claim(root:1,owner:UUID()))
            postUnknown = false
            precondition(done { coordinator.detach(completion:$0) })
        } else if mode == "lost-release-status" || mode == "lost-release-unapplied" {
            precondition(closes == 1 && peer.driver.released == 1 && releasePayloads.count == 1)
            peer.failStatus = false
            precondition(done { coordinator.detach(completion:$0) })
        }
        if mode == "stale-epoch" || mode == "live-native" {
            precondition(peer.driver.released == 0 && releasePayloads.isEmpty && !ledger.claim(root:1,owner:UUID()))
            if mode == "stale-epoch" { precondition(closes == 0) }
        } else {
            precondition(closes == 1 && peer.driver.released == 1 && peer.driver.successfulCloses == 0)
            precondition(releasePayloads.count == (mode == "lost-release-unapplied" ? 2 : 1) && ledger.claim(root:1,owner:UUID()))
        }
        print("PASS v5 coordinator truthful terminal disposal \(mode)")
    }
    // Identity changes after irreversible disposal must never trigger proof for a
    // successor, nor destroy twice; a correct original ACK can still finish proof.
    do {
        let driver = FakeRootGuard(root:root)
        var closes = 0, unknown = true
        let boundary = USBRootGuardCloseBoundary(close:{ closes += 1; return -536870208 },presence:{ _ in
            driver.released > 0 && unknown ? .unknown : .absent
        },dispose:{ driver.release() })
        driver.drainedClose = { try boundary.closeAfterDrain(rootID:$0,clientIDs:$1,allowGone:driver.drainAllowsGone) }
        let owner = USBRootGuard(driver:driver,receipt:receipt,lifetime:30,pollInterval:10)
        let ticket = try done { owner.acquire($0) }.get()
        // Validated ACK can arrive before a local observeNativeClient callback.
        let _:Bool = done { cb in owner.revoke { cb(true) } }
        let first:Result<USBRootGuardDisposition,USBRootGuardError> = done { owner.acknowledgeDrain(ticket,nativeClientID:6,completion:$0) }
        precondition((try? first.get()) == nil && driver.released == 1)
        for badID in [UInt64?.none,0,7] {
            let stale:Result<USBRootGuardDisposition,USBRootGuardError> = done { owner.acknowledgeDrain(ticket,nativeClientID:badID,completion:$0) }
            precondition((try? stale.get()) == nil)
        }
        let b = ticket.binding
        let staleTicket = USBRootGuardTicket(binding:.init(launcher:b.launcher,qemu:b.qemu,epoch:b.epoch+1,request:b.request),guardClientID:5)
        let stale:Result<USBRootGuardDisposition,USBRootGuardError> = done { owner.acknowledgeDrain(staleTicket,nativeClientID:6,completion:$0) }
        precondition((try? stale.get()) == nil)
        unknown = false
        let success:Result<USBRootGuardDisposition,USBRootGuardError> = done { owner.acknowledgeDrain(ticket,nativeClientID:6,completion:$0) }
        precondition((try? success.get()) == .disposedGone)
        let replay:Result<USBRootGuardDisposition,USBRootGuardError> = done { owner.acknowledgeDrain(ticket,nativeClientID:6,completion:$0) }
        precondition((try? replay.get()) == nil && closes == 1 && driver.released == 1)
        print("PASS v5 typed ACK exact native/ticket/epoch proof-pending and completed destruction replay")
    }
}
