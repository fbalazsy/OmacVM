import Foundation
import OmacVMUSB

// Synthetic registry trees: never enumerate or open a host device.
let vendorDescriptor = Data([0x06, 0x00, 0xff, 0x09, 0x01, 0xa1, 0x01,
                             0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x3c,
                             0x09, 0x01, 0x81, 0x02, 0x09, 0x01, 0x91, 0x02, 0xc0])
func hidTree(registryID: UInt64 = 0x100000123, serial: String = "test-boot-01") -> USBScan.Entry {
    let hid = USBScan.Entry(registryID: registryID, className: "AppleUserHIDDevice",
                            conforms: ["IOHIDDevice"], properties: [
        "VendorID": 0x1209, "ProductID": 0x0007, "SerialNumber": serial,
        "Product": "Vendor Bootloader", "Transport": "USB", "ReportDescriptor": vendorDescriptor,
        "PrimaryUsagePage": 65280, "PrimaryUsage": 1,
        "DeviceUsagePairs": [["DeviceUsagePage": 65280, "DeviceUsage": 1]],
    ])
    let interface = USBScan.Entry(registryID: 22, className: "IOUSBHostInterface",
                                  conforms: ["IOUSBHostInterface"], properties: [
        "bInterfaceNumber": 0, "bInterfaceClass": 3, "bInterfaceSubClass": 0, "bInterfaceProtocol": 0,
    ], children: [hid])
    return USBScan.Entry(registryID: 11, className: "IOUSBHostDevice", conforms: ["IOUSBHostDevice"], properties: [
        "idVendor": 0x1209, "idProduct": 0x0007, "USB Product Name": "Vendor Bootloader",
        "USB Serial Number": serial, "locationID": 0x01100000, "USB Address": 5,
    ], children: [interface])
}

func rootlessHIDTests() {
    guard let boot = USBScan.device(hidTree()) else { expect(false, "HID fixture decodes"); return }
    let rows = USBListRows.make(memory: USBMemory(), devices: [boot], states: nil, vmName: "Omarchy")
    expect(rows.plugged.first?.name == "Vendor Bootloader" && rows.kept.isEmpty,
           "vendor HID bootloader is selectable in the existing before-VM list")
    var memory = USBMemory()
    memory.remember(boot, .omarchy)
    let folder = freshFolder("hid-before-start")
    try? memory.save(folder: folder)
    let loaded = USBMemory.load(folder: folder)
    let remembered = USBListRows.make(memory: loaded, devices: [boot], states: nil, vmName: "Omarchy")
    expect(remembered.remembered.first?.device == boot && remembered.remembered.first?.plan == .omarchy,
           "before-VM vendor HID choice survives ordinary usb.json save/load")
    let (s, m, a, _, _, _) = rig(loaded)
    s.plugged(boot)
    expect(s.plugs[boot.location]?.state == .connected && m.log.count == 1 && a.asked.isEmpty,
           "already-present vendor HID uses the remembered choice at VM start")
    hidAdmissionTests()
    hidRoutingTests()
    hidLifecycleTests()
    hidWatchTests()
    hidDeleteTests()
    hidPreferenceTests()
}

