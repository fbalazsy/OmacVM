#!/usr/bin/env python3
"""Fail closed if normal-build coexistence activation or its checksum drifts."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
RUNTIME = HERE.parents[1]
spec = importlib.util.spec_from_file_location('coexistence_verify', HERE / 'verify-finish.py')
assert spec and spec.loader
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)
EXPECTED = json.loads((HERE / 'inputs.json').read_text())['patch_sha256']


class RecipeTests(unittest.TestCase):
    def check_variant(self, old, new):
        with tempfile.TemporaryDirectory(prefix='omacvm-usb-recipe-') as work:
            dest = Path(work)
            (dest / 'patches').mkdir()
            recipe = (RUNTIME / 'build-qemu-gpu-runtime.sh').read_text()
            assert old in recipe
            (dest / 'build-qemu-gpu-runtime.sh').write_text(recipe.replace(old, new, 1))
            (dest / 'patches/SHA256SUMS').write_bytes((RUNTIME / 'patches/SHA256SUMS').read_bytes())
            with self.assertRaises((AssertionError, ValueError)):
                verify.recipe_block(dest, EXPECTED)

    def test_normal(self):
        verify.recipe_block(RUNTIME, EXPECTED)
        self.assertEqual(hashlib.sha256((RUNTIME / 'patches/qemu-usb-session-accounting.patch').read_bytes()).hexdigest(), EXPECTED)

    def test_inactive_patch(self):
        line = 'patch -d "$source_dir" -p1 -f -i "$usb_coexistence_patch"'
        self.check_variant(line, '# ' + line)

    def test_ignored_failure(self):
        line = 'patch -d "$source_dir" -p1 -f -i "$usb_coexistence_patch"'
        self.check_variant(line, line + ' || true')

    def test_wrong_order(self):
        self.check_variant('patch -d "$source_dir" -p1 -f -i "$usb_hid_patch"',
                           'patch -d "$source_dir" -p1 -f -i "$usb_coexistence_patch"')

    def test_wrong_checksum(self):
        self.check_variant('usb_coexistence_patch_sha256=' + EXPECTED,
                           'usb_coexistence_patch_sha256=' + '0' * 64)


if __name__ == '__main__':
    unittest.main()
