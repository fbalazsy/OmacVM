import Foundation
import Darwin
import OmacVMUSB

func nativeWireTests(expect: (Bool, String) -> Void) {
    let attempt = UUID(), id = attempt.uuidString.lowercased()
    var frame = USBNativeFrames(attempt: attempt)
    let listening = Data("{\"schema\":1,\"attempt\":\"\(id)\",\"event\":\"listening\"}\n".utf8)
    do {
        expect(try frame.feed(listening.prefix(7)).isEmpty, "native JSON frame accepts partial input without premature event")
        expect(try frame.feed(listening.dropFirst(7)) == [.listening], "native JSON frame reassembles correlated listening")
        expect(try frame.feed(Data("{\"schema\":1,\"attempt\":\"\(id)\",\"event\":\"postcheck\"}\n".utf8)) == [.postcheck], "native postcheck follows listening")
        do { _ = try frame.feed(listening); expect(false, "native duplicate listening rejected") } catch { expect(true, "native duplicate listening rejected") }
    } catch { expect(false, "native valid frames: \(error)") }
    for text in [String(repeating: "x", count: 16385), "{\"schema\":true,\"attempt\":\"\(id)\",\"event\":\"failed\"}\n", "{\"schema\":1,\"attempt\":\"\(UUID().uuidString.lowercased())\",\"event\":\"released\"}\n"] {
        var f = USBNativeFrames(attempt: attempt)
        do { _ = try f.feed(Data(text.utf8)); expect(false, "oversized, wrong-type or stale event rejected") }
        catch { expect(true, "oversized, wrong-type or stale event rejected") }
    }
    var pair: [Int32] = [0, 0]
    expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0, "ordinary-user native stream fixture opens")
    do {
        let stream = try USBControlSocket(connectedDescriptor: pair[0], expectedUID: getuid())
        defer { stream.close(); Darwin.close(pair[1]) }
        try stream.send(Data("hello\n".utf8))
        var bytes = [UInt8](repeating: 0, count: 6)
        expect(Darwin.read(pair[1], &bytes, 6) == 6 && String(bytes: bytes, encoding: .utf8) == "hello\n", "real stream writes complete bounded message")
        stream.finishRequests()
        var endByte: UInt8 = 0
        expect(Darwin.read(pair[1], &endByte, 1) == 0, "half-close propagates app EOF while retaining native release read side")
        _ = listening.withUnsafeBytes { Darwin.write(pair[1], $0.baseAddress, $0.count) }
        expect(try stream.receive(timeoutMS: 100) == listening, "real stream receives partial-capable status bytes")
        shutdown(pair[1], SHUT_WR)
        do { _ = try stream.receive(timeoutMS: 100); expect(false, "control EOF is not release proof") }
        catch { expect(true, "control EOF is not release proof") }
    } catch { expect(false, "native ordinary socket fixture: \(error)"); Darwin.close(pair[1]) }
    _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
    do { let s = try USBControlSocket(connectedDescriptor: pair[0], expectedUID: getuid() + 1); s.close(); expect(false, "wrong peer UID refused") }
    catch { expect(true, "wrong peer UID refused") }
    Darwin.close(pair[1])
    let helper = FileManager.default.temporaryDirectory.appendingPathComponent("usb-inspect-\(UUID().uuidString)")
    do {
        try Data("#!/bin/sh\nprintf '%s\\n' '{\"schema\":1,\"pid\":42,\"uid\":501,\"start_sec\":12,\"start_usec\":34,\"version\":56}'\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        defer { try? FileManager.default.removeItem(at: helper) }
        let inspected = try USBHelperProcess.inspect(executable: helper, pid: 42)
        expect(inspected.pid == 42 && inspected.version == 56 && inspected.startSec == 12, "ordinary process fixture exercises concrete --inspect-process launcher")
        do {
            _ = try USBHelperProcess.authorization(executable: helper, attempt: attempt,
                app: USBProcessIdentity(pid: 42, uid: 501, startSec: 12, startUsec: 34, version: 56))
            expect(false, "authorization refuses script payloads even before administrator launch")
        } catch { expect(true, "authorization refuses script payloads even before administrator launch") }
        let spec = try USBHelperProcess.authorization(executable: URL(fileURLWithPath: "/usr/bin/true"), attempt: attempt,
            app: USBProcessIdentity(pid: 42, uid: 501, startSec: 12, startUsec: 34, version: 56))
        expect(spec.executableURL?.path == "/usr/bin/osascript" && spec.arguments?.first == "-e", "real default authorization Process is macOS osascript, not unavailable backend")
        try Data("#!/bin/sh\nexec /bin/sleep 5 1>&-\n".utf8).write(to: helper)
        let start = DispatchTime.now().uptimeNanoseconds
        do { _ = try USBHelperProcess.inspect(executable: helper, pid: 42) } catch {}
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        expect(elapsed < 4, "identity subprocess deadline includes EOF-before-exit, not just stdout reading")
    } catch { expect(false, "ordinary helper process fixture: \(error)") }
    let identity = USBProcessIdentity(pid: 42, uid: getuid(), startSec: 12, startUsec: 34, version: 56)
    do {
        let line = try USBNativeWire.capture(attempt: attempt, device: vendorHID(), qemu: identity)
        let object = try JSONSerialization.jsonObject(with: line) as! [String: Any]
        let device = object["device"] as! [String: Any]
        expect(device["serial"] as? String == " raw\nserial " && device["registry_id"] as? Int == 99, "capture request preserves raw serial and exact registry generation")
        let command = try USBHelperInstall.command(source: "/Applications/OmacVM's App.app/Contents/Library/LaunchServices/omacvm-usb-helper", sha256: String(repeating: "a", count: 64), attempt: attempt, app: identity)
        expect(command.contains("/usr/bin/shasum -a 256") && command.contains("/usr/bin/install -o root -g wheel -m 0555") && command.contains("OmacVM'\\''s App.app"), "bootstrap installs staged immutable native payload, hashes root copy and quotes source")
        expect(!command.contains("python") && !command.contains("sudo") && command.contains("--session") && command.contains("exec "), "root executes only fixed installed helper, not user script or Python")
        expect(command.contains("unset PERL5LIB PERL5OPT") && command.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), "root bootstrap sanitizes system-tool interpreter environment")
        expect(command.contains("if [ ! -e /Library/PrivilegedHelperTools ]"), "first installation handles missing standard helper directory")
        expect(command.contains("/bin/chmod -N \"$release\"") && command.contains("/bin/chmod -N \"$executable\""), "protected installed release strips unexpected inherited ACLs")
        let script = USBHelperInstall.appleScript(command)
        expect(script.contains("with timeout of 2147483647 seconds") && script.contains("with administrator privileges"), "OS authorization uses explicit long lifetime, not AppleScript default timeout")
        let syntaxDir = FileManager.default.temporaryDirectory.appendingPathComponent("usb-bootstrap-syntax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: syntaxDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: syntaxDir) }
        let shellFile = syntaxDir.appendingPathComponent("bootstrap.sh")
        try Data(command.utf8).write(to: shellFile)
        let shell = Process(); shell.executableURL = URL(fileURLWithPath: "/bin/sh"); shell.arguments = ["-n", shellFile.path]
        try shell.run(); shell.waitUntilExit()
        expect(shell.terminationStatus == 0, "generated privileged bootstrap passes actual shell syntax validation WITHOUT execution")
        let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        compiler.arguments = ["-o", syntaxDir.appendingPathComponent("authorization.scpt").path, "-e", script]
        compiler.standardOutput = FileHandle.nullDevice; compiler.standardError = FileHandle.nullDevice
        try compiler.run(); compiler.waitUntilExit()
        expect(compiler.terminationStatus == 0, "real AppleScript compiler accepts quoted authorization script WITHOUT executing it")
        do { _ = try USBHelperInstall.command(source: "/x", sha256: "bad", attempt: attempt, app: identity); expect(false, "invalid payload hash refused") }
        catch { expect(true, "invalid payload hash refused") }
    } catch { expect(false, "native request/bootstrap fixtures: \(error)") }
}
