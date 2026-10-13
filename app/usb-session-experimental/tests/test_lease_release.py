"""Legacy diagnostic runner also needs explicit native cleanup proof."""
import json,subprocess,sys,tempfile,unittest
from pathlib import Path
from unittest import mock
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'activation'))
import baldur_lease as m
POPEN=subprocess.Popen
class LeaseRelease(unittest.TestCase):
 def setUp(self):
     # Privileged/network calls in these tests are fakes, never production.
     import os
     for key,value in [('PROFILE_FIXTURE',False),('PROFILE_UID',os.getuid())]:
         guard=mock.patch.object(m,key,value);guard.start();self.addCleanup(guard.stop)
 def test_real_child_orphan_exit_one_is_not_release(self):
  with tempfile.TemporaryDirectory(dir='build') as tmp:
   calls=[]
   class Owned:
    device='fixture-device';char='fixture-char'
    def __init__(self,*args):pass
    def attach(self):pass
    def cleanup(self):calls.append('delete');return []
   def spawn(args,**kw):
    return POPEN([sys.executable,'-c','import socket;s=socket.socket(socket.AF_UNIX);s.bind("usb.sock");raise SystemExit(1)'],cwd=tmp,**kw)
   identity={'pid':42,'sec':1,'usec':0,'version':3,'qmp':m.QMP_PATH}
   with mock.patch.object(m,'inspect',return_value=identity),mock.patch.object(m,'QMP',return_value=lambda *a,**k:{'name':'OmacVM Fixture'}),mock.patch.object(m,'OwnedDevices',Owned),mock.patch.object(m.subprocess,'Popen',spawn),mock.patch.object(m,'wait_ready'),mock.patch.object(m,'wait_socket'),mock.patch.object(m,'USB_SOCKET',str(Path(tmp)/'usb.sock')),mock.patch.object(m.sys.stdin,'isatty',return_value=True),mock.patch.object(m.signal,'signal'),mock.patch.object(m,'bounded_notice'):
    self.assertEqual(m.main(['--pid','42','--lease','5']),1)
   self.assertTrue((Path(tmp)/'usb.sock').exists())
   self.assertEqual(calls,[],'exit 1 is not permission to remove QMP objects')
if __name__=='__main__':unittest.main()
