import Foundation
import CoreFoundation

public enum USBQMPValue {
    case value(Any)
    case rejected(String) // matched QMP error; no mutation ownership
    case unknown(String) // possibly sent; quarantine, never delete by guessed ID
}
public protocol USBPrivilegedQMPTransport {
    func command(_ name: String, _ arguments: [String: Any]) -> USBQMPValue
}

/// Confined to one attempt's serial queue. Own only definitively CREATED objects.
/// Selective port of the archived native broker's mutation/cleanup rules, not its lease/enrollment.
public final class USBRedirection {
    public enum Ownership { case absent, created, rejected, unknown }
    public private(set) var backend: Ownership = .absent
    public private(set) var frontend: Ownership = .absent
    public let frontendID: String
    public let backendID: String
    private let qmp: USBPrivilegedQMPTransport
    public init(attempt: UUID, qmp: USBPrivilegedQMPTransport) {
        frontendID = "usbr-" + attempt.uuidString.lowercased()
        backendID = frontendID + "-c"
        self.qmp = qmp
    }
    public func create(socket: String, cancelled: () -> Bool) -> Bool {
        guard !cancelled(), backend == .absent, frontend == .absent else { return false }
        backend = .unknown
        backend = ownership(qmp.command("chardev-add", ["id": backendID, "backend": ["type": "socket", "data": [
            "addr": ["type": "unix", "data": ["path": socket]], "server": false, "reconnect-ms": 0]]]))
        guard backend == .created, !cancelled() else { return false }
        frontend = .unknown
        frontend = ownership(qmp.command("device_add", ["driver": "usb-redir", "id": frontendID,
                                                         "chardev": backendID, "bus": USBQMP.controller + ".0"]))
        return frontend == .created && !cancelled()
    }
    private func ownership(_ reply: USBQMPValue) -> Ownership {
        switch reply {
        case .value(let v): return (v as? [String: Any])?.isEmpty == true ? .created : .unknown
        case .rejected: return .rejected
        case .unknown: return .unknown
        }
    }
    public func ready(nativePostcheck: Bool) -> Bool {
        guard nativePostcheck, backend == .created, frontend == .created else { return false }
        let reads = [("/machine/peripheral/" + frontendID, "type"),
                     ("/machine/peripheral/" + frontendID, "chardev"),
                     ("/machine/peripheral/" + frontendID, "attached"),
                     ("/chardevs/" + backendID, "connected")]
        // Two coherent passes; existence or frontend-open is never attachment proof.
        for _ in 0..<2 {
            for (i, read) in reads.enumerated() {
                guard case .value(let value) = qmp.command("qom-get", ["path": read.0, "property": read.1]) else { return false }
                if i == 0 { guard value as? String == "usb-redir" else { return false } }
                else if i == 1 { guard value as? String == backendID else { return false } }
                else { guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID(), n.boolValue else { return false } }
            }
        }
        return true
    }
    public func cleanup(nativeReleased: Bool, reaped: Bool, qemuDead: Bool,
                        wait: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Bool {
        guard nativeReleased, reaped else { return false }
        if qemuDead { frontend = .absent; backend = .absent; return true }
        guard frontend != .unknown, backend != .unknown else { return false }
        if frontend == .created {
            guard remove(frontendID, parent: "/machine/peripheral", command: "device_del", wait: wait) else { return false }
            frontend = .absent
        }
        if backend == .created {
            guard remove(backendID, parent: "/chardevs", command: "chardev-remove", wait: wait) else { return false }
            backend = .absent
        }
        return true
    }
    private func remove(_ id: String, parent: String, command: String, wait: (Double) -> Void) -> Bool {
        for i in 0..<20 {
            guard case .value(let v) = qmp.command("qom-list", ["path": parent]),
                  let rows = v as? [[String: Any]], rows.allSatisfy({ $0["name"] is String }) else { return false }
            if !rows.contains(where: { $0["name"] as? String == id }) { return true }
            if i == 0 {
                // Even a lost delete reply is resolved only by later typed absence proof.
                _ = qmp.command(command, ["id": id])
            }
            wait(0.05)
        }
        return false
    }
}
