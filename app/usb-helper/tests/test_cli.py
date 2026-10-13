#!/usr/bin/env python3
"""Ordinary-user process tests; never starts a privileged session or USB."""
import json, os, pathlib, subprocess, unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(os.environ.get('OMACVM_TEST_HELPER', ROOT / 'build/omacvm-usb-helper'))
class InspectTests(unittest.TestCase):
    def test_inspect_current_process(self):
        self.assertTrue(BIN.is_file(), 'native inspect-process implementation missing')
        p = subprocess.run([str(BIN), '--inspect-process', str(os.getpid())], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        d = json.loads(p.stdout)
        self.assertEqual(set(d), {'schema','pid','uid','start_sec','start_usec','version'})
        self.assertEqual((d['schema'],d['pid'],d['uid']), (1,os.getpid(),os.getuid()))
        self.assertGreater(d['start_sec'],0)
        self.assertGreaterEqual(d['start_usec'],0)
        self.assertLess(d['start_usec'],1000000)
        self.assertGreater(d['version'],0)
        q = subprocess.run([str(BIN), '--inspect-process', str(os.getpid())], capture_output=True,text=True)
        self.assertEqual(json.loads(q.stdout), d)
    def test_session_never_elevates_ordinary_user(self):
        p = subprocess.run([str(BIN),'--inspect-process',str(os.getpid())],capture_output=True,text=True)
        d = json.loads(p.stdout)
        args = ['01234567-89ab-cdef-0123-456789abcdef',str(os.getuid()),str(d['pid']),str(d['start_sec']),str(d['start_usec']),str(d['version'])]
        for command in ['--session','--worker']:
            q = subprocess.run([str(BIN),command,*args],capture_output=True,text=True)
            self.assertEqual(q.returncode,77,q.stderr)
            self.assertEqual(q.stdout,'')
    def test_invalid_pid(self):
        self.assertTrue(BIN.is_file(), 'native inspect-process implementation missing')
        for s in ['0','-1','01','1x','2147483648','']:
            p = subprocess.run([str(BIN),'--inspect-process',s],capture_output=True)
            self.assertNotEqual(p.returncode,0,s)
            self.assertEqual(p.stdout,b'')
if __name__ == '__main__': unittest.main(verbosity=2)
