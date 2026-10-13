"""Offline regression for the USBredir recipe's CI wiring (stdlib only).

No build, downloads, QEMU or hardware. Like src/tests/ci-app-build.sh, read
this workflow's indentation rather than requiring PyYAML on macOS's Python.
Run with python3 app/runtime/Tests/usbredir/test-ci.py.
"""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[4]


class CIWiring(unittest.TestCase):
    def test_check_job_runs_offline_recipe_and_wiring_tests(self):
        workflow = (ROOT / ".github/workflows/check.yml").read_text()
        jobs = re.split(r"^  ([A-Za-z0-9_-]+):\s*$", workflow.split("\njobs:\n", 1)[1],
                        flags=re.M)
        check = dict(zip(jobs[1::2], jobs[2::2]))["check"]
        # A step only in the app job would skip forks and manual runs.
        self.assertNotRegex(check, r"(?m)^    if:")
        expected = [
            "python3 app/runtime/Tests/usbredir/test-ci.py",
            "python3 app/runtime/Tests/usbredir/test-runtime.py",
        ]
        steps = re.split(r"(?m)^      - ", check)[1:]
        matching = [step for step in steps
                    if re.search(r"(?m)^          " + re.escape(expected[1]) + r"$", step)]
        self.assertEqual(len(matching), 1, "check must run the offline USBredir recipe suite once")
        # Keep this small offline step unconditional, fail-fast and at repo root.
        # Exact executable lines reject commented-out commands, || true, a
        # capability probe against a stale binary, and accidental build calls.
        lines = [line for line in matching[0].splitlines()[1:]
                 if line.strip() and not line.lstrip().startswith("#")]
        self.assertEqual(lines, ["        run: |"] + ["          " + cmd for cmd in expected])

    def test_check_job_builds_fixture_and_runs_native_session_tests(self):
        workflow = (ROOT / ".github/workflows/check.yml").read_text()
        jobs = re.split(r"^  ([A-Za-z0-9_-]+):\s*$", workflow.split("\njobs:\n", 1)[1],
                        flags=re.M)
        check = dict(zip(jobs[1::2], jobs[2::2]))["check"]
        steps = re.split(r"(?m)^      - ", check)[1:]
        matching = [step for step in steps
                    if step.startswith("name: USB session fixture (no root, USB or VM)\n")]
        self.assertEqual(len(matching), 1, "the helper must be tested, not just syntax-checked")
        lines = [line for line in matching[0].splitlines()[1:]
                 if line.strip() and not line.lstrip().startswith("#")]
        self.assertEqual(lines, [
            "        timeout-minutes: 10",
            "        run: |",
            '          python3 -B app/usb-session-experimental/build.py --profile app/usb-session-experimental/profiles/fixture.json --out "$JOB_TMP/usb" --cache "$JOB_TMP/usb-cache" --download',
            '          python3 -B "$JOB_TMP/usb/source/test.py"',
        ])


if __name__ == "__main__":
    unittest.main(verbosity=2)
