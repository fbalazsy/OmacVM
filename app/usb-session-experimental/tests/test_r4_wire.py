"""Actual QMP serializer against memory sockets and fake identity checker."""
import sys,pathlib,json,unittest
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'activation'))
import baldur_lease as m
from test_qmp import MemorySocket,ID
class Wire(unittest.TestCase):
    def test_definitive_matching_error(self):
        class S(MemorySocket):
            def sendall(self,raw):
                req=json.loads(raw);self.sent.append(req)
                field='return' if req['execute']=='qmp_capabilities' else 'error'
                self.buffer+=(json.dumps({'id':req['id'],field:{}})+'\n').encode()
        s=S()
        with self.assertRaises(m.QMPRejected):m.QMP(ID,connector=lambda _:s,run=lambda *a,**k:None)('device_add',{})
        self.assertTrue(s.closed)
    def test_accepted_lost_and_partial_send_are_ambiguous(self):
        for partial in (False,True):
            class S(MemorySocket):
                def sendall(self,raw):
                    if json.loads(raw)['execute']=='device_add':
                        if partial:raise BrokenPipeError('partial send')
                        return # accepted, but EOF before reply
                    super().sendall(raw)
            s=S()
            with self.assertRaises(m.QMPAmbiguous):m.QMP(ID,connector=lambda _:s,run=lambda *a,**k:None)('device_add',{})
            self.assertTrue(s.closed)
if __name__=='__main__':unittest.main()
