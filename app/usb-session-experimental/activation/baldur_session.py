#!/usr/bin/env python3
"""Explicit local OmacVM Fixture/fixture session; never run this module as root."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import selectors
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
import uuid
from xml.parsers.expat import ExpatError
from activation_evidence import ActivationEvents as Events, socket_absent
from baldur_lease import QMP, OwnedDevices, Ownership, inspect, wait_socket
from local_pins import (ACTIVATOR, USB_SOCKET, QMP_PATH, PROFILE_UID, PROFILE_FIXTURE,
    QEMU_PATH, QEMU_REAL, PROFILE_LOCATION, PROFILE_VID, PROFILE_PID, PROFILE_SERIAL,
    APPLICATION_VID, APPLICATION_PID, APPLICATION_SERIAL, VM_NAME, USER_STATE)

ROOT=Path(__file__).resolve().parents[1]
STATE=Path(USER_STATE)
QEMU=QEMU_PATH

LOCATION=PROFILE_LOCATION

def reconnect_allowed(was_connected,removal_seen,mode,stopped):
    return was_connected and removal_seen and mode=='bootloader' and not stopped

def atomic_json(path,value):
    temp=path.with_name(path.name+'.'+uuid.uuid4().hex)
    fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    try:
        with os.fdopen(fd,'w') as f:
            json.dump(value,f,sort_keys=True);f.write('\n');f.flush();os.fsync(f.fileno())
        os.replace(temp,path)
    finally:
        if temp.exists():temp.unlink()

def state_dir(path=STATE):
    path.mkdir(parents=True,mode=0o700,exist_ok=True)
    st=path.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid!=os.getuid() or stat.S_IMODE(st.st_mode)!=0o700:
        raise RuntimeError('state directory must be nonsymlink profile UID 0700')
    return path

def verify_build():
    manifest=json.loads((ROOT/'BUILD.json').read_text())
    for rel,expected in manifest['source_sha256'].items():
        if hashlib.sha256((ROOT/rel).read_bytes()).hexdigest()!=expected:
            raise RuntimeError('local source changed: '+rel+'; rebuild/review before starting')
    for target,expected in manifest['installed_sha256'].items():
        st=os.lstat(target)
        if not stat.S_ISREG(st.st_mode) or st.st_uid!=0 or stat.S_IMODE(st.st_mode)!=0o555 or not st.st_flags&stat.UF_IMMUTABLE:
            raise RuntimeError('root payload protection mismatch: '+target)
        if hashlib.sha256(Path(target).read_bytes()).hexdigest()!=expected:
            raise RuntimeError('root payload hash mismatch: '+target)

def discover(pid,inspect_fn=inspect):
    """Explicit PID only; native compiled authority decides admission."""
    if type(pid) is not int or not 0 < pid <= 2147483647:
        raise RuntimeError('explicit existing VM PID required')
    return inspect_fn(pid)

def classify_devices(tree):
    hits=[]
    def walk(node):
        if isinstance(node,list):
            for child in node:walk(child)
        elif isinstance(node,dict):
            v=node.get('idVendor');p=node.get('idProduct')
            if (v,p) in ((PROFILE_VID,PROFILE_PID),(APPLICATION_VID,APPLICATION_PID)):
                hits.append(node)
            walk(node.get('IORegistryEntryChildren',[]))
    walk(tree)
    if not hits:return 'absent'
    if len(hits)!=1:raise RuntimeError('ambiguous ECU candidates; no capture')
    d=hits[0];serial=d.get('USB Serial Number');loc=d.get('locationID')
    if (d.get('idVendor'),d.get('idProduct'),serial,loc)==(PROFILE_VID,PROFILE_PID,PROFILE_SERIAL,LOCATION):return 'bootloader'
    if (d.get('idVendor'),d.get('idProduct'),serial,loc)==(APPLICATION_VID,APPLICATION_PID,APPLICATION_SERIAL,LOCATION):return 'application'
    raise RuntimeError('ECU identity/location mismatch; no capture')

def device_mode():
    # A failed observer is not physical removal and must not cancel a live transfer.
    # The native USB owner independently enforces exact peer/device identity.
    try:
        raw=subprocess.run(['/usr/sbin/ioreg','-a','-r','-c','IOUSBHostDevice'],capture_output=True,check=True,timeout=5).stdout
    except (OSError,subprocess.SubprocessError):return 'unknown'
    if len(raw)>16*1024*1024:return 'unknown'
    if not raw.strip():return 'absent' # ioreg emits nothing when no class instance matches
    try:
        tree=plistlib.loads(raw)
        if not isinstance(tree,(list,dict)):return 'unknown'
        return classify_devices(tree)
    except (ValueError,plistlib.InvalidFileException,RuntimeError,RecursionError,ExpatError):return 'unknown'

def protected_socket_absent():
    return socket_absent(USB_SOCKET)

class Controller:
    def __init__(self,path=STATE,pid=None):
        self.pid=pid;self.path=state_dir(path);self.stopped=threading.Event();self.process=None
        self.state={'status':'starting','enabled':True,'connected':False,'guest_verified':False,'controller_pid':os.getpid()}
        self.mu=threading.RLock();self.listener=None;self.control_inode=None
    def record(self,status,**fields):
        with self.mu:
            if status!='root-evidence':self.state.update(status=status,**fields)
            self.state['updated_at']=time.time()
            atomic_json(self.path/'state.json',self.state)
            log=self.path/'events.jsonl'
            if log.exists() and log.stat().st_size>2*1024*1024:os.replace(log,self.path/'events.previous.jsonl')
            fd=os.open(log,os.O_WRONLY|os.O_CREAT|os.O_APPEND|os.O_NOFOLLOW,0o600)
            try:os.write(fd,(json.dumps({'time':time.time(),'status':status,**fields})+'\n').encode())
            finally:os.close(fd)
    def cancel(self,*_):
        with self.mu:
            self.stopped.set()
            self.state.update(enabled=False,connected=False)
            if self.process is not None and self.process.stdin is not None:
                try:self.process.stdin.close()
                except OSError:pass
    def serve_control(self):
        self.listener.settimeout(.2)
        while not self.stopped.is_set():
            try:client,_=self.listener.accept()
            except socket.timeout:continue
            except OSError:return
            with client:
                client.settimeout(1)
                try:
                    command=client.recv(64)
                    if command==b'stop\n':self.cancel()
                    elif command!=b'status\n':continue
                    with self.mu:client.sendall((json.dumps(self.state)+'\n').encode())
                except OSError:pass
    def peer_still_exact(self,identity):
        if inspect(identity['pid'])!=identity:raise RuntimeError('QEMU identity changed; explicit new start required')
    def qom_connected(self,call,owned):
        path='/machine/peripheral/'+owned.device
        return (owned.device in owned.devices() and owned.char in owned.chars()
                and call('qom-get',{'path':path,'property':'attached'}) is True
                and any(row.get('label')==owned.char and row.get('frontend-open') is True
                        for row in call('query-chardev')))
    def capture(self,identity):
        """Return only after root reaped and attributable QMP cleanup completed."""
        verify_build();self.peer_still_exact(identity)
        call=QMP(identity)
        if call('query-name').get('name')!=VM_NAME:raise RuntimeError('wrong QMP VM')
        if not protected_socket_absent():
            self.record('quarantined',connected=False,root_pending=True,error='protected socket occupied or unobservable')
            raise RuntimeError('protected socket occupied or unobservable; manual reconciliation required')
        owned=OwnedDevices(call,uuid.uuid4().hex)
        connected=False;removal=False;failure=None;rc=None;events=None
        try:
            self.record('authorizing',root_pending=True,device_id=owned.device,chardev_id=owned.char,
                        device_ownership='NOT_SENT',char_ownership='NOT_SENT')
            with self.mu:
                if self.stopped.is_set():return False,False
                cmd=['/usr/bin/sudo','-A','--',ACTIVATOR,'--activate',*[str(identity[k]) for k in ('pid','sec','usec','version')],'0']
                self.process=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,close_fds=True)
            events=Events(self.process,self.record);end=time.monotonic()+180
            while not events.started:
                events.drain()
                if self.stopped.is_set():return False,False
                if self.process.poll() is not None:raise RuntimeError('authorization denied or activator refused; no retry')
                if time.monotonic()>end:raise RuntimeError('authorization/start timeout; no retry')
                self.stopped.wait(.05)
            wait_socket(self.process,self.stopped.is_set)
            if self.stopped.is_set():return False,False
            self.record('attaching',device_ownership='UNKNOWN',char_ownership='UNKNOWN')
            owned.attach()
            self.record('awaiting-postcheck',device_ownership=owned.device_state.name,char_ownership=owned.char_state.name)
            start=time.monotonic();next_check=0
            while not self.stopped.is_set():
                events.drain()
                if self.process.poll() is not None:break
                mode=device_mode()
                if mode in ('absent','application'):removal=True
                if events.postcheck and not connected and self.qom_connected(call,owned):
                    with self.mu:
                        if self.stopped.is_set() or self.process.poll() is not None:break
                        connected=True;self.record('connected',connected=True,postcheck=True,guest_verified=False)
                if not connected and time.monotonic()-start>30:raise RuntimeError('startup never produced postcheck + QOM attached/connected')
                if time.monotonic()>next_check:
                    self.peer_still_exact(identity);next_check=time.monotonic()+5
                self.stopped.wait(.25)
        except Exception as error:
            failure=error
        finally:
            with self.mu:
                self.state['connected']=False
                if self.process is not None:
                    try:self.process.stdin.close()
                    except OSError:pass
            if self.process is not None:
                try:rc=self.process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    self.record('quarantined',connected=False,root_pending=True,error='root termination unconfirmed; resources and singleton retained')
                    # Do not orphan an uncertain root supervisor or discard our ledger.
                    while self.process.poll() is None:time.sleep(1)
                    rc=self.process.returncode
                evidence_error=None
                try:
                    if events is not None:events.drain()
                except (OSError,ValueError,RuntimeError) as error:evidence_error=str(error)
                finally:self.process.stdout.close()
                if (rc not in (0,1,124) or events is None or not events.released
                        or events.data or evidence_error or not protected_socket_absent()):
                    self.record('quarantined',connected=False,root_pending=True,activation_exit=rc)
                    raise RuntimeError('root outcome unconfirmed; QMP resources preserved; manual reconciliation required'+('; '+str(failure) if failure else ''))
            errors=owned.cleanup() if self.process is not None else []
            if errors:
                self.record('quarantined',connected=False,root_pending=True,cleanup_errors=errors,
                            device_ownership=owned.device_state.name,char_ownership=owned.char_state.name)
                raise RuntimeError('QMP ownership/removal unconfirmed; manual reconciliation required')
            self.process=None
            self.record('released',connected=False,root_pending=False,activation_exit=rc,
                        child_status=events.child_status if events is not None else None,
                        device_ownership=owned.device_state.name,char_ownership=owned.char_state.name)
        if failure:raise failure
        if self.stopped.is_set():return connected,removal
        if events is None or events.child_status not in (0,1):raise RuntimeError('abnormal helper exit; no retry')
        mode=device_mode()
        removal=removal or mode in ('absent','application')
        if not connected or not removal:raise RuntimeError('unexplained capture exit; no retry')
        return connected,removal
    def run(self):
        lock=os.open(self.path/'controller.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:os.close(lock);raise RuntimeError('session already running')
        control=self.path/'control.sock';prior_read=False
        try:
            try:prior=json.loads((self.path/'state.json').read_text())
            except FileNotFoundError:prior={}
            if not isinstance(prior,dict):raise ValueError('previous session journal is not an object')
            prior_read=True
            if prior.get('root_pending'):
                self.state.update(prior)
                raise RuntimeError('previous session has unresolved root/QMP ownership; no automatic recovery')
            if os.path.lexists(control):
                raise RuntimeError('preexisting control path; reconcile manually, never adopt/unlink')
            self.listener=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);self.listener.bind(str(control));self.control_inode=control.lstat();os.chmod(control,0o600);self.listener.listen(4)
            thread=threading.Thread(target=self.serve_control,daemon=True);thread.start()
            for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(sig,self.cancel)
            verify_build();identity=discover(self.pid);self.record('waiting',identity=identity,root_pending=False)
            reconnect=None
            while not self.stopped.is_set():
                self.peer_still_exact(identity)
                mode=device_mode()
                if mode=='bootloader':
                    if reconnect is not None and not reconnect_allowed(*reconnect,mode,self.stopped.is_set()):
                        raise RuntimeError('reconnect lacks successful capture/removal evidence')
                    reconnect=self.capture(identity)
                    if self.stopped.is_set():break
                    self.record('waiting-reenumeration',mode=mode,connected=False)
                else:self.record('waiting-'+mode,mode=mode,connected=False)
                self.stopped.wait(1)
            self.record('stopped',enabled=False,connected=False)
            return 0
        except Exception as error:
            self.cancel()
            if prior_read:self.record('failed',enabled=False,connected=False,error=str(error))
            else:
                # Unknown ownership: leave the original journal untouched on every start.
                self.state.update(status='failed',root_pending=True,error=str(error))
                print('previous session journal unreadable/invalid; manual reconciliation required: '+str(error),file=sys.stderr)
            return 1
        finally:
            self.cancel()
            if self.listener is not None:
                self.listener.close()
                try:
                    st=control.lstat()
                    if self.control_inode is not None and (st.st_dev,st.st_ino)==(self.control_inode.st_dev,self.control_inode.st_ino) and stat.S_ISSOCK(st.st_mode):
                        control.unlink()
                except FileNotFoundError:pass
            os.close(lock)

def control_request(command,path=STATE):
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as sock:
        sock.settimeout(2);sock.connect(str(path/'control.sock'));sock.sendall((command+'\n').encode());raw=bytearray()
        while b'\n' not in raw:
            data=sock.recv(4096)
            if not data:raise RuntimeError('control EOF')
            raw.extend(data)
            if len(raw)>65536:raise RuntimeError('control response limit')
        return json.loads(raw.split(b'\n')[0])

def read_status(path=STATE):
    try:
        value=control_request('status',path)
        value['controller_running']=True
        return value
    except (OSError,RuntimeError):
        value=json.loads((path/'state.json').read_text()) if (path/'state.json').exists() else {}
        fd=os.open(path/'controller.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
        running=False
        try:
            try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:running=True
        finally:os.close(fd)
        value.update(controller_running=running,connected=False)
        if not running:
            value['status']='unconfirmed-stale-controller' if value.get('root_pending') else 'stopped'
        return value

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=['run','status','stop'])
    parser.add_argument('--pid',type=int,help='explicit already-running pinned VM PID')
    args=parser.parse_args(argv)
    if PROFILE_FIXTURE or os.getuid()!=PROFILE_UID or os.geteuid()!=PROFILE_UID:
        parser.error('physical profile and its ordinary UID required; never root Python')
    os.umask(0o077);state_dir()
    if args.command=='run':
        if not args.pid or not 0<args.pid<=2147483647:parser.error('run requires --pid')
        askpass=os.environ.get('SUDO_ASKPASS','')
        if not os.path.isabs(askpass) or not os.access(askpass,os.X_OK):
            parser.error('set SUDO_ASKPASS to your reviewed existing executable')
        return Controller(pid=args.pid).run()
    if args.command=='stop':
        try:control_request('stop')
        except (OSError,RuntimeError):pass
        end=time.monotonic()+15
        while time.monotonic()<end:
            value=read_status()
            if not value['controller_running']:break
            time.sleep(.1)
    value=read_status();print(json.dumps(value,indent=2))
    return int(args.command=='stop' and (value.get('root_pending') or value['controller_running']))
if __name__=='__main__':
    try:raise SystemExit(main())
    except (OSError,ValueError,RuntimeError,subprocess.SubprocessError) as error:
        print(str(error),file=sys.stderr);raise SystemExit(1)
