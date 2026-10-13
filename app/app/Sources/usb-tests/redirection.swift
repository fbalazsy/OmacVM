import Foundation
import OmacVMUSB

func redirectionTests(expect: (Bool, String) -> Void) {
    let q = RedirectionQMP(), owner = USBRedirection(attempt: UUID(), qmp: RedirectionQMP())
    let r = USBRedirection(attempt: UUID(), qmp: q)
    expect(r.create(socket: "/protected/usb.sock", cancelled: { false }), "native listening creates backend and frontend")
    let data = (q.arguments[0]["backend"] as? [String: Any])?["data"] as? [String: Any]
    expect(data?["server"] as? Bool == false && data?["wait"] == nil && data?["reconnect-ms"] as? Int == 0, "socket-client omits wait and disables reconnect")
    expect(!r.ready(nativePostcheck: false), "listening is not postcheck or Connected")
    expect(r.ready(nativePostcheck: true), "Connected requires typed QOM binding, attached and connected with postcheck")
    q.numericBool = true
    expect(!r.ready(nativePostcheck: true), "numeric 1 is not a typed QMP Boolean")
    q.numericBool = false
    expect(!r.cleanup(nativeReleased: false, reaped: true, qemuDead: false) && !q.sent.contains("device_del"), "never delete QMP before native release")
    expect(r.cleanup(nativeReleased: true, reaped: true, qemuDead: false) && q.sent.suffix(2) == ["chardev-remove", "qom-list"], "release and reap precede owned QMP removal/readback")
    let unknown = RedirectionQMP(); unknown.createReply = .unknown("timeout")
    let u = USBRedirection(attempt: UUID(), qmp: unknown)
    expect(!u.create(socket: "/protected/u.sock", cancelled: { false }), "ambiguous create quarantines")
    expect(!u.cleanup(nativeReleased: true, reaped: true, qemuDead: false) && !unknown.sent.contains("chardev-remove"), "ambiguous QMP ownership never grants delete authority")
    expect(u.cleanup(nativeReleased: true, reaped: true, qemuDead: true), "exact old QEMU ESRCH plus native release retires ownership without replacement monitor")
    let rejected = RedirectionQMP(); rejected.createReply = .rejected("duplicate id")
    let collision = USBRedirection(attempt: UUID(), qmp: rejected)
    expect(!collision.create(socket: "/p/s", cancelled: { false }) && collision.cleanup(nativeReleased: true, reaped: true, qemuDead: false) && !rejected.sent.contains("chardev-remove"), "definitive collision never deletes foreign objects")
    expect(!owner.ready(nativePostcheck: true), "postcheck alone never proves QMP ownership")
}

final class RedirectionQMP: USBPrivilegedQMPTransport {
    var sent: [String] = [], arguments: [[String: Any]] = []
    var objects: [String: Set<String>] = [:]
    var charID = "", frontID = ""
    var numericBool = false
    var createReply: USBQMPValue = .value([String: Any]())
    func command(_ name: String, _ args: [String: Any]) -> USBQMPValue {
        sent.append(name); arguments.append(args)
        switch name {
        case "chardev-add":
            if case .value = createReply { charID = args["id"] as! String; objects["/chardevs", default: []].insert(charID) }
            return createReply
        case "device_add": frontID = args["id"] as! String; objects["/machine/peripheral", default: []].insert(frontID); return .value([String: Any]())
        case "qom-get":
            switch args["property"] as? String {
            case "type": return .value("usb-redir")
            case "chardev": return .value(charID)
            default: return numericBool ? .value(NSNumber(value: 1)) : .value(true)
            }
        case "qom-list": return .value(objects[args["path"] as! String, default: []].map { ["name": $0] })
        case "device_del": objects["/machine/peripheral"]?.remove(args["id"] as! String); return .value([String: Any]())
        case "chardev-remove": objects["/chardevs"]?.remove(args["id"] as! String); return .value([String: Any]())
        default: return .unknown("unexpected")
        }
    }
}
