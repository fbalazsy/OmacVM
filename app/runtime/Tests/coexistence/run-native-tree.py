#!/usr/bin/env python3
"""Compile real native admission bodies with inert IOKit/HID replacements."""
import argparse, hashlib, json, os, subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',type=Path,required=True)
p.add_argument('--build-record',type=Path,required=True)
p.add_argument('--out',type=Path,required=True)
p.add_argument('--case',default=None,help='one registry regression, otherwise original admission suite')
a=p.parse_args(); a.out.mkdir(parents=True,exist_ok=False); a.out=a.out.resolve()
s=(a.source/'dev-host-hid.c').read_text()
def body(signature):
    i=s.index(signature); return s[i:s.index('\n}',i)+2]
actual=body('static bool host_hid_parse(')+'\n'+s[s.index('static uint64_t native_number('):s.index('static void native_input(')]
fixture=Path(__file__).with_name('test-native-tree.c').read_text().replace('/* ACTUAL_NATIVE */',actual)
(a.out/'test.c').write_text(fixture)
cmd=next(r['command'] for r in json.loads(a.build_record.read_text()) if r['name']=='host-coexistence')
cmd=cmd[:1]+['-I'+str(a.source.resolve())]+cmd[1:cmd.index('-c')]+['-O0','-g','-fsanitize=address,undefined','-Wno-unused-function','-Wno-missing-prototypes']
includes=[Path(v[2:]) for v in cmd if v.startswith('-I')]
build=next(x for x in includes if (x/'libqemuutil.a').exists())
deps=next(x.parents[3] for x in includes if str(x).endswith('glib/2.88.3/include/glib-2.0'))
cmd += [str(a.out/'test.c'),str(build/'libqemuutil.a'),str(deps/'glib/2.88.3/lib/libglib-2.0.dylib'),'-framework','CoreFoundation','-o',str(a.out/'test')]
r=subprocess.run(cmd,capture_output=True,text=True);(a.out/'compile.log').write_text(r.stdout+r.stderr)
(a.out/'command.json').write_text(json.dumps(cmd,indent=2))
if r.returncode: print(r.stderr);raise SystemExit(r.returncode)
env=os.environ.copy();env['DYLD_LIBRARY_PATH']=':'.join(str(x) for x in deps.glob('*/*/lib'));env['ASAN_OPTIONS']='detect_leaks=0'
cases=[a.case] if a.case else [None,'pending-present','gone-absent']+[
    'pending-'+c for c in ['missing','creator','class','class-error','parent','parent-error',
    'not-child','invalid','null','error','id-error','id-zero','late-id-error','budget']]+[
    'gone-'+c for c in ['root','guard','native','composite','invalid','null','error',
    'id-error','id-zero','budget','root-zero','optional-zero']]
results=[]
for case in cases:
    r=subprocess.run([str(a.out/'test')]+([case] if case else []),capture_output=True,text=True,env=env,timeout=30)
    (a.out/((case or 'admission')+'.log')).write_text(r.stdout+r.stderr)
    results.append(dict(case=case or 'admission',exit=r.returncode))
    print(case or 'admission',r.returncode,r.stdout+r.stderr)
source_hashes={str(x.name):hashlib.sha256(x.read_bytes()).hexdigest() for x in a.source.iterdir() if x.is_file()}
(a.out/'results.json').write_text(json.dumps({'exit':int(any(x['exit'] for x in results)),
    'cases':results,'source_sha256':source_hashes,'hardware':False},indent=2))
raise SystemExit(any(x['exit'] for x in results))
