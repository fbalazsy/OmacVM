#!/usr/bin/env python3
"""Extract actual production native bodies; execute only inert API replacements."""
import argparse, json, subprocess
from pathlib import Path
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--source', type=Path, required=True)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
a.out.mkdir(parents=True, exist_ok=False)
s = (a.source/'dev-host-hid.c').read_text()
start = s.index('static ', s.index('static void native_start(HostHIDState *s)\n{'))
start = s.index('native_close(HostHIDState *s)\n{', start)
start = s.rfind('static ', 0, start)
end = s.index('\n}', start) + 2
code = Path(__file__).with_name('test-native-close.c').read_text().replace('/* ACTUAL_CLOSE */', s[start:end])
(a.out/'test-native.c').write_text(code)
cmd = ['clang','-fblocks','-Wall','-Wextra','-Wno-unused-parameter','-fsanitize=address,undefined', str(a.out/'test-native.c'), '-o',str(a.out/'test-native')]
r = subprocess.run(cmd, capture_output=True, text=True)
(a.out/'compile.log').write_text(r.stdout+r.stderr)
if r.returncode: print(r.stderr); raise SystemExit(r.returncode)
r = subprocess.run([str(a.out/'test-native')], capture_output=True, text=True)
(a.out/'result.log').write_text(r.stdout+r.stderr)
(a.out/'results.json').write_text(json.dumps({'exit':r.returncode,'command':cmd,'hardware':False}, indent=2))
print(r.stdout+r.stderr)
raise SystemExit(r.returncode)