func hidPreferenceTests() {
    let boot = USBScan.device(hidTree())!
    do {
        let (s, m, a, _, saved, _) = rig()
        s.plugged(boot); a.answer(false, always: true)
        expect(saved().last?.plan(for: boot) == .mac && m.log.isEmpty, "HID Keep on Mac + Always is ordinary USB memory")
        s.connectNow(location: boot.location)
        expect(m.log.count == 1, "HID current Connect works despite future Mac plan")
        s.disconnectNow(location: boot.location)
        s.setPlan(.ask, for: boot)
        s.forget(key: s.memory.devices[0].key)
        expect(s.memory.devices.isEmpty, "HID Ask and Forget require no separate enrollment or revocation")
    }
    do {
        let (s, m, a, _, _, _) = rig()
        var early = hidTree(); early.children = []
        s.plugged(USBScan.device(early)!)
        s.plugged(boot)
        a.answer(true)
        expect(s.plugs[boot.location]?.device.hid == boot.hid && m.log.count == 1,
               "HID arrival while initial parent question is open updates the selected transport before Connect")
    }
    do {
        let (s, m, a, _, _, _) = rig()
        var early = hidTree(); early.children = []
        s.plugged(USBScan.device(early)!); a.answer(false)
        s.plugged(boot); s.connectNow(location: boot.location)
        expect(s.plugs[boot.location]?.device.hid == boot.hid && m.log.count == 1,
               "late HID publication preserves Keep this time but current Connect uses fresh HID route")
    }
    do {
        let m = HIDMachine(), a = FakeAsker(), c = FakeClock()
        var early = hidTree(); early.children = []
        let parent = USBScan.device(early)!
        var memory = USBMemory(); memory.remember(parent, .omarchy)
        let s = USBSession(vmName: "Omarchy", memory: memory, machine: m, asker: a, clock: c, save: { _ in }, log: { _ in })
        s.plugged(parent); s.plugged(boot); c.advance(USBSession.grace)
        expect(m.added == [parent, boot] && m.removed == [parent],
               "late HID publication replaces an already-connected initial parent route instead of silently ignoring it")
    }
    do {
        let m = FakeMachine(), a = FakeAsker(), c = FakeClock()
        m.hold = true; m.result = .gone
        var memory = USBMemory(); memory.remember(boot, .omarchy)
        let s = USBSession(vmName: "Omarchy", memory: memory, machine: m, asker: a, clock: c, save: { _ in }, log: { _ in })
        s.plugged(boot); s.unplugged(location: boot.location)
        m.held.first?()
        expect(s.plugs.isEmpty && m.log.count == 1,
               "HID refused before attach owns no QOM device and does not strand a release obligation")
    }
}

func hidDeleteTests() {
    final class RefusesDelete: USBQMPTransport {
        func execute(_ command: String, _ arguments: [String: Any]?) throws -> [String: Any] {
            if command == "device_del" { throw NSError(domain: "qmp", code: 1) }
            return ["text": ""] // Detached, but the QOM device may still exist.
        }
    }
    expect(!USBQMP.detach(location: 1, over: RefusesDelete(), confirmDelete: true, wait: { _ in }),
           "HID deletion requires device_del acknowledgement, not just absence from info usb")
    expect(USBSession.noticeText(.failed("ordinary-user IOHIDDeviceOpen failed"), vmName: "Omarchy", hid: true).contains("IOHIDDeviceOpen"),
           "native HID failure detail reaches the ordinary error notice")
}

func hidWatchTests() {
    var reads = USBWatch.Reads()
    let initial = reads.begin(11)
    let hidArrival = reads.begin(11)
    expect(!reads.finish(11, ticket: initial, location: 1), "late HID notification invalidates an older incomplete USB snapshot")
    expect(reads.finish(11, ticket: hidArrival, location: 1), "actual HID arrival publishes fresh selected-parent snapshot")
    let pending = reads.begin(11)
    expect(reads.remove(11) == 1 && !reads.finish(11, ticket: pending, location: 1),
           "physical removal invalidates an in-flight HID rescan")
    let replacement = reads.begin(12)
    expect(reads.finish(12, ticket: replacement, location: 1) && reads.remove(11) == nil,
           "old USB termination cannot remove a new generation at the same location")
    let overlapping = reads.begin(13)
    _ = reads.finish(13, ticket: overlapping, location: 1)
    expect(reads.remove(12) == nil, "late old termination cannot erase an already-published replacement")
    let beforeStop = reads.begin(12)
    reads.clear()
    let restart = reads.begin(12)
    expect(!reads.finish(12, ticket: beforeStop, location: 1) && reads.finish(12, ticket: restart, location: 1),
           "watch restart ignores asynchronous reads from the old run")
}

