#!/usr/bin/env python3
"""Inert exact-source QEMU USB core tests using a retained link command.
Only test TUs are compiled; retained QEMU inputs remain read-only. No guest or
host HID is realized: IOKit imports and inherited disk discovery are fenced.
"""
import argparse,hashlib,json,os,re,shlex,shutil,subprocess
from pathlib import Path
HERE=Path(__file__).resolve().parent
CORE_CASES=['set','get','set-error','get-error','get-short','get-long','cancel-set','cancel-get','reset-set','reset-get','remove-set','close-set','close-get','close-queued','reset-queued','remove-queued','busy-set']

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--qemu-build',type=Path,required=True)
    p.add_argument('--runtime',type=Path,required=True)
    p.add_argument('--link-command',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--variant',choices=['plain','ubsan','asan'],default='plain')
    p.add_argument('--suite',choices=['core','shipped','scope','policy'],default='core')
    a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);b=a.qemu_build.resolve()
    sha=lambda f:hashlib.sha256(Path(f).read_bytes()).hexdigest()
    patch=HERE.parent/'patches/qemu-usb-host-hid.patch';text=patch.read_text()
    assert (sha(patch)+'  qemu-usb-host-hid.patch') in (patch.parent/'SHA256SUMS').read_text().splitlines()
    for m in re.finditer(r'--- /dev/null\n\+\+\+ b/([^\n]+)\n@@ -0,0 \+1,(\d+) @@\n',text):
        lines=text[m.end():].splitlines(keepends=True)[:int(m[2])];assert all(x.startswith('+') for x in lines)
        path=out/m[1];path.parent.mkdir(parents=True,exist_ok=True);path.write_text(''.join(x[1:] for x in lines))
    unit=out/'tests/unit';base=(unit/'review-test-base.inc').read_text()
    for name in ['hid-sync-core.c','hid-sync-core-shim.h']:shutil.copy2(HERE/name,unit/name)
    (unit/'sync-test-base.inc').write_text(base.replace('"scope-registry-shim.h"','"hid-sync-core-shim.h"'))
    if a.suite == 'scope':
        # These suites exercise real native admission, not report submission.
        # Current sync API boundary must still be fenced at link time.
        shim=(HERE/'hid-sync-core-shim.h').read_text().split('#include "scope-registry-shim.h"\n',1)[1]
        (unit/'sync-api.inc').write_text(shim)
        base=base.replace('#include "scope-registry-shim.h"','#include "scope-registry-shim.h"\n#include "sync-api.inc"')
        (unit/'review-test-base.inc').write_text(base)
    if a.suite=='policy':
        for name in ['policy-test.c','policy-shim.h']:shutil.copy2(HERE/'hid-policy'/name,unit/name)
        (unit/'review-test-base.inc').write_text(base.replace('"scope-registry-shim.h"','"policy-shim.h"'))
    source={'core':'hid-sync-core.c','shipped':'test-host-hid.c','scope':'scope-test.c','policy':'policy-test.c'}[a.suite]
    db=json.loads((b/'compile_commands.json').read_text());row=next(x for x in db if x['file'].endswith('/dev-host-hid.c'))
    cc=list(row.get('arguments') or shlex.split(row['command']))
    for flag in ['-MQ','-MF']:
        if flag in cc:i=cc.index(flag);del cc[i:i+2]
    if '-MD' in cc:cc.remove('-MD')
    cc[cc.index('-o')+1]=str(out/'test.o');cc[cc.index('-c')+1]=str(unit/source)
    if a.suite!='shipped':cc+=['-DHOST_HID_NATIVE_SHIM','-DHOST_HID_SCOPE_SHIM']
    cc+=['-fblocks','-Werror']
    link=shlex.split(a.link_command.read_text())
    link=[x for x in link if not x.endswith('system_main.c.o') and not x.endswith('hw_usb_dev-host-hid.c.o')]
    inputs={}
    for x in link:
        f=Path(x) if Path(x).is_absolute() else b/x
        if f.is_file():inputs[str(f)]=sha(f)
    link[link.index('-o')+1]=str(out/'test');link[1:1]=[str(out/'test.o'),str(out/'no-native.o')]
    lib=out/'lib';shutil.copytree(a.runtime/'lib',lib,symlinks=True)
    for i,x in enumerate(link):
        if x.startswith('-Wl,-rpath,'):link[i]='-Wl,-rpath,@executable_path/lib'
        elif x.startswith('/') and x.endswith('.dylib'):
            name=Path(x).name
            if name=='libSDL2.dylib':name='libSDL2-2.0.0.dylib'
            matches=list(lib.glob(name)) or list(lib.glob(name[:-6]+'.*.dylib'));assert len(matches)==1,(name,matches);link[i]=str(matches[0])
    flags=[] if a.variant=='plain' else ['-fsanitize='+('undefined' if a.variant=='ubsan' else 'address,undefined'),'-g','-fno-omit-frame-pointer','-fno-sanitize-recover=all']
    env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(out),'TMPDIR':os.environ['TMPDIR'],'LANG':'C','PYTHONDONTWRITEBYTECODE':'1'}
    records=[]
    def run(cmd,timeout=120,extra=None):
        r=subprocess.run(list(map(str,cmd)),cwd=b,env={**env,**(extra or {})},text=True,capture_output=True,timeout=timeout)
        records.append(dict(argv=list(map(str,cmd)),cwd=str(b),exit=r.returncode,stdout=r.stdout,stderr=r.stderr));(out/'commands.json').write_text(json.dumps(records,indent=2)+'\n');return r
    for cmd in [['clang','-c',unit/'no-native.c','-o',out/'no-native.o'],cc+flags,link+flags,['codesign','--force','--sign','-',out/'test']]:
        r=run(cmd);assert not r.returncode,r.stderr
    for name in ['test.o','test']:
        r=run(['nm','-u',out/name]);assert not r.returncode
        assert not re.search(r'_(?:IOHID|IORegistry|IOService|IOObject|IOIterator)\w*',r.stdout),r.stdout
    cases=CORE_CASES
    if a.suite=='shipped':cases=['shipped']
    if a.suite=='scope':
        cases=['parent-snapshot','generic-base','false-built-in','unrelated-name']
        for prefix in ['built-in','boolean-internal','malformed-internal','standard-page','malformed-page','owner','qemu-owner','event','unreadable']:cases += [f'{prefix}-{n}' for n in range(1,6)]
        for prefix in ['missing-page','missing-pairs','empty-pairs','bad-pairs']:cases += [f'{prefix}-{n}' for n in [1,4]]
        cases+=['specialized-hid','name-is-not-class','specialized-leaf','unknown-root-driver','second-hid','second-interface','boot-interface','invalid-iterator','class-failure','parent-failure','wrong-generation','missing-generation','primary-pair-mismatch','security-page','digitizer-page']
    if a.suite=='policy':
        import plistlib
        cases=[x['name'] for x in plistlib.loads((HERE/'hid-policy/corpus.plist').read_bytes())]
    results=[]
    for case in cases:
        r=run([out/'test'],timeout=12,extra={'SYNC_CASE':case,'REVIEW_CASE':case,'POLICY_CORPUS':str(HERE/'hid-policy/corpus.plist')})
        results.append(dict(case=case,exit=r.returncode,stdout=r.stdout,stderr=r.stderr))
        print(a.suite,a.variant,case,r.returncode,flush=True)
    assert all(sha(f)==h for f,h in inputs.items())
    result=dict(suite=a.suite,variant=a.variant,c_sha256=sha(out/'hw/usb/dev-host-hid.c'),patch_sha256=sha(patch),cases=results,passed=sum(x['exit']==0 for x in results),total=len(results),retained_inputs_unchanged=inputs)
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n');return int(result['passed']!=result['total'])
if __name__=='__main__':raise SystemExit(main())
