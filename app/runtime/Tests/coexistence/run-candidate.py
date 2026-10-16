#!/usr/bin/env python3
"""Pinned offline stage-1 recipe. NEVER launches QEMU or initializes USB.

--source is a read-only QEMU c3d48b7... tree with the existing OmacVM patches.
--out must not exist. This is NOT the release runtime build recipe.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--source', type=Path, required=True)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
a.source = a.source.resolve()
a.out = a.out.resolve()
w = Path(__file__).resolve().parent
patch = w.parent.parent/'patches/qemu-usb-session-accounting.patch'
expected = {
    'hw/usb/host-libusb.c': 'b2ee27d3e2390c9186cc386703d37cd8d17b49b7d8d450dd8bc3dc22a5e30ced',
    'hw/usb/dev-host-hid.c': '5071c1628391ac5fd3c99811ce3f237b2c825db7a737524235152c76e0a015eb',
    'hw/usb/meson.build': 'df49fcaf46d72d6387e4d1ec9f8db390269c60bcb2b985a75196ea299e110a16',
}
manifest = json.loads((w/'inputs.json').read_text())
assert hashlib.sha256(patch.read_bytes()).hexdigest() == manifest['patch_sha256']
for name, digest in expected.items():
    assert hashlib.sha256((a.source/name).read_bytes()).hexdigest() == digest, name
assert not a.out.exists(), 'output must be new and owned'
(a.out/'source/hw/usb').mkdir(parents=True)
for name in expected:
    shutil.copyfile(a.source/name, a.out/'source'/name)
subprocess.run(['patch', '-p1', '-f', '-i', str(patch)], cwd=a.out/'source', check=True)
source = a.out/'source/hw/usb'
for mode in ['paths', 'submit', 'iso']:
    cmd = [sys.executable, str(w/'run.py'), '--source', str(source/'host-libusb.c'), '--coordinator', str(source), '--out', str(a.out/mode)]
    if mode != 'paths':
        cmd.append('--'+mode)
    subprocess.run(cmd, check=True)
cmd = ['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-pthread', '-fsanitize=address,undefined', '-I'+str(a.out/'paths'), '-I'+str(source), str(w/'test-ledger.c'), '-o', str(a.out/'ledger')]
subprocess.run(cmd, check=True)
r = subprocess.run([str(a.out/'ledger')], capture_output=True, text=True, check=True)
print(r.stdout)
(a.out/'ledger.log').write_text(r.stdout+r.stderr)
results = []
for mode in ['paths', 'submit', 'iso']:
    results.extend(json.loads((a.out/mode/'results.json').read_text()))
assert len(results) == 8 and all(r['exit'] == 0 for r in results)
(a.out/'result.json').write_text(json.dumps({'path_cases': results, 'ledger_asan_ubsan': 0, 'hardware_executed': False, 'release_ready': False}, indent=2))
print('8 actual-function cases + pthread ledger ASan/UBSan PASS; NOT release ready')
