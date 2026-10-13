#!/usr/bin/env python3
"""Fixture-only offline lifecycle tests. Never run physical-profile binaries here."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parent

def main():
    if not os.getuid() or not os.geteuid():raise SystemExit('never root tests')
    manifest=json.loads((ROOT/'BUILD.json').read_text())
    if manifest['profile_kind']!='fixture':raise SystemExit('tests require synthetic fixture build')
    os.chdir(ROOT);sys.path.insert(0,str(ROOT/'activation'))
    os.environ['TMPDIR']=str(ROOT/'build');tempfile.tempdir=str(ROOT/'build')
    cc=[manifest['cc'],*manifest['flags'],'-Wall','-Wextra','-Werror','-Wno-unused-function']
    fw=['-framework','Security','-framework','CoreFoundation','-lbsm']
    results=[]
    def run(label,args,cwd=ROOT):
        p=subprocess.run(list(map(str,args)),cwd=cwd,capture_output=True,text=True,timeout=150)
        code=p.returncode
        if '--analyze' in args and ('warning:' in p.stderr or 'error:' in p.stderr):code=1
        result={'name':label,'exit':code,'stdout':p.stdout,'stderr':p.stderr};results.append(result)
        print(label,p.returncode,p.stdout[-500:],p.stderr[-4000:],flush=True)
        return p.returncode
    def unit(name,sources,extra=(),libs=fw,cwd=ROOT):
        binary=ROOT/'build'/name
        if not run(name+'-compile',[*cc,*extra,*sources,*libs,'-o',binary]):run(name,[binary],cwd)
    for name in ('reconnect_native','native_handoff'):
        with tempfile.TemporaryDirectory(dir='build') as scratch:
            unit(name,['tests/'+name+'.c','activation/activation_policy.c','activation/activation_flow.c'],cwd=ROOT/scratch)
    for name,sources in [('r1-manifest',['tests/r1_manifest.c','helper/auth_policy.c','helper/policy.c']),('r1-auth',['tests/r1_auth.c','helper/auth_policy.c','helper/policy.c']),('r2-timing',['tests/r2_timing.c','activation/activation_flow.c']),('r3-quarantine',['tests/r3_quarantine.c','activation/activation_policy.c','activation/activation_flow.c']),('r3-flow',['tests/r3_flow.c','activation/activation_flow.c']),('r3-native',['tests/r3_native.c','activation/activation_policy.c','activation/activation_flow.c']),('r2-output',['tests/r2_output.c','activation/activation_policy.c','activation/activation_flow.c']),('r2-exec',['tests/r2_exec.c','activation/activation_policy.c','activation/activation_flow.c']),('r2-deadline',['tests/r2_deadline.c','activation/activation_policy.c']),('local-manifest',['tests/local_manifest.c','activation/activation_policy.c'])]:unit(name,sources)
    for name,sources in [('policy',['policy_test.c','activation_policy.c']),('flow',['flow_test.c','activation_flow.c']),('native',['native_test.c','activation_policy.c']),('manifest',['manifest_test.c','activation_policy.c','activation_flow.c'])]:
        unit('regression-'+name,['activation/'+p for p in sources],cwd=ROOT/'activation')
    for name in ['unit-tests','fuzz-tests','lifecycle-tests','registry-tests','registry-scan-tests','adapter-tests']:
        run('helper-'+name,[ROOT/'helper/build'/name])
    inc=['-Ihelper/vendor/libusb-1.0.30/libusb','-Ihelper/vendor/usbredir-0.15.0/usbredirparser','-Ihelper/vendor/usbredir-0.15.0/usbredirhost']
    unit('local-session',['tests/local_session.c','activation/activation_flow.c','helper/ipc.c'],extra=inc)
    unit('serializer',['helper/serializer_only.c','helper/ipc.c','helper/build/libusbredir-private.a'],extra=inc)
    objects=[ROOT/'helper/build'/name for name in ['policy.o','auth_policy.o','ipc.o','lifecycle.o','native_auth.o','native_registry.o','transport.o','libusbredir-private.a']]+[ROOT/'helper/vendor/libusb-1.0.30/libusb/.libs/libusb-1.0.a']
    unit('helper-clock',['tests/r2_helper_clock.m',*objects],extra=inc,libs=[*fw,'-framework','Foundation','-framework','IOKit','-framework','SystemConfiguration','-lobjc'])
    for name in ['activation_native.c','activation_policy.c','activation_flow.c']:
        run('analyzer-'+name,[*cc,'--analyze','-Xanalyzer','-analyzer-output=text','activation/'+name,'-o','build/'+name+'.plist'])
    env=os.environ.copy();env['PYTHONPATH']=str(ROOT/'activation')
    # Fresh process executes only mocks, real owned filesystem/pipe/dummy-child tests.
    for label,args in [('python-activation',['-m','unittest','-v','test_runner','test_qmp','test_wire']),('python-lifecycle',['-m','unittest','discover','-s','tests','-v'])]:
        p=subprocess.run([sys.executable,'-B',*args],cwd=ROOT,env=env,capture_output=True,text=True,timeout=180)
        results.append({'name':label,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr});print(label,p.returncode,p.stderr[-10000:],flush=True)
    for name,args in [('helper',['--serve']),('activate',['--activate','42','1','0','1','0'])]:
        binary=ROOT/('helper/build/omacvm-usb-session-helper' if name=='helper' else 'build/omacvm-usb-session-activate')
        p=subprocess.run([str(binary),*args],capture_output=True,text=True,timeout=5)
        results.append({'name':name+'-refusal','exit':0 if p.returncode==64 and 'no USB initialized' in p.stderr else 1,'actual_exit':p.returncode,'stderr':p.stderr})
    failed=[r['name'] for r in results if r['exit']]
    (ROOT/'TEST-RESULTS.json').write_text(json.dumps({'checks':len(results),'failed':failed,'results':results},indent=2)+'\n')
    print('OFFLINE checks',len(results),'failed',failed)
    return bool(failed)

if __name__=='__main__':raise SystemExit(main())
