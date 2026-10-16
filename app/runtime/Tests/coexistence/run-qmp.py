#!/usr/bin/env python3
"""Compile production handlers with real retained QEMU core; no USB/QEMU main.
Requires whole-object compile evidence from the owned build-objects.py.
"""
import argparse, json, os, subprocess
from pathlib import Path
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--build-record', type=Path, required=True)
p.add_argument('--source', type=Path, required=True)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
a.out.mkdir(parents=True, exist_ok=False)
a.out = a.out.resolve()
rows = json.loads(a.build_record.read_text())
cmd = next(r['command'] for r in rows if r['name'] == 'host-coexistence')
cmd = cmd[:cmd.index('-c')] + ['-I'+str(a.source.resolve()), '-O0', '-g', '-fsanitize=address,undefined', '-Wno-unused-function', '-Wno-missing-prototypes']
includes = [Path(v[2:]) for v in cmd if v.startswith('-I')]
build = next(x for x in includes if (x/'libqemuutil.a').exists())
deps = next(x.parents[3] for x in includes if str(x).endswith('glib/2.88.3/include/glib-2.0'))
lib = deps/'glib/2.88.3/lib/libglib-2.0.dylib'
cmd += [str(Path(__file__).with_name('test-qmp.c').resolve()), str(build/'libqemuutil.a'), str(lib), '-o', str(a.out/'test-qmp')]
r = subprocess.run(cmd, capture_output=True, text=True)
(a.out/'compile.log').write_text(r.stdout+r.stderr)
(a.out/'command.json').write_text(json.dumps(cmd, indent=2))
if r.returncode:
    print(r.stderr); raise SystemExit(r.returncode)
env = os.environ.copy()
# The installed dependency closure is read-only. Never load libusb or IOKit.
env['DYLD_LIBRARY_PATH'] = ':'.join(str(x) for x in deps.glob('*/*/lib'))
env['ASAN_OPTIONS'] = 'detect_leaks=0'  # production process-lifetime tombstones
cases = ['cleanup-new','cleanup-zero','cleanup-held','cleanup-poison','cleanup-wrong','gone','schema','owner','policy','publication','drain','lookup','renew','replay','stale','revoke','death','expiry','replace','immutable','command-schema','prepare-replay','overflow','guard-reject','nested-schema','lifecycle','cleanup-never','native-partial','native-death','native-expiry','native-guard-loss','native-extra','native-incomplete','native-session','native-descriptor','native-renew-wrong','native-replay','native-ticket-replay','commit-stale','commit-witness','commit-schema','native-ledger-poison','native-ticket-descriptor']
cases += ['guard-gone','guard-gone-native','guard-gone-schema','guard-gone-stale','guard-gone-ids','guard-gone-wrong','guard-gone-accounting','guard-gone-noack','guard-gone-ledger-epoch']
results = []
for case in cases:
    r = subprocess.run([str(a.out/'test-qmp'), case], env=env, capture_output=True, text=True)
    (a.out/(case+'.log')).write_text(r.stdout+r.stderr)
    print(case, r.returncode, (r.stdout+r.stderr)[-2500:])
    results.append(dict(case=case, exit=r.returncode))
(a.out/'results.json').write_text(json.dumps(results, indent=2))
raise SystemExit(any(x['exit'] for x in results))
