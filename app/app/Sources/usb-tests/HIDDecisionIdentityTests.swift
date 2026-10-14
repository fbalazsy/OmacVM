import Foundation
import OmacVMUSB

// Logical identity is VID/PID + raw bytes; registry is only a generation.
func identityDevice(_ kind: String, generation: UInt64 = 102) -> USBDevice {
    var tree = hidTree(registryID: generation, serial: kind == "unicode" ? "e\u{301}" : kind == "ascii" ? "serial-B" : "\u{e9}")
    if kind == "vendor" || kind == "product" {
        let root = kind == "vendor" ? "idVendor" : "idProduct"
        let leaf = kind == "vendor" ? "VendorID" : "ProductID"
        tree.properties[root] = 8; tree.children[0].children[0].properties[leaf] = 8
    }
    return USBScan.device(tree)!
}
func identityGap(_ kind: String, _ d: USBDevice) -> USBDevice {
    var gap = d; gap.hid = nil
    if kind == "protected" { gap.interfaces = [.init(number: 0, interfaceClass: 3, users: ["IOHIDInterface"])] }
    if kind == "incomplete" { gap.hidUnavailable = "HID is still being set up" }
    return gap
}
func hidPendingDecisionTests() {
    let a = identityDevice("same", generation: 101)
    for kind in ["same", "unicode", "product"] {
      for gap in ["none", "incomplete", "protected"] {
        for front in [false, true] {
            let b = identityDevice(kind), same = kind == "same"
            var memory = USBMemory(); if !same { memory.remember(b, .mac) }
            let (s, m, ask, _, _, _) = rig(memory); s.inFront = front; s.plugged(a)
            s.setPlan(.omarchy, for: a)
            if gap != "none" {
                s.plugged(identityGap(gap, a)); s.inFront = true
                expect(ask.open == nil && m.log.isEmpty, "IA-3 suspended question is unavailable \(kind)/\(gap)/\(front)")
                s.inFront = front
            }
            s.plugged(b)
            expect(s.plugs[a.location]?.state == (same ? (front ? .asking : .waiting) : .onMac(remembered: true)) && m.log.isEmpty,
                   "IA-3 unanswered Ask owns identity, not future plan \(kind)/\(gap)/\(front)")
            s.stop()
        }
      }
    }
}

func hidOwnedDecisionTests() {
    let a = identityDevice("same", generation: 101)
    for kind in ["same", "unicode", "product"] {
      for gap in ["incomplete", "protected"] {
        for action in ["connect", "auto", "disconnect", "retry"] {
            let b = identityDevice(kind), same = kind == "same"
            let m = HIDMachine(), ask = FakeAsker(), c = FakeClock()
            var memory = USBMemory(); memory.remember(a, action == "connect" ? .mac : .omarchy)
            if !same { memory.remember(b, action == "connect" || action == "auto" ? .mac : .omarchy) }
            let s = USBSession(vmName: "Fixture", memory: memory, machine: m, asker: ask, clock: c, save: { _ in }, log: { _ in })
            s.plugged(a); if action == "connect" { s.connectNow(location: a.location) }
            s.setPlan(action == "connect" || action == "auto" ? .mac : .omarchy, for: a)
            m.holdDelete = true
            if action == "disconnect" || action == "retry" { s.disconnectNow(location: a.location) }
            s.plugged(identityGap(gap, a)); c.advance(USBSession.grace)
            expect(m.added == [a] && s.plugs[a.location]?.device == a && s.plugs[a.location]?.state == .disconnecting,
                   "IA-3 cleanup keeps old owner \(kind)/\(gap)/\(action)")
            if action == "retry" {
                m.deletes.removeFirst()(false); s.plugged(b); s.connectNow(location: a.location)
                expect(s.plugs[a.location]?.state == .releaseFailed && m.added == [a], "IA-3 failed cleanup blocks replacement \(kind)/\(gap)")
                s.disconnectNow(location: a.location)
            }
            // Finish while metadata is missing: no ordinary fallback and no lost current decision.
            m.deletes.removeFirst()(true)
            if action != "retry" {
                expect(m.added == [a] && !s.rows.plugged.contains(where: \.canConnect), "IA-3 no attach through gap after cleanup \(kind)/\(gap)/\(action)")
                s.plugged(b)
            }
            let reconnect = action == "connect" || action == "auto"
            let expected: USBSession.State = same ? (reconnect ? .connected : .onMac(remembered: false)) : (reconnect ? .onMac(remembered: true) : .connected)
            expect(s.plugs[a.location]?.state == expected && m.added == (expected == .connected ? [a, b] : [a]),
                   "IA-3 released current decision resumes only same identity \(kind)/\(gap)/\(action)")
            s.stop()
        }
      }
    }
    for kind in ["same", "unicode", "product"] {
        let b = identityDevice(kind), m = ReviewMachine(), c = FakeClock(), ask = FakeAsker()
        var memory = USBMemory(); memory.remember(a, .omarchy); if kind != "same" { memory.remember(b, .mac) }
        let s = USBSession(vmName: "Fixture", memory: memory, machine: m, asker: ask, clock: c, save: { _ in }, log: { _ in })
        m.holdAttach = true; s.plugged(a); s.setPlan(.mac, for: a)
        s.plugged(identityGap("incomplete", a)); c.advance(USBSession.grace)
        expect(m.qmp.owns && s.plugs[a.location]?.device == a && m.qmp.calls.filter { $0 == "device_del" }.isEmpty,
               "IA-3 pending add cannot erase old ownership \(kind)")
        m.holdAttach = false; m.finishAttach?(); s.plugged(b)
        expect(s.plugs[a.location]?.state == (kind == "same" ? .connected : .onMac(remembered: true)),
               "IA-3 pending result through gap resumes exact owner \(kind)")
        s.stop()
    }
}

