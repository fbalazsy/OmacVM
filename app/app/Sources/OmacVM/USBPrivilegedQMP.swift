import Foundation
import OmacVMUSB

/// A short authenticated transaction, never a monitor retained across the OS prompt
/// or transport lifetime. QMPConnection handles framing/IDs; helper supplies exec generation.
struct USBPrivilegedQMP: USBPrivilegedQMPTransport {
    let path: String
    let identity: USBProcessIdentity
    let helper: URL
    func command(_ name: String, _ arguments: [String: Any]) -> USBQMPValue {
        do {
            guard try USBHelperProcess.inspect(executable: helper, pid: identity.pid) == identity else {
                return .unknown("QEMU generation changed")
            }
            let q = try QMPConnection(socketPath: path, identifierPrefix: "omacvm-usbr-" + UUID().uuidString,
                                      expectedPeerPID: identity.pid)
            defer { q.close() }
            // Bind both sides of the command to the frozen run, including exec generation.
            guard try USBHelperProcess.inspect(executable: helper, pid: identity.pid) == identity else {
                return .unknown("QEMU changed before command")
            }
            let value = try q.executeValue(name, arguments: arguments, timeoutMilliseconds: 3_000)
            guard try USBHelperProcess.inspect(executable: helper, pid: identity.pid) == identity else {
                return .unknown("QEMU changed after command")
            }
            return .value(value)
        } catch let rejection as QMPConnection.Rejected {
            return .rejected(rejection.localizedDescription)
        } catch {
            // Includes inability to authenticate before sending: no delete authority.
            return .unknown(USBChoice.clean(error.localizedDescription))
        }
    }
}