final class HIDMachine: USBMachine {
    var trace: [String] = []
    var added: [USBDevice] = []
    var removed: [USBDevice] = []
    var attached = true
    var result: USBAttachResult = .attached
    var holdDelete = false
    var holdAttach = false
    var finishAttach: ((USBAttachResult) -> Void)?
    var deletes: [(Bool) -> Void] = []
    func attach(_ d: USBDevice, done: @escaping (USBAttachResult) -> Void) {
        added.append(d); if holdAttach { finishAttach = done } else { done(result) }
    }
    func detach(_ d: USBDevice, done: @escaping (Bool) -> Void) {
        trace.append("delete")
        removed.append(d)
        if holdDelete { deletes.append(done) } else { done(true) }
    }
    func isAttached(_ d: USBDevice, done: @escaping (Bool) -> Void) { trace.append("query"); done(attached) }
}

func hidLifecycleTests() {
    let first = USBScan.device(hidTree())!
    let next = USBScan.device(hidTree(registryID: 0x100000456))!
    func setup() -> (USBSession, HIDMachine, FakeAsker, FakeClock) {
        let m = HIDMachine(), a = FakeAsker(), c = FakeClock()
        var memory = USBMemory(); memory.remember(first, .omarchy)
        let s = USBSession(vmName: "Omarchy", memory: memory, machine: m, asker: a, clock: c, save: { _ in }, log: { _ in })
        return (s, m, a, c)
    }
    do {
        let (s, m, _, c) = setup()
        s.plugged(first); s.plugged(next)
        c.advance(USBSession.grace)
        expect(m.added == [first, next] && m.removed == [first], "new HID generation published before old USB termination is not ignored")
    }
    do {
        let (s, m, a, c) = setup()
        s.plugged(first)
        s.unplugged(location: first.location)
        s.plugged(next)
        c.advance(USBSession.grace)
        expect(m.added == [first, next] && m.removed == [first] && a.asked.isEmpty,
               "HID same serial/new live generation deletes old instance even if old attached read races removal")
        s.disconnectNow(location: next.location)
        expect(m.removed.last == next && s.plugs[next.location]?.state == .onMac(remembered: false),
               "HID Disconnect uses ordinary current row and releases current generation")
    }
    do {
        let (s, m, _, c) = setup()
        m.holdDelete = true
        s.plugged(first); s.unplugged(location: first.location); s.plugged(next)
        c.advance(USBSession.grace)
        expect(m.added == [first] && m.removed == [first], "HID replacement waits for old device_del confirmation")
        expect(m.trace == ["delete"], "E1 HID grace deletes without an unused pre-delete query")
        s.unplugged(location: next.location)
        m.deletes.first?(true)
        expect(m.added == [first] && s.plugs.isEmpty, "HID replacement unplug during old deletion cannot resurrect it")
    }
    do {
        let (s, m, _, c) = setup()
        s.plugged(first)
        m.attached = false
        c.advance(1)
        expect(m.trace == ["query", "delete"], "E1 connected HID health still queries before release")
        expect(s.plugs[first.location]?.state != .connected && m.removed == [first],
               "HID native detach/QEMU loss is no longer displayed as Connected, with no hidden retry")
        expect(m.added.count == 1, "native failure does not reopen the same HID generation automatically")
        s.stop(); c.advance(10)
        expect(s.plugs.isEmpty && m.added.count == 1, "stopped HID session ignores pending health checks")
    }
    do {
        let (s, m, a, _) = setup()
        var early = hidTree(); early.children[0].children = []
        s.plugged(USBScan.device(early)!)
        s.plugged(first)
        expect(m.added == [first] && a.asked.count == 1 && a.open == nil, "late positive HID publication replaces the vanilla parent question and applies its target-only plan")
    }
    do {
        let (s, m, _, _) = setup()
        m.holdDelete = true
        s.plugged(first); s.disconnectNow(location: first.location)
        let rows = USBListRows.make(memory: s.memory, devices: [first], states: s.plugs.mapValues(\.state), vmName: "Omarchy")
        expect(rows.remembered.first?.canConnect == false, "HID Disconnect cannot offer Connect before deletion completes")
        m.deletes.first?(false)
        s.connectNow(location: first.location)
        expect(m.added.count == 1, "failed HID deletion does not permit overlapping reconnect")
    }
}

