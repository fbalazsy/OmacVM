#!/usr/bin/env python3
"""All tests are ordinary-user and offline. No IORegistry enumeration, USB,
root session, QMP, installation or VM mutation is performed.
Pass build.py options (--out, --cache, --download, --sanitize) if needed.
"""
import os, pathlib, subprocess, sys
from build import ROOT, build
assert os.getuid()!=0 and os.geteuid()!=0, 'offline tests must be ordinary user'
subprocess.run([sys.executable,str(ROOT/'tests/test_build.py')],check=True,timeout=30)
out,cc,flags,includes,frameworks=build(sys.argv[1:])
common=[out/(f+'.o') for f in ['process','protocol','hid','cached','io','gate','transport','lifecycle','registry','security','supervisor','backend','session']]
libs=[out/'libusbredir-private.a',out/'sources/libusb-1.0.30/libusb/.libs/libusb-1.0.a']
cases=['protocol_tests.m','hid_tests.c','cached_tests.c','io_tests.c','gate_tests.c','registry_tests.m','transport_tests.c','supervisor_tests.m','security_tests.c','exec_tests.c','acl_tests.c','lifecycle_tests.c']
for case in cases:
    src=ROOT/'tests'/case;binary=out/(src.stem.replace('_','-'))
    objects=[o for o in common if not(case=='acl_tests.c' and o.name=='security.o')]
    command=[cc,*flags,*includes,'-Wall','-Wextra','-Werror',*(['-fobjc-arc'] if src.suffix=='.m' else []),str(src),*map(str,objects),*map(str,libs),*frameworks,'-o',str(binary)]
    print('+ '+' '.join(command),flush=True);subprocess.run(command,check=True)
    subprocess.run([str(binary)],check=True,timeout=30)
os.environ['OMACVM_TEST_HELPER']=str(out/'omacvm-usb-helper')
subprocess.run([sys.executable,str(ROOT/'tests/test_cli.py')],check=True,timeout=30)
print('OFFLINE PASS: '+str(len(cases))+' native test executables + CLI suite; no hardware acceptance claimed',flush=True)
