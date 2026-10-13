import sys,pathlib,unittest,stat,types
from unittest import mock
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'activation'))
import baldur_lease as m
class Output(unittest.TestCase):
    def test_runner_output_never_uses_blocking_stdio(self):
        self.assertTrue(hasattr(m,'bounded_notice'),'runner still uses blocking print while owning root control')
        with mock.patch.object(m.os,'fstat',return_value=types.SimpleNamespace(st_mode=stat.S_IFIFO)),mock.patch.object(m.os,'set_blocking') as nb,mock.patch.object(m.os,'write',side_effect=BlockingIOError) as write:
            self.assertFalse(m.bounded_notice('notice'));nb.assert_called_once_with(1,False);write.assert_called_once()
if __name__=='__main__':unittest.main()