func hidOrdinaryReplacementTests() {
    let a = identityDevice("same", generation: 101)
    for matchingID in [false, true] {
    var b = USBDevice(id: .init(vendor: 0x0483, product: 0x3748), name: "Ordinary probe", deviceClass: 0,
                      interfaces: [.init(number: 0, interfaceClass: 255, users: [])], serial: "ordinary-B",
                      location: a.location, address: 8)
    if matchingID { b.id = a.id } // A proven non-HID interface is not an incomplete HID snapshot.
    for plan: USBPlan in [.ask, .mac, .omarchy] {
      for order in ["remove-first", "publish-first", "released-first"] {
       for phase in ["connected", "connecting", "failed-delete", "replacement-removed"] {
        let m = HIDMachine(), ask = FakeAsker(), c = FakeClock()
        var memory = USBMemory(); memory.remember(a, .omarchy); memory.remember(b, plan)
        let s = USBSession(vmName: "Fixture", memory: memory, machine: m, asker: ask, clock: c, save: { _ in }, log: { _ in })
        var reads = USBWatch.Reads()
        func publish(_ d: USBDevice, _ entry: UInt64) {
            let ticket = reads.begin(entry)
            if reads.finish(entry, ticket: ticket, location: d.location, hid: d.hid != nil) { s.plugged(d) }
        }
        m.holdAttach = phase == "connecting"; publish(a, 101); m.holdDelete = true
        if order != "publish-first", let loc = reads.remove(101) { s.unplugged(location: loc) }
        if order != "released-first" { publish(b, 102) }
        if order == "publish-first" {
            let stale = reads.remove(101)
            expect(stale == nil, "OB late old HID termination cannot remove ordinary replacement")
            if let stale { s.unplugged(location: stale) }
        }
        c.advance(USBSession.grace)
        if phase == "connecting" {
            expect(m.removed.isEmpty && m.added == [a], "OB pending HID attach owns cleanup before ordinary replacement")
            m.holdAttach = false; m.finishAttach?(.attached)
        }
        expect(m.added == [a] && m.removed == [a] && s.plugs[a.location]?.device == a,
               "OB ordinary replacement waits for old HID release \(matchingID)/\(plan)/\(order)/\(phase)")
        if phase == "failed-delete" {
            m.deletes.removeFirst()(false); s.connectNow(location: b.location)
            expect(s.plugs[a.location]?.state == .releaseFailed && m.added == [a], "OB failed delete blocks ordinary add")
            s.disconnectNow(location: a.location)
        }
        if phase == "replacement-removed", order != "released-first" { s.unplugged(location: b.location) }
        m.deletes.removeFirst()(true)
        if phase == "replacement-removed", order != "released-first" {
            expect(s.plugs.isEmpty && m.added == [a], "OB removed ordinary replacement cannot resurrect after HID cleanup")
        }
        if order == "released-first" || phase == "replacement-removed" { publish(b, 102) }
        expect(s.plugs[b.location]?.device == b && s.plugs[b.location]?.state == (plan == .ask ? .asking : plan == .mac ? .onMac(remembered: true) : .connected),
               "OB ordinary replacement takes its own saved route \(plan)/\(order)")
        if plan == .ask { ask.answer(true) }
        if plan == .mac { s.connectNow(location: b.location) }
        expect(m.added == [a, b] && USBQMP.attachArguments(b)["driver"] as? String == "usb-host"
               && s.plugs[b.location]?.state == .connected,
               "OB ordinary Connect uses vanilla transport after HID \(plan)/\(order)")
        s.stop()
       }
      }
      for initial in ["asking", "waiting", "mac"] {
        var memory = USBMemory(); memory.remember(a, initial == "mac" ? .mac : .ask); memory.remember(b, plan)
        let (s, m, ask, _, _, _) = rig(memory); s.inFront = initial != "waiting"; s.plugged(a); s.plugged(b)
        let expected: USBSession.State = plan == .omarchy ? .connected : plan == .mac ? .onMac(remembered: true) : initial == "waiting" ? .waiting : .asking
        expect(s.plugs[b.location]?.device == b && s.plugs[b.location]?.state == expected,
               "OB unowned HID replacement uses ordinary plan \(matchingID)/\(initial)/\(plan)")
        if plan == .ask { s.inFront = true; ask.answer(true) }
        if plan == .mac { s.connectNow(location: b.location) }
        expect(m.log.count == 1 && s.plugs[b.location]?.state == .connected,
               "OB unowned replacement clears HID-only Connect guard \(matchingID)/\(initial)/\(plan)")
        s.stop()
      }
    }
    }
    for classes in [[], [0], [3], [-1], [256], [255]] {
        var gap = a; gap.hid = nil
        gap.interfaces = classes.map { .init(number: 0, interfaceClass: $0, users: []) }
        if classes == [255] { gap.hidUnavailable = "HID is still being set up" }
        let m = HIDMachine(), c = FakeClock(); m.holdDelete = true
        var memory = USBMemory(); memory.remember(a, .omarchy)
        let s = USBSession(vmName: "Fixture", memory: memory, machine: m, asker: FakeAsker(), clock: c, save: { _ in }, log: { _ in })
        s.plugged(a); s.setPlan(.mac, for: a); s.plugged(gap); c.advance(USBSession.grace)
        m.deletes.removeFirst()(true); s.connectNow(location: a.location)
        expect(m.added == [a] && !(s.rows.plugged + s.rows.remembered).contains(where: \.canConnect),
               "OB unknown/same-HID snapshot cannot fall back to usb-host \(classes)")
        let ready = identityDevice("same", generation: 102); s.plugged(ready)
        expect(m.added == [a, ready] && s.memory.plan(for: ready) == .mac,
               "OB metadata gap retains current HID decision, not future picker \(classes)")
        s.stop()
    }
}

