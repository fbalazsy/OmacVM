#!/usr/bin/env python3
"""Ordinary-user reproducible native build. Never installs or touches USB/VM.
Interface: build.py --out DIR --cache DIR [--download] [--sanitize]
"""
import argparse, hashlib, os, pathlib, shlex, shutil, subprocess, tarfile, urllib.request
ROOT=pathlib.Path(__file__).resolve().parent
PINS={
 'libusb-1.0.30.tar.bz2':('fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf','https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2'),
 'usbredir-0.15.0.tar.xz':('6dc2a380277688a068191245dac2ab7063a552999d8ac3ad8e841c10ff050961','https://www.spice-space.org/download/usbredir/usbredir-0.15.0.tar.xz')}
def build(argv=None):
 p=argparse.ArgumentParser();p.add_argument('--out',type=pathlib.Path,default=ROOT/'build');p.add_argument('--cache',type=pathlib.Path,default=ROOT/'vendor');p.add_argument('--download',action='store_true');p.add_argument('--sanitize',action='store_true');a=p.parse_args(argv)
 assert os.getuid()!=0 and os.geteuid()!=0,'build as ordinary user'
 out=a.out.resolve();cache=a.cache.resolve();out.mkdir(parents=True,exist_ok=True);cache.mkdir(parents=True,exist_ok=True)

 cc=subprocess.check_output(['xcrun','--find','clang'],text=True).strip();sdk=os.environ.get('SDKROOT') or subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
 base=['-isysroot',sdk,'-mmacosx-version-min=13.0','-O1' if a.sanitize else '-O2','-g','-fstack-protector-strong']
 base+=['-fsanitize=address,undefined','-fno-omit-frame-pointer'] if a.sanitize else ['-D_FORTIFY_SOURCE=2']
 def run(args,cwd=ROOT,env=None):
  print('+',shlex.join(map(str,args)),flush=True);subprocess.run(list(map(str,args)),cwd=cwd,env=env,check=True)
 for filename,(digest,url) in PINS.items():
  archive=cache/filename
  if not archive.exists():
   if not a.download:raise RuntimeError('missing pinned archive '+str(archive)+' (use --download)')
   with urllib.request.urlopen(url,timeout=60) as response: archive.write_bytes(response.read(16*1024*1024))
  if hashlib.sha256(archive.read_bytes()).hexdigest()!=digest:raise RuntimeError('archive SHA-256 mismatch: '+filename)
  dest=out/'sources';dest.mkdir(exist_ok=True)
  name=filename.split('.tar.')[0]
  if not (dest/name).exists():
   run(['/usr/bin/tar','-xf',archive,'-C',dest]) # Only exact SHA-256 pinned upstream archives.
 usb=out/'sources/libusb-1.0.30';redir=out/'sources/usbredir-0.15.0'
 # Build libusb in this output only. Source donors and cache tarballs remain read-only.
 lib=usb/'libusb/.libs/libusb-1.0.a';stamp=usb/'.omacvm-flags';flags=shlex.join(base)
 if not lib.exists() or not stamp.exists() or stamp.read_text()!=flags:
  env=os.environ.copy();env.update(CC=cc,CFLAGS=flags,SDKROOT=sdk,MACOSX_DEPLOYMENT_TARGET='13.0')
  run(['./configure','--disable-shared','--enable-static','--disable-tests-build','--disable-examples-build'],usb,env)
  run(['make','-j4'],usb,env);stamp.write_text(flags)
 config=out/'config';config.mkdir(exist_ok=True)
 (config/'config.h').write_text('#define USBREDIR_VISIBLE __attribute__((visibility("default")))\n#define VERSION "0.15.0"\n#define PACKAGE_VERSION "0.15.0"\n#define PACKAGE_STRING "usbredir 0.15.0"\n#define ENABLE_EXTRA_CHECKS 1\n'+''.join('#define HAVE_'+h+'_H 1\n' for h in ['INTTYPES','STDINT','STDLIB','STRINGS','STRING','SYS_STAT','SYS_TYPES','UNISTD']))
 includes=['-I'+str(ROOT),'-I'+str(config),'-I'+str(usb/'libusb'),'-I'+str(redir/'usbredirparser'),'-I'+str(redir/'usbredirhost')]
 def obj(src,own=True):
  src=pathlib.Path(src);target=out/(src.stem+'.o')
  run([cc,*base,*includes,'-Wall','-Wextra',*(['-Werror'] if own else []),*(['-fobjc-arc'] if src.suffix=='.m' else []),'-c',src,'-o',target]);return target
 vendor=[obj(redir/f,False) for f in ['usbredirparser/usbredirparser.c','usbredirparser/usbredirfilter.c','usbredirhost/usbredirhost.c']]
 redirlib=out/'libusbredir-private.a';run(['/usr/bin/ar','rcs',redirlib,*vendor])
 names=['process.c','protocol.m','hid.c','cached.c','io.c','gate.c','transport.c','lifecycle.c','registry.m','security.c','supervisor.m','backend.m','session.m','main.m']
 own=[obj(ROOT/f) for f in names]
 fw=['-framework','Foundation','-framework','CoreFoundation','-framework','IOKit','-framework','Security','-framework','SystemConfiguration','-lbsm']
 binary=out/'omacvm-usb-helper';run([cc,*base,*own,redirlib,lib,*fw,'-o',binary])
 if not a.sanitize:run(['/usr/bin/codesign','--force','--sign','-','--options','runtime',binary])
 deps=subprocess.check_output(['/usr/bin/otool','-L',str(binary)],text=True)
 print(deps,flush=True)
 if not a.sanitize:
  for line in deps.splitlines()[1:]:
   dep=line.strip().split(' (')[0]
   if not dep.startswith(('/usr/lib/','/System/Library/')):raise RuntimeError('non-system dynamic dependency: '+dep)
 relink=out/'relink';relink.mkdir(exist_ok=True)
 shutil.copyfile(ROOT.parents[1]/'LICENSE',relink/'APP-LICENSE')
 shutil.copyfile(ROOT/'NOTICE.md',relink/'NOTICE.md')
 run(['/usr/bin/ar','rcs',relink/'omacvm-helper-objects.a',*own])
 for source,name in [(usb/'COPYING','libusb-COPYING'),(redir/'COPYING.LIB','usbredir-COPYING.LIB')]:
  if not source.exists():source=redir/'COPYING'
  shutil.copyfile(source,relink/name)
 for filename in PINS:shutil.copyfile(cache/filename,relink/filename)
 (relink/'relink.sh').write_text('#!/bin/sh\nset -eu\n# Supply rebuilt replacement static libraries in these arguments.\n'+shlex.join([cc,*base])+' -Wl,-force_load,"$(dirname "$0")/omacvm-helper-objects.a" "$1" "$2" '+shlex.join(fw)+' -o "${3:-omacvm-usb-helper}"\n')
 (relink/'README.txt').write_text('LGPL-2.1-or-later relinking materials. The two pinned upstream source archives, license texts and complete application object archive are included. Rebuild modified libusb and usbredir static archives, then sh relink.sh libusbredir-private.a libusb-1.0.a output. Ad-hoc sign the output using codesign --force --sign - --options runtime. A modified helper has a new SHA and requires explicit root installation into its matching release directory. Application native source is MIT, in app/usb-helper. No user-writable dylib is loaded by root. No restriction is imposed on reverse engineering for debugging modifications to these libraries.\n')
 print('BUILT '+str(binary),flush=True)
 return out,cc,base,includes,fw
if __name__=='__main__':build()