func hidRoutingTests() {
    do {
        let m = HIDMachine(), a = FakeAsker(), c = FakeClock()
        var memory = USBMemory(); memory.remember(boardA, .omarchy)
        let s = USBSession(vmName: "Fixture", memory: memory, machine: m, asker: a, clock: c, save: { _ in }, log: { _ in })
        s.plugged(boardA); s.unplugged(location: boardA.location); c.advance(USBSession.grace)
        expect(m.trace == ["query", "delete"], "E1 ordinary grace retains its attached query")
        s.stop()
    }
    let rawSerial = "  " + String(repeating: "z", count: 70) + "Ω  "
    let boot = USBScan.device(hidTree(serial: rawSerial))!
    let args = USBQMP.attachArguments(boot)
    expect(args["driver"] as? String == "usb-host-hid" && args["registry-id"] as? UInt64 == 0x100000123
           && args["vendorid"] as? UInt16 == 0x1209 && args["productid"] as? UInt16 == 7
           && args["serial"] as? String == rawSerial && args["hostbus"] == nil && args["hostaddr"] == nil
           && args["id"] as? String == USBQMP.qemuID(location: boot.location) && args["bus"] as? String == "usb0.0",
           "HID QMP uses exact HID registry ID + VID/PID + raw serial, never USB parent/location or usb-host")
    var memory = USBMemory()
    memory.remember(boot, .omarchy)
    let loaded = USBMemory.decode(memory.encode())!
    let different = USBScan.device(hidTree(serial: rawSerial + "x"))!
    expect(loaded.devices.first?.hidSerial == rawSerial && loaded.plan(for: boot) == .omarchy
           && loaded.plan(for: different) == .ask, "HID remembered identity preserves raw serial, not cleaned display text")
    let q = FakeQMP()
    q.addFails = "HID identity mismatch or unsupported/protected report shape"
    let result = USBQMP.attach(boot, over: q, wait: { _ in })
    expect(result != .attached && q.sent == ["device_add"], "native HID refusal is surfaced without a usb-host fallback")
    var invalid = hidTree()
    invalid.children[0].properties["bInterfaceProtocol"] = 1
    let blocked = USBScan.device(invalid)!
    let (s, m, _, _, _, _) = rig()
    s.plugged(blocked); s.connectNow(location: blocked.location)
    expect(m.log.isEmpty, "unsupported HID has no Connect path through the production session")
}

