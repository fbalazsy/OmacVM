#!/usr/bin/env python3
"""Opt-in source build. Never installs, activates, measures USB or contacts a VM."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from dependencies import obtain, extract
from profile import generate, validate, BASE, NAMESPACE

ROOT=Path(__file__).resolve().parent

def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def run(args, **kw):
    print('+', ' '.join(map(str,args)), flush=True)
    return subprocess.run(list(map(str,args)), check=True, **kw)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True,help='new, private output directory')
    parser.add_argument('--cache',type=Path,required=True)
    parser.add_argument('--download',action='store_true',help='ordinary-user public pinned fetch')
    a=parser.parse_args()
    if os.getuid()==0 or os.geteuid()==0:parser.error('never root')
    if sys.platform!='darwin':parser.error('Apple Silicon macOS build only')
    p=validate(json.loads(a.profile.read_text()))
    cache=obtain(a.cache.resolve(),a.download)
    out=a.out.resolve()
    if out.exists():parser.error('output exists; use a fresh directory')
    out.mkdir(parents=True,mode=0o700)
    (out/'tmp').mkdir(mode=0o700);os.environ['TMPDIR']=str(out/'tmp')
    work=out/'source';work.mkdir()
    for folder in ('helper','activation','tests'):
        shutil.copytree(ROOT/folder,work/folder,ignore=shutil.ignore_patterns('__pycache__','build*','local_pins.*'))
    shutil.copytree(ROOT/'helper/build-config',work/'helper/build-config')
    for name in ('profile.py','dependencies.py','install_plan.py','test.py'):
        shutil.copyfile(ROOT/name,work/name)
    shutil.copytree(ROOT/'profiles',work/'profiles')
    # Full private input + generated authority are build artifacts, never repository files.
    (out/'profile.json').write_text(json.dumps(p,indent=2)+'\n')
    generate(p,work/'activation')
    vendor=work/'helper/vendor';vendor.mkdir()
    for name in ('libusb-1.0.30.tar.bz2','usbredir-0.15.0.tar.xz'):
        stage=out/('extract-'+name.split('.tar.')[0]);extract(cache/name,stage)
        shutil.move(str(stage/name.split('.tar.')[0]),vendor);stage.rmdir()
    sdk=os.environ.get('SDKROOT') or run(['/usr/bin/xcrun','--sdk','macosx','--show-sdk-path'],capture_output=True,text=True).stdout.strip()
    cc=run(['/usr/bin/xcrun','--find','clang'],capture_output=True,text=True).stdout.strip()
    flags=['-isysroot',sdk,'-arch','arm64','-mmacosx-version-min=13.0','-O2','-fstack-protector-strong','-D_FORTIFY_SOURCE=2','-Wno-deprecated-declarations']
    h=work/'helper';b=h/'build';b.mkdir();(work/'build').mkdir();(work/'activation/build').mkdir()
    u=vendor/'usbredir-0.15.0';usb=vendor/'libusb-1.0.30'
    inc=['-I'+str(h/'build-config'),'-I'+str(usb/'libusb'),'-I'+str(u/'usbredirparser'),'-I'+str(u/'usbredirhost')]
    fw=['-framework','Foundation','-framework','CoreFoundation','-framework','IOKit','-framework','Security','-framework','SystemConfiguration','-lbsm','-lobjc']
    def obj(src,own=False):
        src=Path(src);target=b/(src.stem+'.o')
        run([cc,*flags,*inc,'-Wall','-Wextra',*(['-Werror'] if own else []),*(['-fobjc-arc'] if src.suffix=='.m' else []),'-c',src,'-o',target]);return target
    vendorobj=[obj(u/f) for f in ('usbredirparser/usbredirparser.c','usbredirparser/usbredirfilter.c','usbredirhost/usbredirhost.c')]
    redir=b/'libusbredir-private.a';run(['/usr/bin/ar','rcs',redir,*vendorobj])
    env=os.environ.copy();env.update(SDKROOT=sdk,CC=cc,CFLAGS=' '.join(flags),MACOSX_DEPLOYMENT_TARGET='13.0')
    run(['./configure','--disable-shared','--enable-static','--disable-tests-build','--disable-examples-build'],cwd=usb,env=env)
    run(['/usr/bin/make','-j4'],cwd=usb,env=env)
    archive=usb/'libusb/.libs/libusb-1.0.a'
    own={name:obj(h/name,True) for name in ['policy.c','auth_policy.c','ipc.c','lifecycle.c','native_auth.c','native_registry.m','transport.c']}
    def exe(name,sources,libs=False):
        target=b/name;objects=[own[s] if s in own else obj(h/s,True) for s in sources]
        run([cc,*flags,*objects,*([redir,archive] if libs else []),*fw,'-o',target]);return target
    suites=[('unit-tests',['policy.c','auth_policy.c','ipc.c','tests.c'],False),('fuzz-tests',['policy.c','auth_policy.c','ipc.c','fuzz_tests.c'],False),('lifecycle-tests',['lifecycle.c','lifecycle_tests.c'],False),('registry-tests',['policy.c','native_registry.m','registry_tests.m'],False),('registry-scan-tests',['policy.c','registry_scan_tests.m'],False),('adapter-tests',[*own,'adapter_tests.m'],True)]
    for name,sources,libs in suites:exe(name,sources,libs)
    helper=exe('omacvm-usb-session-helper',[*own,'main.m'],True)
    run(['/usr/bin/codesign','--force','--sign','-','--options','runtime',helper])
    # Derived only from this helper's actual signed bytes, before compiling supervisor.
    with (work/'activation/local_pins.h').open('a') as f:f.write('#define HELPER_SHA "'+sha(helper)+'"\n')
    activator=work/'build/omacvm-usb-session-activate'
    run([cc,*flags,'-Wall','-Wextra','-Werror',*[work/'activation'/s for s in ('activation_native.c','activation_policy.c','activation_flow.c')],*fw,'-o',activator])
    run(['/usr/bin/codesign','--force','--sign','-','--options','runtime',activator])
    for binary in (helper,activator):
        run(['/usr/bin/codesign','--verify','--strict',binary])
        deps=run(['/usr/bin/otool','-L',binary],capture_output=True,text=True).stdout.splitlines()[1:]
        if not all(line.strip().startswith(('/usr/lib/','/System/Library/')) for line in deps):raise RuntimeError('non-system dylib')
        if 'LC_RPATH' in run(['/usr/bin/otool','-l',binary],capture_output=True,text=True).stdout:raise RuntimeError('unexpected rpath')
        ents=run(['/usr/bin/codesign','-d','--entitlements',':-',binary],capture_output=True,text=True).stdout
        if '<dict>' in ents:raise RuntimeError('unexpected entitlements')
    binaries={BASE+'/'+NAMESPACE+'-helper':sha(helper),BASE+'/'+NAMESPACE+'-activate':sha(activator)}
    sources={str(f.relative_to(work)):sha(f) for folder in ('activation','helper') for f in (work/folder).iterdir() if f.is_file()}
    manifest={'profile_kind':p['kind'],'source_sha256':sources,'installed_sha256':binaries,'cc':cc,'sdk':sdk,'flags':flags}
    (work/'BUILD.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (out/'BUILD.json').write_text(json.dumps(manifest,indent=2)+'\n')
    # Linkable objects + upstream source and licenses retained for LGPL relinking.
    licenses=out/'licenses';licenses.mkdir()
    shutil.copyfile(usb/'COPYING',licenses/'libusb-COPYING')
    shutil.copyfile(u/'COPYING.LIB',licenses/'usbredir-COPYING.LIB')
    if p['kind']=='physical':
        from install_plan import render
        (out/'install-reviewed.sh').write_text(render(p,helper,activator))
    else:
        (out/'NOT-INSTALLABLE').write_text('Synthetic fixture. Native entrypoints refuse activation even as root.\n')
    print('BUILT '+p['kind']+'; no installation or hardware acceptance')

if __name__=='__main__':main()
