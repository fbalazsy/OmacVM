import Foundation
import OmacVMUSB

func privilegedTests(expect: (Bool, String) -> Void) {
    // Even driverless HID is not ordinary usb-host: class alone cannot prove safety.
    let unknown = USBDevice(id: .init(vendor: 0x1234, product: 0x5678), name: "Unknown HID", deviceClass: 0,
                            interfaces: [.init(number: 0, interfaceClass: 3, users: [])])
    expect(unknown.availability != .free, "HID without a proven vendor report never bypasses privileged policy via usb-host")
    var vendor = vendorHID()
    expect(vendor.captureCandidate, "complete nonboot vendor report is a preliminary candidate, not root authorization")
    expect(vendor.serial == "shown" && vendor.rawSerial == " raw\nserial ", "raw selection identity is separate from display serial")
    for identity in ["empty raw serial", "zero vendor"] {
        var invalid = vendorHID()
        if identity == "empty raw serial" { invalid.rawSerial = "" }
        else { invalid.id = .init(vendor: 0, product: invalid.id.product) }
        expect(!invalid.captureCandidate, "v1 identity rejects \(identity) before authorization")
        let m = CaptureMachine()
        var memory = USBMemory(); memory.remember(invalid, .omarchy)
        let s = USBSession(vmName: "VM", memory: memory, machine: m, asker: FakeAsker(), clock: FakeClock(), save: { _ in }, log: { _ in })
        s.plugged(invalid)
        let rows = USBListRows.make(memory: memory, devices: [invalid], states: s.plugs.mapValues(\.state), vmName: "VM")
        s.connectNow(location: invalid.location)
        expect(m.grants.isEmpty && m.ordinaryAttaches == 0, "invalid \(identity) cannot prompt or fall back to ordinary usb-host")
        expect(rows.remembered.first?.canConnect == false && rows.remembered.first?.status.isEmpty == false, "invalid \(identity) stays visibly unavailable even when remembered Always")
    }
    var rawOnly = vendorHID(); rawOnly.serial = ""; rawOnly.rawSerial = " "
    expect(rawOnly.captureCandidate, "v1 raw serial nonempty check never trims or substitutes display identity")
    vendor.interfaces[0].interfaceProtocol = 1
    expect(!vendor.captureCandidate, "boot keyboard protocol refused")
    vendor = vendorHID(); vendor.interfaces[0].reportDescriptor = Data([0x05, 1, 0x09, 6, 0xa1, 1, 0xc0])
    expect(!vendor.captureCandidate, "keyboard usage page refused even under nonboot interface")
    vendor = vendorHID(); vendor.registryID = 0
    expect(!vendor.captureCandidate, "missing registry generation refused")
    vendor = vendorHID(); vendor.interfaces.append(.init(number: 1, interfaceClass: 3, users: []))
    expect(!vendor.captureCandidate, "composite or unknown additional HID refused")
    let device = vendorHID(), machine = CaptureMachine(), asker = FakeAsker(), clock = FakeClock()
    var memory = USBMemory(); memory.remember(device, .omarchy)
    let session = USBSession(vmName: "Omarchy", memory: memory, machine: machine, asker: asker, clock: clock, save: { _ in }, log: { _ in })
    session.plugged(device)
    expect(machine.grants.isEmpty && asker.asked.isEmpty, "ordinary Always never authorizes privileged capture")
    var rows = USBListRows.make(memory: memory, devices: [device], states: session.plugs.mapValues(\.state), vmName: "Omarchy")
    expect(rows.remembered.first?.canConnect == true && rows.kept.isEmpty, "vendor HID has Connect in the existing list")
    session.inFront = false; session.connectNow(location: device.location)
    expect(machine.grants.isEmpty, "background click cannot authorize capture")
    session.inFront = true; session.connectNow(location: device.location)
    expect(machine.grants.count == 1 && machine.ordinaryAttaches == 0, "foreground explicit Connect creates a typed grant, never usb-host")
    machine.emit?(.connected)
    session.inFront = false; clock.advance(10000)
    expect(machine.cancels.isEmpty && session.plugs[device.location]?.state == .connected, "ready transport has no deadline and survives lost focus")
    session.disconnectNow(location: device.location)
    expect(machine.cancels.count == 1 && session.plugs[device.location]?.state == .releasing, "Disconnect keeps cleanup owner while release pending")
    machine.emit?(.uncertain("release unknown"))
    rows = USBListRows.make(memory: memory, devices: [device], states: session.plugs.mapValues(\.state), vmName: "Omarchy")
    expect(rows.remembered.first?.status.contains("unknown") == true && rows.remembered.first?.canConnect == false, "unknown release is not on Mac or reconnectable")
    machine.emit?(.released(hidRestored: true))
    expect(session.plugs[device.location]?.state == .captureAvailable, "late correlated release retires owner after cancellation")
    let rm = CaptureMachine()
    let rs = USBSession(vmName: "VM", memory: USBMemory(), machine: rm, asker: FakeAsker(), clock: FakeClock(), save: { _ in }, log: { _ in })
    rs.plugged(device)
    rs.onChange = { if rs.plugs[device.location]?.state == .authorizing { rs.stop() } }
    rs.connectNow(location: device.location)
    expect(rm.grants.isEmpty && rs.plugs.isEmpty, "reentrant stop before dispatch retires unlaunched attempt instead of stranding cleanup")
    let tm = CaptureMachine()
    let ts = USBSession(vmName: "VM", memory: USBMemory(), machine: tm, asker: FakeAsker(), clock: FakeClock(), save: { _ in }, log: { _ in })
    ts.plugged(device); ts.connectNow(location: device.location)
    let old = tm.emit
    ts.unplugged(location: device.location)
    var newer = device; newer.registryID += 1
    ts.plugged(newer)
    old?(.released(hidRestored: false))
    expect(tm.grants.count == 1 && ts.plugs[device.location]?.state == .captureAvailable && ts.plugs[device.location]?.device.registryID == newer.registryID, "new physical generation requires fresh explicit Connect after old release")
    ts.connectNow(location: newer.location); old?(.connected)
    expect(ts.plugs[newer.location]?.state == .authorizing, "late event from old attempt cannot mutate replacement attempt")
    ts.stop(); tm.emit?(.released(hidRestored: false))
    expect(ts.plugs.isEmpty, "VM stop retains cleanup owner until native release, then retires tombstone")
    for terminal in [USBCaptureEvent.released(hidRestored: false), .refused("Cancelled")] {
        let removedMachine = CaptureMachine()
        let removedSession = USBSession(vmName: "VM", memory: USBMemory(), machine: removedMachine, asker: FakeAsker(), clock: FakeClock(), save: { _ in }, log: { _ in })
        removedSession.plugged(device); removedSession.connectNow(location: device.location)
        removedSession.unplugged(location: device.location)
        removedSession.plugged(newer)
        // USBRun validates the removed registry generation against its device list
        // before passing this location-only removal of the queued replacement.
        removedSession.unplugged(location: newer.location)
        removedMachine.emit?(.uncertain("Waiting for old release"))
        expect(removedSession.plugs[device.location]?.device.registryID == device.registryID && removedSession.plugs[device.location]?.state == .uncertain("Waiting for old release"), "removing queued replacement preserves old cleanup tombstone")
        removedMachine.emit?(terminal)
        expect(removedSession.plugs.isEmpty, "removed queued generation never reappears after old release or refusal")
        removedSession.connectNow(location: newer.location)
        expect(removedMachine.grants.count == 1, "removed queued generation cannot authorize a phantom Connect")
        removedSession.plugged(newer)
        expect(removedSession.plugs[newer.location]?.state == .captureAvailable && removedMachine.grants.count == 1, "a later present generation is offered only for fresh explicit Connect")
    }
    let limitMachine = CaptureMachine()
    let limitSession = USBSession(vmName: "VM", memory: USBMemory(), machine: limitMachine, asker: FakeAsker(), clock: FakeClock(), save: { _ in }, log: { _ in })
    for index in 0..<5 {
        var d = device; d.location += UInt32(index); d.registryID += UInt64(index)
        limitSession.plugged(d); limitSession.connectNow(location: d.location)
    }
    expect(limitMachine.grants.count == 4, "pending administrator/capture attempts reserve the four USB slots")
    let deniedMachine = CaptureMachine()
    let deniedSession = USBSession(vmName: "VM", memory: USBMemory(), machine: deniedMachine, asker: FakeAsker(), clock: FakeClock(), save: { _ in }, log: { _ in })
    deniedSession.plugged(device); deniedSession.connectNow(location: device.location)
    deniedMachine.emit?(.refused("Administrator declined"))
    let deniedRows = USBListRows.make(memory: USBMemory(), devices: [device], states: deniedSession.plugs.mapValues(\.state), vmName: "VM")
    expect(deniedRows.plugged.first?.canConnect == true && deniedRows.plugged.first?.status.contains("declined") == true, "proven refusal keeps diagnostic and offers explicit retry, unlike unknown ownership")
}

