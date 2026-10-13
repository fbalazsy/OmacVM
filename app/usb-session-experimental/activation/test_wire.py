"""Bounded FAKE sockets; no Unix socket creation or QMP connection."""
import importlib.util,pathlib,unittest
ROOT=pathlib.Path(__file__).resolve().parent
class WireTests(unittest.TestCase):
    def test_contention_retry_and_auth_before_qmp_mutation(self):
        self.assertTrue((ROOT/'baldur_lease.py').exists(),'QMP client not implemented')
        spec=importlib.util.spec_from_file_location('lease',ROOT/'baldur_lease.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
        log=[];time=[0.0];count=[0]
        class Sock:
            def settimeout(self,t):pass
            def connect(self,p):
                count[0]+=1;log.append('connect')
                if count[0]<3:raise ConnectionRefusedError()
            def close(self):log.append('close')
        def pause(dt):time[0]+=dt
        s=m.connect_retry('fake',lambda:Sock(),clock=lambda:time[0],sleep=pause,budget=1)
        self.assertEqual(count[0],3);self.assertEqual(log.count('close'),2);s.close()
        count[0]=0;time[0]=0
        with self.assertRaises(TimeoutError):m.connect_retry('fake',lambda:Sock(),clock=lambda:time[0],sleep=pause,budget=.15)
        self.assertLessEqual(count[0],2)
if __name__=='__main__':unittest.main()
