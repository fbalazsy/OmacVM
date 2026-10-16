#!/usr/bin/env python3
"""Exercise the actual live-root resolver with fake SDK APIs only; no hardware."""
from pathlib import Path
import argparse
import os
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-dir', type=Path, help='isolated source directory for baseline RED replay')
args = parser.parse_args()
source = args.source_dir or Path(__file__).resolve().parents[2] / 'app/app/Sources/OmacVMUSB'
text = (source / 'USBRootGuardIOKit.swift').read_text()
start = text.index('    private let registry = USBRootGuardRegistryLookup(')
binding = text[start:text.index('    private lazy var drainClose', start)]
start = text.index('    private func exactService(')
method = text[start:text.index('    func snapshot(', start)]
error_match = re.search(r'public enum USBRootGuardError: Error, Equatable \{.*?\n\}',
                        (source / 'USBRootGuardTypes.swift').read_text(), re.S)
presence_match = re.search(r'enum USBRootGuardPresence \{[^}]*\}',
                           (source / 'USBRootGuardCloseBoundary.swift').read_text())
assert error_match is not None and presence_match is not None
error, presence = error_match.group(0), presence_match.group(0)
# Rewrite every SDK identifier in the extracted code to a fixture-only symbol.
# Foundation may transitively expose SDK declarations; none can be selected here.
apis = ['IORegistryEntryIDMatching', 'IOServiceGetMatchingService', 'IORegistryCreateIterator',
        'IOIteratorNext', 'IOIteratorIsValid', 'IORegistryEntryGetRegistryEntryID',
        'IOObjectConformsTo', 'IOObjectIsEqualTo', 'IOObjectRelease']
for api in apis:
    binding = re.sub(r'\b' + api + r'\b', 'fake' + api, binding)
    method = re.sub(r'\b' + api + r'\b', 'fake' + api, method)
