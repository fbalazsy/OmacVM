"""Offline user controller exercising actual QMP ledger and real dummy children."""
import json, os, subprocess, sys, tempfile, threading, time, unittest
from pathlib import Path
from unittest import mock
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'activation'))
import baldur_session as s
from baldur_lease import QMPAmbiguous, QMPRejected
REAL_POPEN=subprocess.Popen
ID={'pid':42,'sec':5,'usec':1,'version':7,'qmp':s.QMP_PATH}
class DummyQMP:
 def __init__(self,identity):self.chars=set();self.devices=set();self.calls=[];self.child=None;self.unknown=False
 def __call__(self,op,args=None):
  self.calls.append(op)
  if op=='query-name':return {'name':'OmacVM Fixture'}
  if op=='query-chardev':return [{'label':x,'frontend-open':True} for x in self.chars]
  if op=='qom-list':return [{'name':x} for x in self.devices]
  if op=='qom-get':return True
  if op=='chardev-add':self.chars.add(args['id'])
  elif op=='device_add':
   self.devices.add(args['id'])
   if self.unknown:raise QMPAmbiguous('accepted then lost reply')
  elif op=='device_del':
   assert self.child.poll() is not None,'QMP must not detach before root supervisor ends'
   self.devices.remove(args['id'])
  elif op=='chardev-remove':self.chars.remove(args['id'])
  else:raise AssertionError(op)
  return {}
