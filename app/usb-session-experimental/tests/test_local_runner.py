import sys, unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'activation'))
try: import baldur_session as s
except ImportError: s=None
class SessionTests(unittest.TestCase):
 def test_ioreg_empty_success_is_absent_and_failed_scan_unknown(self):
  from unittest import mock
  from types import SimpleNamespace
  import subprocess
  for output,expected in [(b'','absent'),(b'not a plist','unknown'),(b'<?xml version="1.0"?><plist><array>','unknown')]:
   with mock.patch.object(s.subprocess,'run',return_value=SimpleNamespace(stdout=output)):
    self.assertEqual(s.device_mode(),expected)
  for error in [subprocess.CalledProcessError(1,['ioreg']),subprocess.TimeoutExpired(['ioreg'],5)]:
   with mock.patch.object(s.subprocess,'run',side_effect=error):
    self.assertEqual(s.device_mode(),'unknown')
 def test_observer_identity_ambiguity_is_unknown_not_live_cancellation(self):
  from unittest import mock
  from types import SimpleNamespace
  import plistlib
  for tree in ['not a device tree',[{'idVendor':0x1209,'idProduct':0xffff,'USB Serial Number':'WRONG','locationID':s.LOCATION}]]:
   with mock.patch.object(s.subprocess,'run',return_value=SimpleNamespace(stdout=plistlib.dumps(tree))):
    self.assertEqual(s.device_mode(),'unknown')
 def test_mode_reconnect_requires_observed_removal(self):
  self.assertIsNotNone(s,'persistent local runner is missing')
  self.assertFalse(s.reconnect_allowed(False,True,'bootloader',False))
  self.assertFalse(s.reconnect_allowed(True,False,'bootloader',False))
  self.assertTrue(s.reconnect_allowed(True,True,'bootloader',False))
  self.assertFalse(s.reconnect_allowed(True,True,'bootloader',True))
 def test_readiness_matches_real_qemu11_schema(self):
  class Owned:
   device='d';char='c'
   def devices(self):return {'d'}
   def chars(self):return {'c'}
  attached=True;opened=False
  def call(op,args=None):
   if op=='query-chardev':return [{'label':'foreign','frontend-open':True},{'label':'c','frontend-open':opened}]
   self.assertEqual(op,'qom-get')
   self.assertEqual(args,{'path':'/machine/peripheral/d','property':'attached'})
   return attached
  self.assertFalse(s.Controller.qom_connected(None,call,Owned()))
  opened=True
  self.assertTrue(s.Controller.qom_connected(None,call,Owned()))
  attached=False
  self.assertFalse(s.Controller.qom_connected(None,call,Owned()))
 def test_source_pin_restart_preserves_unconfirmed_journal(self):
  from tempfile import TemporaryDirectory
  import json
  with TemporaryDirectory(dir='build') as d:
   p=Path(d);s.atomic_json(p/'state.json',{'root_pending':True,'device_id':'unconfirmed-owned'})
   controller=s.Controller(p)
   self.assertEqual(controller.run(),1)
   state=json.loads((p/'state.json').read_text())
   self.assertTrue(state.get('root_pending'),'restart must not clear a quarantine journal')
   self.assertEqual(state.get('device_id'),'unconfirmed-owned')
 def test_status_never_reports_stale_connection(self):
  self.assertTrue(hasattr(s,'read_status'),'truthful CLI status missing')
  from tempfile import TemporaryDirectory
  with TemporaryDirectory(dir='build') as d:
   p=Path(d);s.atomic_json(p/'state.json',{'connected':True,'root_pending':True,'status':'connected'})
   value=s.read_status(p)
   self.assertFalse(value['connected']);self.assertFalse(value['controller_running'])
   self.assertEqual(value['status'],'unconfirmed-stale-controller')
 def test_exact_mode_classification_and_wrong_device(self):
  def device(vid,pid,serial,location=s.LOCATION):return {'idVendor':vid,'idProduct':pid,'USB Serial Number':serial,'locationID':location}
  boot=device(0x1209,0xffff,'SYNTHETIC-ONLY');app=device(0x1209,0xfffe,'SYNTHETIC-APP')
  self.assertEqual(s.classify_devices([boot]),'bootloader');self.assertEqual(s.classify_devices([app]),'application')
  self.assertEqual(s.classify_devices([]),'absent')
  for tree in ([boot,boot],[device(0x1209,0xffff,'OTHER')],[device(0x1209,0xfffe,'SYNTHETIC-APP',1)]):
   with self.assertRaises(RuntimeError):s.classify_devices(tree)
 def test_discover_requires_explicit_pid_and_native_identity(self):
  calls=[]
  def inspect(pid):calls.append(pid);return {'pid':pid}
  self.assertEqual(s.discover(42,inspect),{'pid':42});self.assertEqual(calls,[42])
  for bad in (None,True,0,-1,2147483648):
   with self.assertRaises(RuntimeError):s.discover(bad,inspect)
  def deny(pid):raise RuntimeError('wrong pinned argv/hash')
  with self.assertRaisesRegex(RuntimeError,'wrong pinned'):s.discover(42,deny)
 def test_preexisting_control_socket_is_never_unlinked(self):
  import socket
  from tempfile import TemporaryDirectory
  with TemporaryDirectory(dir='build') as d:
   p=Path(d);listener=socket.socket(socket.AF_UNIX);listener.bind(str(p/'control.sock'))
   try:
    self.assertEqual(s.Controller(p).run(),1)
    self.assertTrue((p/'control.sock').exists())
   finally:listener.close()
 def test_replaced_controller_socket_survives_finally(self):
  import socket
  from tempfile import TemporaryDirectory
  from unittest import mock
  with TemporaryDirectory(dir='build') as d:
   p=Path(d);other=socket.socket(socket.AF_UNIX)
   def swap():
    (p/'control.sock').rename(p/'original.sock')
    other.bind(str(p/'control.sock'))
    raise RuntimeError('fixture replacement')
   try:
    with mock.patch.object(s,'verify_build',swap),mock.patch.object(s.signal,'signal'):
     self.assertEqual(s.Controller(p).run(),1)
    self.assertTrue((p/'control.sock').exists())
   finally:other.close()
 def test_shared_qmp_uses_fresh_short_connection_each_call(self):
  from test_qmp import MemorySocket,ID
  from baldur_lease import QMP
  sockets=[]
  def connector(path):
   sock=MemorySocket();sockets.append(sock);return sock
  call=QMP(ID,connector=connector,run=lambda *a,**k:None)
  for _ in range(3):self.assertEqual(call('query-name'),{'name':'OmacVM Fixture'})
  self.assertEqual(len(sockets),3);self.assertTrue(all(sock.closed for sock in sockets))
if __name__=='__main__':unittest.main()
