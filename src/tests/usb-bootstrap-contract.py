"""Exercise generated bootstrap predicates on inert ordinary-user fixtures only.
Never executes the root bootstrap, authorization, session, USB or QMP.
"""
from pathlib import Path
import hashlib
import os
import pwd
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SWIFT = '''import Foundation
public struct USBProcessIdentity { var valid: Bool { true }; let uid: UInt32 = 501; let pid = 42; let startSec = 12; let startUsec = 34; let version = 56 }
enum USBNativeWire { static let root = "/Library/PrivilegedHelperTools/org.omacvm.usb" }
struct USBNativeError: Error { init(_ message: String) {} }
print(try USBHelperInstall.command(source: "/unused/helper", sha256: String(repeating: "a", count: 64), attempt: UUID(), app: USBProcessIdentity()))
'''

class BootstrapContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        assert os.getuid() != 0
        cls.temp = tempfile.TemporaryDirectory(prefix='usb-bootstrap-')
        cls.directory = Path(cls.temp.name)
        (cls.directory / 'main.swift').write_text(SWIFT)
        command = ['xcrun', 'swiftc', '-swift-version', '5']
        if os.environ.get('SDKROOT'): command += ['-sdk', os.environ['SDKROOT']]
        command += [str(ROOT / 'app/app/Sources/OmacVMUSB/USBHelperInstall.swift'), str(cls.directory / 'main.swift'), '-o', str(cls.directory / 'generate')]
        subprocess.run(command, check=True)
        cls.generated = subprocess.check_output([str(cls.directory / 'generate')], text=True)
        cls.functions = cls.generated.split('protected_dir /Library', 1)[0]
        # Only root ownership is adapted to our own UID; keep actual shell predicates.
        cls.functions = cls.functions.replace('" = 0 ]', '" = ' + str(os.getuid()) + ' ]')


    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()

    def predicate(self, directory):
        return subprocess.run(['/bin/sh', '-c', self.functions + '\nprotected_dir ' + shlex.quote(str(directory))], capture_output=True, text=True).returncode

    def test_allow_acl_rejected_deny_acl_accepted(self):
        directory = self.directory / 'acl'
        directory.mkdir(mode=0o755)
        self.assertEqual(self.predicate(directory), 0, 'plain protected directory accepted')
        subprocess.run(['/bin/chmod', '+a', f'user:{pwd.getpwuid(os.getuid()).pw_name} allow write,append,delete_child', str(directory)], check=True)
        try:
            self.assertNotEqual(self.predicate(directory), 0, 'ALLOW ACL refused BEFORE hash/root exec')
        finally: subprocess.run(['/bin/chmod', '-N', str(directory)], check=True)
        subprocess.run(['/bin/chmod', '+a', 'everyone deny delete', str(directory)], check=True)
        try: self.assertEqual(self.predicate(directory), 0, 'native-compatible DENY ACL accepted')
        finally: subprocess.run(['/bin/chmod', '-N', str(directory)], check=True)

    def leaf_fixture(self, acl=None, inherited=False):
        directory = Path(tempfile.mkdtemp(prefix='leaf-', dir=self.directory))
        if inherited:
            assert acl is not None
            subprocess.run(['/bin/chmod', '+a', acl + ',file_inherit,only_inherit', str(directory)], check=True)
            self.addCleanup(subprocess.run, ['/bin/chmod', '-N', str(directory)], check=True)
        payload = directory / 'inert-text-only'
        payload.write_bytes(b'GOOD inert text, never executed\n')
        payload.chmod(0o555)
        self.addCleanup(subprocess.run, ['/bin/chmod', '-N', str(payload)], check=True)
        if acl and not inherited:
            subprocess.run(['/bin/chmod', '+a', acl, str(payload)], check=True)
        return payload

    def leaf_validation(self, payload, digest=None):
        # Execute ONLY the production leaf validation, never its exec or install.
        # Remap root UID and expected digest; retain the actual ACL/hash predicates.
        fragment = self.generated[self.generated.index('[ ! -L "$executable" ]'):self.generated.index('\nexec ')]
        fragment = fragment.replace(' = 0:555 ]', f' = {os.getuid()}:555 ]')
        fragment = fragment.replace('a' * 64, digest or hashlib.sha256(payload.read_bytes()).hexdigest())
        script = self.functions + '\nexecutable=' + shlex.quote(str(payload)) + '\n' + fragment
        return subprocess.run(['/bin/sh', '-x', '-c', script], capture_output=True, text=True)

    def assert_leaf_refused_unchanged(self, payload, result, acl_before):
        self.assertEqual(result.returncode, 73, 'unsafe leaf must be refused BEFORE chmod/hash/exec')
        self.assertNotIn('+ /bin/chmod ', result.stderr, 'do not rehabilitate unsafe inode in place')
        self.assertNotIn('/usr/bin/shasum ', result.stderr, 'refuse before trusting its hash')
        self.assertEqual(subprocess.check_output(['/bin/ls', '-le', str(payload)], text=True), acl_before)
        self.assertEqual(payload.stat().st_mode & 0o7777, 0o555)
        self.assertEqual(payload.read_bytes(), b'GOOD inert text, never executed\n')

    def test_leaf_allow_acls_refused_before_mutation_or_hash(self):
        user = pwd.getpwuid(os.getuid()).pw_name
        for inherited, mixed in [(False, False), (True, False), (False, True)]:
            with self.subTest(inherited=inherited, mixed=mixed):
                payload = self.leaf_fixture(f'user:{user} allow write', inherited=inherited)
                if mixed:
                    subprocess.run(['/bin/chmod', '+a', 'everyone deny delete', str(payload)], check=True)
                acl_before = subprocess.check_output(['/bin/ls', '-le', str(payload)], text=True)
                self.assertIn('inherited allow write' if inherited else 'allow write', acl_before)
                if mixed: self.assertIn('deny delete', acl_before)
                self.assert_leaf_refused_unchanged(payload, self.leaf_validation(payload), acl_before)

    def test_leaf_retained_writable_fd_is_not_rehabilitated(self):
        user = pwd.getpwuid(os.getuid()).pw_name
        # Negative control: real Darwin ACL removal does not revoke an open FD.
        control = self.leaf_fixture(f'user:{user} allow write')
        fd = os.open(control, os.O_WRONLY)
        try:
            subprocess.run(['/bin/chmod', '-N', str(control)], check=True)
            self.assertNotIn('allow write', subprocess.check_output(['/bin/ls', '-le', str(control)], text=True))
            self.assertEqual(control.stat().st_mode & 0o7777, 0o555)
            with self.assertRaises(PermissionError): os.open(control, os.O_WRONLY)
            os.pwrite(fd, b'EDIT', 0)
            self.assertTrue(control.read_bytes().startswith(b'EDIT'), 'held FD survives chmod -N')
        finally: os.close(fd)

        payload = self.leaf_fixture(f'user:{user} allow write')
        acl_before = subprocess.check_output(['/bin/ls', '-le', str(payload)], text=True)
        fd = os.open(payload, os.O_WRONLY)
        try:
            result = self.leaf_validation(payload)
            self.assert_leaf_refused_unchanged(payload, result, acl_before)
            # Rejection is required even though the descriptor still can mutate
            # the rejected inode. No executable bytes are installed or launched.
            os.pwrite(fd, b'EDIT', 0)
            self.assertTrue(payload.read_bytes().startswith(b'EDIT'))
        finally: os.close(fd)

    def test_leaf_clean_and_deny_only_compatibility(self):
        for acl, inherited in [(None, False), ('everyone deny delete', False), ('everyone deny delete', True)]:
            with self.subTest(acl=acl, inherited=inherited):
                payload = self.leaf_fixture(acl, inherited=inherited)
                if acl:
                    before = subprocess.check_output(['/bin/ls', '-le', str(payload)], text=True)
                    self.assertIn('inherited deny delete' if inherited else 'deny delete', before)
                result = self.leaf_validation(payload)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('/usr/bin/shasum -a 256', result.stderr)
                self.assertEqual(payload.read_bytes(), b'GOOD inert text, never executed\n')
                self.assertEqual(payload.stat().st_mode & 0o7777, 0o555)

    def test_leaf_existing_mode_link_and_digest_checks_preserved(self):
        payload = self.leaf_fixture()
        self.assertEqual(self.leaf_validation(payload, digest='0' * 64).returncode, 74)
        payload.chmod(0o755)
        self.assertEqual(self.leaf_validation(payload).returncode, 73)
        payload.chmod(0o555)
        link = payload.with_name('link')
        link.symlink_to(payload)
        self.assertEqual(self.leaf_validation(link).returncode, 73)

    def test_actual_generated_install_mode_matches_native(self):
        # Execute ONLY directory creation block, remapped to our own fixture; no
        # hash, install of executable, root ownership, authorization or exec.
        block = self.generated.split('for d in ', 1)[1].split('\nrelease=', 1)[0]
        block = 'for d in ' + block
        root = self.directory / 'install'
        block = block.replace('/Library/PrivilegedHelperTools/org.omacvm.usb', str(root))
        block = block.replace('-o root -g wheel ', '')
        subprocess.run(['/bin/sh', '-c', self.functions + '\n' + block], check=True)
        native = (ROOT / 'app/usb-helper/session.m').read_text()
        self.assertIn('(runstat.st_mode&07777)!=0711', native, 'native ABI has not silently changed')
        self.assertEqual((root / 'run').stat().st_mode & 0o7777, 0o711, 'actual installer output satisfies native session mode gate')

if __name__ == '__main__': unittest.main(verbosity=2)
