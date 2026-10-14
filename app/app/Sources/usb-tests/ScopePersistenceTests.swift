import Foundation
import OmacVMUSB

func scopePersistenceTests() {
    // Native identity is strcmp(UTF-8), unlike Swift's canonical String equality.
    for (left, right) in [("\u{e9}", "e\u{301}"), (" A\nB ", "AB"), ("\u{e9}", "\u{e9}")] {
        let same = Array(left.utf8) == Array(right.utf8)
        let a = USBScan.device(hidTree(serial: left))!, b = USBScan.device(hidTree(serial: right))!
        expect((a.hid == b.hid) == same, "IA-1 HID equality is byte exact at the same generation")
        for choice: USBPlan in [.mac, .ask] {
            func record(_ raw: String, _ plan: USBPlan) -> USBMemory.Device {
                var e = USBMemory.Device(vendor: "1209", product: "0007", serial: USBChoice.clean(raw), name: "Fixture", choice: plan)
                e.hidSerial = raw
                return e
            }
            let ea = record(left, .mac), eb = record(right, choice)
            var m = USBMemory(devices: same ? [ea] : [eb, ea])
            expect(Set([ea.key, eb.key]).count == (same ? 1 : 2), "IA-1 keys retain raw byte distinctions")
            expect(same || ea != eb, "IA-1 same-choice Device equality does not borrow a canonical twin")
            m.remember(a, .omarchy)
            expect(m.plan(for: a) == .omarchy && m.plan(for: b) == (same ? .omarchy : choice),
                   "IA-1 remember firstIndex updates only its exact entry")
            let folder = freshFolder("ia1-identity")
            try! m.save(folder: folder)
            var loaded = USBMemory.load(folder: folder)
            expect(loaded.devices.count == (same ? 1 : 2) && loaded.plan(for: a) == .omarchy,
                   "IA-1 decode dedupe preserves byte-distinct raw identities")
            let bytes = try! JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("usb.json"))) as! [String: Any]
            let serials = (bytes["devices"] as! [[String: Any]]).map { Array(($0["hidSerial"] as! String).utf8) }
            expect(serials.contains(Array(left.utf8)) && serials.contains(Array(right.utf8)), "IA-1 JSON keeps original raw serial bytes")
            loaded.set(key: ea.key, .ask)
            expect(loaded.plan(for: a) == .ask && loaded.plan(for: b) == (same ? .ask : choice), "IA-1 set isolates exact key")
            loaded.forget(key: ea.key)
            expect(loaded.devices.count == (same ? 0 : 1) && (same || loaded.plan(for: b) == choice), "IA-1 Forget isolates exact key")
        }
    }
    for serial in [" A\nB ", "\tΩ \u{7f}X\r", String(repeating: "z", count: 80), "", "    "] {
        let folder = freshFolder("scope-ordinary-serial")
        let seed = USBMemory(devices: [.init(vendor: "1209", product: "0007", serial: serial, name: "ordinary", choice: .omarchy)])
        try! seed.save(folder: folder)
        let loaded = USBMemory.load(folder: folder)
        var d = USBScan.device(hidTree())!; d.hid = nil; d.serial = USBChoice.clean(serial)
        expect(loaded.devices[0].serial == USBChoice.clean(serial) && loaded.plan(for: d) == .omarchy,
               "SCOPE4 ordinary file decode retains vanilla cleaning: \(serial.debugDescription)")
        var saved = USBMemory(); d.serial = serial; saved.remember(d, .mac)
        expect(saved.devices[0].serial == USBChoice.clean(serial), "SCOPE4 ordinary writer retains vanilla cleaning")
    }
    let folder = freshFolder("scope-target-serial")
    let first = USBScan.device(hidTree(serial: " A\nB "))!
    let second = USBScan.device(hidTree(serial: "AB"))!
    var memory = USBMemory(); memory.remember(first, .omarchy); memory.remember(second, .mac)
    try! memory.save(folder: folder)
    let loaded = USBMemory.load(folder: folder)
    expect(loaded.plan(for: first) == .omarchy && loaded.plan(for: second) == .mac && loaded.devices.count == 2,
           "SCOPE4 target raw identities with same cleaned text stay distinct after file reload")
    var ordinary = second; ordinary.hid = nil
    expect(loaded.plan(for: ordinary) == .ask, "SCOPE4 target-only memory cannot change ordinary routing")
    var legacy = USBMemory(devices: [.init(vendor: "1209", product: "0007", name: "ordinary wildcard", choice: .mac)])
    let original = legacy.devices[0]
    legacy.remember(first, .omarchy)
    try! legacy.save(folder: folder)
    let withTarget = USBMemory.load(folder: folder)
    expect(withTarget.devices.contains(original) && withTarget.plan(for: ordinary) == .mac && withTarget.plan(for: first) == .omarchy,
           "SCOPE4 saving a target does not convert or consume an existing ordinary wildcard record")
    expect(loaded.devices.allSatisfy { $0.serial == "AB" }, "SCOPE4 existing serial field stays vanilla even for target records")
    for sameRaw in [false, true] {
        let back = USBScan.device(hidTree(registryID: 102, serial: sameRaw ? " A\nB " : "AB"))!
        var m = USBMemory(); m.remember(first, .omarchy)
        if !sameRaw { m.remember(back, .mac) }
        try! m.save(folder: folder)
        let (s, machine, asker, clock, _, _) = rig(USBMemory.load(folder: folder))
        s.plugged(first); s.unplugged(location: first.location); s.plugged(back)
        clock.advance(USBSession.grace)
        expect(first.serial == back.serial && first.hid?.registryID != back.hid?.registryID,
               "C2-2 reconnect fixture has equal display serial and distinct generations")
        expect(s.plugs[back.location]?.state == (sameRaw ? .connected : .onMac(remembered: true))
               && machine.log.filter { $0.hasPrefix("attach") }.count == (sameRaw ? 2 : 1) && asker.asked.isEmpty,
               "C2-2 raw identity, not cleaned serial, decides grace reconnect: same=\(sameRaw)")
        s.stop()
    }
}
