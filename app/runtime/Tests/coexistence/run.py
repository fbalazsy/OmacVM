#!/usr/bin/env python3
"""Compile actual production bodies with inert USB dependencies; no USB load/init."""
import argparse
from pathlib import Path
import subprocess
import json
import re
p = argparse.ArgumentParser()
p.add_argument('--source', type=Path, required=True)
p.add_argument('--coordinator', type=Path, required=True)
p.add_argument('--out', type=Path, required=True)
p.add_argument('--submit', action='store_true')
p.add_argument('--iso', action='store_true')
a = p.parse_args()
w = Path(__file__).resolve().parent
a.out.mkdir(parents=True, exist_ok=True)
(a.out / 'qemu').mkdir(exist_ok=True)
(a.out / 'qemu/osdep.h').write_text('')
(a.out / 'libusb.h').write_text('')
s = a.source.read_text()
def body(name):
    match = re.search(r'^(?:static )?(?:int|void|bool)\s+' + re.escape(name) + r'\([^;]*?\)\n\{', s, re.M)
    assert match, name
    start = match.start()
    return s[start:s.index('\n}', start) + 2]
code = '#define CONFIG_DARWIN 1\n' + (w/'stubs.h').read_text()
code += '\n#include "host-coexistence.c"\n'
if a.iso:
    code += (w/'test-iso.c').read_text().replace('/* WRAPPER */', body('usb_host_iso_free_xfer'))
elif a.submit:
    assert 'usb_host_submit_transfer(' in s, 'RED: production submit fence missing'
    code += (w/'test-submit.c').read_text().replace('/* WRAPPER */', body('usb_host_submit_transfer'))
else:
    code += '\nstatic int usb_host_close(USBHostDevice *s);\n'
    code += '\n'.join(body(n) for n in ['usb_host_checked', 'usb_host_open', 'usb_host_abort_xfers', 'usb_host_close', 'hmp_info_usbhost'])
    code += '\n' + (w/'test-paths.c').read_text()
(a.out/'paths.c').write_text(code)
cmd = ['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-Wno-unused-function', '-Wno-unused-variable', '-pthread', '-I'+str(a.out), '-I'+str(a.coordinator), str(a.out/'paths.c'), '-o', str(a.out/'paths')]
subprocess.run(cmd, check=True)
results = []
for case in (['iso'] if a.iso else ['submit'] if a.submit else ['ordinary', 'hmp', 'timeout', 'open-error', 'attach-error', 'detach-error']):
    r = subprocess.run([str(a.out/'paths'), case], capture_output=True, text=True)
    results.append(dict(case=case, exit=r.returncode, stdout=r.stdout, stderr=r.stderr))
    print(case, r.returncode)
(a.out/'results.json').write_text(json.dumps(results, indent=2))
raise SystemExit(any(r['exit'] for r in results))
