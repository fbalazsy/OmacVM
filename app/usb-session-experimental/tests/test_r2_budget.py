"""Actual QMP budget, fake clock/socket/auth only."""
import sys,pathlib,unittest
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'activation'))
import baldur_lease as m
from test_qmp import ID,MemorySocket
class Budget(unittest.TestCase):
    def test_connection_and_auth_do_not_reset_reply_budget(self):
        clock=[10.0];s=MemorySocket()
        def connector(_):clock[0]+=4;return s
        def auth(*a,**kw):clock[0]+=4
        # A single deadline must cover connect+auth+reply; no mutation after it.
        q=m.QMP(ID,connector=connector,run=auth)
        from unittest import mock
        with mock.patch.object(m.time,'monotonic',side_effect=lambda:clock[0]):
            with self.assertRaises(TimeoutError):q('device_add',{})
        self.assertEqual(s.sent,[])
if __name__=='__main__':unittest.main()
