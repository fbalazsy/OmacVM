#!/usr/bin/env python3
"""Verify pinned source and patch roundtrip, without QEMU, USB or private files.

--source is a read-only QEMU tree after the normal HID and busy-device patches.
Only the affected baseline files are copied into a fresh temporary directory.
"""
import argparse
import hashlib
import json
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile


def recipe_block(runtime, expected):
    recipe = (runtime / 'build-qemu-gpu-runtime.sh').read_text()
    sums = (runtime / 'patches/SHA256SUMS').read_text()
    assert f"usb_coexistence_patch_sha256={expected}" in recipe, 'recipe checksum drift'
    assert f"{expected}  qemu-usb-session-accounting.patch" in sums, 'manifest checksum drift'
    start = recipe.index('patch -d "$source_dir" -p1 -f -i "$usb_exact_bus_patch"')
    end = recipe.index('# OmacVM: a main loop stall', start)
    block = recipe[start:end]
    active = [line for line in block.splitlines() if line and not line.startswith('#')]
    assert len(active) == 6, 'USB patch block must remain unconditional and checked'
    assert active[1].startswith('verify_file_sha "USB vendor HID patch"')
    assert active[2] == 'patch -d "$source_dir" -p1 -f -i "$usb_hid_patch"'
    assert active[3] == 'patch -d "$source_dir" -p1 -f -i "$native_dir/patches/qemu-usb-host-busy-device.patch"'
    assert active[4] == 'verify_file_sha "USB coexistence patch" "$usb_coexistence_patch" "$usb_coexistence_patch_sha256"'
    assert active[5] == 'patch -d "$source_dir" -p1 -f -i "$usb_coexistence_patch"'
    helper = re.search(r'^verify_file_sha\(\) \{\n.*?^\}', recipe, re.M | re.S)
    assert helper, 'checksum helper missing'
    return helper.group(), block


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(source):
    here = Path(__file__).resolve().parent
    manifest = json.loads((here / 'inputs.json').read_text())
    patch = here.parents[1] / 'patches/qemu-usb-session-accounting.patch'
    assert digest(patch) == manifest['patch_sha256'], 'packaged patch drift'
    runtime = here.parents[1]
    helper, block = recipe_block(runtime, manifest['patch_sha256'])
    for name, expected in manifest['base_sha256'].items():
        assert digest(source / name) == expected, 'baseline drift: ' + name
    with tempfile.TemporaryDirectory(prefix='omacvm-coexistence-roundtrip-') as work:
        dest = Path(work)
        for name in manifest['base_sha256']:
            (dest / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / name, dest / name)
        subprocess.run(['patch', '-p1', '-f', '-i', str(patch)], cwd=dest, check=True)
        for name, expected in manifest['source_sha256'].items():
            assert digest(dest / name) == expected, 'patched source drift: ' + name
        actual = {str(p.relative_to(dest)) for p in dest.rglob('*') if p.is_file()}
        assert actual == set(manifest['source_sha256']), 'unexpected patched paths'
        # Reconstruct the input to the normal recipe's USB block, then execute
        # that exact block and its real checksum helper. No recipe top-level runs.
        for name in manifest['source_sha256']:
            if name not in manifest['base_sha256']:
                (dest / name).unlink()
        for name in manifest['base_sha256']:
            shutil.copyfile(source / name, dest / name)
        for name in ['busy-device', 'hid', 'exact-bus']:
            subprocess.run(['patch', '-R', '-p1', '-f', '-i',
                            str(runtime / ('patches/qemu-usb-host-' + name + '.patch'))],
                           cwd=dest, check=True)
        env = os.environ.copy()
        env.update(source_dir=str(dest), native_dir=str(runtime),
                   usb_exact_bus_patch=str(runtime / 'patches/qemu-usb-host-exact-bus.patch'),
                   usb_hid_patch=str(runtime / 'patches/qemu-usb-host-hid.patch'),
                   usb_hid_patch_sha256=digest(runtime / 'patches/qemu-usb-host-hid.patch'),
                   usb_coexistence_patch=str(patch),
                   usb_coexistence_patch_sha256=manifest['patch_sha256'])
        subprocess.run(['/bin/bash', '-euo', 'pipefail', '-c',
                        'die() { printf "%s\\n" "$*" >&2; exit 1; }\n' + helper + '\n' + block],
                       env=env, check=True)
        for name, expected in manifest['source_sha256'].items():
            assert digest(dest / name) == expected, 'normal recipe output drift: ' + name
    print('PASS checksums, eight-source roundtrip and exact normal USB recipe block; no hardware run')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    verify(parser.parse_args().source.resolve())
