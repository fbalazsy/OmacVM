"""Build setup respects the caller's temp policy; no compiler or USB access."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('usb_helper_build', Path(__file__).resolve().parents[1] / 'build.py')
assert SPEC is not None and SPEC.loader is not None
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


class BuildEnvironment(unittest.TestCase):
    def test_temp_environment_is_not_replaced(self):
        # Stop at tool discovery, before any archive or compiler is used.
        class StopDiscovery(Exception):
            pass
        with tempfile.TemporaryDirectory(prefix='usb-build-environment-') as directory:
            for value in (None, directory):
                with self.subTest(tmpdir=value), mock.patch.dict(os.environ):
                    if value is None:
                        os.environ.pop('TMPDIR', None)
                    else:
                        os.environ['TMPDIR'] = value
                    with mock.patch.object(BUILD.subprocess, 'check_output', side_effect=StopDiscovery):
                        with self.assertRaises(StopDiscovery):
                            BUILD.build(['--out', str(Path(directory) / 'out'), '--cache', str(Path(directory) / 'cache')])
                    self.assertEqual(os.environ.get('TMPDIR'), value)


if __name__ == '__main__':
    unittest.main(verbosity=2)
