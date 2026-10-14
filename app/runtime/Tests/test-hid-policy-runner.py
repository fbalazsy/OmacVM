#!/usr/bin/env python3
"""Runner preflight tests: temporary trees, no compiler or native API calls."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

RUNTIME = Path(__file__).resolve().parents[1]


class Runner(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.runtime = self.root / 'runtime'
        shutil.copytree(RUNTIME / 'patches', self.runtime / 'patches')
        runner = self.runtime / 'Tests/hid-policy/run.py'
        runner.parent.mkdir(parents=True)
        shutil.copy2(RUNTIME / 'Tests/hid-policy/run.py', runner)
        for name in ('policy-test.c', 'policy-shim.h'):
            shutil.copy2(RUNTIME / 'Tests/hid-policy' / name, runner.parent / name)
        self.patch = self.runtime / 'patches/qemu-usb-host-hid.patch'
        hunk = self.patch.read_bytes().split(b'+++ b/hw/usb/dev-host-hid.c\n', 1)[1]
        lines = hunk.split(b'--- ', 1)[0].splitlines(keepends=True)[1:]
        self.native = self.root / 'qemu/hw/usb/dev-host-hid.c'
        self.native.parent.mkdir(parents=True)
        self.native.write_bytes(b''.join(line[1:] for line in lines if line.startswith(b'+')))
        build = self.root / 'qemu/build'
        build.mkdir()
        (build / 'compile_commands.json').write_text(json.dumps([
            {'file': str(self.native), 'arguments': ['clang', '-o', 'native.o', '-c', str(self.native)]}]))
        unit = self.root / 'qemu/tests/unit'
        unit.mkdir(parents=True)
        for name in ('review-test-base.inc', 'review-native-shim.h', 'scope-registry-shim.h', 'no-native.c'):
            (unit / name).touch()
        (self.root / 'staged/lib').mkdir(parents=True)
        self.marker = self.root / 'external-command-ran'
        self.ninja = self.root / 'ninja'
        self.ninja.write_text('#!/bin/sh\n: > "' + str(self.marker) + '"\nexit 91\n')
        self.ninja.chmod(0o755)
        self.out = self.root / 'result'
        self.command = [sys.executable, str(runner), '--qemu-build', str(build),
                        '--runtime', str(self.root / 'staged'), '--swift-source', str(self.root),
                        '--output', str(self.out), '--ninja', str(self.ninja), '--sdk', str(self.root)]

    def run_runner(self, extra=()):
        return subprocess.run(self.command + list(extra), capture_output=True, text=True,
                              env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'}, timeout=15)

    def test_mismatched_native_is_rejected_before_any_command(self):
        self.native.write_bytes(self.native.read_bytes() + b'/* stale source */\n')
        result = self.run_runner()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists(), result.stderr)
        self.assertIn('native source does not match packaged patch', result.stderr)

    def test_corrupt_patch_is_rejected_before_any_command(self):
        self.patch.write_bytes(self.patch.read_bytes() + b'corrupt\n')
        result = self.run_runner()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists(), result.stderr)
        self.assertIn('patch SHA256SUMS mismatch', result.stderr)

    def test_valid_source_records_identity_before_and_after_command(self):
        result = self.run_runner()
        self.assertNotEqual(result.returncode, 0)  # deliberate ninja exit 91
        self.assertTrue(self.marker.exists(), result.stderr)
        before = json.loads((self.out / 'provenance-before.json').read_text())
        after = json.loads((self.out / 'provenance-after.json').read_text())
        want = hashlib.sha256(self.native.read_bytes()).hexdigest()
        self.assertEqual(before['native_sha256'], want)
        self.assertEqual(before['packaged_native_sha256'], want)
        self.assertEqual(after['native_sha256'], want)
        self.assertEqual(after['copied_native_sha256'], want)
        self.assertEqual(before['patch_sha256'], hashlib.sha256(self.patch.read_bytes()).hexdigest())

    def test_changed_copy_or_source_during_command_is_rejected(self):
        for target in (self.native, self.out / 'hw/usb/dev-host-hid.c'):
            with self.subTest(target=target):
                self.ninja.write_text('#!/bin/sh\nprintf "changed\\n" >> "' + str(target) + '"\nexit 91\n')
                result = self.run_runner()
                self.assertNotEqual(result.returncode, 0)
                after = json.loads((self.out / 'provenance-after.json').read_text())
                self.assertIn('does not match packaged patch', after['error'])
                shutil.rmtree(self.out)
                if target == self.native:
                    self.native.write_bytes(self.native.read_bytes().removesuffix(b'changed\n'))

    def test_missing_symlink_or_ambiguous_manifest_is_rejected(self):
        manifest = self.runtime / 'patches/SHA256SUMS'
        original = manifest.read_bytes()
        for mode in ('missing', 'symlink', 'duplicate'):
            with self.subTest(mode=mode):
                manifest.unlink()
                if mode == 'symlink':
                    manifest.symlink_to(RUNTIME / 'patches/SHA256SUMS')
                elif mode == 'duplicate':
                    entry = next(line for line in original.splitlines(keepends=True)
                                 if b'qemu-usb-host-hid.patch' in line)
                    manifest.write_bytes(original + entry)
                result = self.run_runner()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.marker.exists(), result.stderr)
                shutil.rmtree(self.out)
                manifest.unlink(missing_ok=True)
                manifest.write_bytes(original)

    def test_swift_compilation_is_explicitly_single_threaded(self):
        runner = (RUNTIME / 'Tests/hid-policy/run.py').read_text()
        self.assertIn("'-num-threads', '1', '-j', '1'", runner)

    def test_bad_cli_arguments_never_start_commands(self):
        for args in (['--variant', 'wrong'], ['--unknown'], ['--qemu-build']):
            with self.subTest(args=args):
                result = self.run_runner(args)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.marker.exists())
                self.assertFalse(self.out.exists())


if __name__ == '__main__':
    unittest.main()
