"""Bounded native lifecycle evidence shared by session and diagnostic runners."""
import json
import os

class ActivationEvents:
    def __init__(self,process,record=lambda *a,**k:None,lease=0):
        self.process=process;self.record=record;self.lease=lease;self.data=bytearray()
        self.started=False;self.postcheck=False;self.released=False;self.child_status=None;self.failed=False
        os.set_blocking(process.stdout.fileno(),False)
    def drain(self):
        if self.failed:raise RuntimeError('invalid root evidence stream')
        try:self._drain()
        except (OSError,ValueError,RuntimeError):
            self.failed=True;raise
    def _drain(self):
        for _ in range(16):
            try:chunk=os.read(self.process.stdout.fileno(),4096)
            except BlockingIOError:break
            if not chunk:break
            self.data.extend(chunk)
            if len(self.data)>8192:raise RuntimeError('root event buffer overflow')
            while b'\n' in self.data:
                line,_,rest=self.data.partition(b'\n');self.data[:]=rest
                event=json.loads(line)
                if event=={'activation':'started','lease':self.lease} and not self.started and not self.released:self.started=True
                elif event=={'helper':'postcheck'} and not self.postcheck and not self.released:self.postcheck=True
                elif (isinstance(event,dict) and set(event)=={'activation','child_status'}
                      and event['activation']=='released' and type(event['child_status']) is int
                      and -1<=event['child_status']<=255 and not self.released):
                    self.released=True;self.child_status=event['child_status']
                else:raise RuntimeError('unexpected root evidence event')
                self.record('root-evidence',event=event)

def socket_absent(path):
    try:os.lstat(path)
    except FileNotFoundError:return True
    except OSError:return False
    return False
