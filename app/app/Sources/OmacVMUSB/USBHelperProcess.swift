import Foundation
import Darwin
import CryptoKit

public enum USBHelperProcess {
    public static func bundled(in bundle: Bundle = .main) -> URL {
        bundle.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/omacvm-usb-helper")
    }
    /// Ordinary-user process identity inspection only: never --session here.
    public static func inspect(executable: URL, pid: pid_t) throws -> USBProcessIdentity {
        guard pid > 1 else { throw USBNativeError("Invalid process PID") }
        let p = Process(), out = Pipe()
        p.executableURL = executable; p.arguments = ["--inspect-process", String(pid)]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        let fd = out.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        defer { try? out.fileHandleForReading.close() }
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        var data = Data(), bytes = [UInt8](repeating: 0, count: 2048), eof = false
        while !eof {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                if p.isRunning { p.terminate() }
                throw USBNativeError("Native process inspection timed out")
            }
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&pollFD, 1, 25)
            let n = Darwin.read(fd, &bytes, bytes.count)
            if n > 0 { data.append(contentsOf: bytes.prefix(n)) }
            else if n == 0 { eof = true }
            else if errno != EAGAIN && errno != EINTR { throw USBNativeError("Cannot read native process identity") }
            guard data.count <= 16384 else {
                if p.isRunning { p.terminate() }; throw USBNativeError("Native identity exceeds bound")
            }
        }
        // A process may close stdout before exiting. The same startup budget
        // covers its reap; never waitUntilExit unbounded after a pipe EOF.
        while p.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if p.isRunning {
            // This is ONLY our ordinary-user --inspect-process child, never root/session.
            _ = Darwin.kill(p.processIdentifier, SIGKILL)
            p.waitUntilExit()
            throw USBNativeError("Native process inspection timed out")
        }
        p.waitUntilExit()
        struct Schema: Decodable { let schema: Int }
        guard p.terminationStatus == 0, try JSONDecoder().decode(Schema.self, from: data).schema == 1 else { throw USBNativeError("Native process inspection refused") }
        let identity = try JSONDecoder().decode(USBProcessIdentity.self, from: data)
        guard identity.valid, identity.pid == pid else { throw USBNativeError("Invalid native process generation") }
        return identity
    }
    /// Builds the real process without launching it (unit tests never authorize).
    public static func authorization(executable: URL, attempt: UUID, app: USBProcessIdentity) throws -> Process {
        let info = try executable.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize, size > 0, size <= 64 * 1024 * 1024 else { throw USBNativeError("Bundled USB helper is missing or invalid") }
        let data = try Data(contentsOf: executable)
        // Refuse interpreted payloads; static dependency closure is independently
        // checked by packaging and the native helper's protected-path self-check.
        let magic = Array(data.prefix(4))
        guard [[0xcf, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf],
               [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
               [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca]].contains(magic) else {
            throw USBNativeError("Privileged payload must be a native Mach-O executable")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let command = try USBHelperInstall.command(source: executable.path, sha256: digest, attempt: attempt, app: app)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", USBHelperInstall.appleScript(command)]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        return p
    }
}

public enum USBLaunchFailure: Error { case beforeCapture(String) }

public final class USBHelperLauncher: USBNativeLaunching {
    private let executable: URL
    private let app: USBProcessIdentity
    public init(executable: URL, app: USBProcessIdentity) { self.executable = executable; self.app = app }
    public func start(_ grant: USBCaptureGrant, cancelled: () -> Bool) throws -> USBNativeChannel {
        if cancelled() { throw USBLaunchFailure.beforeCapture("Cancelled before authorization") }
        let p: Process
        do {
            p = try USBHelperProcess.authorization(executable: executable, attempt: grant.attempt, app: app)
            if cancelled() { throw USBLaunchFailure.beforeCapture("Cancelled before authorization") }
            try p.run()
        } catch { throw USBLaunchFailure.beforeCapture("Administrator authorization or helper installation failed") }
        let deadline = DispatchTime.now().uptimeNanoseconds + 120_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let control = try? USBControlSocket(attempt: grant.attempt) {
                return USBHelperChannel(process: p, socket: control)
            }
            if !p.isRunning { p.waitUntilExit(); throw USBLaunchFailure.beforeCapture("Administrator authorization declined or helper failed before capture") }
            // On cancellation during the OS prompt, keep waiting for a late connection:
            // the operation sends cancel FIRST; never capture after revoked consent.
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning { p.terminate() }
        throw USBNativeError("Authorization startup expired; helper cleanup not confirmed")
    }
}

private final class USBHelperChannel: USBNativeChannel {
    let process: Process, socket: USBControlSocket
    init(process: Process, socket: USBControlSocket) { self.process = process; self.socket = socket }
    func send(_ data: Data) throws { try socket.send(data) }
    func receive(timeoutMS: Int32) throws -> Data? { try socket.receive(timeoutMS: timeoutMS) }
    func close() { socket.close() }
    func finishRequests() { socket.finishRequests() }
    func reap(timeout: Double) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { Thread.sleep(forTimeInterval: 0.025) }
        guard !process.isRunning else { return false }
        process.waitUntilExit(); return true
    }
    func qemuIsDead(_ identity: USBProcessIdentity) -> Bool {
        // EPERM, PID reuse or changed generation is not death evidence.
        Darwin.kill(identity.pid, 0) == -1 && errno == ESRCH
    }
}
