"""Exercise the exact live HID collector at a fake IOKit boundary; no hardware.
Usage: SDKROOT=... TMPDIR=... python3 collector.py NEW_OWNED_OUTPUT_DIRECTORY
Only the IOKit import is replaced. Collector/Entry/admission and helper bodies
are copied verbatim, with their hashes retained beside the execution output.
"""
from pathlib import Path
import hashlib, json, os, subprocess, sys
source = Path(__file__).resolve().parent
root = source.parents[1] / 'app/Sources/OmacVMUSB'
out = Path(sys.argv[1]).resolve(); out.mkdir(exist_ok=False)
env = dict(os.environ); assert env.get('TMPDIR')
hid = (root / 'USBHID.swift').read_text()
assert hid.count('import IOKit\n') == 1
(out / 'USBHID.swift').write_text(hid.replace('import IOKit\n', ''))
devices = (root / 'USBDevices.swift').read_text()
helpers = devices[devices.index('    static func className('):]
(out / 'Helpers.swift').write_text('import Foundation\nenum USBScan {\n' + helpers)
cmd = ['swiftc', '-swift-version', '5', '-num-threads', '1', '-j1']
if env.get('SDKROOT'): cmd += ['-sdk', env['SDKROOT']]
cmd += [str(out / 'USBHID.swift'), str(out / 'Helpers.swift'), str(source / 'Collector.swift'), '-o', str(out / 'collector')]
r = subprocess.run(cmd, env=env, capture_output=True, text=True)
(out / 'build.log').write_text(r.stdout + r.stderr)
assert r.returncode == 0, out / 'build.log'
symbols = subprocess.check_output(['nm', '-u', str(out / 'collector')], text=True)
(out / 'symbols.txt').write_text(symbols)
assert not any(name in symbols for name in ['_IORegistry', '_IOObject', '_IOIterator', '_IOService', '_IOHID'])
r = subprocess.run([str(out / 'collector')], env=env, capture_output=True, text=True)
(out / 'run.log').write_text(r.stdout + r.stderr)
(out / 'result.json').write_text(json.dumps(dict(argv=cmd, exit=r.returncode,
    hidSHA256=hashlib.sha256(hid.encode()).hexdigest(), helpersSHA256=hashlib.sha256(helpers.encode()).hexdigest()), indent=2) + '\n')
print(r.stdout + r.stderr)
sys.exit(r.returncode)
