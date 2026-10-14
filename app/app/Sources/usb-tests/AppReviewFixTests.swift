import Foundation
import OmacVMUSB

func app4ReadOrderingTests() {
    var r = USBWatch.Reads()
    let old = r.begin(11), unrelated = r.begin(99), new = r.begin(12)
    expect(r.finish(12, ticket: new, location: 1), "APP-4 newer first snapshot publishes")
    expect(r.remove(12) == 1 && !r.finish(11, ticket: old, location: 1),
           "APP-4 removal keeps latest-location watermark against older pending first read")
    expect(r.finish(99, ticket: unrelated, location: 2), "APP-4 ordering is per location, not global")
    let late = r.begin(13)
    r.clear()
    let restart = r.begin(14)
    expect(!r.finish(13, ticket: late, location: 1) && r.finish(14, ticket: restart, location: 1),
           "APP-4 stop invalidates reads but permits fresh restart")
}

func app5PreferenceRefreshTests() {
    // A saved ordinary route is not a user's decision for a later HID identity.
    for ordinaryPlan in USBPlan.allCases {
      for targetPlan in USBPlan.allCases {
        for hidFirst in [false, true] {
            let boot = USBScan.device(hidTree())!
            var tree = hidTree(); tree.children = []
            let parent = USBScan.device(tree)!
            var memory = USBMemory(); memory.remember(parent, ordinaryPlan); memory.remember(boot, targetPlan)
            let (s, m, a, c, _, _) = rig(memory); s.inFront = false
            var reads = USBWatch.Reads(); let p = reads.begin(3101), h = reads.begin(3101, publication: true)
            func parentDone() { if reads.finish(3101, ticket: p, location: boot.location, hid: false) { s.plugged(parent) } }
            func hidDone() { if reads.finish(3101, ticket: h, location: boot.location, hid: true, publication: true) { s.plugged(boot) } }
            if hidFirst { hidDone(); parentDone() } else { parentDone(); hidDone() }
            c.advance(USBSession.grace)
            // An already connected parent retains its current connection, as before.
            let connectedParent = !hidFirst && ordinaryPlan == .omarchy
            let expected: USBSession.State = connectedParent || targetPlan == .omarchy ? .connected : targetPlan == .mac ? .onMac(remembered: true) : .waiting
            expect(s.plugs[boot.location]?.state == expected && a.asked.isEmpty,
                   "IA-2 automatic parent=\(ordinaryPlan) target=\(targetPlan) HIDfirst=\(hidFirst)")
            expect(s.memory == memory && (ordinaryPlan != .mac || hidFirst || targetPlan != .omarchy || m.log.count == 1),
                   "IA-2 publication never consumes ordinary/target memory")
            s.stop()
        }
      }
    }
    for action in ["keep", "always", "disconnect", "connectFailed", "future"] {
      for targetPlan in USBPlan.allCases {
        let boot = USBScan.device(hidTree())!
        var tree = hidTree(); tree.children = []
        let parent = USBScan.device(tree)!
        var pending = hidTree(); pending.children[0].children = []
        let unavailable = USBScan.device(pending)!
        var memory = USBMemory(); memory.remember(boot, targetPlan)
        if action == "disconnect" { memory.remember(parent, .omarchy) }
        if action == "connectFailed" || action == "future" { memory.remember(parent, .mac) }
        let (s, m, a, _, _, _) = rig(memory); s.plugged(parent)
        switch action {
        case "keep", "always": a.answer(false, always: action == "always")
        case "disconnect": s.disconnectNow(location: parent.location)
        case "connectFailed": m.result = .busy; s.connectNow(location: parent.location); m.result = .attached
        default: s.setPlan(.omarchy, for: parent) // Next plug only, NOT a current Keep decision.
        }
        let before = s.plugs[parent.location]!.state, calls = m.log.count
        s.plugged(boot)
        let expected = action == "future" ? (targetPlan == .omarchy ? USBSession.State.connected : targetPlan == .mac ? .onMac(remembered: true) : .asking) : before
        expect(s.plugs[boot.location]?.state == expected && (action == "future" || m.log.count == calls),
               "IA-2 explicit \(action) versus automatic late target \(targetPlan)")
        if action != "future" {
            s.setPlan(.omarchy, for: boot)
            for _ in 0..<2 { s.plugged(unavailable); s.connectNow(location: boot.location); s.plugged(boot) }
            expect(s.plugs[boot.location]?.state == before && m.log.count == calls,
                   "IA-2 explicit \(action) survives repeated incomplete refresh and future plan")
        }
        s.stop()
      }
    }
    let boot = USBScan.device(hidTree())!
    var early = hidTree(); early.children = []
    var pending = hidTree(); pending.children[0].children = []
    let unavailable = USBScan.device(pending)!
    for always in [false, true] {
        let folder = freshFolder("app5-\(always)")
        let m = FakeMachine(), a = FakeAsker(), c = FakeClock()
        let s = USBSession(vmName: "Fixture", memory: USBMemory(), machine: m, asker: a, clock: c,
                           save: { try! $0.save(folder: folder) }, log: { _ in })
        s.plugged(boot); a.answer(false, always: always)
        s.setPlan(.omarchy, for: boot)
        s.plugged(unavailable); s.connectNow(location: boot.location)
        expect(m.log.isEmpty, "APP-5 current Connect refuses temporarily unavailable metadata")
        s.plugged(boot)
        expect(m.log.isEmpty && s.plugs[boot.location]?.state == .onMac(remembered: always),
               "APP-5 Keep decision survives eligibility refresh, always=\(always)")
        expect(USBMemory.load(folder: folder).plan(for: boot) == .omarchy,
               "APP-5 future Omarchy plan persists independently of this plug")
        s.unplugged(location: boot.location); s.plugged(boot)
        expect(m.log.count == 1 && s.plugs[boot.location]?.state == .connected,
               "APP-5 only physical replug applies future Omarchy plan")
        s.stop()
    }
}

