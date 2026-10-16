import Foundation
final class FakeRootGuard: USBRootGuardDriver {
    var root: USBScan.Entry
    var closed = 0, successfulCloses = 0, released = 0, snapshots = 0, opens = 0
    var fail: String?
    var drainedClose: ((UInt64, [UInt64]) throws -> USBRootGuardDisposition)?
    var drainAllowsGone = false
    func closeAfterDrain(rootID: UInt64, clientIDs: [UInt64], allowGone: Bool) throws -> USBRootGuardDisposition {
        drainAllowsGone = allowGone
        if let drainedClose {
            closed += 1
            let disposition = try drainedClose(rootID,clientIDs)
            if disposition == .closed { successfulCloses += 1 }
            return disposition
        }
        try close(); return .closed
    }
    var guardID: UInt64 = 5
    var extra = false
    var snapshotHook: ((Int, inout USBScan.Entry) -> Void)?
    var event: ((USBRootGuardError) -> Void)?
    var queue: DispatchQueue?
    init(root: USBScan.Entry) { self.root = root }
    func snapshot(rootID: UInt64) throws -> USBScan.Entry {
        snapshots += 1
        if fail == "snapshot\(snapshots)" { throw USBRootGuardError.lost }
        snapshotHook?(snapshots,&root)
        return root
    }
    func create(rootID: UInt64) throws {
        root.children.append(.init(registryID:guardID,className:"AppleUSBHostDeviceUserClient",properties:["IOUserClientCreator":"pid 100, launcher"]))
        if extra { root.children.append(.init(registryID:6,className:"AppleUSBHostDeviceUserClient",properties:["IOUserClientCreator":"pid 100, launcher"])) }
        if fail == "create" { throw USBRootGuardError.refused }
    }
    func monitor(queue: DispatchQueue, event: @escaping (USBRootGuardError) -> Void) throws {
        self.queue = queue; self.event = event
        if fail == "monitor" { throw USBRootGuardError.refused }
    }
    func open() throws { opens += 1; if fail == "open" { throw USBRootGuardError.refused } }
    func close() throws { closed += 1; if fail == "close" { throw USBRootGuardError.uncertain }; successfulCloses += 1 }
    func release() { released += 1; event = nil }
    func signal(_ reason: USBRootGuardError) { queue!.async { self.event?(reason) } }
}
