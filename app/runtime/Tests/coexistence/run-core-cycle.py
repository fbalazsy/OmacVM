#!/usr/bin/env python3
"""Inert actual QEMU core + whole ordinary/native TUs, never QEMU main or USB.

All writable inputs are copied. Retained build flags/objects/dependencies are
read-only. libusb is NOT linked; every public USB export is inert in the fixture.
"""
import argparse, hashlib, json, os, shlex, shutil, subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',type=Path,required=True)
p.add_argument('--build-record',type=Path,required=True)
p.add_argument('--link-command',type=Path,required=True)
p.add_argument('--runtime-lib',type=Path,required=True,help='read-only relocated runtime dependency directory')
p.add_argument('--out',type=Path,required=True)
cases=['cycle','native-first','claim-cleanup','native-open-failure','native-create-failure','native-close-failure','native-held','native-foreign','abort-dispatch','submit-error','clean','restore-failure','reentrant-close','exit','callback-close','attach-close','stream-failure','halt-failure','config-failure','alt-failure','reset-failure','postload','retention','freeze-ops']
p.add_argument('cases',nargs='*',default=cases)
cases += ['native-postopen-extra','native-postopen-foreign','native-postopen-close-failure','native-create-identity']
cases += ['native-gone']
cases += ['native-gone-bql-proof']
cases += ['native-gone-held','native-gone-unknown','native-gone-invalid','native-gone-root','native-gone-guard','native-gone-native','native-gone-postrelease','native-gone-race','native-gone-live-error','native-gone-stale','native-gone-no-native','native-gone-pending']
cases += ['guard-gone','guard-gone-live','guard-gone-unknown','guard-gone-invalid','guard-gone-root','guard-gone-guard','guard-gone-native','native-gone-guard-disposed']
a=p.parse_args(); out=a.out.resolve();out.mkdir(parents=True,exist_ok=False)
assert a.cases and set(a.cases)<=set(cases), 'unknown/empty case selection'
w=Path(__file__).resolve().parent
shutil.copytree(a.source,out/'source')
source_hashes={str(x.relative_to(a.source)):hashlib.sha256(x.read_bytes()).hexdigest() for x in a.source.iterdir() if x.is_file()}
shutil.copy(w/'test-core-cycle.c',out/'test-core-cycle.c')
shutil.copy(w/'core-cycle.inc',out/'core-cycle.inc')
rows=json.loads(a.build_record.read_text())
cc=next(r['command'] for r in rows if r['name']=='host-coexistence')
cc=cc[:cc.index('-c')]
incs=[Path(x[2:]) for x in cc if x.startswith('-I')]
b=next(x for x in incs if (x/'libqemuutil.a').exists())
link=shlex.split(a.link_command.read_text())
link=[x for x in link if not x.endswith(('system_main.c.o','hw_usb_host-libusb.c.o','hw_usb_dev-host-hid.c.o','hw_usb_host-coexistence.c.o')) and not ('libusb/1.0.30/lib/' in x)]
link[link.index('-o')+1]=str(out/'test')
lib=out/'lib'
shutil.copytree(a.runtime_lib,lib,symlinks=True)
for x in list(lib.glob('libusb*')): x.unlink()
for i,x in enumerate(link):
 if x.startswith('-Wl,-rpath,'): link[i]='-Wl,-rpath,@executable_path/lib'
 elif x.startswith('/') and x.endswith('.dylib'):
  name=Path(x).name
  if name=='libSDL2.dylib':name='libSDL2-2.0.0.dylib'
  matches=list(lib.glob(name)) or list(lib.glob(name[:-6]+'.*.dylib'))
  assert len(matches)==1,(name,matches)
  link[i]=str(matches[0])
inputs={}
for i,x in enumerate(link):
 f=Path(x) if Path(x).is_absolute() else b/x
 if not x.startswith('-') and f.is_file():
  link[i]=str(f);inputs[str(f)]=hashlib.sha256(f.read_bytes()).hexdigest()
cc=cc[:1]+['-I'+str(out/'source')]+cc[1:]+['-I'+str(b.parent/'hw/usb'),'-O0','-g','-fsanitize=address,undefined','-Wno-missing-prototypes','-Wno-unused-function','-Wno-unused-variable','-Wno-redundant-decls']
link[1:1]=[str(out/'test.o'),str(out/'native.o'),str(out/'no-native.o'),'-fsanitize=address,undefined']
logs=[]
def run(cmd,limit=180):
 r=subprocess.run(cmd,cwd=out,capture_output=True,text=True,timeout=limit)
 logs.append(dict(command=cmd,exit=r.returncode,stdout=r.stdout,stderr=r.stderr))
 (out/'commands.json').write_text(json.dumps(logs,indent=2))
 if r.returncode: print(r.stdout+r.stderr);raise SystemExit(r.returncode)
 return r
shutil.copy(w/'test-core-native.c',out/'native.c')
shutil.copytree(w/'core-shim',out/'core-shim')
(out/'no-native.c').write_text('#include <IOKit/IOKitLib.h>\n#include <stdlib.h>\nio_object_t IOIteratorNext(io_iterator_t i){abort();}\nkern_return_t IOObjectRelease(io_object_t i){abort();}\nCFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t e,CFStringRef k,CFAllocatorRef a,IOOptionBits o){abort();}\nkern_return_t IORegistryCreateIterator(mach_port_t p,const io_name_t n,IOOptionBits o,io_iterator_t*i){abort();}\nkern_return_t IOServiceGetMatchingServices(mach_port_t p,CFDictionaryRef d,io_iterator_t*i){abort();}\nCFMutableDictionaryRef IOServiceMatching(const char*n){abort();}\n')
for name in ['test-core-cycle','native','no-native']:
 run(cc+['-c',str(out/(name+'.c')),'-o',str(out/('test.o' if name=='test-core-cycle' else name+'.o'))])
run(link)
# No libusb dylib or native IOUSB/IOHID exports may be resolved in test units.
r=run(['nm','-u',str(out/'test.o'),str(out/'native.o')])
assert not any(s in r.stdout for s in ['_libusb_','_IOHID','_IORegistry','_IOService','_IOObject','_IOIterator'])
run(['codesign','--force','--sign','-',str(out/'test')])
env=os.environ.copy();env['ASAN_OPTIONS']='detect_leaks=0'
# Respect the caller's portable scratch root; never write into a developer HOME.
assert env.get('TMPDIR'), 'set TMPDIR to an owned scratch directory'
# Existing private dylibs have already-relocated rpaths in retained link flags.
results=[]
for case in a.cases:
 r=subprocess.run([str(out/'test'),case],cwd=out,env=env,capture_output=True,text=True,timeout=30)
 (out/(case+'.log')).write_text(r.stdout+r.stderr)
 results.append(dict(case=case,exit=r.returncode));print(case,r.returncode,r.stdout+r.stderr)
assert all(hashlib.sha256(Path(x).read_bytes()).hexdigest()==h for x,h in inputs.items())
assert all(hashlib.sha256((a.source/x).read_bytes()).hexdigest()==h and hashlib.sha256((out/'source'/x).read_bytes()).hexdigest()==h for x,h in source_hashes.items())
(out/'results.json').write_text(json.dumps(dict(cases=results,source_sha256=source_hashes,retained_inputs=inputs,hardware=False,libusb_linked=False,instrumentation='changed whole units ASan/UBSan; retained QEMU core and external dylibs uninstrumented; leak detection disabled; inherited no-return stack warning retained'),indent=2))
raise SystemExit(any(r['exit'] for r in results))
