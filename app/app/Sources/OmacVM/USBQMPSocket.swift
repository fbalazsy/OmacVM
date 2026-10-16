import Foundation
import OmacVMUSB

/// One short QMP connection per command. No retained monitor lease: network,
/// sleep and unrelated ordinary USB remain able to use QEMU's control socket.
struct USBQMPSocket: USBQMPTransport {
    let path: String
    var emulated = false
    var coexistenceTask: USBCoexistenceTask? = nil
    func execute(_ command: String, _ arguments: [String: Any]?) throws -> [String: Any] {
        var args = arguments
        if emulated, command == "device_add", args?["driver"] as? String == "usb-host" {
            args = ["driver": "usb-tablet", "id": args?["id"] ?? "", "bus": args?["bus"] ?? ""]
        }
        let coexistence = command.hasPrefix("x-omacvm-usb-coexistence-")
        if coexistence {
            guard let task = coexistenceTask, (try? USBCoexistenceTask.measure(task.pid)) == task else { throw USBCoexistenceError.identity }
        }
        let q = try QMPConnection(socketPath: path, identifierPrefix: "omacvm-usb",
                                  timeoutMilliseconds:coexistence ? 500 : 2000,
                                  expectedPeerPID:coexistence ? coexistenceTask?.pid : nil)
        defer { q.close() }
        return try q.execute(command, arguments: args, timeoutMilliseconds: coexistence ? 750 : 3_000)
    }
}
