import Foundation
import Darwin
import CryptoKit
import OmacVMUSB

// PARENT-ONLY live gate. Build without running. No AppDelegate, Runner,
// USBWatch, app registration, helper or netd; actual production guard/QMP path.
enum HelperError: Error { case io(String) }
struct TracedSocket: USBQMPTransport {
    let socket: USBQMPSocket
    func execute(_ command:String,_ arguments:[String:Any]?) throws -> [String:Any] {
        let request = try JSONSerialization.data(withJSONObject:["execute":command,"arguments":arguments ?? [:]],options:.sortedKeys)
        print("REQUEST " + String(decoding:request,as:UTF8.self)); fflush(stdout)
        do {
            let result = try socket.execute(command,arguments)
            let bytes = try JSONSerialization.data(withJSONObject:result,options:.sortedKeys)
            print("RECEIPT " + String(decoding:bytes,as:UTF8.self)); fflush(stdout)
            return result
        } catch { print("TRANSPORT_ERROR \(error)"); fflush(stdout); throw error }
    }
}
@main struct LiveCoexistence {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 8, let duration = Double(args[6]), duration > 0, duration <= 86400 else {
            print("usage: live-coexistence QEMU_EXEC QEMU_ARGV_JSON QMP_SOCKET TARGET_JSON DESCRIPTOR_BIN HOLD_SECONDS SOURCE_ID"); exit(2)
        }
        let executable = URL(fileURLWithPath:args[1]).standardizedFileURL
        guard args[1].hasPrefix("/"), FileManager.default.isExecutableFile(atPath:executable.path),
              let argv = try JSONSerialization.jsonObject(with:LiveControl.readFile(args[2])) as? [String],
              !argv.contains("-daemonize"),
              let display = argv.firstIndex(of:"-display"), display + 1 < argv.count, argv[display+1] == "none",
              argv.filter({$0 == "-display"}).count == 1,
              !argv.contains("-nographic") else { throw HelperError.io("Require direct, foreground, headless QEMU argv (-display none), without a shell or daemonize") }
        let target = try USBCoexistenceTarget(wire:USBCoexistenceCodec.decode(LiveControl.readFile(args[4])))
        let descriptor = try LiveControl.readFile(args[5])
        guard target.descriptorHash == USBCoexistenceTarget.hash(descriptor) else { throw USBCoexistenceError.identity }
        // Refuse a stale/unrelated monitor before spawning the only owned child.
        guard !FileManager.default.fileExists(atPath:args[3]) else { throw HelperError.io("QMP path already exists") }
        let launcher = try USBCoexistenceTask.measure(getpid())
        let launch = USBCoexistenceCodec.launchID() // exactly once for this actual child launch
        let executableHash = SHA256.hash(data:try LiveControl.readFile(executable.path,limit:268435456)).map { String(format:"%02x",$0) }.joined()
        print("HARNESS_PID=\(getpid()) LAUNCH=\(launch) START=\(launcher.seconds):\(launcher.microseconds)")
        print("QEMU_SOURCE=\(args[7]) EXEC=\(executable.path) SHA256=\(executableHash) ARGV_FILE=\(args[2]) TARGET_FILE=\(args[4])")
        fflush(stdout)
        let process = Process()
        process.executableURL = executable
        process.arguments = argv
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey:"OMACVM_USB_REQUEST")
        process.environment = environment
        // Process.run directly spawns QEMU. QEMU captures this PID and kernel start
        // at startup; attaching to an existing/reparented QEMU is not supported.
        try process.run()
        let qemu = try USBCoexistenceTask.measure(process.processIdentifier)
        print("QEMU_PID=\(qemu.pid) START=\(qemu.seconds):\(qemu.microseconds) DIRECT_PARENT=\(launcher.pid)"); fflush(stdout)
        let socket = USBQMPSocket(path:args[3],coexistenceTask:qemu)
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        var ready = false
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            // The startup probe is ordinary QMP, but its connection still binds
            // peer PID, with a short connect/read timeout and kernel start check.
            if (try? USBCoexistenceTask.measure(qemu.pid)) != qemu { break }
            if let connection = try? QMPConnection(socketPath:args[3],identifierPrefix:"harness-start",timeoutMilliseconds:250,expectedPeerPID:qemu.pid) {
                ready = (try? connection.execute("query-status",arguments:nil,timeoutMilliseconds:250)) != nil
                connection.close()
                if ready { break }
            }
            Thread.sleep(forTimeInterval:0.1)
        }
        guard ready else {
            // No prepare or guard has run, so terminating only our child is safe.
            if process.isRunning { process.terminate() }
            throw HelperError.io("Owned QEMU QMP startup failed within 15 seconds; no prepare sent")
        }
        let controller = LiveCoexistenceController(process:process,transport:TracedSocket(socket:socket),launcher:launcher,qemu:qemu,launch:launch)
        controller.start(target:target,descriptor:descriptor,duration:duration)
        dispatchMain()
    }
}
