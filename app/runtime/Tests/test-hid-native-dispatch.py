#!/usr/bin/env python3
"""Compile the real native wrapper against inert IOKit and port-model seams.
No hardware, QEMU launch, privileges, or third-party Python packages required.
"""
import argparse, hashlib, json, os, re, subprocess
from pathlib import Path

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--patch',type=Path,default=Path(__file__).resolve().parents[1]/'patches/qemu-usb-host-hid.patch')
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--variant',choices=['plain','ubsan','asan'],default='plain')
    ap.add_argument('--cases',nargs='+',default=['collision','input-first','capacity-control','get-exact','get-short','get-long','set-error','get-error','close-queued','close-running','reset-queued','removed-queued'])
    a=ap.parse_args();a.output.mkdir(parents=True,exist_ok=False)
    text=a.patch.read_text();m=re.search(r'\+\+\+ b/hw/usb/dev-host-hid.c\n@@ -0,0 \+1,(\d+) @@\n',text)
    assert m
    lines=text[m.end():].splitlines(keepends=True)[:int(m[1])];assert all(x.startswith('+') for x in lines)
    c=''.join(x[1:] for x in lines)
    fragments=[c[c.index('struct HostHIDState {'):c.index('static bool native_open')],c[c.index('static void host_hid_receive('):c.index('static void host_hid_bh(')],c[c.index('static void native_input('):c.rindex('#endif')]]
    (a.output/'native.inc').write_text('\n'.join(fragments))
    env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':os.environ['HOME'],'TMPDIR':os.environ['TMPDIR'],'LANG':'C','PYTHONDONTWRITEBYTECODE':'1'}
    logs=[]
    def run(argv,timeout=30):
        r=subprocess.run(list(map(str,argv)),env=env,text=True,capture_output=True,timeout=timeout)
        logs.append(dict(argv=list(map(str,argv)),exit=r.returncode,stdout=r.stdout,stderr=r.stderr))
        (a.output/'commands.json').write_text(json.dumps(logs,indent=2)+'\n');return r
    flags=[] if a.variant=='plain' else ['-fsanitize=undefined','-fno-sanitize-recover=all'] if a.variant=='ubsan' else ['-fsanitize=address,undefined','-fno-sanitize-recover=all']
    cmd=['clang','-std=gnu11','-fblocks','-g','-O1','-Wall','-Wextra','-Werror','-Wno-unused-function','-Wno-unused-parameter',*flags,'-I',a.output,Path(__file__).with_name('hid-native-dispatch.c'),'-framework','CoreFoundation','-o',a.output/'test']
    r=run(cmd);assert r.returncode==0,r.stderr
    symbols=run(['nm','-u',a.output/'test']);assert symbols.returncode==0
    assert not re.search(r'_(?:IOHID|IORegistry|IOService|IOObject|IOIterator)\w*',symbols.stdout)
    results=[]
    for case in a.cases:
        r=run([a.output/'test',case],10);results.append(dict(case=case,exit=r.returncode,stdout=r.stdout,stderr=r.stderr));print(r.stdout,end='',flush=True)
    result=dict(variant=a.variant,production_c_sha256=hashlib.sha256(c.encode()).hexdigest(),patch_sha256=hashlib.sha256(text.encode()).hexdigest(),hardware_symbols=False,cases=results,passed=sum(x['exit']==0 for x in results),total=len(results))
    (a.output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return int(result['passed']!=result['total'])
if __name__=='__main__':raise SystemExit(main())