func appReviewFixTests() {
    for hold in [false, true] {
        let (s, m, a, c, _, _) = rig()
        m.hold = hold
        var early = hidTree(); early.children = []
        var protected = hidTree()
        protected.children[0].children[0].properties["ReportDescriptor"] = Data([0x05, 1]) + vendorDescriptor.dropFirst(3)
        let rejected = USBScan.device(protected)!
        s.plugged(USBScan.device(hidTree())!); a.answer(true)
        s.plugged(rejected)
        m.held.forEach { $0() }; c.advance(USBSession.grace)
        s.disconnectNow(location: rejected.location); s.connectNow(location: rejected.location)
        expect(m.log.filter { $0.hasPrefix("attach") }.count == 1 && s.rows.kept.count == 1
               && s.rows.plugged.isEmpty, "APP-1 revoked positive target cannot reconnect through ordinary route, pending=\(hold)")
        s.stop()
    }
    var zero = hidTree()
    zero.properties["idProduct"] = 0
    zero.children[0].children[0].properties["ProductID"] = 0
    let unsupported = USBScan.device(zero)!
    let (s, m, _, _, _, _) = rig()
    s.plugged(unsupported); s.connectNow(location: unsupported.location)
    expect(unsupported.hid == nil && m.log.isEmpty,
           "PID zero is unsupported by bounded native HID, with no ordinary USB fallback")
    zero.children[0].children = []
    zero.children[0].properties["bInterfaceClass"] = 0xff
    expect(USBScan.device(zero)?.availability == .free,
           "PID zero is not globally invalid for ordinary USB")
    app4ReadOrderingTests()
    app5PreferenceRefreshTests()
    hidDecisionIdentityTests()
    // APP-1: both nil-HID snapshots differ in eligibility, not HID identity.
    for front in [true, false] {
        let (s, m, a, _, _, _) = rig()
        s.inFront = front
        var tree = hidTree(); tree.children = []
        let early = USBScan.device(hidTree())!
        tree = hidTree()
        tree.children[0].children[0].properties["ReportDescriptor"] = Data([0x05, 1]) + vendorDescriptor.dropFirst(3)
        let rejected = USBScan.device(tree)!
        s.plugged(early); s.plugged(rejected)
        s.inFront = true; a.answer(true); s.connectNow(location: early.location)
        expect(s.plugs[early.location]?.device == rejected && m.log.isEmpty && a.open == nil,
               "APP-1 asking/waiting positive-target refresh invalidates rejected snapshot (front=\(front))")
        s.stop()
    }
}
