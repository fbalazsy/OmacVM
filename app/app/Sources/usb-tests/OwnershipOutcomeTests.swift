import Foundation
import OmacVMUSB

func ownershipOutcomeTests() {
    let boot = USBScan.device(hidTree())!
    let closed = ReviewPeer()
    closed.closeBeforeCommand = true
    let notSent = USBQMP.attach(boot, over: closed, wait: { _ in })
    if case .failed = notSent {
        expect(!closed.owns, "APP-3 known closed connection sends no add and needs no release")
    } else {
        expect(false, "APP-3 known closed connection sends no add and needs no release")
    }
    final class UntypedFailure: USBQMPTransport {
        func execute(_ command: String, _ arguments: [String: Any]?) throws -> [String: Any] {
            throw NSError(domain: "inert", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to find; busy; no free ports"])
        }
    }
    if case .releaseRequired = USBQMP.attach(boot, over: UntypedFailure(), wait: { _ in }) {
        expect(true, "APP-2 untyped error words cannot establish no creation")
    } else { expect(false, "APP-2 untyped error words cannot establish no creation") }
    func session(_ d: USBDevice, _ m: ReviewMachine, _ c: FakeClock) -> USBSession {
        var memory = USBMemory(); memory.remember(d, .omarchy)
        return USBSession(vmName: "Fixture", memory: memory, machine: m, asker: FakeAsker(), clock: c, save: { _ in }, log: { _ in })
    }
    for d in [boot, board("ordinary", loc: boot.location)] {
        for mode in [ReviewPeer.Mode.addEOF, .addTimeout, .infoFailureDeleteReject] {
            let m = ReviewMachine(), c = FakeClock()
            m.qmp.mode = mode
            let s = session(d, m, c); s.plugged(d)
            if d.hid == nil {
                expect(s.plugs[d.location]?.state == .onMac(remembered: false) && m.qmp.owns,
                       "SCOPE2 ordinary ambiguous add retains upstream On Mac outcome: \(mode)")
                s.unplugged(location: d.location)
                expect(s.rows.remembered.first?.status == "Not plugged in" && s.plugs.isEmpty,
                       "SCOPE2 ordinary removal has no new cleanup tombstone")
                s.stop()
                continue
            }
            expect(s.plugs[d.location]?.state == .releaseFailed && m.qmp.owns,
                   "APP-2 unknown/created add retains cleanup for \(mode), HID=\(d.hid != nil)")
            s.connectNow(location: d.location)
            m.qmp.mode = .infoFailureDeleteReject
            s.disconnectNow(location: d.location)
            expect(s.plugs[d.location]?.state == .releaseFailed && m.qmp.owns && m.qmp.drivers.count == 1,
                   "APP-2 failed Disconnect retry cannot permit another add")
            m.qmp.mode = .normal
            s.disconnectNow(location: d.location)
            expect(s.plugs[d.location]?.state == .onMac(remembered: false) && !m.qmp.owns,
                   "APP-2 successful Disconnect retry confirms return to Mac")
            s.stop()
        }
    }
    let badEnvelopes: [[String: Any]] = [
        ["error": ["desc": "failed to find"]],
        ["error": ["class": "GenericError", "desc": 123]],
        ["error": "failed to find", "return": [:]],
        ["error": ["class": "GenericError", "desc": "failed to find"], "return": [:]],
        ["error": ["class": "GenericError", "desc": "failed to find"], "event": "DEVICE_DELETED"],
        ["return": [:], "event": "DEVICE_DELETED"],
    ]
    for (i, envelope) in badEnvelopes.enumerated() {
        let m = ReviewMachine(), c = FakeClock()
        m.qmp.addEnvelope = envelope
        let s = session(boot, m, c); s.plugged(boot)
        expect(s.plugs[boot.location]?.state == .releaseFailed && m.qmp.owns,
               "APP-2 malformed/contradictory matched envelope \(i) is uncertain, never a no-add rejection")
        s.stop()
    }
    for detail in ["selected HID registry generation is absent", "unrelated native realize rejection", "busy", "failed to find"] {
        let m = ReviewMachine(), c = FakeClock()
        m.qmp.mode = .addReject; m.qmp.rejectionDetail = detail; m.holdAttach = true
        let s = session(boot, m, c)
        s.plugged(boot); s.unplugged(location: boot.location); m.finishAttach?(); c.advance(USBSession.grace)
        expect(s.plugs.isEmpty && !m.qmp.owns && m.qmp.calls == ["device_add"],
               "APP-3 definitive rejection owns nothing regardless of words: \(detail)")
        s.stop()
    }
}
