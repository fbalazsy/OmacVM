import AppKit
import OmacVMUSB

// Runs the real startup model and USBRun list methods, never start()/USBWatch/AppDelegate.
@MainActor enum UIKeys {
    static func run() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var count = 0, failures = 0
        func check(_ ok: Bool, _ name: String) {
            count += 1; if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL") \(name)")
        }
        let target = USBScan.device(keyFixture())!
        precondition(target.hid != nil && target.serial == "AB")
        var ordinary = target; ordinary.hid = nil
        ordinary.interfaces = [.init(number: 0, interfaceClass: 255, users: [])]
        ordinary.location += 1
        for running in [false, true] {
            for exact in [false, true] {
              for forgetFirst in [false, true] {
                let label = "\(running ? "running" : "before")-\(exact ? "exact" : "wildcard")-forgetFirst-\(forgetFirst)"
                let folder = root.appendingPathComponent(label)
                try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let seed = USBMemory(devices: [.init(vendor: "1209", product: "0007", serial: exact ? "AB" : "", name: "ordinary", choice: .mac)])
                try! seed.save(folder: folder)
                let before = USBListBefore(folder: folder, vmName: "Omarchy", preview: [target, ordinary])
                before.start()
                let inert = KeyInert()
                let session = USBSession(vmName: "Omarchy", memory: USBMemory.load(folder: folder), machine: inert, asker: inert, clock: inert, save: { try! $0.save(folder: folder) }, log: { _ in })
                session.inFront = false
                session.plugged(target); session.plugged(ordinary)
                var config = VMConfig(); config.location = folder
                let run = USBRun(config: config, qemuPID: 0, log: { _ in })
                run.session = session // Access-only seam in an owned fixture copy; no production edit.
                func row() -> USBListRows.Row {
                    let rows = running ? session.rows : before.rows
                    return (rows.remembered + rows.plugged).first { $0.device?.location == target.location }!
                }
                // Forget without a target record must never remove an ordinary legacy entry.
                if forgetFirst {
                    if running { run.forget(row()) } else { before.forget(row()) }
                    check(USBMemory.load(folder: folder).devices == seed.devices, "\(label) initial Forget preserves ordinary record")
                }
                for plan: USBPlan in [.omarchy, .mac, .ask] {
                    if running { run.setPlan(plan, row: row()) } else { before.setPlan(plan, row: row()) }
                    let loaded = USBMemory.load(folder: folder)
                    check(loaded.plan(for: target) == plan && loaded.entry(for: target)?.hidSerial == target.hid?.serial,
                          "\(label) picker \(plan) saves exact raw target key")
                    check(loaded.devices.contains(seed.devices[0]) && loaded.plan(for: ordinary) == .mac,
                          "\(label) picker \(plan) preserves ordinary record")
                    let reloaded = USBListBefore(folder: folder, vmName: "Omarchy", preview: [target]); reloaded.start()
                    check(reloaded.rows.remembered.first { $0.device != nil }?.plan == plan,
                          "\(label) picker \(plan) reloads through actual before model")
                    reloaded.stop()
                }
                if running { run.forget(row()) } else { before.forget(row()) }
                let loaded = USBMemory.load(folder: folder)
                check(loaded.devices == seed.devices && loaded.plan(for: target) == .ask,
                      "\(label) target Forget removes only target and reloads Ask")
                before.stop(); run.stop()
              }
            }
        }
        for running in [false, true] {
          for (pair, serials) in [("unicode", ["\u{e9}", "e\u{301}"]), ("display", [" A\nB ", "AB"]), ("same", ["\u{e9}", "\u{e9}"])] {
            for sameChoice in [false, true] {
                let label = "IA-1-\(running)-\(pair)-\(sameChoice)", same = pair == "same"
                let folder = root.appendingPathComponent(label)
                try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let a = USBScan.device(keyFixture(serials[0]))!
                var b = USBScan.device(keyFixture(serials[1]))!; b.location += 1
                let seed = USBMemory(devices: [.init(vendor: "1209", product: "0007", name: "ordinary wildcard", choice: .mac)])
                try! seed.save(folder: folder)
                let before = USBListBefore(folder: folder, vmName: "Omarchy", preview: [a, b]); before.start()
                let inert = KeyInert()
                let session = USBSession(vmName: "Omarchy", memory: seed, machine: inert, asker: inert, clock: inert,
                                         save: { try! $0.save(folder: folder) }, log: { _ in })
                session.inFront = false; session.plugged(a); session.plugged(b)
                var config = VMConfig(); config.location = folder
                let run = USBRun(config: config, qemuPID: 0, log: { _ in }); run.session = session
                func row(_ d: USBDevice) -> USBListRows.Row {
                    let rows = running ? session.rows : before.rows
                    return (rows.remembered + rows.plugged).first { $0.device?.location == d.location }!
                }
                func set(_ p: USBPlan, _ d: USBDevice) {
                    if running { run.setPlan(p, row: row(d)) } else { before.setPlan(p, row: row(d)) }
                }
                set(.ask, a); set(sameChoice ? .ask : .mac, b)
                var loaded = USBMemory.load(folder: folder)
                check(loaded.devices.count == (same ? 2 : 3) && loaded.devices.contains(seed.devices[0]), "\(label) set/reload isolates ordinary and raw records")
                check(Set(loaded.devices.map(\.key)).count == loaded.devices.count, "\(label) unique SwiftUI keys")
                for plan: USBPlan in [.omarchy, .mac, .ask] {
                    set(plan, a); loaded = USBMemory.load(folder: folder)
                    check(loaded.plan(for: a) == plan && loaded.plan(for: b) == (same ? plan : sameChoice ? .ask : .mac), "\(label) key-first picker \(plan)")
                    let reloaded = USBListBefore(folder: folder, vmName: "Omarchy", preview: [a, b]); reloaded.start()
                    let rows = reloaded.rows.remembered + reloaded.rows.plugged
                    check(rows.first { $0.device?.location == a.location }?.plan == plan
                          && rows.first { $0.device?.location == b.location }?.plan == (same ? plan : sameChoice ? .ask : .mac), "\(label) actual reloaded rows bind correct twins")
                    reloaded.stop()
                }
                if running { run.forget(row(a)) } else { before.forget(row(a)) }
                loaded = USBMemory.load(folder: folder)
                check(loaded.devices.count == (same ? 1 : 2) && loaded.devices.contains(seed.devices[0]) && loaded.plan(for: a) == .ask,
                      "\(label) Forget removes only exact identity")
                if !same {
                    if running { run.forget(row(b)) } else { before.forget(row(b)) }
                    check(USBMemory.load(folder: folder).devices == seed.devices, "\(label) second Forget preserves ordinary")
                }
                before.stop(); run.stop()
            }
          }
        }
        for startsAsHID in [false, true] {
          for action in ["keep", "always", "disconnect", "connect", "connectFailed", "future"] {
            for plan in USBPlan.allCases {
                let label = "IA-2-\(startsAsHID)-\(action)-\(plan)", folder = root.appendingPathComponent(label)
                try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let boot = USBScan.device(keyFixture())!
                var tree = keyFixture(); tree.children = []
                let parent = USBScan.device(tree)!, initial = startsAsHID ? boot : parent
                var pending = keyFixture(); pending.children[0].children = []
                let incomplete = USBScan.device(pending)!
                var memory = USBMemory(); memory.remember(boot, plan)
                memory.remember(initial, action == "keep" || action == "always" ? .ask : action == "disconnect" ? .omarchy : .mac)
                try! memory.save(folder: folder)
                let inert = KeyInert(allowTransfers: true)
                let session = USBSession(vmName: "Fixture", memory: USBMemory.load(folder: folder), machine: inert, asker: inert, clock: inert,
                                         save: { try! $0.save(folder: folder) }, log: { _ in })
                session.inFront = action == "keep" || action == "always"; session.plugged(initial)
                var config = VMConfig(); config.location = folder
                let run = USBRun(config: config, qemuPID: 0, log: { _ in }); run.session = session
                func row() -> USBListRows.Row { (session.rows.remembered + session.rows.plugged).first { $0.device != nil }! }
                switch action {
                case "keep", "always": inert.answer?(USBAnswer(connect: false, always: action == "always"))
                case "disconnect": run.disconnect(row())
                case "connect", "connectFailed": inert.result = action == "connect" ? .attached : .busy; run.connect(row())
                default: run.setPlan(.omarchy, row: row())
                }
                let before = session.plugs[boot.location]!.state
                session.plugged(boot); inert.fire()
                let expected = !startsAsHID && action == "future" ? (plan == .omarchy ? USBSession.State.connected : plan == .mac ? .onMac(remembered: true) : .waiting) : before
                check(session.plugs[boot.location]?.state == expected, "\(label) actual running list current action survives publication")
                run.setPlan(plan, row: row())
                if ["keep", "always", "disconnect", "connectFailed"].contains(action) || (startsAsHID && action == "future") {
                    for _ in 0..<2 { session.plugged(incomplete); session.plugged(boot) }
                    check(session.plugs[boot.location]?.state == expected, "\(label) incomplete refresh does not apply future picker")
                }
                check(USBMemory.load(folder: folder).plan(for: boot) == plan, "\(label) actual running picker reload")
                run.stop()
            }
          }
        }
        for kind in ["same", "unicode", "product"] {
          for gap in ["none", "incomplete", "protected"] {
            for keep in [false, true] {
                let label = "IA-3-\(kind)-\(gap)-\(keep)", folder = root.appendingPathComponent(label)
                try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let a = USBScan.device(keyFixture("\u{e9}"))!
                var tree = keyFixture(kind == "unicode" ? "e\u{301}" : "\u{e9}", generation: 102)
                if kind == "product" { tree.properties["idProduct"] = 8; tree.children[0].children[0].properties["ProductID"] = 8 }
                let b = USBScan.device(tree)!
                // Actual startup controls create the distinct per-device preferences.
                let before = USBListBefore(folder: folder, vmName: "Fixture", preview: [a]); before.start()
                before.setPlan(keep ? .ask : .mac, row: before.rows.plugged[0]); before.stop()
                if kind != "same" {
                    let next = USBListBefore(folder: folder, vmName: "Fixture", preview: [b]); next.start()
                    next.setPlan(.omarchy, row: (next.rows.remembered + next.rows.plugged).first { $0.device != nil }!); next.stop()
                }
                let inert = KeyInert(allowTransfers: true)
                let session = USBSession(vmName: "Fixture", memory: USBMemory.load(folder: folder), machine: inert, asker: inert, clock: inert,
                                         save: { try! $0.save(folder: folder) }, log: { _ in })
                session.inFront = keep; session.plugged(a)
                if keep { inert.answer?(.init(connect: false, always: false)) }
                var config = VMConfig(); config.location = folder
                let run = USBRun(config: config, qemuPID: 0, log: { _ in }); run.session = session
                run.setPlan(.omarchy, row: (session.rows.remembered + session.rows.plugged).first { $0.device != nil }!)
                if gap != "none" {
                    var pending = keyFixture("\u{e9}")
                    if gap == "incomplete" { pending.children[0].children = [] }
                    else { pending.children[0].children[0].properties["ReportDescriptor"] = Data([0x05, 1, 0x09, 6, 0xa1, 1, 0xc0]) }
                    session.plugged(USBScan.device(pending)!)
                    check(!(session.rows.remembered + session.rows.plugged).contains { $0.canConnect }, "\(label) gap offers no Connect")
                }
                session.plugged(b)
                let row = (session.rows.remembered + session.rows.plugged).first { $0.device != nil }!, same = kind == "same"
                check(session.plugs[a.location]?.state == (same ? .onMac(remembered: !keep) : .connected) && inert.added == (same ? [] : [b]), "\(label) actual startup/running decision identity")
                check(row.plan == .omarchy && row.canConnect == same && row.canDisconnect == !same, "\(label) current native controls differ from future picker")
                check(USBMemory.load(folder: folder).plan(for: b) == .omarchy, "\(label) future plan survives file reload")
                run.stop()
            }
          }
        }
        print("\(count) assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
private func keyFixture(_ serial: String = " A\nB ", generation: UInt64 = 101) -> USBScan.Entry {
    let metadata: [String: Any] = ["PrimaryUsagePage": 65280, "PrimaryUsage": 1, "DeviceUsagePairs": [["DeviceUsagePage": 65280, "DeviceUsage": 1]]]
    var props = metadata
    props.merge(["VendorID": 0x1209, "ProductID": 7, "SerialNumber": serial, "Product": "Fixture", "Transport": "USB", "ReportDescriptor": Data([0x06,0,0xff,0x09,1,0xa1,1,0x75,8,0x95,60,0x81,2,0x91,2,0xc0])]) { _, b in b }
    let leaf = USBScan.Entry(registryID: 1101, className: "IOHIDInterface", properties: metadata)
    let hid = USBScan.Entry(registryID: generation, className: "AppleUserHIDDevice", conforms: ["IOHIDDevice"], properties: props, children: [leaf])
    let iface = USBScan.Entry(registryID: 2101, className: "IOUSBHostInterface", properties: ["bInterfaceClass":3,"bInterfaceSubClass":0,"bInterfaceProtocol":0], children: [hid])
    return USBScan.Entry(registryID: 3101, className: "IOUSBHostDevice", properties: ["idVendor":0x1209,"idProduct":7,"USB Serial Number":serial,"locationID":0x01100000,"USB Address":5], children: [iface])
}
private final class KeyInert: USBMachine, USBAsker, USBClock {
    let allowTransfers: Bool
    var result: USBAttachResult = .attached
    var answer: ((USBAnswer) -> Void)?
    var tasks: [() -> Void] = []
    init(allowTransfers: Bool = false) { self.allowTransfers = allowTransfers }
    var added: [USBDevice] = []
    func attach(_ d: USBDevice, done: @escaping (USBAttachResult) -> Void) { precondition(allowTransfers); added.append(d); done(result) }
    func detach(_ d: USBDevice, done: @escaping (Bool) -> Void) { precondition(allowTransfers); done(true) }
    func isAttached(_ d: USBDevice, done: @escaping (Bool) -> Void) { precondition(allowTransfers); done(true) }
    func ask(_ q: USBQuestion, answer: @escaping (USBAnswer) -> Void) { precondition(allowTransfers); self.answer = answer }
    func cancel() { answer = nil }
    func notice(title: String, text: String) {}
    func after(_ seconds: Double, _ run: @escaping () -> Void) { tasks.append(run) }
    func fire() { let pending = tasks; tasks = []; pending.forEach { $0() } }
}
