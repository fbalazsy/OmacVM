import Foundation
import OmacVMUSB

func nativeLifecycleTests(expect: @escaping (Bool, String) -> Void) {
    func grant() -> USBCaptureGrant {
        let m = CaptureMachine()
        let s = USBSession(vmName: "VM", memory: USBMemory(), machine: m, asker: FakeAsker(), clock: FakeClock(), save: { _ in }, log: { _ in })
        s.plugged(vendorHID()); s.connectNow(location: vendorHID().location)
        return m.grants[0]
    }
    let g = grant(), q = RedirectionQMP(), io = LifecycleIO(attempt: g.attempt)
    io.refuseCancelAfterReleasing = true
    var events: [USBCaptureEvent] = []
    let operation = USBNativeOperation(grant: g, qemu: .init(pid: 42, uid: getuid(), startSec: 1, startUsec: 0, version: 1),
                                       launcher: io, qmp: q, event: { events.append($0) })
    operation.run()
    expect(io.captureSent && events.contains(.connected) && events.last == .released(hidRestored: true), "production lifecycle combines native postcheck + QMP and releases only after reap/cleanup")
    expect(io.reapCalled && q.sent.contains("device_del"), "real lifecycle requests reap before QMP teardown")
    let g2 = grant(), io2 = LifecycleIO(attempt: g2.attempt), q2 = RedirectionQMP()
    io2.events = ["releasing", "released"]
    var e2: [USBCaptureEvent] = []
    let op2 = USBNativeOperation(grant: g2, qemu: .init(pid: 42, uid: getuid(), startSec: 1, startUsec: 0, version: 1), launcher: io2, qmp: q2, event: { e2.append($0) })
    op2.cancel(); op2.run()
    expect(!io2.started && !io2.captureSent && q2.sent.isEmpty, "cancel before admission launches nothing and sends no capture")
    let g3 = grant(), io3 = LifecycleIO(attempt: g3.attempt), q3 = RedirectionQMP()
    io3.events = ["listening", "postcheck", "EOF"]
    var e3: [USBCaptureEvent] = []
    let op3 = USBNativeOperation(grant: g3, qemu: .init(pid: 42, uid: getuid(), startSec: 1, startUsec: 0, version: 1), launcher: io3, qmp: q3, event: { e3.append($0) })
    op3.run()
    expect(e3.contains { if case .uncertain = $0 { return true }; return false } && !q3.sent.contains("device_del"), "EOF/exit alone quarantines; no falsely released state or QMP deletion")

    // Frozen v1 first-request cancel: no capture, releasing/released(false).
    // Exercise the production operation through the session and row model too.
    for outcome in ["released", "EOF", "unreaped", "captured"] {
        let m = CaptureMachine(), d = vendorHID()
        let s = USBSession(vmName: "VM", memory: USBMemory(), machine: m, asker: FakeAsker(), clock: FakeClock(), save: { _ in }, log: { _ in })
        s.plugged(d); s.connectNow(location: d.location)
        let g = m.grants[0], io = LifecycleIO(attempt: g.attempt), q = RedirectionQMP()
        io.events = outcome == "EOF" ? ["releasing", "EOF"] : ["releasing", "released"]
        io.hidRestored = false
        io.reapResult = outcome != "unreaped"
        var emitted: [USBCaptureEvent] = []
        let op = USBNativeOperation(grant: g, qemu: .init(pid: 42, uid: getuid(), startSec: 1, startUsec: 0, version: 1), launcher: io, qmp: q, event: { emitted.append($0); m.emit?($0) })
        if outcome != "captured" {
            io.onStart = { s.disconnectNow(location: d.location); op.cancel() }
        }
        io.onReap = {
            expect(s.plugs[d.location]?.state == .releasing, "cancelled attempt retains cleanup owner before process reap completes")
            expect(!emitted.contains { if case .refused = $0 { return true }; if case .released = $0 { return true }; return false }, "no terminal cancellation or release emitted before native release and reap")
        }
        op.run()
        expect(io.captureSent == (outcome == "captured") && io.reapCalled && q.sent.isEmpty, "first-cancel fixture never sends capture or creates QMP ownership")
        let rows = USBListRows.make(memory: s.memory, devices: [d], states: s.plugs.mapValues(\.state), vmName: "VM")
        expect(!emitted.contains(.released(hidRestored: true)), "cancellation never fabricates HID restoration")
        switch outcome {
        case "released":
            expect(emitted.last == .refused("Cancelled before capture"), "first cancel with native release and reap is a retryable no-capture refusal")
            expect(rows.plugged.first?.canConnect == true && rows.plugged.first?.status.contains("Cancelled") == true, "cancel during administrator prompt offers explicit retry without HID warning")
            s.connectNow(location: d.location)
            expect(m.grants.count == 2 && m.grants[0].attempt != m.grants[1].attempt, "proven no-capture cancellation admits only a fresh explicit attempt")
        case "captured":
            expect(emitted.last == .released(hidRestored: false) && rows.plugged.first?.canConnect == false, "sent capture without HID restoration remains ended and not retryable")
        default:
            expect(emitted.last.map { if case .uncertain = $0 { return true }; return false } == true && rows.plugged.first?.canConnect == false, "no-capture cancellation without release proof or successful reap stays quarantined")
        }
        io.onStart = nil; io.onReap = nil
    }
}

final class LifecycleIO: USBNativeLaunching, USBNativeChannel {
    let attempt: UUID
    var events = ["listening", "postcheck", "releasing", "released"]
    var started = false, captureSent = false, reapCalled = false
    var refuseCancelAfterReleasing = false, releasing = false
    var hidRestored = true, reapResult = true
    var onStart: (() -> Void)?, onReap: (() -> Void)?
    init(attempt: UUID) { self.attempt = attempt }
    func start(_ grant: USBCaptureGrant, cancelled: () -> Bool) throws -> USBNativeChannel { started = true; onStart?(); return self }
    func send(_ data: Data) throws {
        let text = String(data: data, encoding: .utf8)!
        if text.contains("cancel"), releasing, refuseCancelAfterReleasing { throw USBNativeError("EPIPE after releasing; released is still buffered") }
        captureSent = captureSent || text.contains("capture")
    }
    func receive(timeoutMS: Int32) throws -> Data? {
        let event = events.removeFirst()
        if event == "releasing" { releasing = true }
        if event == "EOF" { throw USBNativeError("fixture EOF") }
        return Data("{\"schema\":1,\"attempt\":\"\(attempt.uuidString.lowercased())\",\"event\":\"\(event)\",\"hid_restored\":\(hidRestored)}\n".utf8)
    }
    func reap(timeout: Double) -> Bool { reapCalled = true; onReap?(); return reapResult }
    func close() {}
    func finishRequests() {}
    func qemuIsDead(_ identity: USBProcessIdentity) -> Bool { false }
}
