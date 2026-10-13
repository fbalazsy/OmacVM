#!/usr/bin/env python3
"""Explicit profile UID one-shot lease. Root is ONLY the installed native activator.
No firmware/guest commands, SSH, installations, broad USB APIs or persistent jobs.
"""
import argparse
import errno
import json
import os
import re
import selectors
import signal
import socket
import stat
import subprocess
import sys
import time
import uuid
from enum import Enum, auto

from local_pins import ACTIVATOR, USB_SOCKET, QMP_PATH, FILTER, USB_BUS, PROFILE_UID, VM_NAME, PROFILE_FIXTURE
from activation_evidence import ActivationEvents, socket_absent
ALLOWED={'query-name','query-chardev','qom-list','qom-get','chardev-add','device_add','device_del','chardev-remove'}

def bounded_notice(text,fd=1):
    """Best-effort diagnostic, never stdio buffering or regular-file writes."""
    try:
        mode=os.fstat(fd).st_mode
        if not (stat.S_ISFIFO(mode) or stat.S_ISSOCK(mode) or os.isatty(fd)):return False
        data=(text+'\n').encode('utf-8')
        if len(data)>4096:return False
        os.set_blocking(fd,False)
        return os.write(fd,data)==len(data)
    except (OSError,ValueError):return False

def sudo_command(identity,lease,askpass=False):
    if type(lease) is not int or not 5<=lease<=120:raise ValueError('lease must be 5..120 seconds')
    return ['/usr/bin/sudo',*(['-A'] if askpass else []),'--',ACTIVATOR,'--activate',str(identity['pid']),str(identity['sec']),str(identity['usec']),str(identity['version']),str(lease)]

def connect_retry(path,factory=None,clock=time.monotonic,sleep=time.sleep,budget=8.0):
    factory=factory or (lambda:socket.socket(socket.AF_UNIX,socket.SOCK_STREAM))
    end=clock()+budget
    while clock()<end:
        sock=factory()
        try:
            sock.settimeout(max(.01,min(2.0,end-clock())))
            sock.connect(path)
            return sock
        except OSError as error:
            sock.close()
            if not isinstance(error,ConnectionRefusedError) and error.errno!=errno.ECONNREFUSED:raise
            sleep(min(.1,max(0,end-clock())))
    raise TimeoutError('QMP contention: retry budget exhausted; no command replayed')

class QMPRejected(RuntimeError):
    """Matching error reply: this mutation was definitively rejected."""
class QMPAmbiguous(RuntimeError):
    """Mutation may have reached QEMU; labels alone cannot attribute it."""
class Ownership(Enum):
    NOT_SENT=auto()
    UNKNOWN=auto()
    CREATED=auto()
    REJECTED=auto()
    ABSENT=auto()

