"""Compile production QMPConnection and exercise real socketpair replies; no QEMU."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SWIFT = r'''
import Foundation
import Darwin

enum HelperError: Error { case io(String) }
var assertions = 0
func expect(_ value: Bool, _ name: String) {
    assertions += 1
    guard value else { fatalError(name) }
}
func readObject(_ fd: Int32) -> [String: Any] {
    var data = Data()
    while true {
        var byte: UInt8 = 0
        guard Darwin.read(fd, &byte, 1) == 1 else { fatalError("fixture EOF") }
        if byte == 10 { return try! JSONSerialization.jsonObject(with: data) as! [String: Any] }
        if byte != 13 { data.append(byte) }
    }
}
func fixture(_ reply: [String: Any], stale: Bool = false, event: Bool = false) throws -> QMPConnection {
    var fds: [Int32] = [-1, -1]
    precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    let server = fds[1]
    DispatchQueue.global().async {
        defer { Darwin.close(server) }
        try! QMPConnection.writeJSON(["QMP": [:]], to: server)
        let caps = readObject(server)
        try! QMPConnection.writeJSON(["id": caps["id"]!, "return": [:]], to: server)
        let command = readObject(server)
        if stale {
            try! QMPConnection.writeJSON(["id": "other", "error": ["class": "GenericError", "desc": "stale"]], to: server)
        }
        if event { try! QMPConnection.writeJSON(["event": "DEVICE_DELETED"], to: server) }
        var answer = reply
        answer["id"] = command["id"]!
        try! QMPConnection.writeJSON(answer, to: server)
    }
    return try QMPConnection(connectedDescriptor: fds[0], identifierPrefix: "fixture")
}
let bool = try fixture(["return": true], stale: true)
expect(try bool.executeValue("qom-get") as? Bool == true, "raw Bool return")
bool.close()
let array = try fixture(["return": [["label": "ours"]]])
expect((try array.executeValue("query-chardev") as? [[String: Any]])?.first?["label"] as? String == "ours", "raw array return")
array.close()
let number = try fixture(["return": 42])
expect(try number.executeValue("number") as? Int == 42, "raw number return")
number.close()
let null = try fixture(["return": NSNull()])
expect(try null.executeValue("null") is NSNull, "JSON null remains present")
null.close()
let text = try fixture(["return": "monitor text"])
expect(try text.execute("human-monitor-command")["text"] as? String == "monitor text", "legacy text wrapper")
text.close()
let dictionary = try fixture(["return": ["running": true]], event: true)
let execution = try dictionary.executeCapturingEvents("query-status")
expect(execution.result["running"] as? Bool == true && execution.events == ["DEVICE_DELETED"], "legacy dictionary/events")
dictionary.close()
let reject = try fixture(["error": ["class": "GenericError", "desc": "refused"]])
do { _ = try reject.executeValue("device_add"); fatalError("must reject") }
catch let error as QMPConnection.Rejected { expect(error.localizedDescription.contains("refused"), "definitive typed rejection") }
reject.close()
for invalid: [String: Any] in [[:], ["error": "bad"], ["error": ["desc": "bad"]], ["return": [:], "error": ["class": "GenericError", "desc": "contradiction"]]] {
    let q = try fixture(invalid)
    do { _ = try q.executeValue("invalid"); fatalError("invalid reply accepted") }
    catch is QMPConnection.Rejected { fatalError("malformed reply is ambiguous, not definitive rejection") }
    catch { assertions += 1 }
    q.close()
}
print("PASS \(assertions) production QMP socketpair assertions")
'''
with tempfile.TemporaryDirectory(prefix='qmp-values-') as tmp:
    directory = Path(tmp)
    main = directory / 'main.swift'
    main.write_text(SWIFT)
    command = ['xcrun', 'swiftc', '-swift-version', '5']
    if os.environ.get('SDKROOT'):
        command += ['-sdk', os.environ['SDKROOT']]
    command += [str(ROOT / 'app/app/Sources/OmacVM/QMPConnection.swift'), str(main), '-o', str(directory / 'test')]
    subprocess.run(command, check=True)
    subprocess.run([str(directory / 'test')], check=True, timeout=20)
