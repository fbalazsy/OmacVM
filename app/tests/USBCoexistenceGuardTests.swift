import Foundation

func coexistenceGuardTests(root: USBScan.Entry, receipt: USBRootGuardReceipt) {
    func wait<T>(_ operation: (@escaping (T) -> Void) -> Void) -> T {
        let s = DispatchSemaphore(value: 0); var value: T?
        operation { value = $0; s.signal() }
        precondition(s.wait(timeout: .now()+2) == .success)
        return value!
    }
    let driver = FakeRootGuard(root: root)
    let guardOwner = USBRootGuard(driver: driver, receipt: receipt, lifetime: 0.12, pollInterval: 0.01)
    let ticket = try! wait { guardOwner.acquire($0) }.get()
    precondition(wait { guardOwner.beginCommit(ticket, completion: $0) })
    driver.queue!.sync {
        driver.root.children[0].children[0].children.append(.init(registryID: 6, className: "IOHIDLibUserClient", properties: ["IOUserClientCreator":"pid 200, qemu"]))
    }
    Thread.sleep(forTimeInterval: 0.04)
    precondition(wait { guardOwner.observeNativeClient(6, ticket: ticket, completion: $0) }, "commit receipt must reconcile before native polling")
    for _ in 0..<4 {
        Thread.sleep(forTimeInterval: 0.05)
        precondition(wait { guardOwner.renew(ticket, completion: $0) }, "bounded renewal must outlive original deadline")
    }
    let _: Bool = wait { done in guardOwner.revoke { done(true) } }
    precondition(!wait { guardOwner.renew(ticket, completion: $0) })
    precondition((try? wait { guardOwner.acknowledgeDrain(ticket, completion: $0) }.get()) != nil)
    let lateDriver = FakeRootGuard(root:root)
    let late = USBRootGuard(driver:lateDriver,receipt:receipt,lifetime:0.12,pollInterval:1)
    let lateTicket = try! wait { late.acquire($0) }.get()
    precondition(wait { late.beginCommit(lateTicket,completion:$0) })
    lateDriver.queue!.sync {
        lateDriver.root.children[0].children[0].children.append(.init(registryID:6,className:"IOHIDLibUserClient",properties:["IOUserClientCreator":"pid 200, qemu"]))
        lateDriver.snapshotHook = { _,_ in Thread.sleep(forTimeInterval:0.15) }
    }
    precondition(!wait { late.observeNativeClient(6,ticket:lateTicket,completion:$0) }, "snapshot spanning deadline cannot commit")
    let _: Bool = wait { done in late.revoke { done(true) } }
    precondition((try? wait { late.acknowledgeDrain(lateTicket,completion:$0) }.get()) != nil)
    print("PASS guard commit phase and bounded renewal")
}
