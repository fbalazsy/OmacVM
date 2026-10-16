#!/usr/bin/env python3
"""Compile actual ISO completion with inert dependencies, never load USB."""
import argparse
from pathlib import Path
import subprocess
p = argparse.ArgumentParser()
p.add_argument('--source', type=Path, required=True)
p.add_argument('--out', type=Path, required=True)
p.add_argument('--completions', action='store_true')
a = p.parse_args()
a.source = a.source.resolve()
a.out = a.out.resolve()
a.out.mkdir(parents=True, exist_ok=False)
(a.out/'qemu').mkdir()
(a.out/'qemu/osdep.h').write_text('')
(a.out/'libusb.h').write_text('')
s = (a.source/'host-libusb.c').read_text()
def extract(signature):
    start = s.index(signature)
    end = s.index('\n}', start) + 2
    return s[start:end]
if a.completions:
    fixture = Path(__file__).with_name('test-completions.c').read_text()
    actual = '\n'.join(extract('static void LIBUSB_CALL usb_host_req_complete_' + n + '(') for n in ['ctrl', 'data'])
    code = fixture.replace('/* ACTUAL_COMPLETIONS */', actual)
else:
    fixture = Path(__file__).with_name('test-dispatch.c').read_text()
    code = fixture.replace('/* ACTUAL_CALLBACK */', extract('static void LIBUSB_CALL\nusb_host_req_complete_iso('))
(a.out/'test.c').write_text('#define CONFIG_DARWIN 1\n' + code)
cmd = ['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-variable', '-Wno-sign-compare', '-pthread', '-fsanitize=address,undefined', '-I'+str(a.out), '-I'+str(a.source), str(a.out/'test.c'), '-o', str(a.out/'test')]
subprocess.run(cmd, check=True)
failed = False
for case in (['ctrl', 'data'] if a.completions else ['iso']):
    r = subprocess.run([str(a.out/'test'), case], capture_output=True, text=True)
    (a.out/(case + '.log')).write_text(r.stdout+r.stderr)
    print(case, r.returncode, r.stdout+r.stderr)
    failed |= r.returncode != 0
raise SystemExit(failed)
