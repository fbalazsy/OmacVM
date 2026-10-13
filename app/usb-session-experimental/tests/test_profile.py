"""Build-time policy has no runtime authority/configuration fallback."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ProfileTests(unittest.TestCase):
    def test_profile_compiler_required_and_fixture_is_explicit(self):
        self.assertTrue((ROOT / 'profile.py').is_file(), 'missing build-time profile compiler')
        spec = importlib.util.spec_from_file_location('profile', ROOT / 'profile.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        p = json.loads((ROOT / 'profiles/fixture.json').read_text())
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            module.generate(p, out)
            h = (out / 'local_pins.h').read_text()
            self.assertIn('#define PROFILE_FIXTURE 1', h)
            self.assertIn('#define PROFILE_UID 4242', h)
            self.assertNotIn('getenv', h)
            self.assertNotIn('HELPER_SHA', h)  # derived from built helper, never input authority

    def test_duplicate_pinned_drive_is_rejected_before_build(self):
        spec = importlib.util.spec_from_file_location('profile', ROOT / 'profile.py')
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        p = json.loads((ROOT / 'profiles/fixture.json').read_text())
        p['argv'] += ['-drive', p['disk_arg']]
        with self.assertRaisesRegex(ValueError, 'disk argv mismatch'):
            module.validate(p)

    def test_delete_control_character_rejected_before_generation(self):
        spec = importlib.util.spec_from_file_location('profile', ROOT / 'profile.py')
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        for field in ('argv', 'serial'):
            with self.subTest(field=field):
                p = json.loads((ROOT / 'profiles/fixture.json').read_text())
                if field == 'argv':p['argv'] += ['-unknown', 'value' + chr(127)]
                else:p[field] += chr(127)
                with self.assertRaises(ValueError):module.validate(p)

    def test_fixture_cannot_generate_install_plan(self):
        self.assertTrue((ROOT/'install_plan.py').is_file(), 'missing bounded installer generator')
        spec = importlib.util.spec_from_file_location('install_plan', ROOT/'install_plan.py')
        module = importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        p = json.loads((ROOT/'profiles/fixture.json').read_text())
        with self.assertRaises(ValueError):module.render(p, Path('helper'), Path('activate'))

    def test_no_discovery_or_stale_controller_socket_adoption(self):
        source = (ROOT / 'activation/baldur_session.py').read_text()
        self.assertNotIn("'/bin/ps'", source)
        self.assertNotIn('only user controller socket', source)
        self.assertIn("parser.add_argument('--pid'", source)

    def test_native_argv_rejects_unreviewed_extra_arguments(self):
        source = (ROOT / 'activation/native_platform.c').read_text()
        self.assertIn('PROFILE_ARGV', source)

if __name__ == '__main__':
    unittest.main()
