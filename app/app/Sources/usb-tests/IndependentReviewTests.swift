import Foundation
import Darwin
import OmacVMUSB

// Inert socketpair QMP peer. This is not a real QEMU/USB connection.
// The exact production QMPConnection is compiled beside this test file.
final class ReviewPeer: USBQMPTransport {
    enum Mode { case normal, addEOF, addTimeout, addReject, infoFailureDeleteReject, deleteEOF }
    var mode: Mode = .normal
    var addEnvelope: [String: Any]?
    var rejectionDetail = "selected HID registry generation is absent"
    var closeBeforeCommand = false
    var owns = false
    var calls: [String] = []
    var drivers: [String] = []
    func execute(_ command: String, _ arguments: [String: Any]?) throws -> [String: Any] {
        calls.append(command)
        if command == "device_add" { drivers.append(arguments?["driver"] as? String ?? "?") }
        var fd: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fd) == 0 else { fatalError("socketpair") }
        for f in fd {
            var one: Int32 = 1
            _ = setsockopt(f, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        let server = fd[1]
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { [self] in
            defer { Darwin.close(server); group.leave() }
            func readObject() -> [String: Any]? {
                var data = Data(), byte: UInt8 = 0
                while Darwin.read(server, &byte, 1) == 1 {
                    if byte == 10 { return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
                    if byte != 13 { data.append(byte) }
                }
                return nil
            }
            func send(_ o: [String: Any]) { try? QMPConnection.writeJSON(o, to: server) }
            send(["QMP": [:]])
            guard let caps = readObject() else { return }
            send(["id": caps["id"]!, "return": [:]])
            guard let request = readObject() else { return }
            var response: [String: Any] = ["id": request["id"]!, "return": [:]]
            switch command {
            case "device_add":
                if mode == .addReject {
                    response = ["id": request["id"]!, "error": ["class": "GenericError", "desc": rejectionDetail]]
                } else {
                    owns = true
                    if mode == .addEOF { return }
                    if mode == .addTimeout { Thread.sleep(forTimeInterval: 0.75); return }
                }
            case "device_del":
                if mode == .infoFailureDeleteReject {
                    response = ["id": request["id"]!, "error": ["class": "GenericError", "desc": "inert refusal to release"]]
                } else if !owns {
                    response = ["id": request["id"]!, "error": ["class": "DeviceNotFound", "desc": "Device not found"]]
                } else {
                    owns = false
                    if mode == .deleteEOF { return }
                }
            default:
                if mode == .infoFailureDeleteReject { return }
                response["return"] = owns ? "  Device 0.1, Port 1, Speed 12 Mb/s, Product Fixture, ID: usbh-01100000\n" : ""
            }
            if command == "device_add", let envelope = addEnvelope {
                response = envelope
                response["id"] = request["id"]!
            }
            send(response)
        }
        defer { group.wait() }
        let q = try QMPConnection(connectedDescriptor: fd[0], identifierPrefix: "org.omacvm.app.test.independent-review", timeoutMilliseconds: 500, expectedPeerPID: getpid())
        defer { q.close() }
        if closeBeforeCommand { q.close() }
        return try q.execute(command, arguments: arguments, timeoutMilliseconds: 500)
    }
}

final class ReviewMachine: USBMachine {
    let qmp = ReviewPeer()
    var holdAttach = false
    var finishAttach: (() -> Void)?
    func attach(_ d: USBDevice, done: @escaping (USBAttachResult) -> Void) {
        let r = USBQMP.attach(d, over: qmp, wait: { _ in })
        if holdAttach { finishAttach = { done(r) } } else { done(r) }
    }
    func detach(_ d: USBDevice, done: @escaping (Bool) -> Void) {
        done(USBQMP.detach(location: d.location, over: qmp, confirmDelete: d.hid != nil, wait: { _ in }))
    }
    func isAttached(_ d: USBDevice, done: @escaping (Bool) -> Void) {
        done((try? USBQMP.attached(over: qmp))?.contains(USBQMP.qemuID(location: d.location)) ?? false)
    }
}

func independentReviewTests() {
    print("BEGIN INDEPENDENT REVIEW PROBES")
    for shape in ["keyboard/mouse", "FIDO", "mixed", "composite"] {
        var tree = hidTree()
        switch shape {
        case "keyboard/mouse": tree.children[0].children[0].properties["ReportDescriptor"] = Data([0x05, 1]) + vendorDescriptor.dropFirst(3)
        case "FIDO": tree.children[0].children[0].properties["ReportDescriptor"] = Data([0x06, 0xd0, 0xf1]) + vendorDescriptor.dropFirst(3)
        case "mixed": tree.children[0].children[0].properties["ReportDescriptor"] = vendorDescriptor.dropLast() + Data([0x05, 7, 0xc0])
        default: tree.children.append(tree.children[0])
        }
        let blocked = USBScan.device(tree)!
        var allBlocked = true
        for serial in ["", blocked.serial] {
            let memory = USBMemory(devices: [.init(vendor: "1209", product: "0007", serial: serial, name: "Legacy or exact Always", choice: .omarchy)])
            let (s, m, a, _, _, _) = rig(memory)
            s.plugged(blocked)
            s.connectNow(location: blocked.location)
            let r = USBListRows.make(memory: memory, devices: [blocked], states: s.plugs.mapValues(\.state), vmName: "Inert Review")
            allBlocked = allBlocked && m.log.isEmpty && a.asked.isEmpty && r.kept.count == 1
            s.stop()
        }
        expect(allBlocked, "REVIEW control \(shape) stays blocked with exact AND legacy wildcard Always routing")
    }
    let boot = USBScan.device(hidTree())!
    func session(_ m: ReviewMachine, _ a: FakeAsker, _ c: FakeClock, remembered: Bool = true) -> USBSession {
        var memory = USBMemory()
        if remembered { memory.remember(boot, .omarchy) }
        return USBSession(vmName: "Inert Review", memory: memory, machine: m, asker: a, clock: c, save: { _ in }, log: { print("review-log: \($0)") })
    }
    func rows(_ s: USBSession, _ d: USBDevice) -> USBListRows.Row? {
        let r = USBListRows.make(memory: s.memory, devices: [d], states: s.plugs.mapValues(\.state), vmName: "Inert Review")
        return (r.remembered + r.plugged).first
    }
    do {
        let m = ReviewMachine(), a = FakeAsker(), c = FakeClock()
        let s = session(m, a, c, remembered: false)
        var early = hidTree(); early.children = []
        var protected = hidTree()
        protected.children[0].children[0].properties["ReportDescriptor"] = Data([0x05, 1]) + vendorDescriptor.dropFirst(3)
        let rejected = USBScan.device(protected)!
        s.plugged(boot)
        s.plugged(rejected)
        a.answer(true)
        print("OBS R1 availability=\(rejected.availability) stored=\(String(describing:s.plugs[boot.location]?.device.availability)) state=\(String(describing:s.plugs[boot.location]?.state)) drivers=\(m.qmp.drivers)")
        expect(m.qmp.drivers.isEmpty, "REVIEW R1 revoked positive HID cancels its stale question before attach")
        s.stop()
    }
    for mode in [ReviewPeer.Mode.addEOF, .addTimeout] {
        let m = ReviewMachine(), a = FakeAsker(), c = FakeClock()
        m.qmp.mode = mode
        let s = session(m, a, c); s.plugged(boot)
        let r = rows(s, boot)!
        print("OBS R2 mode=\(mode) owned=\(m.qmp.owns) state=\(String(describing:s.plugs[boot.location]?.state)) canConnect=\(r.canConnect) canDisconnect=\(r.canDisconnect) calls=\(m.qmp.calls)")
        expect(!m.qmp.owns || (!r.canConnect && r.canDisconnect), "REVIEW R2 applied add with \(mode) keeps cleanup ownership, not On Mac/Connect")
        s.stop()
    }
    do {
        let m = ReviewMachine(), a = FakeAsker(), c = FakeClock()
        m.qmp.mode = .infoFailureDeleteReject
        let s = session(m, a, c); s.plugged(boot)
        let r = rows(s, boot)!
        print("OBS R3 owned=\(m.qmp.owns) state=\(String(describing:s.plugs[boot.location]?.state)) canConnect=\(r.canConnect) canDisconnect=\(r.canDisconnect) calls=\(m.qmp.calls)")
        expect(!m.qmp.owns || (!r.canConnect && r.canDisconnect), "REVIEW R3 post-add read failure and failed rollback retains cleanup ownership")
        s.stop()
    }
    do {
        let m = ReviewMachine(), a = FakeAsker(), c = FakeClock()
        let s = session(m, a, c); s.plugged(boot)
        m.qmp.mode = .deleteEOF
        s.disconnectNow(location: boot.location)
        let r = rows(s, boot)!
        print("OBS CONTROL lost-delete owned=\(m.qmp.owns) state=\(String(describing:s.plugs[boot.location]?.state)) canConnect=\(r.canConnect)")
        expect(!r.canConnect && s.plugs[boot.location]?.state == .releaseFailed, "REVIEW control lost delete reply is conservatively releaseFailed")
        s.stop()
    }
    do {
        let m = ReviewMachine(), a = FakeAsker(), c = FakeClock()
        m.qmp.mode = .addReject; m.holdAttach = true
        let s = session(m, a, c); s.plugged(boot); s.unplugged(location: boot.location)
        m.finishAttach?(); c.advance(USBSession.grace)
        print("OBS R4 owned=\(m.qmp.owns) state=\(String(describing:s.plugs[boot.location]?.state)) calls=\(m.qmp.calls)")
        expect(s.plugs.isEmpty, "REVIEW R4 definitive native add rejection plus unplug creates no phantom release debt")
        s.stop()
    }
    do {
        var r = USBWatch.Reads()
        let old = r.begin(11), new = r.begin(12)
        let acceptedNew = r.finish(12, ticket: new, location: 1)
        let acceptedOld = r.finish(11, ticket: old, location: 1)
        let removeNew = r.remove(12), removeOld = r.remove(11)
        print("OBS R5 newer=\(acceptedNew) staleOlder=\(acceptedOld) removeNew=\(String(describing:removeNew)) removeOld=\(String(describing:removeOld))")
        expect(acceptedNew && !acceptedOld && removeNew == 1 && removeOld == nil, "REVIEW R5 first pending old snapshot cannot overwrite newer physical generation")
    }
    do {
        let (s, m, a, _, _, _) = rig()
        var early = hidTree(); early.children = []
        var pending = hidTree(); pending.children[0].children = []
        s.plugged(USBScan.device(early)!); a.answer(false)
        s.setPlan(.omarchy, for: boot)
        s.plugged(USBScan.device(pending)!)
        s.plugged(boot)
        print("OBS R6 state=\(String(describing:s.plugs[boot.location]?.state)) actions=\(m.log)")
        expect(m.log.isEmpty && s.plugs[boot.location]?.state == .onMac(remembered: false), "REVIEW R6 Keep this time survives intermediate incomplete HID before late publication")
        s.stop()
    }
    do {
        var tree = hidTree()
        tree.properties["idProduct"] = 0
        tree.children[0].children[0].properties["ProductID"] = 0
        let d = USBScan.device(tree)!
        print("OBS R7 product=\(d.id.product) available=\(d.availability) route=\(USBQMP.attachArguments(d)["driver"] ?? "?")")
        expect(d.availability != .free, "REVIEW R7 app admission matches native nonzero productid precondition")
    }
    print("END INDEPENDENT REVIEW PROBES")
}
