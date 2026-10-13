"""In-memory races only; actual runner classes, never main or real sockets."""
import sys,pathlib,unittest
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'activation'))
import baldur_lease as m
class Race:
    def __init__(self,where='chardev-add',ambiguous=False):self.chars=set();self.devs=set();self.deleted=[];self.where=where;self.ambiguous=ambiguous
    def __call__(self,op,args=None):
        if op=='query-chardev':return [{'label':x} for x in self.chars]
        if op=='qom-list':return [{'name':x} for x in self.devs]
        if op in ('chardev-add','device_add'):
            (self.chars if op=='chardev-add' else self.devs).add(args['id'])
            if op==self.where:
                error=getattr(m,'QMPAmbiguous' if self.ambiguous else 'QMPRejected',RuntimeError)
                raise error('lost reply' if self.ambiguous else 'duplicate ID')
            return {}
        if op=='chardev-remove':self.deleted.append(args['id']);self.chars.discard(args['id']);return {}
        if op=='device_del':self.deleted.append(args['id']);self.devs.discard(args['id']);return {}
        raise AssertionError(op)
class Ownership(unittest.TestCase):
    def test_definitive_collision_preserved(self):
        for op in ('chardev-add','device_add'):
            with self.subTest(op=op):
                f=Race(op);o=m.OwnedDevices(f,'b'*32)
                with self.assertRaises(RuntimeError):o.attach()
                o.cleanup();foreign=o.char if op=='chardev-add' else o.device
                self.assertNotIn(foreign,f.deleted)
    def test_ambiguous_delivery_preserves_unattributable_objects(self):
        for op in ('chardev-add','device_add'):
            with self.subTest(op=op):
                f=Race(op,True);o=m.OwnedDevices(f,'c'*32)
                with self.assertRaises(RuntimeError):o.attach()
                self.assertTrue(o.cleanup());self.assertEqual(f.deleted,[])
    def test_ambiguous_delete_never_replayed(self):
        class Lost(Race):
            def __init__(self):super().__init__(where=None);self.attempts=0
            def __call__(self,op,args=None):
                if op=='device_del':self.attempts+=1;raise m.QMPAmbiguous('delivery unknown')
                return super().__call__(op,args)
        f=Lost();o=m.OwnedDevices(f,'d'*32,sleep=lambda _:None);o.attach()
        self.assertTrue(o.cleanup());self.assertTrue(o.cleanup())
        self.assertEqual(f.attempts,1);self.assertIn(o.char,f.chars)
if __name__=='__main__':unittest.main()