class QMP:
    def __init__(self,identity,connector=connect_retry,run=subprocess.run):
        self.identity=identity;self.connector=connector;self.run=run;self.deadline=float("inf")
    def limit_until(self,deadline):self.deadline=min(self.deadline,deadline)
    def __call__(self,op,args=None):
        if op not in ALLOWED:raise ValueError('operation outside one-shot scope')
        end=min(self.deadline,time.monotonic()+8)
        def time_left():
            left=end-time.monotonic()
            if left<=0:raise TimeoutError('QMP absolute budget exhausted')
            return left
        sock=(self.connector(QMP_PATH,budget=time_left()) if self.connector is connect_retry else self.connector(QMP_PATH));delivering=False
        try:
            i=self.identity
            # Authenticate THIS connected socket's audit token/PID/version, not
            # just the pathname. Never transmit a QMP command before success.
            self.run([ACTIVATOR,'--peer',str(sock.fileno()),str(i['pid']),str(i['sec']),str(i['usec']),str(i['version'])],pass_fds=(sock.fileno(),),check=True,timeout=time_left(),stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            time_left();buffer=bytearray();total=0
            def receive():
                nonlocal total
                while b'\n' not in buffer:
                    remaining=end-time.monotonic()
                    if remaining<=0:raise TimeoutError('QMP read deadline')
                    sock.settimeout(remaining);chunk=sock.recv(4096)
                    if not chunk:raise ConnectionError('QMP EOF')
                    buffer.extend(chunk);total+=len(chunk)
                    if total>1048576:raise ValueError('QMP reply budget exceeded')
                line,_,rest=buffer.partition(b'\n');buffer[:]=rest
                value=json.loads(line)
                if not isinstance(value,dict):raise ValueError('QMP object expected')
                return value
            if 'QMP' not in receive():raise ValueError('QMP greeting missing')
            result=None
            for name,arguments in [('qmp_capabilities',None),(op,args)]:
                token=uuid.uuid4().hex;request={'execute':name,'id':token}
                if arguments is not None:request['arguments']=arguments
                remaining=end-time.monotonic()
                if remaining<=0:raise TimeoutError('QMP write deadline')
                delivering=name==op
                sock.settimeout(remaining);sock.sendall((json.dumps(request)+'\r\n').encode('ascii'))
                for _ in range(4096):
                    reply=receive()
                    if reply.get('id')==token:break
                else:raise ValueError('QMP event budget exceeded')
                if 'error' in reply:raise QMPRejected('QMP '+name+': '+json.dumps(reply['error']))
                if 'return' not in reply:raise ValueError('QMP reply missing return')
                result=reply['return']
            return result
        except QMPRejected:raise
        except Exception as error:
            if delivering:raise QMPAmbiguous('QMP delivery unknown: '+str(error)) from error
            raise
        finally:sock.close()

class OwnedDevices:
    """Single adapter ledger, NOT exclusion of hostile same-UID QMP writers.

    Successful replies are attributable only under the stated no-hostile-writer
    threat model. Unknown creation outcomes never acquire deletion authority.
    """
    def __init__(self,call,nonce,sleep=time.sleep,clock=time.monotonic):
        if not re.fullmatch('[0-9a-f]{32}',nonce):raise ValueError('invalid lease nonce')
        self.call=call;self.char='omacvm-usb-session-'+nonce+'-c';self.device='omacvm-usb-session-'+nonce+'-d'
        self.char_state=Ownership.NOT_SENT;self.device_state=Ownership.NOT_SENT
        self.sleep=sleep;self.clock=clock
    def chars(self):return {x['label'] for x in self.call('query-chardev')}
    def devices(self):return {x['name'] for x in self.call('qom-list',{'path':'/machine/peripheral'})}
    def create(self,field,op,args):
        setattr(self,field,Ownership.UNKNOWN)
        try:self.call(op,args)
        except QMPRejected:
            setattr(self,field,Ownership.REJECTED);raise
        except Exception:
            # Even an untyped adapter failure conveys no attribution proof.
            raise
        else:setattr(self,field,Ownership.CREATED)
    def attach(self):
        if self.char in self.chars() or self.device in self.devices():raise RuntimeError('lease ID collision; no changes allowed')
        self.create('char_state','chardev-add',{'id':self.char,'backend':{'type':'socket','data':{'addr':{'type':'unix','data':{'path':USB_SOCKET}},'server':False}}})
        self.create('device_state','device_add',{'driver':'usb-redir','id':self.device,'bus':USB_BUS,'chardev':self.char,'filter':FILTER})
        if self.device not in self.devices() or self.char not in self.chars():raise RuntimeError('QMP attach readback failed')
    def cleanup(self):
        # Preserve both ends if an unknown frontend may reference the backend.
        if Ownership.UNKNOWN in (self.char_state,self.device_state):
            return ['QMP delivery/ownership unconfirmed; resources preserved']
        if self.device_state==Ownership.REJECTED:
            return ['frontend definitively rejected; foreign collision and backend preserved']
        errors=[];end=self.clock()+5
        if isinstance(self.call,QMP):self.call.limit_until(end)
        try:
            if self.device_state==Ownership.CREATED:
                if self.device in self.devices():
                    self.device_state=Ownership.UNKNOWN
                    try:self.call('device_del',{'id':self.device})
                    except QMPRejected:raise
                    except (OSError,RuntimeError,ValueError):pass # read back only, no replay
                    for _ in range(30):
                        if self.device not in self.devices():break
                        if self.clock()>=end:raise TimeoutError('owned device removal unverified')
                        self.sleep(.1)
                    else:raise TimeoutError('owned device removal unverified')
                self.device_state=Ownership.ABSENT
            if self.char_state==Ownership.CREATED:
                if self.char in self.chars():
                    self.char_state=Ownership.UNKNOWN
                    try:self.call('chardev-remove',{'id':self.char})
                    except QMPRejected:raise
                    except (OSError,RuntimeError,ValueError):pass
                if self.char in self.chars():raise RuntimeError('owned chardev removal unverified')
                self.char_state=Ownership.ABSENT
        except Exception as error:errors.append(str(error))
        return errors

def inspect(pid):
    out=subprocess.check_output([ACTIVATOR,'--inspect',str(pid)],text=True,timeout=15)
    i=json.loads(out)
    if i.get('pid')!=pid or i.get('qmp')!=QMP_PATH:raise RuntimeError('native identity mismatch')
    for key in ['pid','sec','usec','version']:
        if type(i.get(key)) is not int or i[key]<0:raise RuntimeError('invalid native identity')
    return i

def wait_ready(process,lease,cancelled,events=None):
    # Authorization may wait for the user; root only exists after sudo approves.
    end=time.monotonic()+180
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout,selectors.EVENT_READ)
        events=events or ActivationEvents(process,lease=lease)
        while time.monotonic()<end and not cancelled():
            events.drain()
            if events.started:return
            if process.poll() is not None:raise RuntimeError('sudo/activator exited before readiness')
            selector.select(.1)
    raise TimeoutError('authorization cancelled or timed out')

