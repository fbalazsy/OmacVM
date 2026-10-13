"""Tests use FAKE QMP/root processes; never contact VM or sudo."""
import importlib.util, pathlib, unittest
ROOT=pathlib.Path(__file__).resolve().parent
class RunnerTests(unittest.TestCase):
    def test_owned_qmp_lifecycle_and_failure_paths(self):
        self.assertTrue((ROOT/'baldur_lease.py').exists(),'profile UID runner not implemented')
        spec=importlib.util.spec_from_file_location('lease',ROOT/'baldur_lease.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
        class Fake:
            def __init__(self,fail=None,autoremove=True): self.calls=[];self.chars={'unrelated'};self.devs={'existing-usb'};self.fail=fail;self.autoremove=autoremove
            def __call__(self,op,args=None):
                self.calls.append((op,args))
                if op=='query-chardev': return [{'label':x} for x in self.chars]
                if op=='qom-list': return [{'name':x} for x in self.devs]
                if op=='chardev-add': self.chars.add(args['id'])
                elif op=='device_add': self.devs.add(args['id'])
                elif op=='device_del':
                    self.devs.discard(args['id'])
                    if self.autoremove: self.chars.discard('omacvm-usb-session-'+('a'*32)+'-c')
                elif op=='chardev-remove': self.chars.discard(args['id'])
                if op==self.fail: self.fail=None;raise TimeoutError('OFFLINE lost mutation reply')
                return {}
        for fail in [None,'chardev-add','device_add']:
            for auto in [False,True]:
                fake=Fake(fail,auto); lease=m.OwnedDevices(fake,'a'*32,sleep=lambda _:None)
                try: lease.attach()
                except TimeoutError: pass
                if fail:
                    self.assertTrue(lease.cleanup())
                    self.assertFalse(any(op in ('device_del','chardev-remove') for op,args in fake.calls))
                else:
                    self.assertEqual(lease.cleanup(),[])
                    self.assertEqual(fake.chars,{'unrelated'});self.assertEqual(fake.devs,{'existing-usb'})
                for op,args in fake.calls:
                    if op in ('device_del','chardev-remove'): self.assertTrue(args['id'].startswith('omacvm-usb-session-'+'a'*32))
                adds=[args for op,args in fake.calls if op=='device_add']
                if adds:self.assertEqual(adds[0]['filter'],'0x03:0x1209:0xffff:-1:1|-1:-1:-1:-1:0')
        fake=Fake();fake.chars.add('omacvm-usb-session-'+('a'*32)+'-c');lease=m.OwnedDevices(fake,'a'*32)
        with self.assertRaises(RuntimeError):lease.attach()
        self.assertEqual(lease.cleanup(),[]);self.assertFalse(any(x[0].endswith('remove') for x in fake.calls))
        self.assertRaises(ValueError,m.OwnedDevices,Fake(),'../bad')
        ident={'pid':12345,'sec':123,'usec':0,'version':10,'qmp':m.QMP_PATH}
        self.assertEqual(m.sudo_command(ident,120,True),['/usr/bin/sudo','-A','--',m.ACTIVATOR,'--activate','12345','123','0','10','120'])
        self.assertNotIn('-S',m.sudo_command(ident,5,False))
if __name__=='__main__':unittest.main()
