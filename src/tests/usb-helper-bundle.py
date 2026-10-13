"""Bundle wiring checks, no VM, root, USB or network."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]

class USBHelperBundle(unittest.TestCase):
    def test_native_payload_built_staged_and_signed_in_both_modes(self):
        text = (ROOT / 'app/scripts/build-app.sh').read_text()
        build = 'python3 "$ROOT/usb-helper/build.py" --out "$ROOT/.build/usb-helper"'
        stage = 'install -m755 "$ROOT/.build/usb-helper/omacvm-usb-helper" "$USB_HELPER"'
        self.assertIn(build, text)
        self.assertIn('USB_HELPER=$C/Library/LaunchServices/omacvm-usb-helper', text)
        self.assertIn(stage, text)
        self.assertLess(text.index(build), text.index(stage))
        signing = text[text.index('if [[ -n ${OMACVM_SIGN_ID:-} ]]; then'):]
        developer, adhoc = signing.split('\nelse\n', 1)
        self.assertIn('codesign "${SIGN[@]}" --identifier org.omacvm.usb-helper "$USB_HELPER"', developer)
        self.assertIn('codesign --force --sign - --options runtime --identifier org.omacvm.usb-helper "$USB_HELPER"', adhoc)
        self.assertNotRegex(text, r'sudo.*usb-helper')

    def test_lgpl_relink_materials_are_bundled(self):
        text = (ROOT / 'app/scripts/build-app.sh').read_text()
        self.assertIn('ditto "$ROOT/.build/usb-helper/relink" "$C/Resources/licenses/usb-helper-relink"', text)

    def test_native_build_and_tests_run_in_fork_safe_check_job(self):
        text = (ROOT / '.github/workflows/check.yml').read_text()
        check = text.split('  check:\n', 1)[1].split('\n  app:', 1)[0]
        self.assertIn('python3 app/usb-helper/test.py', check)
        self.assertIn('python3 app/usb-helper/build.py --out', check)
        self.assertLess(check.index('python3 app/usb-helper/build.py --out'), check.index('python3 app/usb-helper/test.py'))
        self.assertIn('python3 app/usb-helper/test.py --out "$RUNNER_TEMP/usb-helper-tests" --cache "$RUNNER_TEMP/usb-helper-cache"', check)
        self.assertIn('swift run usb-tests --offline', check)

if __name__ == '__main__':
    unittest.main(verbosity=2)
