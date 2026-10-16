#!/usr/bin/env python3
"""Actual native bridge with inert QOM/BH/worker/close APIs; no hardware."""
import argparse,json,os,subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',type=Path,required=True);p.add_argument('--build-record',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
a=p.parse_args();a.out.mkdir(parents=True,exist_ok=False);a.out=a.out.resolve()
s=(a.source/'dev-host-hid.c').read_text()
def body(signature):
 i=s.index(signature);return s[i:s.index('\n}',i)+2]
actual='\n'.join(body(x) for x in ['static void host_hid_closed(void *opaque)\n{','static void host_hid_unrealize(USBDevice *dev)\n{'])+'\n'+s[s.index('static HostHIDState *coex_device;'):]
(a.out/'test.c').write_text(Path(__file__).with_name('test-native-bridge.c').read_text().replace('/* ACTUAL_BRIDGE */',actual))
cmd=next(r['command'] for r in json.loads(a.build_record.read_text()) if r['name']=='host-coexistence');cmd=cmd[:cmd.index('-c')]+['-I'+str(a.source.resolve()),'-O0','-g','-fsanitize=address,undefined','-Wno-unused-function','-Wno-missing-prototypes']
includes=[Path(v[2:]) for v in cmd if v.startswith('-I')];build=next(x for x in includes if (x/'libqemuutil.a').exists());deps=next(x.parents[3] for x in includes if str(x).endswith('glib/2.88.3/include/glib-2.0'))
cmd += [str(a.out/'test.c'),str(build/'libqemuutil.a'),str(deps/'glib/2.88.3/lib/libglib-2.0.dylib'),'-o',str(a.out/'test')]
r=subprocess.run(cmd,capture_output=True,text=True);(a.out/'compile.log').write_text(r.stdout+r.stderr);(a.out/'command.json').write_text(json.dumps(cmd,indent=2))
if r.returncode:print(r.stderr);raise SystemExit(r.returncode)
env=os.environ.copy();env['DYLD_LIBRARY_PATH']=':'.join(str(x) for x in deps.glob('*/*/lib'));env['ASAN_OPTIONS']='detect_leaks=0'
results=[]
for case in ['success','partial','failed-close']:
 r=subprocess.run([str(a.out/'test'),case],capture_output=True,text=True,env=env);(a.out/(case+'.log')).write_text(r.stdout+r.stderr);print(case,r.returncode,r.stdout+r.stderr);results.append(dict(case=case,exit=r.returncode))
(a.out/'results.json').write_text(json.dumps(results,indent=2));raise SystemExit(any(x['exit'] for x in results))
