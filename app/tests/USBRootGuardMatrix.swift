import Foundation

func guardMatrix(root: USBScan.Entry, receipt: USBRootGuardReceipt) {
    var passed = 0
    func verify(_ yes: Bool, _ name: String) { precondition(yes,name); passed += 1; print("PASS \(name)") }
    func wait<T>(_ action: (@escaping (T) -> Void) -> Void) -> T {
        let sem = DispatchSemaphore(value:0); var value: T?
        action { value = $0; sem.signal() }
        precondition(sem.wait(timeout:.now()+3) == .success,"async deadline")
        return value!
    }
    func rejects(_ name: String, _ change: (inout USBScan.Entry) -> Void) {
        var candidate = root; change(&candidate)
        verify(USBRootGuardPolicy.validate(candidate,receipt:receipt,guardClientID:nil) == nil,name)
    }
    rejects("incomplete root") { $0.complete = false }
    rejects("incomplete descendant") { $0.children[0].children[0].complete = false }
    rejects("zero root") { $0.registryID = 0 }
    rejects("new root same serial") { $0.registryID = 90 }
    rejects("new session") { $0.properties["sessionID"] = 100 }
    rejects("null session") { $0.properties["sessionID"] = NSNull() }
    rejects("bool session") { $0.properties["sessionID"] = true }
    rejects("float session") { $0.properties["sessionID"] = 99.5 }
    rejects("new interface generation") { $0.children[0].registryID = 90 }
    rejects("new HID generation") { $0.children[0].children[0].registryID = 90 }
    rejects("replaced cache same PID") { $0.children[1].registryID = 90 }
    rejects("foreign cache creator") { $0.children[1].properties["IOUserClientCreator"] = "pid 201, qemu" }
    rejects("missing creator") { $0.children[1].properties.removeValue(forKey:"IOUserClientCreator") }
    rejects("display name not provenance") { $0.children[1].properties["IOUserClientCreator"] = "qemu 200" }
    rejects("creator numeric prefix collision") { $0.children[1].properties["IOUserClientCreator"] = "pid 2001, qemu" }
    rejects("cache unknown child") { $0.children[1].children = [.init(registryID:80,className:"Unknown")] }
    rejects("extra own cache") { var c = $0.children[1]; c.registryID = 80; $0.children.append(c) }
    rejects("unknown descendant") { $0.children.append(.init(registryID:80,className:"Unknown")) }
    rejects("duplicate registry ID") { $0.children.append($0.children[0]) }
    rejects("mixed interfaces") { var c = $0.children[0]; c.registryID = 80; $0.children.append(c) }
    rejects("boot protocol") { $0.children[0].properties["bInterfaceProtocol"] = 1 }
    rejects("keyboard usage") { $0.children[0].children[0].properties["PrimaryUsagePage"] = 1 }
    rejects("FIDO usage") { $0.children[0].children[0].properties["PrimaryUsagePage"] = 0xf1d0 }
    rejects("missing usage pairs") { $0.children[0].children[0].properties.removeValue(forKey:"DeviceUsagePairs") }
    rejects("unknown metadata type") { $0.children[0].properties["bInterfaceClass"] = NSNull() }
    rejects("descriptor replacement") { $0.children[0].children[0].properties["ReportDescriptor"] = Data([0]) }
    rejects("serial replacement") { $0.properties["USB Serial Number"] = "other" }
    rejects("raw serial no normalization") { $0.children[0].children[0].properties["SerialNumber"] = "serial " }
    for index in [0,1] {
        rejects("Built-In child \(index)") { $0.children[index].properties["Built-In"] = true }
        rejects("null Built-In child \(index)") { $0.children[index].properties["Built-In"] = NSNull() }
        rejects("lowercase built-in child \(index)") { $0.children[index].properties["built-in"] = Data() }
    }
    rejects("Built-In root") { $0.properties["Built-In"] = true }
    rejects("Built-In HID") { $0.children[0].children[0].properties["Built-In"] = true }
    rejects("protected cache metadata") { $0.children[1].properties["PrimaryUsagePage"] = 1; $0.children[1].properties["PrimaryUsage"] = 6 }
    let initial = USBRootGuardPolicy.validate(root,receipt:receipt,guardClientID:nil)!
    var telemetry = root
    telemetry.children[0].children[0].properties["DebugState"] = ["InputReportCount":2]
    verify(USBRootGuardPolicy.validate(telemetry,receipt:receipt,guardClientID:nil) == initial,"HID telemetry not identity")
    telemetry.children[0].children[0].properties["Built-In"] = true
    verify(USBRootGuardPolicy.validate(telemetry,receipt:receipt,guardClientID:nil) == nil,"telemetry never masks protected metadata")
    var metadata = root
    metadata.children[0].properties["FuturePolicyMetadata"] = 1
    verify(USBRootGuardPolicy.validate(metadata,receipt:receipt,guardClientID:nil) != initial,"no arbitrary equality whitelist")
    metadata = root; metadata.children[0].properties["DebugState"] = 1
    verify(USBRootGuardPolicy.validate(metadata,receipt:receipt,guardClientID:nil) != initial,"only HID DebugState excluded")

    for failure in ["snapshot1","create","snapshot2","monitor","open","snapshot3"] {
        let driver = FakeRootGuard(root:root); driver.fail = failure
        let owner = USBRootGuard(driver:driver,receipt:receipt,lifetime:5)
        let result: Result<USBRootGuardTicket,USBRootGuardError> = wait { owner.acquire($0) }
        verify((try? result.get()) == nil,"refuses \(failure)")
        verify(driver.released == 1 && driver.closed == (failure == "snapshot3" ? 1 : 0),"cleanup \(failure)")
    }
    do {
        let driver = FakeRootGuard(root:root); driver.extra = true
        let owner = USBRootGuard(driver:driver,receipt:receipt,lifetime:5)
        let result: Result<USBRootGuardTicket,USBRootGuardError> = wait { owner.acquire($0) }
        verify((try? result.get()) == nil && driver.opens == 0 && driver.released == 1,"multiple causal delta refused before open")
    }
    for reason in [USBRootGuardError.requestingClose,.lost,.expired] {
        let driver = FakeRootGuard(root:root)
        let revocation = DispatchSemaphore(value:0)
        let owner = USBRootGuard(driver:driver,receipt:receipt,lifetime:reason == .expired ? 0.03 : 5,pollInterval:0.01,
            onRevoke:{ _,_ in revocation.signal() })
        let result: Result<USBRootGuardTicket,USBRootGuardError> = wait { owner.acquire($0) }
        let ticket = try! result.get()
        if reason != .expired { driver.signal(reason) }
        verify(revocation.wait(timeout:.now()+2) == .success,"observes \(reason)")
        verify(driver.closed == 0 && driver.released == 0,"holds until drain \(reason)")
        let wrong = USBRootGuardTicket(binding:.init(launcher:UUID(),qemu:receipt.binding.qemu,epoch:receipt.binding.epoch,request:receipt.binding.request),guardClientID:5)
        let stale: Result<USBRootGuardDisposition,USBRootGuardError> = wait { owner.acknowledgeDrain(wrong,completion:$0) }
        verify((try? stale.get()) == nil && driver.closed == 0,"stale ACK cannot close \(reason)")
        let end: Result<USBRootGuardDisposition,USBRootGuardError> = wait { owner.acknowledgeDrain(ticket,completion:$0) }
        verify((try? end.get()) != nil && driver.closed == 1 && driver.released == 1,"drain closes \(reason)")
        let replay: Result<USBRootGuardDisposition,USBRootGuardError> = wait { owner.acknowledgeDrain(ticket,completion:$0) }
        verify((try? replay.get()) == nil && driver.closed == 1,"ACK replay refused \(reason)")
        let reacquire: Result<USBRootGuardTicket,USBRootGuardError> = wait { owner.acquire($0) }
        verify((try? reacquire.get()) == nil,"acquire replay refused \(reason)")
    }
    for mutation in ["replace","disconnect","null","foreign","guardmetadata"] {
        let driver = FakeRootGuard(root:root)
        driver.snapshotHook = { count, root in
            guard count >= 4 else { return }
            switch mutation {
            case "replace": root.children[2].registryID = 80
            case "disconnect": root.complete = false
            case "null": root.properties["sessionID"] = NSNull()
            case "guardmetadata": root.children[2].properties["PrimaryUsagePage"] = 65280; root.children[2].properties["PrimaryUsage"] = 2
            default: root.children.append(.init(registryID:81,className:"IOHIDLibUserClient"))
            }
        }
        let sem = DispatchSemaphore(value:0)
        let owner = USBRootGuard(driver:driver,receipt:receipt,lifetime:5,pollInterval:0.01,onRevoke:{ _,_ in sem.signal() })
        let result: Result<USBRootGuardTicket,USBRootGuardError> = wait { owner.acquire($0) }
        let ticket = try! result.get()
        verify(sem.wait(timeout:.now()+2) == .success && driver.closed == 0,"live \(mutation) revokes without close")
        let _: Result<USBRootGuardDisposition,USBRootGuardError> = wait { owner.acknowledgeDrain(ticket,completion:$0) }
    }
    do {
        let driver = FakeRootGuard(root:root)
        let owner = USBRootGuard(driver:driver,receipt:receipt,lifetime:5)
        let result: Result<USBRootGuardTicket,USBRootGuardError> = wait { owner.acquire($0) }
        let ticket = try! result.get()
        let _: Bool = wait { cb in owner.revoke { cb(true) } }
        driver.fail = "close"
        let bad: Result<USBRootGuardDisposition,USBRootGuardError> = wait { owner.acknowledgeDrain(ticket,completion:$0) }
        verify((try? bad.get()) == nil && driver.released == 0,"close failure retains ownership")
        driver.fail = nil
        let good: Result<USBRootGuardDisposition,USBRootGuardError> = wait { owner.acknowledgeDrain(ticket,completion:$0) }
        verify((try? good.get()) != nil && driver.released == 1,"close retry after same drain")
    }
    do {
        let driver = FakeRootGuard(root:root)
        driver.snapshotHook = { count, root in if count == 3 { root.complete = false } }
        driver.fail = "close"
        let sem = DispatchSemaphore(value:0)
        var cleanupTicket: USBRootGuardTicket?
        let owner = USBRootGuard(driver:driver,receipt:receipt,lifetime:5,onRevoke:{ ticket,_ in cleanupTicket = ticket; sem.signal() })
        let result: Result<USBRootGuardTicket,USBRootGuardError> = wait { owner.acquire($0) }
        verify((try? result.get()) == nil && driver.released == 0,"failed postcheck close retains handle")
        verify(sem.wait(timeout:.now()+0.1) == .success && cleanupTicket != nil,"failed precommit cleanup publishes retry ticket")
        driver.fail = nil
        let end: Result<USBRootGuardDisposition,USBRootGuardError> = wait { owner.acknowledgeDrain(cleanupTicket!,completion:$0) }
        verify((try? end.get()) != nil && driver.released == 1,"failed precommit cleanup recoverable")
    }
    for clientID in [UInt64(6), UInt64(0), UInt64(4), UInt64(7)] {
        let driver = FakeRootGuard(root:root)
        driver.snapshotHook = { count, root in
            if count == 4 { root.children[0].children[0].children.append(.init(registryID:6,className:"IOHIDLibUserClient",properties:["IOUserClientCreator":"pid 200, qemu"])) }
        }
        let owner = USBRootGuard(driver:driver,receipt:receipt,lifetime:5,pollInterval:10)
        let result: Result<USBRootGuardTicket,USBRootGuardError> = wait { owner.acquire($0) }
        let ticket = try! result.get()
        let observed: Bool = wait { owner.observeNativeClient(clientID,ticket:ticket,completion:$0) }
        verify(observed == (clientID == 6),"typed native exact client \(clientID)")
        if observed {
            let repeated: Bool = wait { owner.observeNativeClient(clientID,ticket:ticket,completion:$0) }
            verify(!repeated,"native receipt replay refused")
        }
        let _: Bool = wait { cb in owner.revoke { cb(true) } }
        let _: Result<USBRootGuardDisposition,USBRootGuardError> = wait { owner.acknowledgeDrain(ticket,completion:$0) }
    }
    do {
        let driver = FakeRootGuard(root:root)
        let owner = USBRootGuard(driver:driver,receipt:receipt,lifetime:5,pollInterval:10)
        let result: Result<USBRootGuardTicket,USBRootGuardError> = wait { owner.acquire($0) }
        let ticket = try! result.get()
        let premature: Result<USBRootGuardDisposition,USBRootGuardError> = wait { owner.acknowledgeDrain(ticket,completion:$0) }
        verify((try? premature.get()) == nil && driver.closed == 0,"drain before revocation refused")
        let _: Bool = wait { cb in owner.revoke { cb(true) } }
        let b = receipt.binding
        for wrong in [USBRootGuardBinding(launcher:UUID(),qemu:b.qemu,epoch:b.epoch,request:b.request),
                      .init(launcher:b.launcher,qemu:UUID(),epoch:b.epoch,request:b.request),
                      .init(launcher:b.launcher,qemu:b.qemu,epoch:b.epoch+1,request:b.request),
                      .init(launcher:b.launcher,qemu:b.qemu,epoch:b.epoch,request:UUID())] {
            let ack = USBRootGuardTicket(binding:wrong,guardClientID:5)
            let response: Result<USBRootGuardDisposition,USBRootGuardError> = wait { owner.acknowledgeDrain(ack,completion:$0) }
            verify((try? response.get()) == nil && driver.closed == 0,"all binding components enforced")
        }
        let wrongClient = USBRootGuardTicket(binding:b,guardClientID:80)
        let response: Result<USBRootGuardDisposition,USBRootGuardError> = wait { owner.acknowledgeDrain(wrongClient,completion:$0) }
        verify((try? response.get()) == nil && driver.closed == 0,"guard ID bound to drain")
        let _: Result<USBRootGuardDisposition,USBRootGuardError> = wait { owner.acknowledgeDrain(ticket,completion:$0) }
    }
    let sameTask = USBRootGuardReceipt(binding:receipt.binding,rootID:1,sessionID:99,interfaceID:2,hidID:3,cacheClientID:4,qemuPID:100,launcherPID:100,serial:receipt.serial,descriptor:receipt.descriptor)
    verify(USBRootGuardPolicy.validate(root,receipt:sameTask,guardClientID:nil) == nil,"same task cannot supply separate-task witness")
    for badDelta in ["null","foreign","unknown"] {
        let driver = FakeRootGuard(root:root)
        driver.snapshotHook = { count, root in
            guard count == 2 else { return }
            if badDelta == "null" { root.children.removeLast() }
            else if badDelta == "foreign" { root.children[2].properties["IOUserClientCreator"] = "pid 999, other" }
            else { root.children[2].className = "UnknownClient" }
        }
        let owner = USBRootGuard(driver:driver,receipt:receipt,lifetime:5)
        let result: Result<USBRootGuardTicket,USBRootGuardError> = wait { owner.acquire($0) }
        verify((try? result.get()) == nil && driver.opens == 0 && driver.released == 1,"causal delta \(badDelta) fails closed")
    }
    print("MATRIX assertions=\(passed)")
}
