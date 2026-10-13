"""Offline tests of the real QMP serializer against in-memory sockets only."""
import importlib.util,json,pathlib,subprocess,unittest
from unittest import mock
ROOT=pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('lease',ROOT/'baldur_lease.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
ID={'pid':12345,'sec':1,'usec':0,'version':3,'qmp':m.QMP_PATH}
class MemorySocket:
    def __init__(self):self.buffer=b'{"QMP":{}}\r\n';self.sent=[];self.closed=False
    def fileno(self):return 99
    def settimeout(self,n):assert n>0
    def recv(self,n):data=self.buffer[:n];self.buffer=self.buffer[n:];return data
    def sendall(self,raw):
        req=json.loads(raw);self.sent.append(req)
        self.buffer+=(json.dumps({'event':'FAKE_EVENT'})+'\n'+json.dumps({'id':req['id'],'return':{'name':'OmacVM Fixture'} if req['execute']=='query-name' else {}})+'\n').encode()
    def close(self):self.closed=True
class QMPTests(unittest.TestCase):
    def setUp(self):
        # Privileged/network calls in these tests are fakes, never production.
        import os
        for key,value in [('PROFILE_FIXTURE',False),('PROFILE_UID',os.getuid())]:
            guard=mock.patch.object(m,key,value);guard.start();self.addCleanup(guard.stop)
    def test_client_socket_omits_server_only_wait(self):
        sent=[]
        owned=m.OwnedDevices(lambda op,args=None:sent.append((op,args)), 'a'*32)
        with mock.patch.object(owned,'chars',side_effect=[set(),{owned.char}]),mock.patch.object(owned,'devices',side_effect=[set(),{owned.device}]):
            owned.attach()
        data=next(args['backend']['data'] for op,args in sent if op=='chardev-add')
        self.assertIs(data['server'],False)
        self.assertNotIn('wait',data,'QEMU rejects even wait=false for socket client mode')
    def test_auth_failure_never_transmits_qmp(self):
        sock=MemorySocket()
        def deny(*args,**kwargs):raise subprocess.CalledProcessError(64,args[0])
        with self.assertRaises(subprocess.CalledProcessError):m.QMP(ID,connector=lambda _:sock,run=deny)('query-name')
        self.assertEqual(sock.sent,[]);self.assertTrue(sock.closed)
    def test_authenticated_socket_replies_and_events(self):
        sock=MemorySocket();auth=[]
        def accept(args,**kw):self.assertEqual(sock.sent,[]);self.assertEqual(kw['pass_fds'],(99,));auth.append(args)
        self.assertEqual(m.QMP(ID,connector=lambda _:sock,run=accept)('query-name'),{'name':'OmacVM Fixture'})
        self.assertEqual([x['execute'] for x in sock.sent],['qmp_capabilities','query-name']);self.assertTrue(sock.closed)
        self.assertEqual(auth[0],[m.ACTIVATOR,'--peer','99','12345','1','0','3'])
    def test_eof_and_unapproved_operation(self):
        sock=MemorySocket();sock.buffer=b''
        with self.assertRaises(ConnectionError):m.QMP(ID,connector=lambda _:sock,run=lambda *a,**k:None)('query-name')
        self.assertTrue(sock.closed)
        with self.assertRaises(ValueError):m.QMP(ID,connector=lambda _:self.fail('must not connect'))('system_reset')
    def test_nonroot_main_split_with_fake_sudo_and_qmp(self):
        events=[]
        evidence=mock.Mock(released=True,failed=False,data=b'')
        class Pipe:
            def close(self):events.append('close-control-pipe')
        class Process:
            stdin=Pipe();stdout=Pipe()
            def poll(self):return 0
            def wait(self,timeout):events.append('wait-root');return 0
        class Owned:
            device='own-device';char='own-char'
            def __init__(self,*args):pass
            def attach(self):events.append('attach')
            def cleanup(self):events.append('cleanup-own-qmp');return []
        def spawn(args,**kw):
            self.assertEqual(args[0],'/usr/bin/sudo');self.assertEqual(args[2],m.ACTIVATOR)
            self.assertNotIn(sys_executable,args);self.assertEqual(kw['stdin'],subprocess.PIPE)
            events.append('sudo-native');return Process()
        import sys
        sys_executable=sys.executable
        with mock.patch.object(m,'ActivationEvents',return_value=evidence),mock.patch.object(m,'socket_absent',return_value=True),mock.patch.object(m,'inspect',return_value=ID),mock.patch.object(m,'QMP',return_value=lambda *a,**k:{'name':'OmacVM Fixture'}),mock.patch.object(m,'OwnedDevices',Owned),mock.patch.object(m.subprocess,'Popen',side_effect=spawn),mock.patch.object(m,'wait_ready'),mock.patch.object(m,'wait_socket'),mock.patch.object(m.os.path,'lexists',return_value=False),mock.patch.object(m.sys.stdin,'isatty',return_value=True),mock.patch.object(m.signal,'signal'),mock.patch('builtins.print'):
            self.assertEqual(m.main(['--pid','12345','--lease','5']),0)
        self.assertEqual(events,['sudo-native','attach','close-control-pipe','wait-root','close-control-pipe','cleanup-own-qmp'])
if __name__=='__main__':unittest.main()