def wait_socket(process,cancelled):
    end=time.monotonic()+5
    while time.monotonic()<end and not cancelled():
        if process.poll() is not None:raise RuntimeError('activator exited before socket')
        try:
            s=os.lstat(USB_SOCKET)
            if not stat.S_ISSOCK(s.st_mode) or s.st_uid!=PROFILE_UID or stat.S_IMODE(s.st_mode)!=0o600:raise RuntimeError('unexpected protected socket metadata')
            return
        except FileNotFoundError:time.sleep(.05)
    raise TimeoutError('protected helper socket not ready')

def main(argv=None):
    parser=argparse.ArgumentParser(description='Explicit SyntheticVendorHID lease to existing OmacVM Fixture (no firmware commands).')
    parser.add_argument('--pid',type=int,required=True,help='explicit existing OmacVM Fixture QEMU PID; no discovery/restart')
    parser.add_argument('--lease',type=int,required=True,help='5..120 seconds, no automatic renewal')
    parser.add_argument('--sudo-askpass',action='store_true',help='use real sudo -A with your existing SUDO_ASKPASS program')
    args=parser.parse_args(argv)
    if PROFILE_FIXTURE or os.getuid()!=PROFILE_UID or os.geteuid()!=PROFILE_UID:parser.error('run as ordinary profile UID, never sudo this Python script')
    if not 0<args.pid<=2147483647 or not 5<=args.lease<=120:parser.error('invalid PID or lease (5..120)')
    if args.sudo_askpass:
        ap=os.environ.get('SUDO_ASKPASS','')
        if not os.path.isabs(ap) or not os.access(ap,os.X_OK):parser.error('SUDO_ASKPASS must name your existing absolute executable; no password is read by this runner')
    elif not sys.stdin.isatty():parser.error('interactive terminal required, or use --sudo-askpass')
    cancelled=[False];process=None
    def stop(_sig,_frame):
        cancelled[0]=True
        # Deliver EOF immediately even while a bounded QMP call is outstanding.
        if process is not None:
            try:process.stdin.close()
            except OSError:pass
    for sig in [signal.SIGINT,signal.SIGTERM,signal.SIGHUP]:signal.signal(sig,stop)
    owned=None;errors=[];helper_exit=None;events=None;released=False
    try:
        identity=inspect(args.pid);call=QMP(identity)
        if call('query-name').get('name')!=VM_NAME:raise RuntimeError('authenticated VM name mismatch')
        if os.path.lexists(USB_SOCKET):raise RuntimeError('protected socket already exists; no stale-path deletion')
        owned=OwnedDevices(call,uuid.uuid4().hex)
        bounded_notice(json.dumps({'lease':args.lease,'pid':args.pid,'device_id':owned.device,'chardev_id':owned.char,'status':'requesting-sudo'}))
        if cancelled[0]:raise RuntimeError("cancelled before authorization")
        process=subprocess.Popen(sudo_command(identity,args.lease,args.sudo_askpass),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,close_fds=True)
        events=ActivationEvents(process,lease=args.lease)
        wait_ready(process,args.lease,lambda:cancelled[0],events);wait_socket(process,lambda:cancelled[0])
        if cancelled[0]:raise RuntimeError('cancelled before QMP attachment')
        owned.attach()
        bounded_notice('QMP objects attached; guest usability and HID restoration NOT verified. Ctrl-C ends this lease.')
        end=time.monotonic()+args.lease+3
        while not cancelled[0] and process.poll() is None and time.monotonic()<end:
            events.drain();time.sleep(.1)
    except Exception as error:errors.append(str(error))
    finally:
        # EOF tells the native supervisor to signal/reap ONLY its own helper.
        if process is not None:
            try:process.stdin.close()
            except OSError:pass
        if process is not None:
            try:helper_exit=process.wait(timeout=130)
            except subprocess.TimeoutExpired:errors.append('sudo/activator did not exit; owned QMP IDs retained, no unrelated process signalled')
            try:
                if events is not None:events.drain()
                released=(helper_exit in (0,1,124) and events is not None and events.released
                          and not events.failed and not events.data and socket_absent(USB_SOCKET))
            except (OSError,ValueError,RuntimeError) as error:errors.append(str(error))
            finally:process.stdout.close()
            if not released:errors.append('native release/socket absence unconfirmed; QMP resources retained')
            if helper_exit not in (None,0):errors.append('sudo/activator exit '+str(helper_exit))
        # Parent's real evidence requires helper release/rematch BEFORE QMP
        # deletion; otherwise device_del causes transport EOF during cleanup.
        if owned is not None and (process is None or released):
            errors.extend(owned.cleanup())
    bounded_notice(json.dumps({'activation_exit':helper_exit,'errors':errors,'hardware_acceptance':'NOT VERIFIED'}))
    return 1 if errors else 0

if __name__=='__main__':raise SystemExit(main())