work = Path(tempfile.mkdtemp(prefix='rootguard-live-root.', dir=os.environ['TMPDIR']))
swift = work / 'live-root.swift'
swift.write_text('import Foundation\n' + error + '\n' + presence + r'''
typealias io_service_t = UInt32
typealias io_iterator_t = UInt32
typealias IOOptionBits = UInt32
let kIOMainPortDefault: UInt32 = 0
let kIOServicePlane = "IOService"
let kIORegistryIterateRecursively: UInt32 = 1
let KERN_SUCCESS: Int32 = 0
struct Matcher { let id: UInt64 }
var nullMatcher = false, nullService = false, failID = false, wrongClass = false
var invalidIterator = true
var reportedID: UInt64 = 101
var entries: [(UInt32, UInt64)] = [(20, 999)]
var cursor = 0, scans = 0, matches = 0, dictionaries = 0
var acquired: [UInt32] = [], released: [UInt32] = []
func fakeIORegistryEntryIDMatching(_ id: UInt64) -> Matcher? {
    if nullMatcher { return nil }
    dictionaries += 1; return Matcher(id:id)
}
func fakeIOServiceGetMatchingService(_ port: UInt32, _ matcher: Matcher) -> UInt32 {
    precondition(port == 0 && matcher.id == 101)
    dictionaries -= 1; matches += 1
    if nullService { return 0 }
    acquired.append(30); return 30
}
func fakeIORegistryEntryGetRegistryEntryID(_ entry: UInt32, _ id: inout UInt64) -> Int32 {
    if failID { return -1 }
    if entry == 30 { id = reportedID; return 0 }
    guard let item = entries.first(where: { $0.0 == entry }) else { return -1 }
    id = item.1; return 0
}
func fakeIOObjectConformsTo(_ entry: UInt32, _ name: String) -> Int32 {
    precondition(entry == 30 && name == "IOUSBHostDevice")
    return wrongClass ? 0 : 1
}
func fakeIOObjectIsEqualTo(_ a: UInt32, _ b: UInt32) -> Int32 { a == b ? 1 : 0 }
@discardableResult func fakeIOObjectRelease(_ entry: UInt32) -> Int32 {
    precondition(entry != 0); released.append(entry); return 0
}
func fakeIORegistryCreateIterator(_ port: UInt32, _ plane: String, _ options: UInt32,
                                  _ iterator: inout UInt32) -> Int32 {
    precondition(port == 0 && plane == "IOService" && options == 1)
    cursor = 0; scans += 1; iterator = 10; acquired.append(10); return 0
}
func fakeIOIteratorIsValid(_ iterator: UInt32) -> Int32 {
    // Invalidate after yielding a child, matching the observed midscan failure.
    precondition(iterator == 10); return invalidIterator && cursor > 0 ? 0 : 1
}
func fakeIOIteratorNext(_ iterator: UInt32) -> UInt32 {
    precondition(iterator == 10)
    guard cursor < entries.count else { return 0 }
    let entry = entries[cursor].0; cursor += 1; acquired.append(entry); return entry
}
final class ActualAdapter {
    var service: UInt32 = 0
''' + binding + method + r'''
    func resolve(_ id: UInt64) throws -> UInt32 { try exactService(id) }
    func presence(_ id: UInt64) -> USBRootGuardPresence { registry.presence(id) }
}
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL \(message)"); exit(1) }
}
func reset() {
    nullMatcher = false; nullService = false; failID = false; wrongClass = false
    invalidIterator = true; reportedID = 101; entries = [(20,999)]
    cursor = 0; scans = 0; matches = 0; dictionaries = 0; acquired = []; released = []
}
func balanced(_ mode: String) {
    check(acquired.sorted() == released.sorted() && dictionaries == 0, "reference balance: \(mode)")
}
@main struct LiveRootTest {
    static func main() {
        setbuf(stdout,nil)
        for mode in ["published-root-global-invalid", "retained-root-equal", "null-matcher", "null-service",
                     "wrong-id", "zero-read-id", "id-read-failure", "wrong-class", "retained-root-mismatch", "zero-request"] {
            reset()
            let adapter = ActualAdapter()
            if mode == "retained-root-equal" { adapter.service = 30 }
            if mode == "retained-root-mismatch" { adapter.service = 31 }
            nullMatcher = mode == "null-matcher"; nullService = mode == "null-service"
            failID = mode == "id-read-failure"; wrongClass = mode == "wrong-class"
            if mode == "wrong-id" { reportedID = 102 }
            if mode == "zero-read-id" { reportedID = 0 }
            let succeeds = mode == "published-root-global-invalid" || mode == "retained-root-equal"
            var result: UInt32 = 0
            var failure: USBRootGuardError?
            do { result = try adapter.resolve(mode == "zero-request" ? 0 : 101) }
            catch let error as USBRootGuardError { failure = error }
            catch { check(false,"unexpected error \(error)") }
            if succeeds {
                check(result == 30 && failure == nil, "\(mode): exact published root must survive unrelated invalid global iteration; got \(String(describing:failure))")
                check(released.isEmpty, "successful resolver transfers its owned reference")
                _ = fakeIOObjectRelease(result)
            } else {
                check(result == 0 && failure != nil && failure != .rootAbsent,
                      "\(mode): no positive live root; must refuse/unknown, never proven absence")
            }
            check(scans == 0, "live resolution must not scan the global registry")
            check(matches == (mode == "null-matcher" || mode == "zero-request" ? 0 : 1), "single consumed match: \(mode)")
            balanced(mode)
            print("LIVE_ROOT \(mode) passed with balanced refs")
        }
        for mode in ["unregistered-guard", "unregistered-native", "complete-absent", "invalid-global", "unreadable-global"] {
            reset(); invalidIterator = mode == "invalid-global"
            failID = mode == "unreadable-global"
            let adapter = ActualAdapter()
            if mode.hasPrefix("unregistered-") { entries.append((21,101)) }
            let expected: USBRootGuardPresence = mode.hasPrefix("unregistered-") ? .present :
                (mode == "complete-absent" ? .absent : .unknown)
            check(adapter.presence(101) == expected, "global presence remains complete-scan-only: \(mode)")
            check(scans == 1 && matches == 0, "absence/unregistered lookup must not use published matching")
            balanced(mode)
            print("LIVE_ROOT \(mode) passed with balanced refs")
        }
        print("PASS 15 actual live-root/global-presence cases; fake SDK only, no native API execution")
    }
}
''')
command = ['swiftc', '-num-threads', '2', '-j2', '-warnings-as-errors', '-parse-as-library',
           str(source / 'USBRootGuardRegistryLookup.swift'), str(swift), '-o', str(work / 'live-root-test')]
subprocess.run(command, check=True)
print('Live-root evidence directory:', work, flush=True)
raise SystemExit(subprocess.run([str(work / 'live-root-test')]).returncode)
