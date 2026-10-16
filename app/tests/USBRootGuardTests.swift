import Foundation

@main struct RootGuardTests {
    static func main() throws {
        setbuf(stdout,nil)
        let binding = USBRootGuardBinding(launcher: UUID(), qemu: UUID(), epoch: 1, request: UUID())
        let descriptor = Data([0x06,0x00,0xff,0x09,0x01,0xa1,0x01,0x75,0x08,0x95,0x01,0x81,0x02,0xc0])
        let usage: [String: Any] = ["PrimaryUsagePage": 65280, "PrimaryUsage": 1,
            "DeviceUsagePairs": [["DeviceUsagePage":65280,"DeviceUsage":1]]]
        var hp = usage
        hp.merge(["VendorID":1234,"ProductID":5678,"Transport":"USB","SerialNumber":"serial", "Product":"board","ReportDescriptor":descriptor]) { _, b in b }
        let hid = USBScan.Entry(registryID: 3, className: "IOHIDDevice", properties: hp)
        let interface = USBScan.Entry(registryID: 2, className: "IOUSBHostInterface", properties: ["bInterfaceClass":3,"bInterfaceSubClass":0,"bInterfaceProtocol":0], children:[hid])
        let cache = USBScan.Entry(registryID: 4, className: "AppleUSBHostDeviceUserClient", properties:["IOUserClientCreator":"pid 200, qemu"])
        let root = USBScan.Entry(registryID:1,className:"IOUSBHostDevice",properties:["idVendor":1234,"idProduct":5678,"sessionID":UInt64(99),"USB Serial Number":"serial"],children:[interface,cache])
        let receipt = USBRootGuardReceipt(binding:binding, rootID:1, sessionID:99, interfaceID:2, hidID:3, cacheClientID:4, qemuPID:200, launcherPID:100, serial:Data("serial".utf8), descriptor:descriptor)
        if let selection = ProcessInfo.processInfo.environment["COEX_INTEROP_CASE"] {
            try coexistenceInteropTests(root:root,receipt:receipt,selection:selection); return
        }
        if ProcessInfo.processInfo.environment["PR427_REVIEW"] == "1" {
            try coexistenceReviewTests(root:root,receipt:receipt); return
        }
        try coexistenceCleanupTests(root:root,receipt:receipt)
        if ProcessInfo.processInfo.environment["COEX_CLEANUP_ONLY"] == "1" { return }
        try coexistenceInteropTests(root:root,receipt:receipt,selection:"all",finishProcess:false)
        try coexistenceGuardGoneTests(root:root,receipt:receipt)
        try coexistencePhysicalLossTests(root:root,receipt:receipt)
        try coexistenceModeCycleTests(root:root,receipt:receipt)
        try coexistenceHarnessTests(root:root,receipt:receipt)
        try coexistenceReviewTests(root:root,receipt:receipt)
        precondition(USBRootGuardPolicy.validate(root, receipt: receipt, guardClientID:nil) != nil, "exact cache exception must pass full policy")
        let initial = USBRootGuardPolicy.validate(root, receipt:receipt, guardClientID:nil)!
        var changedCache = root
        changedCache.children[1].properties["PrimaryUsagePage"] = 65280
        changedCache.children[1].properties["PrimaryUsage"] = 2
        precondition(USBRootGuardPolicy.validate(changedCache, receipt:receipt, guardClientID:nil) != initial, "cache protected metadata must be immutable too")
        print("PASS exact-cache policy")
        let shim = FakeRootGuard(root: root)
        let owner = USBRootGuard(driver: shim, receipt: receipt, lifetime: 10, pollInterval: 10)
        let opened = DispatchSemaphore(value:0)
        var ticket: USBRootGuardTicket?
        owner.acquire { result in ticket = try? result.get(); opened.signal() }
        precondition(opened.wait(timeout:.now()+2) == .success)
        precondition(ticket?.guardClientID == 5)
        let revoked = DispatchSemaphore(value:0)
        owner.revoke(reason:.requestingClose) { revoked.signal() }
        precondition(revoked.wait(timeout:.now()+2) == .success)
        precondition(shim.closed == 0, "requesting-close MUST wait for drain ACK")
        let done = DispatchSemaphore(value:0)
        owner.acknowledgeDrain(ticket!) { result in
            precondition((try? result.get()) != nil); done.signal()
        }
        precondition(done.wait(timeout:.now()+2) == .success)
        precondition(shim.closed == 1 && shim.released == 1)
        print("PASS acquire revoke drain close ordering")
        guardMatrix(root:root,receipt:receipt)
        coexistenceGuardTests(root:root,receipt:receipt)
        try coexistenceCodecTests()
        try coexistenceCoordinatorTests(root:root,receipt:receipt)
        coexistenceInventoryTests(root:root)
        coexistenceSessionTests(root:root)
        try coexistenceFailureTests(root:root,receipt:receipt)
        try coexistenceMachineTests(root:root,receipt:receipt)
        try coexistenceLifetimeTests(root:root,receipt:receipt)
    }
}
