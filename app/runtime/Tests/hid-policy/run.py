#!/usr/bin/env python3
"""Run the shared plist through compiled Swift discovery and fake-native admission.
Needs an already-built, pinned QEMU tree and staged runtime. Never builds QEMU,
starts a guest or opens a real device. Outputs stay in a new --output directory.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess

HERE = Path(__file__).resolve().parent


def verify_native(source, out, phase, before=None):
    """Bind the compiled C copy to this checkout's checksum-covered patch.

    Only the current full-file addition format is accepted. Recipe changes that
    turn this into an incremental patch must update this check, not bypass it.
    """
    native = source / 'hw/usb/dev-host-hid.c'
    patches = HERE.parents[1] / 'patches'
    record = {'source': str(native), 'patch': str(patches / 'qemu-usb-host-hid.patch')}
    def read(path):
        if path.is_symlink() or not path.is_file():
            raise ValueError('not a regular provenance input: ' + str(path))
        return path.read_bytes()
    def sha(data):
        return hashlib.sha256(data).hexdigest()
    try:
        patch = read(Path(record['patch']))
        manifest = read(patches / 'SHA256SUMS')
        record.update(patch_sha256=sha(patch), manifest_sha256=sha(manifest),
                      native_sha256=sha(read(native)))
        entries = [line for line in manifest.decode().splitlines()
                   if line.split()[-1:] == ['qemu-usb-host-hid.patch']]
        if entries != [record['patch_sha256'] + '  qemu-usb-host-hid.patch']:
            raise ValueError('patch SHA256SUMS mismatch')
        additions = re.findall(rb'^--- /dev/null\n\+\+\+ b/hw/usb/dev-host-hid.c\n'
                               rb'@@ -0,0 \+1,(\d+) @@\n((?:\+.*\n)+)', patch, re.M)
        if len(additions) != 1 or len(additions[0][1].splitlines()) != int(additions[0][0]):
            raise ValueError('expected one complete native source addition')
        packaged = b''.join(line[1:] for line in additions[0][1].splitlines(keepends=True))
        record['packaged_native_sha256'] = sha(packaged)
        if record['native_sha256'] != record['packaged_native_sha256']:
            raise ValueError('native source does not match packaged patch')
        if before is not None:
            record['copied_native_sha256'] = sha(read(out / 'hw/usb/dev-host-hid.c'))
            if record['copied_native_sha256'] != record['native_sha256']:
                raise ValueError('compiled native copy does not match packaged patch')
            if any(record[key] != value for key, value in before.items()):
                raise ValueError('native provenance changed during run')
    except (OSError, ValueError) as error:
        record['error'] = str(error)
        raise RuntimeError('native provenance: ' + str(error)) from error
    finally:
        (out / ('provenance-' + phase + '.json')).write_text(json.dumps(record, indent=2) + '\n')
    return record


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--qemu-build', type=Path, required=True)
    p.add_argument('--runtime', type=Path, required=True)
    p.add_argument('--swift-source', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--ninja', required=True)
    p.add_argument('--sdk', required=True)
    p.add_argument('--variant', choices=['plain', 'ubsan', 'asan'], default='plain')
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=False)
    b = a.qemu_build.resolve()
    out = a.output.resolve()
    source = b.parent
    before = verify_native(source, out, 'before')
    env = {**os.environ, 'SDKROOT': a.sdk, 'PYTHONDONTWRITEBYTECODE': '1',
           'POLICY_CORPUS': str(HERE / 'corpus.plist')}
    commands = []
    def run(cmd, name, cwd=out, timeout=180, extra=None):
        verify_native(source, out, 'before-command', before)
        try:
            r = subprocess.run(list(map(str, cmd)), cwd=cwd, env={**env, **(extra or {})},
                               capture_output=True, text=True, timeout=timeout)
        finally:
            verify_native(source, out, 'after', before)
        (out / (name + '.log')).write_text(r.stdout + r.stderr)
        commands.append(dict(argv=list(map(str, cmd)), cwd=str(cwd), exit=r.returncode))
        (out / 'commands.json').write_text(json.dumps(commands, indent=2))
        return r
    def checked(cmd, name, **kw):
        r = run(cmd, name, **kw)
        if r.returncode: raise RuntimeError(f'{name} failed; see {out}')
        return r.stdout
    for d in ['tests/unit', 'hw/usb', 'lib']:
        (out / d).mkdir(parents=True)
    for f in ['review-test-base.inc', 'review-native-shim.h', 'scope-registry-shim.h', 'no-native.c']:
        shutil.copy2(source / 'tests/unit' / f, out / 'tests/unit' / f)
    base = out / 'tests/unit/review-test-base.inc'
    text = base.read_text()
    # Existing base may select the scope shim conditionally; replace its registry boundary.
    text = text.replace('"review-native-shim.h"', '"policy-shim.h"').replace('"scope-registry-shim.h"', '"policy-shim.h"')
    base.write_text(text)
    for f in ['policy-test.c', 'policy-shim.h']:
        shutil.copy2(HERE / f, out / 'tests/unit' / f)
    shutil.copy2(source / 'hw/usb/dev-host-hid.c', out / 'hw/usb/dev-host-hid.c')
    for f in (a.runtime / 'lib').iterdir():
        if f.is_file(): shutil.copy2(f, out / 'lib' / f.name)
    db = json.loads((b / 'compile_commands.json').read_text())
    row = next(x for x in db if x['file'].endswith('/dev-host-hid.c'))
    cc = row.get('arguments') or shlex.split(row['command'])
    cc = list(cc)
    for flag in ['-MQ', '-MF']:
        if flag in cc:
            i = cc.index(flag); del cc[i:i+2]
    if '-MD' in cc: cc.remove('-MD')
    cc[cc.index('-o') + 1] = str(out / 'policy.o')
    cc[-1] = str(out / 'tests/unit/policy-test.c')
    cc += ['-DHOST_HID_NATIVE_SHIM', '-fblocks', '-Werror']
    lines = checked([a.ninja, '-t', 'commands', 'qemu-system-aarch64'], 'ninja-commands', cwd=b).splitlines()
    link = next(shlex.split(x) for x in lines if ' -o qemu-system-aarch64-unsigned ' in x)
    link = [x for x in link if not x.endswith('system_main.c.o') and not x.endswith('hw_usb_dev-host-hid.c.o')]
    link[link.index('-o') + 1] = str(out / 'policy-native')
    link[1:1] = [str(out / 'policy.o'), str(out / 'no-native.o')]
    for i, x in enumerate(link):
        if x.startswith('-Wl,-rpath,'): link[i] = '-Wl,-rpath,@executable_path/lib'
        elif x.startswith('/') and x.endswith('.dylib'):
            name = Path(x).name
            if name == 'libSDL2.dylib': name = 'libSDL2-2.0.0.dylib'
            candidates = list((out / 'lib').glob(name)) or list((out / 'lib').glob(name[:-6] + '.*.dylib'))
            if len(candidates) != 1: raise RuntimeError('unresolved private dependency: ' + x)
            link[i] = str(candidates[0])
    flags = [] if a.variant == 'plain' else ['-fsanitize=' + ('undefined' if a.variant == 'ubsan' else 'address,undefined'), '-g', '-fno-omit-frame-pointer']
    if a.variant == 'ubsan': flags += ['-fno-sanitize-recover=all']
    checked(['clang', '-isysroot', a.sdk, '-c', out / 'tests/unit/no-native.c', '-o', out / 'no-native.o'], 'fence-build')
    checked(cc + flags, 'native-compile', cwd=b)
    checked(link + flags, 'native-link', cwd=b)
    checked(['codesign', '--force', '--sign', '-', out / 'policy-native'], 'native-sign')
    for f in ['policy.o', 'policy-native']:
        symbols = checked(['nm', '-u', out / f], 'symbols-' + f)
        if re.search(r'_(?:IOHID|IORegistry|IOService|IOObject|IOIterator)\w*', symbols):
            raise RuntimeError('unfenced IOKit import: ' + f)
    swift = ['swiftc', '-num-threads', '1', '-j', '1', '-sdk', a.sdk,
             '-module-cache-path', str(out / 'swift-cache')]
    checked(swift + ['-emit-library', '-emit-module', '-module-name', 'OmacVMUSB', '-o', out / 'libOmacVMUSB.dylib'] + sorted(a.swift_source.resolve().glob('*.swift')), 'swift-module')
    checked(swift + ['-parse-as-library', '-I', out, '-L', out, '-lOmacVMUSB', '-Xlinker', '-rpath', '-Xlinker', out, HERE / 'PolicyCorpus.swift', '-o', out / 'policy-swift'], 'swift-compile')
    r = run([out / 'policy-swift', HERE / 'corpus.plist'], 'swift-results')
    failures = int(r.returncode != 0)
    cases = plistlib.loads((HERE / 'corpus.plist').read_bytes())
    for case in cases:
        r = run([out / 'policy-native'], 'native-' + case['name'], timeout=12, extra={'REVIEW_CASE': case['name']})
        failures += int(r.returncode != 0)
    print(f'{len(cases)} shared cases, variant={a.variant}, failures={failures}; {out}')
    return 1 if failures else 0

if __name__ == '__main__':
    raise SystemExit(main())
