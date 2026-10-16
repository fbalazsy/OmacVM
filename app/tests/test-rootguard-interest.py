#!/usr/bin/env python3
"""Replay the actual interest callback against SDK constants, no IOKit calls."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = root / 'app/app/Sources/OmacVMUSB/USBRootGuardIOKit.swift'
text = source.read_text()
start = text.index('            guard let context else { return }', text.index('func monitor('))
end = text.index('\n        },Unmanaged.passUnretained', start)
callback = text[start:end]
work = Path(tempfile.mkdtemp(prefix='rootguard-interest.', dir=os.environ['TMPDIR']))
header = work / 'messages.h'
header.write_text('#include <IOKit/IOMessage.h>\nenum { SDKRequestingClose = kIOMessageServiceIsRequestingClose, SDKTerminated = kIOMessageServiceIsTerminated, SDKWasClosed = kIOMessageServiceWasClosed };\n')
swift = work / 'callback.swift'
swift.write_text('''import Foundation
final class USBRootGuardIOKit {
    enum Reason: String { case requestingClose, lost }
    var event: ((Reason)->Void)?
}
func callback(_ context:UnsafeMutableRawPointer?,_ message:UInt32) {
''' + callback + '''
}
let owner = USBRootGuardIOKit()
var events:[String] = []
owner.event = { events.append($0.rawValue) }
let context = Unmanaged.passUnretained(owner).toOpaque()
var failures = 0
for (message,expected) in [(UInt32(SDKRequestingClose),["requestingClose"]),(UInt32(SDKTerminated),["lost"]),(UInt32(SDKWasClosed),["lost"]),(UInt32(0xe0005003),[]),(UInt32(0),[])] {
    events.removeAll()
    callback(context,message)
    print(String(format:"SDK_INTEREST message=0x%08x",message),"events=\\(events) expected=\\(expected)")
    if events != expected { failures += 1 }
}
callback(nil,UInt32(SDKRequestingClose))
print("\\(failures == 0 ? "PASS" : "FAIL") actual production interest callback vs SDK messages; no native API execution")
exit(failures == 0 ? 0 : 1)
''')
env = os.environ.copy()
command = ['swiftc', '-num-threads', '2', '-j2', '-warnings-as-errors', '-import-objc-header', str(header), str(swift), '-o', str(work / 'callback-test')]
subprocess.run(command, env=env, check=True)
print('Interest evidence directory:', work, flush=True)
result = subprocess.run([str(work / 'callback-test')], env=env)
raise SystemExit(result.returncode)