func hidAdmissionTests() {
    for (name, descriptor) in [
        ("64-byte unnumbered", Data([0x06, 0, 0xff, 0x09, 1, 0xa1, 1, 0x75, 8, 0x95, 64, 0x81, 2, 0xc0])),
        ("64-byte numbered including ID", Data([0x06, 0, 0xff, 0x09, 1, 0xa1, 1, 0x85, 7, 0x75, 8, 0x95, 63, 0x81, 2, 0xc0])),
    ] {
        var tree = hidTree(serial: String(repeating: "Ω", count: 126))
        tree.children[0].children[0].properties["ReportDescriptor"] = descriptor
        expect(USBScan.device(tree)?.availability == .free, "HID accepted boundary: \(name), 126 UTF-16 serial units")
    }
    var ordinary = hidTree()
    ordinary.children[0].children = []
    ordinary.children[0].properties["bInterfaceClass"] = 0xff
    let probe = USBScan.device(ordinary)!
    expect(probe.availability == .free && probe.hid == nil && USBQMP.attachArguments(probe)["driver"] as? String == "usb-host",
           "read-only registry fixture preserves ordinary unused USB route")
    ordinary.children[0].children = [.init(registryID: 99, className: "AppleUSBFTDI")]
    expect(USBScan.device(ordinary)?.availability == .usedByMac("macOS uses it as a serial port"),
           "read-only registry fixture preserves non-HID usedByMac constraint")

    func rejected(_ name: String, _ change: (inout USBScan.Entry) -> Void) {
        var tree = hidTree()
        change(&tree)
        guard let d = USBScan.device(tree) else { expect(false, "\(name): visible physical device"); return }
        var memory = USBMemory()
        memory.remember(d, .omarchy)
        let (s, m, a, _, _, _) = rig(memory)
        s.plugged(d)
        let rows = USBListRows.make(memory: memory, devices: [d], states: nil, vmName: "Omarchy")
        expect(d.hid == nil && d.availability != .free && rows.kept.count == 1
               && m.log.isEmpty && a.asked.isEmpty, "HID refused, even remembered Always: \(name)")
    }
    let invalidDescriptors: [(String, Data)] = [
        ("keyboard page", Data([0x05, 0x01]) + vendorDescriptor.dropFirst(3)),
        ("FIDO page", Data([0x06, 0xd0, 0xf1]) + vendorDescriptor.dropFirst(3)),
        ("mixed protected page", vendorDescriptor.dropLast() + Data([0x05, 0x07, 0xc0])),
        ("two applications", vendorDescriptor + vendorDescriptor),
        ("oversized descriptor", Data(repeating: 0, count: 1025)),
        ("empty descriptor", Data()),
        ("truncated item", Data([0x06, 0x00])),
        ("long item", vendorDescriptor.dropLast() + Data([0xfe, 0, 0, 0xc0])),
        ("global push", vendorDescriptor.dropLast() + Data([0xa4, 0xc0])),
        ("delimiter", vendorDescriptor.dropLast() + Data([0xa9, 0, 0xc0])),
        ("unbalanced collection", vendorDescriptor.dropLast()),
        ("extended keyboard usage", vendorDescriptor.dropLast() + Data([0x0b, 1, 0, 1, 0, 0xc0])),
        ("65 byte report", Data([0x06, 0, 0xff, 0x09, 1, 0xa1, 1, 0x75, 8, 0x95, 65, 0x81, 2, 0xc0])),
        ("mixed report ID modes", vendorDescriptor.dropLast() + Data([0x85, 7, 0x81, 2, 0xc0])),
    ]
    for (name, desc) in invalidDescriptors {
        rejected(name) { $0.children[0].children[0].properties["ReportDescriptor"] = desc }
    }
    for (key, value) in [("SerialNumber", ""), ("SerialNumber", String(repeating: "s", count: 127)),
                          ("SerialNumber", "bad\u{0}serial"), ("Product", String(repeating: "p", count: 127)),
                          ("Transport", "Bluetooth")] {
        rejected("invalid \(key)") { $0.children[0].children[0].properties[key] = value }
    }
    rejected("missing product") { $0.children[0].children[0].properties["Product"] = nil }
    rejected("zero vendor") { $0.properties["idVendor"] = 0; $0.children[0].children[0].properties["VendorID"] = 0 }
    rejected("identity mismatch") { $0.children[0].children[0].properties["VendorID"] = 123 }
    rejected("boot protocol") { $0.children[0].properties["bInterfaceProtocol"] = 1 }
    rejected("missing subclass") { $0.children[0].properties["bInterfaceSubClass"] = nil }
    rejected("composite") { $0.children.append($0.children[0]) }
    rejected("multiple HID descendants") { $0.children[0].children.append($0.children[0].children[0]) }
    rejected("incomplete topology") { $0.children[0].complete = false }
    rejected("non-HID driver") { $0.children.append(.init(registryID: 44, className: "SomeVendorDriver")) }
    rejected("non-HID interface user") { $0.children[0].children.append(.init(registryID: 45, className: "OtherUserClient", name: "other-app")) }
    for noInterfaces in [false, true] {
        var tree = hidTree()
        if noInterfaces { tree.properties["bDeviceClass"] = 3; tree.children = [] }
        else { tree.children[0].children = [] }
        let d = USBScan.device(tree)!
        expect(d.hid == nil && d.availability == .free,
               "SCOPE3 unpublished HID remains vanilla-free, without gaining HID admission")
    }
}
