#!/usr/bin/env python3
"""Explicit contract examples, not expectations derived from either implementation.
Run only when editing fixtures; both executable adapters consume corpus.plist.
"""
from pathlib import Path
from copy import deepcopy
import plistlib
D=bytes.fromhex('0600ff0901a101150026ff007508953c09018102953c0901910295010901b102c0')
def usage(page=65280,u=1,count=1):
 return dict(PrimaryUsagePage=page,PrimaryUsage=u,DeviceUsagePairs=[dict(DeviceUsagePage=page,DeviceUsage=u)]*count)
def node(cls,parent,props=None,conforms=None):
 return dict(cls=cls,parent=parent,props=props or {},conforms=conforms or [])
base=[node('AppleUserHIDDevice',3,dict(usage(),VendorID=49745,ProductID=5889,SerialNumber='fixture-01',Product='Fixture',Transport='USB',ReportDescriptor=D),['IOHIDDevice']),node('IOUSBHostDevice',0,dict(idVendor=49745,idProduct=5889,bDeviceClass=0,locationID=17825792,**{'USB Address':5,'USB Serial Number':'fixture-01'})),node('IOUSBHostInterface',2,dict(bInterfaceClass=3,bInterfaceSubClass=0,bInterfaceProtocol=0)),node('IOHIDInterface',1,usage()),node('AppleUSBHostCompositeDevice',2)]
rows=[]
def case(name,allow=False,create=None,native=None):
 r=dict(name=name,nodes=deepcopy(base),swift=bool(allow),native=bool(allow if native is None else native),create=int(allow) if create is None else create,open=int(allow if native is None else native))
 rows.append(r);return r
def prop(r,n,k,v):r['nodes'][n-1]['props'][k]=v
def drop(r,n,k):r['nodes'][n-1]['props'].pop(k,None)
case('generic',True)
for n in [0,1,16,17,128,129]: prop(case(f'pairs-{n}',1<=n<=16),1,'DeviceUsagePairs',usage(count=n)['DeviceUsagePairs'])
for n in range(1,6):
 for value,label,allow in [(False,'boolean-false',True),(0,'integer-zero',True),(True,'boolean-true',False),(1,'integer-one',False),(0.0,'float-zero',False),('0','string-zero',False)]:prop(case(f'internal-{n}-{label}',allow),n,'Built-In',value)
 for cls in ['IOHIDLibUserClient','IOUSBHostDeviceUserClient','IOHIDEventService','QEMUUSBClient']:
  case(f'owner-{n}-{cls}')['nodes'].append(node(cls,n))
for k in ['PrimaryUsagePage','PrimaryUsage']:
 for v,label in [(65280.0 if k.endswith('Page') else 1.0,'float'),(True,'bool'),(-1,'negative'),(65536,'large'),('1','string')]:prop(case(f'{k}-{label}'),1,k,v)
for k in ['VendorID','ProductID']:
 for v,label in [(float(base[0]['props'][k]),'float'),(True,'bool'),(0,'zero')]:prop(case(f'{k}-{label}',create=1),1,k,v)
for k in ['idVendor','idProduct']:
 for v,label in [(1,'mismatch'),(float(base[1]['props'][k]),'float'),(True,'bool')]:prop(case(f'{k}-{label}'),2,k,v)
for v,label in [(9,'hub'),(17,'billboard'),(256,'overflow'),(0.0,'float')]:prop(case('root-class-'+label),2,'bDeviceClass',v)
drop(case('root-class-absent',True),2,'bDeviceClass')
for k in ['bInterfaceClass','bInterfaceSubClass','bInterfaceProtocol']:
 prop(case(k+'-float'),3,k,float(base[2]['props'][k]))
for count in [0,1,2]:
 r=case(f'leaves-{count}',count<=1)
 if not count:r['nodes'][3]['parent']=0
 if count==2:r['nodes'].append(node('IOHIDInterface',1,usage()))
for count in [0,2,60,61]:
 r=case(f'providers-{count}',count<=60);r['nodes']=r['nodes'][:4]+[node('AppleUSBHostCompositeDevice',2) for _ in range(count)]
for n,conform in [(1,'IOHIDDevice'),(2,'IOUSBHostDevice'),(3,'IOUSBHostInterface'),(4,'IOHIDInterface')]:
 r=case('subclass-'+str(n));r['nodes'][n-1]['cls']='Special'+conform;r['nodes'][n-1]['conforms']=[conform]
r=case('generic-hid-class',True);r['nodes'][0]['cls']='IOHIDDevice'
for name,n,parent in [('hid-under-provider',1,5),('leaf-under-interface',4,3)]:case(name)['nodes'][n-1]['parent']=parent
case('child-under-leaf')['nodes'].append(node('IOHIDInterface',4,usage()))
for n in [2,3,5]:
 for label,metadata in [('primary-only',dict(PrimaryUsagePage=65280,PrimaryUsage=1)),('pairs-only',dict(DeviceUsagePairs=usage()['DeviceUsagePairs'])),('other-vendor',usage(65281,2)),('empty-pairs',dict(DeviceUsagePairs=[])),('partial-primary',dict(PrimaryUsagePage=65280)),('mismatch-pairs',dict(PrimaryUsagePage=65280,PrimaryUsage=1,DeviceUsagePairs=usage(65281,2)['DeviceUsagePairs']))]:
  r=case(f'optional-{n}-{label}',label in ['primary-only','pairs-only','other-vendor']);r['nodes'][n-1]['props'].update(metadata)
for n in [1,4]:
 for k in ['PrimaryUsagePage','PrimaryUsage','DeviceUsagePairs']:drop(case(f'required-{n}-missing-{k}'),n,k)
for label,value in [('wrong-array',['vendor']),('dictionary',usage()),('pair-float',[dict(DeviceUsagePage=65280.0,DeviceUsage=1)])]:prop(case('pairs-'+label),1,'DeviceUsagePairs',value)
for serial,label,ok in [('', 'empty',False),(' A\nB ','raw',True),('λ雪','unicode',True),('x'*126,'max',True),('x'*127,'long',False),('a\0b','nul',False)]:
 r=case('serial-'+label,ok,create=1);prop(r,1,'SerialNumber',serial)
for extended in [False,True]:
 desc=bytes.fromhex('0600ff')+ (bytes.fromhex('0b010000ff') if extended else bytes.fromhex('0901'))+bytes.fromhex('0601ff')+D[5:]
 for old in [False,True]:
  r=case(('extended' if extended else 'local')+'-page-'+('old' if old else 'new'),old);prop(r,1,'ReportDescriptor',desc)
  if not old:
   for n in [1,4]:r['nodes'][n-1]['props'].update(usage(65281,1))
for label,at,val in [('usage',4,2),('page',1,1),('protected',2,1)]:
 r=case('final-descriptor-'+label,True,create=1,native=False);d=bytearray(D);d[at]=val;r['final']=dict(ReportDescriptor=bytes(d))
for label,at,val in [('protected',2,1),('usage-mismatch',4,2),('overflow',15,255)]:
 r=case('descriptor-'+label);d=bytearray(D);d[at]=val;prop(r,1,'ReportDescriptor',bytes(d))
assert len({r['name'] for r in rows})==len(rows)
Path(__file__).with_name('corpus.plist').write_bytes(plistlib.dumps(rows,fmt=plistlib.FMT_BINARY,sort_keys=True))
print(len(rows),'explicit cases')
