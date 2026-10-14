"""Actual app list wiring, offline. Fixture-only @Entry expansion is NOT an official build.
Usage: SDKROOT=... TMPDIR=... python3 run.py NEW_OWNED_OUTPUT_DIRECTORY
No AppDelegate, USBWatch.start(), real QMP, activation or hardware calls.
"""
from pathlib import Path
import json, os, plistlib, shutil, subprocess, sys, uuid
source = Path(__file__).resolve().parent
out = Path(sys.argv[1]).resolve(); out.mkdir(exist_ok=False)
package = out / 'package'
repo_package = source.parents[1] / 'app'
shutil.copytree(repo_package/'Sources', package/'Sources', symlinks=False)
shutil.copy2(repo_package/'Package.swift', package/'Package.swift')
src = package/'Sources/OmacVM'
shutil.copy2(source/'UIKeys.swift', src/'UIKeys.swift')
def replace(file, old, new):
    p = src/file; s = p.read_text(); assert s.count(old) == 1, (file, old)
    p.write_text(s.replace(old,new))
replace('SettingsView.swift', '    @Entry var spyStart: String? = nil',
        '    var spyStart: String? { get { self[KeySpy.self] } set { self[KeySpy.self] = newValue } }')
p = src/'SettingsView.swift'; p.write_text(p.read_text()+'\nprivate struct KeySpy: EnvironmentKey { static let defaultValue: String? = nil }\n')
replace('USBRun.swift', 'private var session: USBSession?', 'var session: USBSession?')
replace('main.swift', '''MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}''', 'MainActor.assumeIsolated { UIKeys.run() }')
env = dict(os.environ)
assert env.get('TMPDIR'), 'Set TMPDIR to an authorized scratch directory'
build = out/'build'
cmd = ['swift','build','--package-path',str(package),'--build-system','native','--scratch-path',str(build),'--jobs','1','-Xswiftc','-num-threads','-Xswiftc','1','-Xswiftc','-j1','--product','OmacVM']
with (out/'build.log').open('w') as f: r = subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT)
(out/'command.json').write_text(json.dumps({'argv':cmd,'exit':r.returncode},indent=2))
if r.returncode: raise SystemExit(r.returncode)
app = out/'fixture.app'; mac = app/'Contents/MacOS'; mac.mkdir(parents=True)
shutil.copy2(build/'debug/OmacVM',mac/'OmacVM')
identity = 'org.omacvm.app.test.usbkeys.'+uuid.uuid4().hex
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':identity,'CFBundleExecutable':'OmacVM','CFBundlePackageType':'APPL'}))
subprocess.run(['codesign','--force','--sign','-','--identifier',identity,str(app)],check=True)
subprocess.run(['codesign','--verify','--strict',str(app)],check=True)
home = out/'home'; home.mkdir()
with (out/'run.log').open('w') as f:
    r = subprocess.run([str(mac/'OmacVM'),str(out/'fixtures')],env=dict(env,HOME=str(home),CFFIXED_USER_HOME=str(home)),stdout=f,stderr=subprocess.STDOUT,timeout=90)
print((out/'run.log').read_text())
raise SystemExit(r.returncode)
