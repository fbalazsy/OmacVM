#!/usr/bin/env python3
"""Replay the production owned-reference destructor with inert refs, never IOKit."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'app/app/Sources/OmacVMUSB/USBRootGuardIOKit.swift').read_text()
start = source.index('    func release() {')
body = source[start:source.rindex('\n}')]
work = Path(tempfile.mkdtemp(prefix='rootguard-owned-release.', dir=os.environ['TMPDIR']))
swift = work / 'release.swift'
swift.write_text('''import Foundation
final class Replay {
    typealias Ref = UnsafeMutablePointer<UnsafeMutablePointer<COMRef>?>
    struct COMRef { let Release: (Ref) -> Int32 }
    var service: UInt32 = 10, notice: UInt32 = 11
    var port: Int? = 12
    var event: (() -> Void)? = {}
    var usb: Ref?, plugin: Ref?
    var counts: [String:Int] = [:]
    let queue = DispatchQueue(label:"inert-owned-release")
    let key = DispatchSpecificKey<Bool>()
    func record(_ name: String) {
        precondition(DispatchQueue.getSpecific(key:key) == true)
        counts[name, default:0] += 1
    }
    func IOObjectRelease(_ ref: UInt32) { record(ref == 11 ? "notice" : "service") }
    func IONotificationPortSetDispatchQueue(_ port: Int, _ queue: DispatchQueue?) {
        precondition(port == 12 && queue == nil); record("detach-port")
    }
    func IONotificationPortDestroy(_ port: Int) { precondition(port == 12); record("destroy-port") }
''' + body + '''
    func test() {
        queue.setSpecific(key:key,value:true)
        let u = UnsafeMutablePointer<COMRef>.allocate(capacity:1)
        let p = UnsafeMutablePointer<COMRef>.allocate(capacity:1)
        let ur = Ref.allocate(capacity:1), pr = Ref.allocate(capacity:1)
        u.initialize(to:COMRef(Release:{ _ in self.record("usb"); return 0 }))
        p.initialize(to:COMRef(Release:{ _ in self.record("plugin"); return 0 }))
        ur.initialize(to:u); pr.initialize(to:p); usb = ur; plugin = pr
        queue.sync { release(); release() }
        precondition(counts == ["notice":1,"service":1,"detach-port":1,"destroy-port":1,"usb":1,"plugin":1])
        precondition(usb == nil && plugin == nil && port == nil && event == nil && service == 0 && notice == 0)
        ur.deinitialize(count:1); pr.deinitialize(count:1); ur.deallocate(); pr.deallocate()
        u.deinitialize(count:1); p.deinitialize(count:1); u.deallocate(); p.deallocate()
        print("PASS actual production owned USB/plugin/registry/notification destructor: serial, once, nil pointers; no IOKit execution")
    }
}
@main struct Test { static func main() { Replay().test() } }
''')
subprocess.run(['swiftc', '-num-threads', '2', '-j2', '-warnings-as-errors', '-parse-as-library', str(swift), '-o', str(work / 'test')], check=True)
print('Owned release evidence directory:', work, flush=True)
raise SystemExit(subprocess.run([str(work / 'test')]).returncode)