func hidDecisionIdentityTests() {
    hidOrdinaryReplacementTests()
    // Replacing the active question with a saved route must not strand another port.
    for plan: USBPlan in [.mac, .ask, .omarchy] {
        let a = identityDevice("same", generation: 101), b = identityDevice("ascii")
        var c = identityDevice("unicode", generation: 103); c.location = a.location + 1
        var memory = USBMemory(); memory.remember(b, plan)
        let (s, m, ask, _, _, _) = rig(memory)
        s.plugged(a); s.plugged(c)
        expect(s.asking == a.location && s.queue == [c.location], "Q1 second port waits behind A")
        s.plugged(b)
        expect(s.asking == c.location && s.plugs[c.location]?.state == .asking && ask.asked.count == 2,
               "Q1 replacement \(plan) advances waiting C without activation")
        expect(s.plugs[b.location]?.state == (plan == .omarchy ? .connected : plan == .mac ? .onMac(remembered: true) : .waiting)
               && m.log.count == (plan == .omarchy ? 1 : 0), "Q1 replacement retains its own route \(plan)")
        s.stop()
    }
    hidPendingDecisionTests()
    hidOwnedDecisionTests()
    let a = identityDevice("same", generation: 101)
    for kind in ["same", "unicode", "ascii", "vendor", "product"] {
      for gap in ["none", "incomplete", "protected"] {
        for action in ["auto", "keep", "always", "failed", "disconnect", "future"] {
            let b = identityDevice(kind), same = kind == "same"
            var memory = USBMemory(); memory.remember(a, ["keep", "always"].contains(action) ? .ask : action == "disconnect" ? .omarchy : .mac)
            if !same { memory.remember(b, .omarchy) }
            let (s, m, ask, _, _, _) = rig(memory); s.plugged(a)
            switch action {
            case "keep", "always": ask.answer(false, always: action == "always")
            case "failed": m.result = .busy; s.connectNow(location: a.location); m.result = .attached
            case "disconnect": s.disconnectNow(location: a.location)
            default: break
            }
            let current = s.plugs[a.location]!.state, before = m.log.count
            s.setPlan(.omarchy, for: a) // Future only, for automatic as well as explicit current Mac.
            if gap != "none" { s.plugged(identityGap(gap, a)); s.connectNow(location: a.location) }
            s.plugged(b)
            expect(s.plugs[a.location]?.state == (same ? current : .connected) && m.log.count == before + (same ? 0 : 1),
                   "IA-3 Mac owner \(kind)/\(gap)/\(action) preserves same decision only")
            expect(s.plugs[a.location]?.device == b, "IA-3 refreshed row uses latest generation \(kind)/\(gap)/\(action)")
            s.stop()
        }
      }
    }
}
