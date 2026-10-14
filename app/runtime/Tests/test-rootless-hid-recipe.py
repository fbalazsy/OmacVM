#!/usr/bin/env python3
"""Offline recipe checks; never run QEMU or access native HID APIs.

QEMU_SOURCE_ARCHIVE optionally checks application to the checksum-pinned archive.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tarfile
import tempfile
import unittest
import sys

RUNTIME = Path(__file__).resolve().parents[1]
PATCH = "qemu-usb-host-hid.patch"
PATCH_SHA = "b7f417bfbaea4c7b3fcf0477396f4a88536ceee06fb295c342a588f02ac400f5"
C_SHA = "991cbced2ea2cf82de03e59a63462c624239ac14dd4fbac51316600aca4d1002"
ARCHIVE_SHA = "7563781d7dec46f11509801e027f852597235d29ca7afa44a07ed9d8b108b8cd"
PIN = "c3d48b7d1e89604920e5b81b91140c2ad39a1943"


def sha(data):
    return hashlib.sha256(data).hexdigest()


class Recipe(unittest.TestCase):
    def ci_step(self, job, name):
        text = (RUNTIME.parents[1] / '.github/workflows/check.yml').read_text()
        jobs = re.split(r'^  ([\w-]+):\s*$', text.split('jobs:\n', 1)[1], flags=re.M)
        body = dict(zip(jobs[1::2], jobs[2::2]))[job]
        if job == 'check':
            self.assertNotRegex(body, r'(?m)^    (?:if|continue-on-error):')
        steps = re.split(r'^      - name: ', body, flags=re.M)[1:]
        matches = [step for step in steps if step.splitlines()[0] == name]
        self.assertEqual(len(matches), 1, 'missing/duplicate CI step: ' + name)
        step = matches[0]
        self.assertNotRegex(step, r'(?m)^        (?:if|continue-on-error):')
        return step, '\n'.join(line[10:] for line in step.split('        run: |\n', 1)[1].splitlines()
                               if line.startswith('          '))

    def test_unconditional_ci_runs_recipe_and_runner_tests(self):
        _, block = self.ci_step('check', 'Rootless HID recipe and runner (offline)')
        self.assertEqual(block, 'python3 app/runtime/Tests/test-rootless-hid-recipe.py -v\n'
                               'python3 app/runtime/Tests/test-hid-policy-runner.py -v')

    def test_unconditional_native_dispatch_ci(self):
        _, block = self.ci_step('check', 'Rootless HID native dispatch (no hardware)')
        self.assertEqual(block, 'python3 app/runtime/Tests/test-hid-native-dispatch.py '
                         '--output "$JOB_TMP/hid-native-dispatch"')

    def test_native_ci_uses_retained_build_and_propagates_failure(self):
        step, block = self.ci_step('app', 'Rootless HID shared corpus (fresh runtime only)')
        self.assertIn('        id: hid_policy\n', step)
        _, build = self.ci_step('app', 'OmacVM.app builds (build-app.sh, not a release)')
        self.assertIn('OMACVM_RUNTIME_KEEP_WORK=1 app/scripts/build-app.sh', build)
        workflow = (RUNTIME.parents[1] / '.github/workflows/check.yml').read_text()
        self.assertIn("if: ${{ !cancelled() && steps.hid_policy.outcome == 'success' }}", workflow)
        for mode in ('fresh', 'runner-exit1', 'cache', 'cleaned', 'not-retained'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                work = root / 'kept'
                qemu = work / 'source/qemu-fixture/build'
                qemu.mkdir(parents=True)
                (qemu / 'compile_commands.json').write_text('[]')
                ninja = work / 'tools/ninja-fixture.data/scripts/ninja'
                ninja.parent.mkdir(parents=True)
                ninja.touch()
                ninja.chmod(0o755)
                runner = root / 'app/runtime/Tests/hid-policy/run.py'
                runner.parent.mkdir(parents=True)
                # A call recorder, not native coverage. Real run.py is separately
                # opt-in below, against the actual pinned QEMU objects.
                runner.write_text('import json, os, pathlib, sys\n'
                                  'pathlib.Path("called.json").write_text(json.dumps(sys.argv[1:]))\n'
                                  'sys.exit(int(os.environ["FIXTURE_EXIT"]))\n')
                log = '[qemu-source-build] kept work dir: ' + str(work) + '\n'
                if mode == 'cache':
                    log = 'Runtime unchanged, reusing\n'
                elif mode == 'not-retained':
                    log = '[qemu-source-build] Building qemu-system-aarch64\n'
                elif mode == 'cleaned':
                    (qemu / 'compile_commands.json').unlink()
                (root / 'build.log').write_text(log)
                result = subprocess.run(['/bin/bash', '-e', '-o', 'pipefail', '-c', block],
                    cwd=root, capture_output=True, text=True,
                    env={**os.environ, 'JOB_TMP': tmp, 'SDKROOT': tmp,
                         'FIXTURE_EXIT': '1' if mode == 'runner-exit1' else '0'})
                self.assertEqual(result.returncode == 0, mode in ('fresh', 'cache'),
                                 result.stdout + result.stderr)
                called = root / 'called.json'
                self.assertEqual(called.exists(), mode in ('fresh', 'runner-exit1'))
                if called.exists():
                    args = json.loads(called.read_text())
                    self.assertEqual(args, ['--qemu-build', str(qemu), '--ninja', str(ninja),
                        '--runtime', 'app/runtime/.build/qemu-gpu-runtime',
                        '--swift-source', 'app/app/Sources/OmacVMUSB',
                        '--output', str(root / 'hid-policy'), '--sdk', tmp])
                if mode == 'cache':
                    self.assertIn('SKIP', result.stdout)

    def test_shared_admission_corpus(self):
        """Opt-in compile gate; missing build inputs are an explicit skip, not PASS."""
        if not os.environ.get("HID_POLICY_QEMU_BUILD"):
            self.skipTest("set HID_POLICY_QEMU_BUILD/RUNTIME/SWIFT_SOURCE/NINJA and SDKROOT for the compiled corpus")
        with tempfile.TemporaryDirectory() as tmp:
            command = [sys.executable, str(RUNTIME / "Tests/hid-policy/run.py"),
                       "--output", str(Path(tmp) / "result"), "--sdk", os.environ["SDKROOT"]]
            for option in ("qemu-build", "runtime", "swift-source", "ninja"):
                command += ["--" + option, os.environ["HID_POLICY_" + option.upper().replace("-", "_")]]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_exact_reviewed_patch_is_verified_and_applied(self):
        recipe = (RUNTIME / "build-qemu-gpu-runtime.sh").read_text()
        patch = RUNTIME / "patches" / PATCH
        self.assertTrue(patch.is_file(), "reviewed rootless HID patch is absent")
        self.assertEqual(sha(patch.read_bytes()), PATCH_SHA)
        manifest = (RUNTIME / "patches/SHA256SUMS").read_text().splitlines()
        self.assertEqual([line for line in manifest if line.endswith("  " + PATCH)],
                         [PATCH_SHA + "  " + PATCH])
        self.assertIn("qemu_commit=" + PIN, recipe)
        self.assertIn('usb_hid_patch="$native_dir/patches/' + PATCH + '"', recipe)
        self.assertIn("usb_hid_patch_sha256=" + PATCH_SHA, recipe)
        check = 'verify_file_sha "Rootless USB HID patch" "$usb_hid_patch" "$usb_hid_patch_sha256"'
        apply = 'patch -d "$source_dir" -p1 -f -i "$usb_hid_patch"'
        self.assertIn(check, recipe)
        self.assertEqual(recipe.count(apply), 1)
        self.assertLess(recipe.index(check), recipe.index(apply))
        self.assertLess(recipe.index(apply), recipe.index('../configure'))

    def test_patch_application_and_bad_inputs(self):
        recipe = (RUNTIME / "build-qemu-gpu-runtime.sh").read_text()
        patch_path = RUNTIME / "patches" / PATCH
        self.assertTrue(patch_path.is_file(), "reviewed rootless HID patch is absent")
        patch_bytes = patch_path.read_bytes()
        functions = "\n".join(re.findall(
            r"^(?:die|verify_file_sha)\(\) \{.*?^\}", recipe, re.M | re.S))
        lines = recipe.replace("\\\n", " ").splitlines()
        commands = "\n".join(line for line in lines if "$usb_hid_patch" in line
                             or line.startswith("usb_hid_patch"))
        archive = os.environ.get("QEMU_SOURCE_ARCHIVE")
        if archive:
            self.assertEqual(sha(Path(archive).read_bytes()), ARCHIVE_SHA)
            with tarfile.open(archive, "r:gz") as src:
                member = src.extractfile("qemu-" + PIN + "/hw/usb/meson.build")
                assert member is not None
                meson = member.read()
        else:
            # Only the unchanged context of the one modified file; all other
            # files are additions. The archive mode checks the real pinned base.
            hunk = patch_bytes.decode().split("+++ b/hw/usb/meson.build\n", 1)[1]
            hunk = hunk.split("--- /dev/null", 1)[0]
            meson = ("\n" * 80 + "\n".join(line[1:] for line in hunk.splitlines()
                                if line.startswith(" ")) + "\n").encode()
        for mode in ("valid", "missing", "corrupt", "symlink"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / "patches").mkdir()
                source = root / "source"
                (source / "hw/usb").mkdir(parents=True)
                (source / "tests/unit").mkdir(parents=True)
                (source / "hw/usb/meson.build").write_bytes(meson)
                patch = root / "patches" / PATCH
                if mode == "symlink":
                    patch.symlink_to(RUNTIME / "patches" / PATCH)
                elif mode != "missing":
                    patch.write_bytes(patch_bytes + (b"corrupted\n" if mode == "corrupt" else b""))
                shell = "set -eu\n" + functions + "\n"
                shell += "native_dir=" + shlex.quote(str(root)) + "\n"
                shell += "source_dir=" + shlex.quote(str(source)) + "\n" + commands
                result = subprocess.run(["/bin/bash", "-c", shell],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, mode == "valid", result.stdout + result.stderr)
                output = source / "hw/usb/dev-host-hid.c"
                if mode == "valid":
                    self.assertEqual(sha(output.read_bytes()), C_SHA)
                else:
                    self.assertFalse(output.exists(), "bad input reached patch application")

    def test_packaging_rejects_missing_hid_capability(self):
        prepare = (RUNTIME / "prepare-qemu-gpu-runtime.sh").read_text()
        match = re.search(r"  for device in \\\n.*?^  done$", prepare, re.M | re.S)
        assert match is not None
        gate = match.group(0)
        names = re.findall(r"'name \"([^\"]+)\"'", gate)
        self.assertIn("usb-host-hid", names)
        for present in (False, True):
            device_help = "\n".join('name "' + n + '"' for n in names
                                    if present or n != "usb-host-hid")
            result = subprocess.run(["/bin/bash", "-c", "set -eu\n"
                'die() { printf "%s\\n" "$*" >&2; exit 1; }\n'
                + "device_help=" + shlex.quote(device_help) + "\n" + gate],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0 if present else 1, result.stderr)


if __name__ == "__main__":
    unittest.main()
