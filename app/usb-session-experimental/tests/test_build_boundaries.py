"""Negative profile/archive tests: no subprocess, root, USB or VM access."""
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
import profile as pins
import dependencies
import install_plan

class BuildBoundaries(unittest.TestCase):
    def setUp(self):self.p=json.loads((ROOT/'profiles/fixture.json').read_text())
    def test_invalid_profiles_fail_closed(self):
        cases=[('uid',0),('uid',True),('gid',-1),('kind','auto'),('serial',''),
               ('qemu_sha256','0'*64),('qemu_cdhash','ff'),('qemu_path','../vm'),
               ('qmp_path','/a/../b'),('location',0),('vid',1),('report_hex','00'*33),
               ('config_hex','00'*34),('device_hex','00'*18),('argv',[])]
        for key,value in cases:
            with self.subTest(key=key,value=value),self.assertRaises(ValueError):
                p=copy.deepcopy(self.p);p[key]=value;pins.validate(p)
        for key in self.p:
            p=copy.deepcopy(self.p);del p[key]
            with self.assertRaises(ValueError):pins.validate(p)
        p=copy.deepcopy(self.p);p['runtime_override']='never'
        with self.assertRaises(ValueError):pins.validate(p)
    def test_qmp_path_must_roundtrip_native_json_evidence(self):
        p=copy.deepcopy(self.p);p['qmp_path']='/fixture/quote".qmp'
        p['argv'][4]='unix:'+p['qmp_path']+',server=on,wait=off'
        with self.assertRaises(ValueError):pins.validate(p)

    def test_generated_policy_preserves_exact_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            pins.generate(self.p,tmp)
            h=(Path(tmp)/'local_pins.h').read_text()
            for key in ('qemu_sha256','qemu_cdhash','serial','qmp_path'):
                self.assertIn(self.p[key],h)
            self.assertIn('PROFILE_ARGV',h)
            self.assertNotIn('SUDO_UID',h)
    def test_archive_rejects_traversal_links_duplicate_and_collision(self):
        variants=[('../escape','file'),('/absolute','file'),('link','symlink'),('fifo','fifo'),('dup','duplicate'),('parent','collision')]
        for name,kind in variants:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as tmp:
                arc=Path(tmp)/'x.tar'
                with tarfile.open(arc,'w') as t:
                    member=tarfile.TarInfo(name);member.size=1
                    if kind=='symlink':member.type=tarfile.SYMTYPE;member.linkname='/outside'
                    if kind=='fifo':member.type=tarfile.FIFOTYPE
                    t.addfile(member,io.BytesIO(b'x'))
                    if kind=='duplicate':t.addfile(member,io.BytesIO(b'x'))
                    if kind=='collision':
                        child=tarfile.TarInfo('parent/child');child.size=1;t.addfile(child,io.BytesIO(b'x'))
                with self.assertRaises(ValueError):dependencies.extract(arc,Path(tmp)/'out')
                self.assertFalse((Path(tmp)/'out').exists())
    def test_installer_render_is_offline_shell_only(self):
        # Test-only synthetic physical-shaped metadata, NOT a physical profile/build.
        p=copy.deepcopy(self.p);p['kind']='physical'
        with tempfile.TemporaryDirectory() as tmp:
            helper=Path(tmp)/'helper';helper.write_bytes(b'not executable fixture')
            activate=Path(tmp)/'activate';activate.write_bytes(b'not executable fixture')
            script=install_plan.render(p,helper,activate)
            path=Path(tmp)/'install.sh';path.write_text(script)
            subprocess.run(['/bin/bash','-n',str(path)],check=True)
            for command in ('python','curl','wget','launchctl','sudoers','chmod 777','codesign --force'):
                self.assertNotIn(command,script)
            self.assertIn('verify_hash "$stage/helper" "$HELPER_SHA"',script)
            self.assertIn("'0:555:1'",script)
            self.assertIn('Exact complete rerun',script)

if __name__=='__main__':unittest.main()
