"""Fake main dependencies only; proves helper-before-QMP ordering on uncertainty."""
import sys,pathlib,unittest,subprocess
from unittest import mock
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'activation'))
import baldur_lease as m
from test_qmp import ID
class Runner(unittest.TestCase):
    def setUp(self):
        # Privileged/network calls in these tests are fakes, never production.
        import os
        for key,value in [('PROFILE_FIXTURE',False),('PROFILE_UID',os.getuid())]:
            guard=mock.patch.object(m,key,value);guard.start();self.addCleanup(guard.stop)
    def test_unconfirmed_supervisor_exit_never_tears_down_qmp(self):
        for status in (125,-9,70):
            events=[]
            class Pipe:
                def close(self):events.append('close')
            class Process:
                stdin=Pipe();stdout=Pipe()
                def poll(self):return status
                def wait(self,timeout):events.append('wait');return status
            class Owned:
                device='d';char='c'
                def __init__(self,*a):pass
                def attach(self):events.append('attach')
                def cleanup(self):events.append('QMP DELETE');return []
            with mock.patch.object(m,'ActivationEvents',return_value=mock.Mock(released=False,failed=False,data=b'')),mock.patch.object(m,'inspect',return_value=ID),mock.patch.object(m,'QMP',return_value=lambda *a,**k:{'name':'OmacVM Fixture'}),mock.patch.object(m,'OwnedDevices',Owned),mock.patch.object(m.subprocess,'Popen',return_value=Process()),mock.patch.object(m,'wait_ready'),mock.patch.object(m,'wait_socket'),mock.patch.object(m.os.path,'lexists',return_value=False),mock.patch.object(m.sys.stdin,'isatty',return_value=True),mock.patch.object(m.signal,'signal'),mock.patch('builtins.print'):
                self.assertEqual(m.main(['--pid','12345','--lease','5']),1)
            self.assertNotIn('QMP DELETE',events)
    def test_signal_closes_control_during_qmp_work(self):
        handlers={};state={'closed':False}
        class Pipe:
            def close(self):state['closed']=True
        class Process:
            stdin=Pipe();stdout=Pipe()
            def poll(self):return 0
            def wait(self,timeout):return 0
        class Owned:
            device='d';char='c'
            def __init__(self,*a):pass
            def attach(self):
                handlers[m.signal.SIGTERM](15,None)
                state['closed_during_qmp']=state['closed']
            def cleanup(self):return []
        with mock.patch.object(m,'ActivationEvents',return_value=mock.Mock(released=False,failed=False,data=b'')),mock.patch.object(m,'inspect',return_value=ID),mock.patch.object(m,'QMP',return_value=lambda *a,**k:{'name':'OmacVM Fixture'}),mock.patch.object(m,'OwnedDevices',Owned),mock.patch.object(m.subprocess,'Popen',return_value=Process()),mock.patch.object(m,'wait_ready'),mock.patch.object(m,'wait_socket'),mock.patch.object(m.os.path,'lexists',return_value=False),mock.patch.object(m.sys.stdin,'isatty',return_value=True),mock.patch.object(m.signal,'signal',side_effect=lambda sig,cb:handlers.update({sig:cb})),mock.patch.object(m,'bounded_notice'):
            m.main(['--pid','12345','--lease','5'])
        self.assertTrue(state.get('closed_during_qmp'),'control must close before QMP work returns')
if __name__=='__main__':unittest.main()
