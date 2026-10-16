import Foundation

final class CoexistencePeer: USBQMPTransport {
    private let wireLock = NSLock()
    private var storedWire: [String: Any] = [:]
    // A queued STATUS may outlive the preceding completion. Return a retained
    // value snapshot under the same lock used when replacing the wire buffer.
    var wire: [String: Any] {
        get { wireLock.lock(); defer { wireLock.unlock() }; return storedWire }
        set { wireLock.lock(); storedWire = newValue; wireLock.unlock() }
    }
    // Main-thread assertions can overlap queued revocation/status work after a
    // completion. Publish immutable history snapshots, not a live Array buffer.
    private let historyLock = NSLock()
    private var history: [String] = []
    var commands: [String] {
        historyLock.lock(); defer { historyLock.unlock() }
        return history
    }
    var lostCommit = false
    var rejectCommit = false
    var drainedCommit = false
    var failStatus = false
    var failPrepare = false
    var corruptEpoch = false
    var uncertainDrain = false
    var pendingDrain = false
    var lostRelease = false
    var loseReleaseBeforeApply = false
    var lostRenew = false
    var sequenceHook: ((String)->Void)?
    var argumentsHook: ((String,[String:Any]?)->Void)?
    var guardID: UInt64 = 5, nativeID: UInt64 = 6
    var driver: FakeRootGuard
    init(root: USBScan.Entry, descriptor: Data) {
        driver = FakeRootGuard(root: root)
        wire = ["lease":["qemu-launch":String(repeating:"b",count:32),"launcher":["launch":String(repeating:"a",count:32),"task":["pid":100,"start-sec":"1","start-usec":"0"]],"lease-epoch":"1"],"sequence":"1","state":"guard-pending","published":["target":["root-id":"1","interface-id":"2","hid-id":"3","vendor-id":1234,"product-id":5678,"serial-utf8":"serial","descriptor-sha256":USBCoexistenceTarget.hash(descriptor)],"session":"99","cache-client-id":"4","qemu-task":["pid":200,"start-sec":"2","start-usec":"0"]],"guard-client-id":"0","native-client-id":"0","handles":"0","transfers":"0","callbacks":"0","uncertain":false]
    }
    func execute(_ command: String, _ arguments: [String: Any]?) throws -> [String: Any] {
        let op = command.replacingOccurrences(of:"x-omacvm-usb-coexistence-",with:"")
        historyLock.lock(); history.append(op); historyLock.unlock()
        sequenceHook?(op); argumentsHook?(op,arguments)
        if op == "status" && failStatus || op == "prepare" && failPrepare { throw USBCoexistenceError.uncertain }
        if op == "status" || op == "prepare" { return wire }
        if op == "commit" && rejectCommit {
            // Actual final coex_commit records cleanup ID before reservation;
            // reservation refusal keeps sequence, and neverstarted STATUS ACKs.
            wire["guard-client-id"] = arguments?["guard-client-id"]
            wire["state"] = "guard-release"
            throw USBCoexistenceError.rejected("COEX_IDENTITY")
        }
        if op == "release" && loseReleaseBeforeApply {
            loseReleaseBeforeApply = false; failStatus = true
            throw USBCoexistenceError.uncertain
        }
        wire["sequence"] = (arguments?["call"] as? [String:Any])?["sequence"]
        if op == "commit" {
            wire["state"] = "native"; wire["guard-client-id"] = String(guardID); wire["native-client-id"] = String(nativeID)
            driver.queue!.sync { driver.root.children[0].children[0].children.append(.init(registryID:nativeID,className:"IOHIDLibUserClient",properties:["IOUserClientCreator":"pid 200, qemu"])) }
            if drainedCommit { wire["state"] = "guard-release" }
            if lostCommit { throw USBCoexistenceError.uncertain }
        }
        if op == "revoke" { wire["state"] = uncertainDrain ? "uncertain" : (pendingDrain ? "revoking" : "guard-release"); wire["uncertain"] = uncertainDrain }
        if op == "renew" && lostRenew { throw USBCoexistenceError.uncertain }
        if op == "release" {
            let args = arguments ?? [:]
            let gone = args["guard-disposed-gone"] as? Bool == true
            precondition(Set(args.keys) == Set(gone ? ["call","guard-client-id","guard-closed","guard-disposed-gone"] : ["call","guard-client-id","guard-closed"]))
            precondition(args["guard-client-id"] as? String == String(guardID))
            precondition(args["guard-closed"] as? Bool == !gone)
            precondition(gone ? (driver.successfulCloses == 0 && driver.released == 1) : driver.successfulCloses == 1,
                         "release must follow truthful native drain ACK and guard disposition")
            wire["state"] = "retired"
            if lostRelease { throw USBCoexistenceError.uncertain }
        }
        if corruptEpoch { var lease = wire["lease"] as! [String:Any]; lease["lease-epoch"] = "2"; wire["lease"] = lease }
        return wire
    }
}
func coexistenceCoordinatorTests(root: USBScan.Entry, receipt: USBRootGuardReceipt) throws {
    do {
        let peer = CoexistencePeer(root:root,descriptor:receipt.descriptor)
        let finished = DispatchSemaphore(value:0)
        DispatchQueue.global().async {
            for _ in 0..<2000 { _ = try! peer.execute("x-omacvm-usb-coexistence-status",nil) }
            finished.signal()
        }
        while finished.wait(timeout:.now()) != .success {
            precondition(peer.commands.allSatisfy { $0 == "status" })
        }
        precondition(peer.commands.count == 2000)
        print("PASS inert peer history snapshots survive concurrent status/assertion")
    }
    do {
        let peer = CoexistencePeer(root:root,descriptor:receipt.descriptor)
        let finished = DispatchSemaphore(value:0)
        DispatchQueue.global().async {
            for _ in 0..<2000 {
                let snapshot = try! peer.execute("x-omacvm-usb-coexistence-status",nil)
                _ = try! USBCoexistenceStatus(wire:snapshot)
            }
            finished.signal()
        }
        for value in 1...2000 { peer.wire["sequence"] = String(value) }
        precondition(finished.wait(timeout:.now()+5) == .success)
        print("PASS inert peer wire snapshots survive concurrent STATUS decoding and mutation")
    }
    for lost in [false,true] {
        let peer = CoexistencePeer(root:root,descriptor:receipt.descriptor); peer.lostCommit = lost
        let initial = try USBCoexistenceStatus(wire:peer.wire)
        let ledger = USBCoexistenceLedger()
        let c = USBCoexistenceCoordinator(transport:peer, launcher:initial.launcher, qemu:initial.qemu, launch:initial.launch, ledger:ledger, automaticTimers:false, taskMatches:{ _ in true }, guardFactory: { r, revoke in
            USBRootGuard(driver:peer.driver,receipt:r,lifetime:5,onRevoke:revoke)
        })
        func done(_ body: (@escaping (Bool)->Void)->Void) -> Bool {
            let s = DispatchSemaphore(value:0); var value = false
            body { value = $0; s.signal() }; precondition(s.wait(timeout:.now()+3) == .success); return value
        }
        precondition(done { c.attach(target:initial.target,descriptor:receipt.descriptor,deviceID:"usbh-test",completion:$0) })
        precondition(!done { c.attach(target:initial.target,descriptor:receipt.descriptor,deviceID:"usbh-test",completion:$0) }, "duplicate attachment must not replay prepare")
        precondition(done { c.renewNow(completion:$0) })
        precondition(done { c.detach(completion:$0) })
        precondition(peer.commands.filter { $0 == "commit" }.count == 1)
        precondition(peer.commands.suffix(2) == ["revoke","release"])
        precondition(!ledger.reserve(root:1,owner:UUID(),qemuLaunch:initial.qemuLaunch,epoch:1), "consumed epoch cannot be reused")
        print("PASS coordinator actual guard lifecycle lost-reply=\(lost)")
    }
}
