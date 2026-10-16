#!/usr/bin/env python3
"""Replay the verbatim production registry binding with fake APIs; never IOKit."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = root / 'app/app/Sources/OmacVMUSB'
text = (source / 'USBRootGuardIOKit.swift').read_text()
start = text.index('    private let registry = USBRootGuardRegistryLookup(')
end = text.index('    private lazy var drainClose', start)
binding = text[start:end].replace('private let registry', 'let registry', 1)
error_match = re.search(r'public enum USBRootGuardError: Error, Equatable \{.*?\n\}',
                        (source / 'USBRootGuardTypes.swift').read_text(), re.S)
presence_match = re.search(r'enum USBRootGuardPresence \{[^}]*\}',
                           (source / 'USBRootGuardCloseBoundary.swift').read_text())
assert error_match is not None and presence_match is not None
error, presence = error_match.group(0), presence_match.group(0)
work = Path(tempfile.mkdtemp(prefix='rootguard-registry.', dir=os.environ['TMPDIR']))
swift = work / 'binding.swift'
swift_text = '''import Foundation
''' + error + '\n' + presence + '''
typealias io_iterator_t = UInt32
typealias IOOptionBits = UInt32
let kIOMainPortDefault: UInt32 = 0
let kIOServicePlane = "IOService"
let kIORegistryIterateRecursively: UInt32 = 1
let KERN_SUCCESS: Int32 = 0
let kIOReturnError: Int32 = -1
var entries: [(UInt32, UInt64)] = []
var cursor = 0
var iteratorStatus: Int32 = 0
var nullIterator = false, invalidIterator = false, failID = false
var creates = 0, released: [UInt32] = []
// Fake published-service matching deliberately cannot see unpublished clients.
func IORegistryEntryIDMatching(_ id: UInt64) -> UInt64? { id }
func IOServiceGetMatchingServices(_ port: UInt32, _ id: UInt64, _ iterator: inout UInt32) -> Int32 {
    iterator = 0; return 0
}
func IORegistryCreateIterator(_ port: UInt32, _ plane: String, _ options: UInt32, _ iterator: inout UInt32) -> Int32 {
    precondition(port == 0 && plane == "IOService" && options == 1)
    creates += 1; cursor = 0; iterator = nullIterator ? 0 : 10
    return iteratorStatus
}
func IOIteratorNext(_ iterator: UInt32) -> UInt32 {
    precondition(iterator == 10)
    guard cursor < entries.count else { return 0 }
    defer { cursor += 1 }; return entries[cursor].0
}
func IOIteratorIsValid(_ iterator: UInt32) -> Int32 { invalidIterator ? 0 : 1 }
func IORegistryEntryGetRegistryEntryID(_ entry: UInt32, _ id: inout UInt64) -> Int32 {
    guard !failID, let value = entries.first(where: { $0.0 == entry }) else { return -1 }
    id = value.1; return 0
}
func IOObjectRelease(_ object: UInt32) -> Int32 { precondition(object != 0); released.append(object); return 0 }
func actualRegistryBinding() -> USBRootGuardRegistryLookup {
    // Lexical aliases ensure the verbatim binding can ONLY call fixture APIs,
    // even when Foundation transitively makes IOKit declarations visible.
    let IORegistryEntryIDMatching = fakeIORegistryEntryIDMatching
    let IOServiceGetMatchingServices = fakeIOServiceGetMatchingServices
    let IORegistryCreateIterator = fakeIORegistryCreateIterator
    let IOIteratorNext = fakeIOIteratorNext
    let IOIteratorIsValid = fakeIOIteratorIsValid
    let IORegistryEntryGetRegistryEntryID = fakeIORegistryEntryGetRegistryEntryID
    let IOObjectRelease = fakeIOObjectRelease
''' + binding + '''
    _ = IORegistryEntryIDMatching; _ = IOServiceGetMatchingServices
    _ = IORegistryCreateIterator // Some aliases intentionally unused by v1 RED.
    return registry
}
@main struct BindingTest {
    static func main() {
        setbuf(stdout,nil)
        for mode in ["absent-root", "absent-guard", "absent-native", "unpublished-guard", "unpublished-native",
                     "status-failure", "null", "invalid", "id-failure", "duplicate"] {
            entries = [(20,100),(21,200)]; released = []; creates = 0
            iteratorStatus = mode == "status-failure" ? -1 : 0
            nullIterator = mode == "null"; invalidIterator = mode == "invalid"; failID = mode == "id-failure"
            let id: UInt64 = mode.hasSuffix("guard") ? 5 : (mode.hasSuffix("native") ? 6 : 1)
            if mode.hasPrefix("unpublished-") { entries.append((22,id)) }
            if mode == "duplicate" { entries += [(22,id),(23,id)] }
            var published: UInt32 = 0
            precondition(IOServiceGetMatchingServices(0,id,&published) == 0 && published == 0)
            let result = ActualRegistryBinding().registry.presence(id)
            let expected: USBRootGuardPresence = mode.hasPrefix("absent-") ? .absent :
                (mode.hasPrefix("unpublished-") ? .present : .unknown)
            precondition(result == expected, "actual adapter binding: \\(mode)")
            let yielded = entries.prefix(cursor).map { $0.0 }
            precondition(released.sorted() == (yielded + (creates == 0 || nullIterator ? [] : [10])).sorted())
            print("REGISTRY_BINDING \\(mode) creates=\\(creates) passed with balanced refs")
        }
        print("PASS actual production recursive registry binding vs unpublished client and absence; no native API execution")
    }
}
'''
for api in ['IORegistryEntryIDMatching', 'IOServiceGetMatchingServices', 'IORegistryCreateIterator',
            'IOIteratorNext', 'IOIteratorIsValid', 'IORegistryEntryGetRegistryEntryID', 'IOObjectRelease']:
    swift_text = swift_text.replace('func ' + api + '(', 'func fake' + api + '(')
swift_text = swift_text.replace('ActualRegistryBinding().registry.presence(id)', 'actualRegistryBinding().presence(id)')
swift_text = swift_text.replace('precondition(IOServiceGetMatchingServices(0,id,&published)',
                                'precondition(fakeIOServiceGetMatchingServices(0,id,&published)')
swift.write_text(swift_text)
command = ['swiftc', '-num-threads', '2', '-j2', '-warnings-as-errors', '-parse-as-library',
           str(source / 'USBRootGuardRegistryLookup.swift'), str(swift), '-o', str(work / 'binding-test')]
subprocess.run(command, check=True)
print('Registry binding evidence directory:', work, flush=True)
raise SystemExit(subprocess.run([str(work / 'binding-test')]).returncode)