class ControllerFixture(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(dir='build')
  self.path=Path(self.temp.name);self.c=s.Controller(self.path);self.q=DummyQMP(ID);self.count=0;self.authorizations=[]
 def tearDown(self):
  if self.q.child and self.q.child.poll() is None:
   self.q.child.stdin.close();self.q.child.wait(timeout=3);self.q.child.stdout.close()
  self.temp.cleanup()
 def spawn(self,args,**kwargs):
  self.authorizations.append(args)
  self.assertEqual(args[:4],['/usr/bin/sudo','-A','--',s.ACTIVATOR]);self.assertEqual(args[-1],'0')
  code='import sys,json;print(json.dumps({"activation":"started","lease":0}),flush=True);print(json.dumps({"helper":"postcheck"}),flush=True);sys.stdin.buffer.read();print(json.dumps({"activation":"released","child_status":0}),flush=True)'
  self.q.child=REAL_POPEN([sys.executable,'-c',code],**kwargs);return self.q.child
 def patches(self,mode):
  from contextlib import ExitStack
  stack=ExitStack()
  for target,value in [('verify_build',lambda:None),('inspect',lambda pid:dict(ID)),('QMP',lambda identity:self.q),('wait_socket',lambda *a:None),('device_mode',mode),('protected_socket_absent',lambda:True)]:stack.enter_context(mock.patch.object(s,target,value))
  stack.enter_context(mock.patch.object(s.os.path,'lexists',return_value=False));stack.enter_context(mock.patch.object(s.subprocess,'Popen',self.spawn))
  return stack
 def stop_mode(self):
  self.count+=1
  if self.count==3:self.c.cancel()
  return 'bootloader'
 def test_unknown_observer_never_cancels_or_proves_removal(self):
  def unknown():
   self.count+=1
   if self.count==3:self.c.cancel()
   return 'unknown'
  with self.patches(unknown):connected,removed=self.c.capture(ID)
  self.assertTrue(connected)
  self.assertFalse(removed,'observation failure is not physical removal evidence')
 def test_stop_closes_exact_pipe_waits_child_then_owned_cleanup(self):
  with self.patches(self.stop_mode):connected,removed=self.c.capture(ID)
  self.assertTrue(connected);self.assertFalse(removed);self.assertEqual(len(self.authorizations),1)
  self.assertIsNotNone(self.q.child.poll());self.assertEqual(self.q.chars,set());self.assertEqual(self.q.devices,set())
  self.assertFalse(json.loads((self.path/'state.json').read_text())['root_pending'])
  log=(self.path/'events.jsonl').read_text();self.assertIn('postcheck',log);self.assertIn('connected',log)
 def test_unknown_create_never_deleted_and_restart_blocked(self):
  self.q.unknown=True
  with self.patches(lambda:'bootloader'),self.assertRaisesRegex(RuntimeError,'ownership/removal'):
   self.c.capture(ID)
  self.assertNotIn('device_del',self.q.calls);self.assertNotIn('chardev-remove',self.q.calls)
  self.assertTrue(json.loads((self.path/'state.json').read_text())['root_pending'])
  c2=s.Controller(self.path);self.assertEqual(c2.run(),1)
  self.assertTrue(json.loads((self.path/'state.json').read_text())['root_pending'])
 def assert_journal_blocks_two_starts(self,original,unreadable=False):
  journal=self.path/'state.json';journal.write_bytes(original)
  if unreadable:journal.chmod(0)
  exits=[];snapshots=[];captures=[]
  try:
   for attempt in range(2):
    controller=s.Controller(self.path)
    def capture(identity):
     captures.append(identity);controller.cancel();return False,False
    with self.patches(lambda:'bootloader'),mock.patch.object(s,'discover',return_value=dict(ID)),mock.patch.object(s.signal,'signal'),mock.patch.object(controller,'capture',side_effect=capture):
     exits.append(controller.run())
    # Restore readability after the first refusal, as in the reviewer repro.
    # The unresolved ownership must still block the second invocation.
    if unreadable:journal.chmod(0o600)
    snapshots.append(journal.read_bytes())
   self.assertEqual(exits,[1,1])
   self.assertEqual(captures,[])
   self.assertEqual(snapshots[0],original,'failed read must preserve exact journal bytes')
   if not unreadable:self.assertEqual(snapshots[1],original)
   else:
    state=json.loads(snapshots[1]);self.assertTrue(state['root_pending'])
    self.assertEqual(state['device_id'],'unresolved-device');self.assertEqual(state['chardev_id'],'unresolved-char')
  finally:journal.chmod(0o600)
 def test_unreadable_pending_journal_blocks_two_starts(self):
  original=b'{"status":"quarantined","root_pending":true,"device_id":"unresolved-device","chardev_id":"unresolved-char"}\n'
  self.assert_journal_blocks_two_starts(original,unreadable=True)
 def test_malformed_pending_journal_blocks_two_starts(self):
  self.assert_journal_blocks_two_starts(b'{"root_pending":tru')
 def test_nonobject_journal_blocks_two_starts(self):
  self.assert_journal_blocks_two_starts(b'[]\n')
 def test_wrong_peer_never_spawns(self):
  with self.patches(lambda:'bootloader'),mock.patch.object(s,'inspect',return_value={**ID,'version':8}),self.assertRaisesRegex(RuntimeError,'identity changed'):
   self.c.capture(ID)
  self.assertEqual(self.authorizations,[])
 def test_authorization_denial_never_retried(self):
  def denied(args,**kwargs):
   self.authorizations.append(args);self.q.child=REAL_POPEN([sys.executable,'-c','raise SystemExit(1)'],**kwargs);return self.q.child
  with self.patches(lambda:'bootloader'),mock.patch.object(s.subprocess,'Popen',denied),self.assertRaisesRegex(RuntimeError,'denied'):
   self.c.capture(ID)
  self.assertEqual(len(self.authorizations),1);self.assertNotIn('device_add',self.q.calls)
 def test_expected_removal_allows_reconnect_but_no_mode_commands(self):
  def transition():
   self.count+=1
   if self.count>=3:
    if not self.q.child.stdin.closed:self.q.child.stdin.close()
    return 'application'
   return 'bootloader'
  with self.patches(transition):connected,removed=self.c.capture(ID)
  self.assertTrue(connected and removed)
  self.assertTrue(s.reconnect_allowed(connected,removed,'bootloader',False))
  self.assertTrue(set(self.q.calls)<=set(s.QMP.__module__ and ['query-name','query-chardev','qom-list','qom-get','chardev-add','device_add','device_del','chardev-remove']))
 def test_enabled_run_reconnects_once_with_fresh_owned_ids(self):
  ended=0
  def modes():
   nonlocal ended
   if not self.authorizations:return 'bootloader'
   if len(self.authorizations)==1:
    if self.q.child.poll() is not None:
     ended+=1
     return 'application' if ended==1 else 'bootloader'
    self.count+=1
    if self.count>=3:
     if not self.q.child.stdin.closed:self.q.child.stdin.close()
     return 'application'
    return 'bootloader'
   self.count+=1
   if self.count>=6:self.c.cancel()
   return 'bootloader'
  with self.patches(modes),mock.patch.object(s,'discover',return_value=dict(ID)),mock.patch.object(s.signal,'signal'):
   self.assertEqual(self.c.run(),0)
  self.assertEqual(len(self.authorizations),2)
  rows=[json.loads(line) for line in (self.path/'events.jsonl').read_text().splitlines()]
  ids=[row['device_id'] for row in rows if row['status']=='authorizing']
  self.assertEqual(len(set(ids)),2)
  self.assertEqual(self.q.devices,set());self.assertEqual(self.q.chars,set())
  self.assertFalse(self.c.state['root_pending'])
 def test_stop_during_readiness_never_publishes_connected(self):
  def readiness(call,owned):
   self.c.cancel();self.q.child.wait(timeout=3)
   return True
  with self.patches(lambda:'bootloader'),mock.patch.object(self.c,'qom_connected',readiness):
   connected,removed=self.c.capture(ID)
  rows=[json.loads(line) for line in (self.path/'events.jsonl').read_text().splitlines()]
  self.assertNotIn('connected',[row['status'] for row in rows])
  self.assertFalse(connected);self.assertFalse(self.c.state['connected'])
  self.assertFalse(self.c.state['enabled']);self.assertFalse(self.c.state['root_pending'])
  self.assertEqual(self.q.child.returncode,0)
 def test_child_exit_during_readiness_never_publishes_connected(self):
  def readiness(call,owned):
   self.q.child.stdin.close();self.q.child.wait(timeout=3)
   return True
  error=None
  with self.patches(lambda:'bootloader'),mock.patch.object(self.c,'qom_connected',readiness):
   try:self.c.capture(ID)
   except RuntimeError as caught:error=caught
  rows=[json.loads(line) for line in (self.path/'events.jsonl').read_text().splitlines()]
  self.assertNotIn('connected',[row['status'] for row in rows])
  self.assertRegex(str(error),'unexplained capture exit')
  self.assertFalse(self.c.state['connected']);self.assertFalse(self.c.state['root_pending'])
 def test_connected_publication_serializes_cancel(self):
  entered=threading.Event();finished=threading.Event();workers=[];record=self.c.record
  def cancel():
   entered.set();self.c.cancel();finished.set()
  def publication(status,**fields):
   if status=='connected':
    worker=threading.Thread(target=cancel);workers.append(worker);worker.start()
    self.assertTrue(entered.wait(2))
    self.assertFalse(finished.wait(.1),'cancel must not complete inside connected publication')
    self.assertFalse(self.c.stopped.is_set(),'cancel flag must use the publication mutex too')
   record(status,**fields)
  try:
   with self.patches(lambda:'bootloader'),mock.patch.object(self.c,'record',publication):
    connected,removed=self.c.capture(ID)
   self.assertTrue(connected);self.assertTrue(finished.is_set())
   self.assertFalse(self.c.state['connected']);self.assertFalse(self.c.state['enabled'])
  finally:
   for worker in workers:worker.join(3)
 def test_teardown_clears_connected_before_qmp_cleanup(self):
  seen=[];cleanup=s.OwnedDevices.cleanup
  def observe(owned):seen.append(self.c.state.get('connected'));return cleanup(owned)
  def removed():
   self.count+=1
   if self.count>=3 and not self.q.child.stdin.closed:self.q.child.stdin.close()
   return 'application'
  with self.patches(removed),mock.patch.object(s.OwnedDevices,'cleanup',observe):self.c.capture(ID)
  self.assertEqual(seen,[False])
 def test_unexplained_exit_does_not_retry(self):
  def unexplained():
   self.count+=1
   if self.count==3:self.q.child.stdin.close()
   return 'bootloader'
  with self.patches(unexplained),self.assertRaisesRegex(RuntimeError,'unexplained'):
   self.c.capture(ID)
  self.assertEqual(len(self.authorizations),1)
 def test_cancel_before_authorization_never_spawns(self):
  self.c.cancel()
  with self.patches(lambda:'bootloader'):self.c.capture(ID)
  self.assertEqual(self.authorizations,[])
 def test_preexisting_socket_is_pending_not_false_release(self):
  with self.patches(lambda:'bootloader'),mock.patch.object(s.os.path,'lexists',return_value=True),mock.patch.object(s,'protected_socket_absent',return_value=False):
   with self.assertRaisesRegex(RuntimeError,'occupied'):self.c.capture(ID)
  self.assertTrue(self.c.state.get('root_pending'))
  self.assertEqual(self.authorizations,[])
 def test_orphan_socket_never_claims_release(self):
  real_lexists=os.path.lexists
  def orphan(args,**kwargs):
   self.authorizations.append(args)
   code='import socket,sys,json;s=socket.socket(socket.AF_UNIX);s.bind("usb.sock");print(json.dumps({"activation":"started","lease":0}),flush=True);print(json.dumps({"helper":"postcheck"}),flush=True);sys.stdin.buffer.read();raise SystemExit(1)'
   self.q.child=REAL_POPEN([sys.executable,'-c',code],cwd=self.path,**kwargs);return self.q.child
  error=None
  with self.patches(self.stop_mode),mock.patch.object(s,'USB_SOCKET',str(self.path/'usb.sock')),mock.patch.object(s.os.path,'lexists',real_lexists),mock.patch.object(s.subprocess,'Popen',orphan):
   try:self.c.capture(ID)
   except RuntimeError as e:error=e
  self.assertTrue(json.loads((self.path/'state.json').read_text())['root_pending'],'real AF_UNIX orphan must not be reported released')
  self.assertIsNotNone(error)
  self.assertTrue((self.path/'usb.sock').exists(),'ordinary wrapper must not unlink socket')
  self.assertNotIn('device_del',self.q.calls)
 def test_native_release_event_does_not_override_orphan_inode(self):
  def orphan(args,**kwargs):
   code='import socket,sys,json;s=socket.socket(socket.AF_UNIX);s.bind("usb.sock");print(json.dumps({"activation":"started","lease":0}),flush=True);print(json.dumps({"helper":"postcheck"}),flush=True);sys.stdin.buffer.read();print(json.dumps({"activation":"released","child_status":0}),flush=True)'
   self.q.child=REAL_POPEN([sys.executable,'-c',code],cwd=self.path,**kwargs);return self.q.child
  with self.patches(self.stop_mode),mock.patch.object(s,'protected_socket_absent',lambda:s.socket_absent(self.path/'usb.sock')),mock.patch.object(s.subprocess,'Popen',orphan):
   with self.assertRaisesRegex(RuntimeError,'root outcome unconfirmed'):self.c.capture(ID)
  self.assertTrue(self.c.state['root_pending']);self.assertNotIn('device_del',self.q.calls)
  self.assertTrue((self.path/'usb.sock').exists())
 def test_abnormal_helper_status_reaped_but_never_reconnects(self):
  def abnormal(args,**kwargs):
   code='import sys,json;print(json.dumps({"activation":"started","lease":0}),flush=True);print(json.dumps({"helper":"postcheck"}),flush=True);sys.stdin.buffer.read();print(json.dumps({"activation":"released","child_status":137}),flush=True);raise SystemExit(1)'
   self.q.child=REAL_POPEN([sys.executable,'-c',code],**kwargs);return self.q.child
  def removal():
   self.count+=1
   if self.count>=3 and not self.q.child.stdin.closed:self.q.child.stdin.close()
   return 'absent'
  with self.patches(removal),mock.patch.object(s.subprocess,'Popen',abnormal):
   with self.assertRaisesRegex(RuntimeError,'abnormal helper'):self.c.capture(ID)
  self.assertFalse(self.c.state['root_pending']);self.assertEqual(self.c.state['child_status'],137)
  self.assertEqual(self.q.devices,set())
 def test_unknown_startup_does_not_authorize_capture(self):
  def unknown():
   self.count+=1
   if self.count==2:self.c.cancel()
   return 'unknown'
  with self.patches(unknown),mock.patch.object(s,'discover',return_value=dict(ID)),mock.patch.object(s.signal,'signal'):
   self.assertEqual(self.c.run(),0)
  self.assertEqual(self.authorizations,[])
  self.assertIn('waiting-unknown',(self.path/'events.jsonl').read_text())
 def test_real_user_control_socket_stop(self):
  import socket
  self.c.listener=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
  self.c.listener.bind(str(self.path/'control.sock'));self.c.listener.listen(2)
  worker=threading.Thread(target=self.c.serve_control);worker.start()
  try:
   self.assertTrue(s.control_request('status',self.path)['enabled'])
   self.assertFalse(s.control_request('stop',self.path)['enabled'])
   worker.join(2);self.assertFalse(worker.is_alive());self.assertTrue(self.c.stopped.is_set())
  finally:self.c.listener.close()
if __name__=='__main__':unittest.main()