final class CaptureMachine: USBMachine, USBCaptureMachine {
    var grants: [USBCaptureGrant] = []
    var cancels: [UUID] = []
    var ordinaryAttaches = 0
    var emit: ((USBCaptureEvent) -> Void)?
    func capture(_ grant: USBCaptureGrant, event: @escaping (USBCaptureEvent) -> Void) { grants.append(grant); emit = event }
    func cancelCapture(_ attempt: UUID) { cancels.append(attempt) }
    func attach(_ d: USBDevice, done: @escaping (USBAttachResult) -> Void) { ordinaryAttaches += 1; done(.busy) }
    func detach(_ d: USBDevice, done: @escaping (Bool) -> Void) { done(true) }
    func isAttached(_ d: USBDevice, done: @escaping (Bool) -> Void) { done(false) }
}

func vendorHID() -> USBDevice {
    USBDevice(id: .init(vendor: 0x1234, product: 0x5678), name: "Vendor board", deviceClass: 0,
              interfaces: [.init(number: 0, interfaceClass: 3, users: ["IOHIDDevice"], interfaceSubclass: 0,
                                 interfaceProtocol: 0, reportDescriptor: Data([0x06, 0x00, 0xff, 0x09, 1, 0xa1, 1, 0x75, 8, 0x95, 8, 0x09, 1, 0x81, 2, 0xc0]))],
              serial: "shown", location: 0x12340000, address: 4, registryID: 99, rawSerial: " raw\nserial ")
}
