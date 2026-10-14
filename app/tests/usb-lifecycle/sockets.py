"""Actual QMPConnection + USBQMPMachine + USBSession, inert Unix peers only.
Usage: SDKROOT=... TMPDIR=... python3 sockets.py NEW_OWNED_OUTPUT_DIRECTORY
Compiles exact production transport/startup model bodies (no rewritten methods).
"""
from pathlib import Path
import os, subprocess, shutil, socket, threading, json, tempfile, sys, hashlib
source=Path(__file__).resolve().parent
p=Path(sys.argv[1]).resolve();p.mkdir(exist_ok=False)
package=source.parents[1]/'app';src=package/'Sources/OmacVM'
env=dict(os.environ);assert env.get('TMPDIR'), 'Set TMPDIR to an authorized scratch directory'
def command(cmd, log):
 with (p/log).open('w') as f:r=subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT)
 assert r.returncode==0, (cmd,p/log)
command(['swift','build','--package-path',str(package),'--build-system','native','--scratch-path',str(p/'build'),'--jobs','1','-Xswiftc','-num-threads','-Xswiftc','1','-Xswiftc','-j1','--target','OmacVMUSB'],'module.log')
s=(src/'USBRun.swift').read_text();suffix=s[s.index('struct USBQMPSocket:'):]
(p/'Transport.swift').write_text('import Foundation\nimport Darwin\nimport OmacVMUSB\n'+suffix)
s=(src/'USBView.swift').read_text();body=s[s.index('@MainActor\nfinal class USBListBefore'):s.index('/// "USB Devices":')]
(p/'Before.swift').write_text('import Foundation\nimport Combine\nimport OmacVMUSB\n'+body)
module=p/'build/debug'
cmd=['swiftc','-swift-version','5','-num-threads','1','-j1']
if env.get('SDKROOT'):cmd+=['-sdk',env['SDKROOT']]
cmd+=['-I',str(module/'Modules'),str(src/'QMPConnection.swift'),str(package/'Sources/usb-tests/ReviewHelperError.swift'),str(p/'Transport.swift'),str(p/'Before.swift'),str(source/'SocketLifecycle.swift'),*map(str,(module/'OmacVMUSB.build').glob('*.o')),'-o',str(p/'probe')]
command(cmd,'build.log')
results=[]
modes=['rawCollision','rawSame','watchParentFirst','watchHIDFirst','deleteMalformed','rollbackMalformed','deleteString','rollbackString','deleteText','rollbackText','deleteEvent','rollbackEvent','deleteRejected','rollbackRejected','deleteConfirmed','rollbackConfirmed','deleteRetry','rollbackRetry','rawUnicodeDifferent','rawUnicodeSame']
modes += [f'late-{parent}-{target}-{order}-auto' for parent in ['mac','ask','omarchy'] for target in ['mac','ask','omarchy'] for order in ['parent','hid']]
modes += [f'late-{parent}-{target}-parent-{action}' for parent,action in [('ask','keep'),('ask','always'),('omarchy','disconnect'),('mac','connect'),('mac','connectFailed'),('mac','future')] for target in ['mac','ask','omarchy']]
modes += [f'identity-{kind}-{action}-{gap}-{order}' for kind in ['same','ascii','unicode','product'] for action in ['auto','keep'] for gap in ['none','incomplete','protected'] for order in ['new','remove']]
modes += [f'ordinary-{identity}-{plan}-{order}-{release}' for identity in ['different','same'] for plan in ['ask','mac','omarchy'] for order in ['remove','publish','released'] for release in ['normal','retry']]
for mode in modes:
 private=Path(tempfile.mkdtemp(prefix='hidq-',dir=env['TMPDIR']));path=private/'s';owned=set();calls=[];stop=threading.Event();errors=[];deletes=[]
 server=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);server.bind(str(path));server.listen();server.settimeout(.1)
 def serve():
  try:
   while not stop.is_set():
    try:conn,_=server.accept()
    except socket.timeout:continue
    with conn,conn.makefile('rwb',buffering=0) as f:
     conn.settimeout(8)
     def send(obj):f.write(json.dumps(obj).encode()+b'\r\n')
     send({'QMP':{}});caps=json.loads(f.readline());send({'id':caps['id'],'return':{}})
     raw=f.readline()
     if not raw:continue
     request=json.loads(raw);calls.append(request);command=request['execute'];args=request.get('arguments',{});answer={'id':request['id'],'return':{}}
     if command=='device_add':
      if mode.endswith('-connectFailed'):answer={'id':request['id'],'error':{'class':'GenericError','desc':'fixture rejected'}}
      else:owned.add(args['id'])
     elif command=='device_del':
      deletes.append(command)
      if mode.endswith('Malformed') or (mode.endswith(('Retry','-retry')) and len(deletes)==1):answer.update(error='not a valid rejection or success envelope')
      elif mode.endswith('String'):answer={'id':request['id'],'error':'not a valid rejection'}
      elif mode.endswith('Text'):answer['return']='not a mutation success object'
      elif mode.endswith('Event'):answer['event']='DEVICE_DELETED'
      elif mode.endswith('Rejected'):answer={'id':request['id'],'error':{'class':'GenericError','desc':'still owned'}}
      else:owned.discard(args['id'])
     else:
      detached=mode.startswith('rollback') or (mode.startswith('delete') and bool(deletes))
      answer['return']='' if detached else ''.join('  Device 0.1, Port 1, Speed 12 Mb/s, Product Fixture, ID: '+i+'\n' for i in sorted(owned))
     send(answer)
  except Exception as e:errors.append(repr(e))
 thread=threading.Thread(target=serve);thread.start();home=p/(mode+'-home');home.mkdir()
 try:r=subprocess.run([str(p/'probe'),str(path),mode,str(home/'vm')],env=dict(env,HOME=str(home),CFFIXED_USER_HOME=str(home)),capture_output=True,text=True,timeout=25)
 finally:stop.set();thread.join(timeout=10);server.close();shutil.rmtree(private)
 (p/(mode+'.log')).write_text(r.stdout+r.stderr)
 obs=json.loads((home/'vm/observed.json').read_text()) if r.returncode==0 else {}
 adds=[c for c in calls if c['execute']=='device_add']
 if mode in ['rawCollision','rawUnicodeDifferent']:ok=obs.get('state')=='onMac(remembered: true)' and len(adds)==1 and obs['secondMemoryPlan']=='mac' and not owned
 elif mode in ['rawSame','rawUnicodeSame']:ok=obs.get('state')=='connected' and len(adds)==2 and [c['arguments']['registry-id'] for c in adds]==[101,102]
 elif mode.startswith('ordinary-'):
  _,identity,plan,order,release=mode.split('-')
  expected='asking' if plan=='ask' else 'onMac(remembered: true)' if plan=='mac' else 'connected'
  ok=obs.get('state')=='connected' and obs.get('routed')==expected and obs.get('currentOrdinary') and obs.get('blockedUntilRelease') and obs.get('storedPlan')==plan
  ok=ok and len(adds)==2 and [a['arguments']['driver'] for a in adds]==['usb-host-hid','usb-host']
  if len(adds)==2:
   args=adds[1]['arguments'];ok=ok and args.get('hostbus')==1 and args.get('hostaddr')==8 and 'registry-id' not in args and 'serial' not in args
   trace=[c['execute'] for c in calls];last_delete=max(i for i,c in enumerate(calls) if c['execute']=='device_del')
   ok=ok and calls.index(adds[1])>last_delete and trace[last_delete+1]=='human-monitor-command' and len(deletes)==(2 if release=='retry' else 1)
  if order=='publish':ok=ok and obs.get('delivery')==['publish:3101:true','publish:3102:true','remove:false']
 elif mode.startswith('late-'):
  _,parent,target,order,action=mode.split('-')
  connected=action=='connect' or (action=='auto' and parent=='omarchy' and order=='parent') or (action in ['auto','future'] and target=='omarchy')
  kept=action in ['keep','always','disconnect','connectFailed']
  expected='connected' if connected else 'onMac(remembered: true)' if action=='always' or (not kept and target=='mac') else 'onMac(remembered: false)' if kept else 'waiting'
  expected_adds=(2 if action=='connect' or (parent=='omarchy' and order=='parent' and action=='auto') else 1) if connected else (1 if action in ['disconnect','connectFailed'] else 0)
  expected_parent='mac' if action=='always' else 'omarchy' if action=='future' else parent
  ok=obs.get('state')==expected and len(adds)==expected_adds and obs.get('storedCount')==2 and obs.get('parentPlan')==expected_parent and obs.get('targetPlan')==('omarchy' if kept else target)
  hidadds=[c['arguments'] for c in adds if c['arguments']['driver']=='usb-host-hid']
  ok=ok and len(hidadds)==(1 if connected else 0) and all(a['registry-id']==101 and a['serial'].encode()==b'\xc3\xa9' and 'hostbus' not in a and 'hostaddr' not in a for a in hidadds)
 elif mode.startswith('identity-'):
  _,kind,action,gap,order=mode.split('-');same=kind=='same'
  expected='connected' if not same else 'onMac(remembered: true)' if action=='auto' else 'waiting' if order=='remove' else 'onMac(remembered: false)'
  plan='omarchy' if not same else 'mac' if action=='auto' else 'ask'
  raw='serial-B' if kind=='ascii' else 'e\u0301' if kind=='unicode' else '\u00e9'
  ok=obs.get('state')==expected and len(adds)==(0 if same else 1) and obs.get('plan')==plan and obs.get('storedPlan')==plan and obs.get('currentUTF8')==list(raw.encode())
  ok=ok and all(c['arguments']['driver']=='usb-host-hid' and c['arguments']['registry-id']==102 and c['arguments']['serial'].encode()==raw.encode() and c['arguments']['productid']==(8 if kind=='product' else 7) and 'hostbus' not in c['arguments'] and 'hostaddr' not in c['arguments'] for c in adds)
 elif mode.startswith('watch'):ok=obs.get('state')=='connected' and len(adds)==1 and bool(owned)
 elif mode.endswith('Retry'):ok=obs.get('canConnect') and not obs['canDisconnect'] and not owned and len(deletes)==2 and len(adds)==1
 elif mode.endswith('Confirmed'):ok=obs.get('canConnect') and not obs['canDisconnect'] and not owned
 else:ok=obs.get('state')=='releaseFailed' and obs.get('canDisconnect') and not obs['canConnect'] and bool(owned)
 if mode.startswith('raw'):
  trace=[c['execute'] for c in calls]
  expected_trace=['device_add','human-monitor-command','device_del','human-monitor-command']
  if mode.endswith('Same'):expected_trace+=['device_add','human-monitor-command']
  ok=ok and trace==expected_trace  # No unused pre-delete query; post-delete proof remains.
 expected_questions=1 if mode.endswith(('-keep','-always')) or (mode.startswith('identity-') and '-keep-' in mode) or (mode.startswith('ordinary-') and '-ask-' in mode) else 0
 ok=bool(ok and not errors and r.returncode==0 and obs.get('questions')==expected_questions)
 results.append({'mode':mode,'passed':ok,'exit':r.returncode,'commands':calls,'stillOwned':sorted(owned),'serverErrors':errors,'observation':obs})
 print(('PASS' if ok else 'FAIL'),mode,obs.get('state'))
(p/'results.json').write_text(json.dumps({'buildCommand':cmd,'transport_sha256':hashlib.sha256(suffix.encode()).hexdigest(),'before_sha256':hashlib.sha256(body.encode()).hexdigest(),'results':results},indent=2)+'\n')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
