"""Real pipes and local path metadata, no native/root or external observers."""
import json,os,socket,sys,tempfile,unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'activation'))
from activation_evidence import ActivationEvents,socket_absent
class Evidence(unittest.TestCase):
 def parse(self,data,lease=0):
  rd,wr=os.pipe();f=os.fdopen(rd,'rb',buffering=0)
  try:
   os.write(wr,data);os.close(wr);wr=-1
   e=ActivationEvents(SimpleNamespace(stdout=f),lease=lease);e.drain();return e
  finally:
   f.close()
   if wr>=0:os.close(wr)
 def test_final_coalesced_events_preserve_exact_child_status(self):
  for code in (-1,0,1,23,124,137,143,255):
   e=self.parse((json.dumps({'activation':'started','lease':0})+'\n'+json.dumps({'helper':'postcheck'})+'\n'+json.dumps({'activation':'released','child_status':code})+'\n').encode())
   self.assertTrue(e.started and e.postcheck and e.released);self.assertEqual(e.child_status,code)
 def test_legacy_lease_events_share_release_parser(self):
  e=self.parse(b'{"activation":"started","lease":5}\n{"activation":"released","child_status":1}\n',lease=5)
  self.assertTrue(e.started and e.released)
 def test_missing_partial_invalid_duplicate_evidence_is_not_release(self):
  self.assertFalse(self.parse(b'').released)
  self.assertTrue(self.parse(b'{"activation":"released"').data)
  for body in (b'[]\n',b'{}\n',b'not-json\n',b'{"activation":"released","child_status":true}\n',b'{"activation":"released","child_status":256}\n',b'{"activation":"released","child_status":0}\n'*2):
   with self.assertRaises((ValueError,RuntimeError)):self.parse(body)
 def test_parse_failure_is_sticky(self):
  rd,wr=os.pipe()
  with os.fdopen(rd,'rb',buffering=0) as f:
   e=ActivationEvents(SimpleNamespace(stdout=f));os.write(wr,b'no\n');os.close(wr)
   with self.assertRaises(ValueError):e.drain()
   with self.assertRaises(RuntimeError):e.drain()
   self.assertTrue(e.failed)
 def test_unobservable_socket_is_not_absent(self):
  with mock.patch('activation_evidence.os.lstat',side_effect=PermissionError):self.assertFalse(socket_absent('fixture'))
  with mock.patch('activation_evidence.os.lstat',side_effect=FileNotFoundError):self.assertTrue(socket_absent('fixture'))
 def test_symlink_is_not_absent(self):
  with tempfile.TemporaryDirectory(dir='build') as tmp:
   path=Path(tmp)/'usb.sock';path.symlink_to('missing');self.assertFalse(socket_absent(path))
if __name__=='__main__':unittest.main()
