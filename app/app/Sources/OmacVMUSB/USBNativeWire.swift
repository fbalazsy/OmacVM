import Foundation
import Darwin

public struct USBNativeError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct USBProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let uid: UInt32
    public let startSec: UInt64
    public let startUsec: UInt64
    public let version: UInt32
    enum CodingKeys: String, CodingKey { case pid, uid, version; case startSec = "start_sec", startUsec = "start_usec" }
    public init(pid: Int32, uid: UInt32, startSec: UInt64, startUsec: UInt64, version: UInt32) {
        self.pid = pid; self.uid = uid; self.startSec = startSec; self.startUsec = startUsec; self.version = version
    }
    public var valid: Bool { pid > 1 && startSec > 0 && startUsec < 1_000_000 && version > 0 }
    public var object: [String: Any] { ["pid": pid, "uid": uid, "start_sec": startSec, "start_usec": startUsec, "version": version] }
}

public enum USBNativeWire {
    public static let root = "/Library/PrivilegedHelperTools/org.omacvm.usb"
    public static func directory(_ attempt: UUID) -> String { root + "/run/" + attempt.uuidString.lowercased() }
    public static func capture(attempt: UUID, device: USBDevice, qemu: USBProcessIdentity) throws -> Data {
        guard device.captureCandidate, qemu.valid else { throw USBNativeError("Invalid capture identity") }
        return try encode(["schema": 1, "command": "capture", "attempt": attempt.uuidString.lowercased(),
                           "device": ["registry_id": device.registryID, "location": device.location, "vendor": device.id.vendor,
                                      "product": device.id.product, "serial": device.rawSerial], "qemu": qemu.object])
    }
    public static func cancel(_ attempt: UUID) throws -> Data {
        try encode(["schema": 1, "command": "cancel", "attempt": attempt.uuidString.lowercased()])
    }
    private static func encode(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 16384 else { throw USBNativeError("Native request exceeds bound") }
        data.append(10); return data
    }
}

public enum USBNativeEvent: Equatable {
    case listening, postcheck, releasing
    case released(hidRestored: Bool)
    case failed(String), uncertain(String)
}

public struct USBNativeFrames {
    private var bytes = Data()
    private let attempt: String
    private var phase = "initial"
    public init(attempt: UUID) { self.attempt = attempt.uuidString.lowercased() }
    public mutating func feed(_ data: Data) throws -> [USBNativeEvent] {
        var events: [USBNativeEvent] = []
        for byte in data {
            if byte != 10 {
                guard bytes.count < 16384 else { throw USBNativeError("Native status exceeds bound") }
                bytes.append(byte); continue
            }
            struct Wire: Decodable { let schema: Int; let attempt: String; let event: String; let message: String?; let hid_restored: Bool? }
            let w = try JSONDecoder().decode(Wire.self, from: bytes); bytes.removeAll(keepingCapacity: true)
            guard w.schema == 1, w.attempt == attempt else { throw USBNativeError("Stale native status") }
            let transitions: [String: Set<String>] = ["initial": ["listening", "failed", "releasing", "uncertain"],
                "listening": ["postcheck", "releasing", "uncertain"], "postcheck": ["releasing", "uncertain"],
                "releasing": ["released", "uncertain"], "uncertain": ["releasing", "released"], "released": [], "failed": []]
            guard transitions[phase]?.contains(w.event) == true else { throw USBNativeError("Unordered native status") }
            phase = w.event
            let message = USBChoice.clean(w.message ?? "Native helper refused capture")
            switch w.event {
            case "listening": events.append(.listening)
            case "postcheck": events.append(.postcheck)
            case "releasing": events.append(.releasing)
            case "released": events.append(.released(hidRestored: w.hid_restored ?? false))
            case "failed": events.append(.failed(message))
            case "uncertain": events.append(.uncertain(message))
            default: throw USBNativeError("Unknown native status")
            }
        }
        return events
    }
}

/// One owner, one serial I/O thread. Nonblocking and bounded; no active-session lifetime limit.
public final class USBControlSocket {
    private var fd: Int32
    public init(connectedDescriptor: Int32, expectedUID: uid_t) throws {
        fd = connectedDescriptor
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == expectedUID else {
            Darwin.close(fd); fd = -1; throw USBNativeError("Native control peer UID mismatch")
        }
        var one: Int32 = 1
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(fd); fd = -1; throw USBNativeError("Cannot configure native control socket")
        }
    }
    public convenience init(attempt: UUID) throws {
        let path = USBNativeWire.directory(attempt) + "/control.sock"
        var info = stat()
        // Native grants the app access via UID-owned 0600 sockets; their enclosing
        // path is root-owned and peer credentials MUST still be root, not the owner.
        for directory in ["/Library", "/Library/PrivilegedHelperTools", USBNativeWire.root,
                          USBNativeWire.root + "/run", USBNativeWire.directory(attempt)] {
            guard lstat(directory, &info) == 0, info.st_uid == 0,
                  info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0 else {
                throw USBNativeError("Unprotected native control directory")
            }
        }
        guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK,
              info.st_mode & 0o077 == 0 else { throw USBNativeError("Native control endpoint not ready") }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw USBNativeError("Cannot create native control socket") }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(fd); throw USBNativeError("Cannot configure native connect")
        }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(fd); throw USBNativeError("Native path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.initializeMemory(as: UInt8.self, repeating: 0); $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if result != 0 {
            guard errno == EINPROGRESS else { Darwin.close(fd); throw USBNativeError("Native control not listening") }
            var pending = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard poll(&pending, 1, 100) > 0, getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                Darwin.close(fd); throw USBNativeError("Native control connect pending")
            }
        }
        try self.init(connectedDescriptor: fd, expectedUID: 0)
    }
    deinit { close() }
    public func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    public func finishRequests() { if fd >= 0 { _ = shutdown(fd, SHUT_WR) } }
    public func send(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 16385 else { throw USBNativeError("Native output exceeds bound") }
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                guard DispatchTime.now().uptimeNanoseconds < deadline else { throw USBNativeError("Native output stalled") }
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n > 0 { offset += n }
                else if n < 0 && errno == EINTR { continue }
                else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0); _ = poll(&p, 1, 50)
                } else { throw USBNativeError("Native control write failed") }
            }
        }
    }
    public func receive(timeoutMS: Int32) throws -> Data? {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let n = poll(&p, 1, timeoutMS)
        if n == 0 || (n < 0 && errno == EINTR) { return nil }
        guard n > 0 else { throw USBNativeError("Native control poll failed") }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return nil }
        guard count > 0 else { throw USBNativeError("Native control ended without release proof") }
        return Data(bytes.prefix(count))
    }
}
