import Foundation
import OmacVMUSB

func ownershipRaceTests() {
    let boot = USBScan.device(hidTree())!
    // Ordinary races are independently compared to the clean upstream in the
    // differential harness, including the original 6b callback order.
    for d in [boot] {
        func session(_ m: ReviewMachine, _ c: FakeClock) -> USBSession {
            var memory = USBMemory(); memory.remember(d, .omarchy)
            return USBSession(vmName: "Fixture", memory: memory, machine: m, asker: FakeAsker(), clock: c, save: { _ in }, log: { _ in })
        }
        do {
            let m = ReviewMachine(), c = FakeClock()
            m.qmp.mode = .addReject; m.holdAttach = true
            let s = session(m, c); s.plugged(d); s.unplugged(location: d.location)
            c.advance(USBSession.grace); m.finishAttach?()
            expect(s.plugs.isEmpty && m.qmp.calls == ["device_add"],
                   "APP-3 grace before rejected attach delivery creates no phantom delete, HID=\(d.hid != nil)")
            s.stop()
        }
        do {
            let m = ReviewMachine(), c = FakeClock()
            m.qmp.mode = .addEOF; m.holdAttach = true
            let s = session(m, c); s.plugged(d); s.unplugged(location: d.location)
            m.qmp.mode = .infoFailureDeleteReject
            c.advance(USBSession.grace); m.finishAttach?()
            let rows = s.rows
            expect(m.qmp.owns && s.plugs[d.location]?.state == .releaseFailed
                   && rows.remembered.first?.canDisconnect == true && rows.remembered.first?.canConnect == false,
                   "APP-2 unplug and delayed unknown add retains visible Disconnect debt, HID=\(d.hid != nil)")
            m.qmp.mode = .normal; s.disconnectNow(location: d.location)
            expect(!m.qmp.owns && s.plugs.isEmpty, "APP-2 absent device release retry removes only confirmed tombstone")
            s.stop()
        }
        do {
            let m = ReviewMachine(), c = FakeClock()
            m.qmp.mode = .addEOF
            let s = session(m, c); s.plugged(d)
            s.unplugged(location: d.location)
            let rows = s.rows
            expect(rows.remembered.first?.canDisconnect == true && rows.remembered.first?.canConnect == false,
                   "APP-2 production running rows retain unresolved cleanup after physical unplug")
            m.qmp.mode = .normal; s.disconnectNow(location: d.location)
            expect(!m.qmp.owns && s.plugs.isEmpty, "APP-2 release after unplug cannot resurrect absent device")
            s.stop()
        }
    }
}
