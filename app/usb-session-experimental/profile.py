"""Ordinary-user build-time profile compiler. Never imported by privileged code."""
import json
import re
from pathlib import Path

BASE = '/Library/PrivilegedHelperTools'
NAMESPACE = 'org.omacvm.usb-session-experimental'
KEYS = {'kind', 'uid', 'gid', 'qemu_path', 'qemu_real', 'qemu_sha256',
        'qemu_cdhash', 'vm_name', 'qmp_path', 'disk_arg', 'fast_arg',
        'vid', 'pid', 'location', 'bus', 'serial', 'product', 'device_hex',
        'config_hex', 'report_hex', 'application_vid', 'application_pid',
        'application_serial', 'usb_bus', 'user_state', 'argv'}

def validate(p):
    if not isinstance(p, dict) or set(p) != KEYS:
        raise ValueError('exact profile keys required; no defaults')
    if p['kind'] not in ('fixture', 'physical'):
        raise ValueError('explicit fixture or physical kind required')
    for key in ('uid', 'gid', 'vid', 'pid', 'location', 'bus', 'application_vid', 'application_pid'):
        maximum = 255 if key == 'bus' else 65535 if key in ('vid','pid','application_vid','application_pid') else 4294967294
        if type(p[key]) is not int or not 0 < p[key] <= maximum:
            raise ValueError('invalid ' + key)
    argv = p['argv']
    if not isinstance(argv, list) or not 1 <= len(argv) <= 4096 or any(not isinstance(s,str) or not s or not s.isascii() or any(ord(c)<32 or ord(c)==127 for c in s) or len(s)>4096 for s in argv):
        raise ValueError('explicit complete argv required')
    if argv[0] != p['qemu_path']:
        raise ValueError('argv[0] mismatch')
    for flag, value in [('-name',p['vm_name']),('-qmp','unix:'+p['qmp_path']+',server=on,wait=off'),('-netdev',p['fast_arg'])]:
        if argv.count(flag) != 1 or argv.index(flag)+1 >= len(argv) or argv[argv.index(flag)+1] != value:
            raise ValueError('critical argv mismatch: '+flag)
    if sum(argv[i]=='-drive' and argv[i+1]==p['disk_arg'] for i in range(len(argv)-1)) != 1:
        raise ValueError('disk argv mismatch')
    for key in KEYS - {'argv','uid','gid','vid','pid','location','bus','application_vid','application_pid'}:
        value = p[key]
        if not isinstance(value, str) or not value or not value.isascii() or any(ord(c) < 32 or ord(c) == 127 for c in value) or len(value) > 2048:
            raise ValueError('invalid text ' + key)
    for key in ('qemu_path', 'qemu_real', 'qmp_path', 'user_state'):
        if not p[key].startswith('/') or any(x in ('.','..','') for x in p[key].split('/')[1:]):
            raise ValueError('canonical absolute path required: ' + key)
    for key, length in [('qemu_sha256',64),('qemu_cdhash',40),('device_hex',36),('config_hex',68),('report_hex',66)]:
        if not re.fullmatch('[0-9a-f]{%d}' % length, p[key]) or not int(p[key], 16):
            raise ValueError('invalid exact hex: ' + key)
    if any(c in p['qmp_path'] for c in ('"', '\\')):
        raise ValueError('QMP path must be JSON-safe in native evidence')
    if len(p['user_state']) + len('/control.sock') >= 104:
        raise ValueError('user control socket pathname bound')
    if len(p['serial']) > 63 or len(p['product']) > 63 or len(p['qmp_path']) > 100:
        raise ValueError('native buffer bound')
    d, c, r = (bytes.fromhex(p[k]) for k in ('device_hex','config_hex','report_hex'))
    if d[:2] != bytes([18,1]) or d[4:7] != bytes(3) or d[17] != 1 or int.from_bytes(d[8:10],'little') != p['vid'] or int.from_bytes(d[10:12],'little') != p['pid']:
        raise ValueError('device identity/topology mismatch')
    expected = {0:9,1:2,2:34,3:0,4:1,5:1,9:9,10:4,11:0,12:0,13:1,14:3,15:0,16:0,18:9,19:33,23:1,24:34,25:33,26:0,27:7,28:5,29:129,30:3,31:64,32:0,33:1}
    if any(c[k] != v for k,v in expected.items()):
        raise ValueError('only reviewed single vendor HID topology supported')
    # Keep the reviewed vendor-defined usage page, usages and transfer shape.
    # Only the two data report counts may vary (nonzero, <= 60).
    shape = bytes.fromhex('0600ff0901a101150026ff00750895200901810295200901910295010901b102c0')
    if any(a != b for i,(a,b) in enumerate(zip(r,shape)) if i not in (15,21)) or not all(1 <= r[i] <= 60 for i in (15,21)):
        raise ValueError('report outside reviewed vendor-defined shape')
    return p

def generate(p, out):
    validate(p)
    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    defines = {'PROFILE_FIXTURE':int(p['kind']=='fixture'), 'PROFILE_UID':p['uid'], 'PROFILE_GID':p['gid'],
               'PROFILE_UID_TEXT':str(p['uid']), 'INSTALL_DIR':BASE,
               'ACTIVATOR':BASE+'/'+NAMESPACE+'-activate', 'HELPER':BASE+'/'+NAMESPACE+'-helper',
               'STATE_DIR':BASE+'/'+NAMESPACE, 'SOCKET_DIR':BASE+'/'+NAMESPACE+'/run',
               'USB_SOCKET':BASE+'/'+NAMESPACE+'/run/usb.sock',
               'QEMU_PATH':p['qemu_path'], 'QEMU_REAL':p['qemu_real'], 'QEMU_SHA':p['qemu_sha256'],
               'QEMU_CDHASH':p['qemu_cdhash'], 'VM_NAME':p['vm_name'], 'QMP_PATH':p['qmp_path'],
               'QMP_ARG':'unix:'+p['qmp_path']+',server=on,wait=off', 'DISK_ARG':p['disk_arg'], 'FAST_ARG':p['fast_arg'],
               'DEVICE_HEX':p['device_hex'], 'CONFIG_HEX':p['config_hex'], 'PROFILE_VID':p['vid'],
               'PROFILE_PID':p['pid'], 'PROFILE_LOCATION':p['location'], 'PROFILE_BUS':p['bus'],
               'PROFILE_SERIAL':p['serial'], 'PROFILE_PRODUCT':p['product']}
    h = '#pragma once\n/* Generated at build time; administrator reviews compiled authority. */\n'
    for key,value in defines.items():
        h += '#define '+key+' '+(json.dumps(value) if isinstance(value,str) else str(value))+'\n'
    for name,key in [('PROFILE_DEVICE','device_hex'),('PROFILE_CONFIG','config_hex'),('PROFILE_REPORT','report_hex')]:
        h += '#define '+name+'_BYTES {'+','.join('0x%02x'%b for b in bytes.fromhex(p[key]))+'}\n'
    h += '#define PROFILE_ARGV {'+','.join(json.dumps(s) for s in p['argv'])+'}\n'
    (out/'local_pins.h').write_text(h)
    values = {**defines, 'FILTER':'0x03:0x%04x:0x%04x:-1:1|-1:-1:-1:-1:0'%(p['vid'],p['pid']),
              'USB_BUS':p['usb_bus'], 'USER_STATE':p['user_state'], 'APPLICATION_VID':p['application_vid'],
              'APPLICATION_PID':p['application_pid'], 'APPLICATION_SERIAL':p['application_serial']}
    (out/'local_pins.py').write_text('"""Generated user-side values grant no root authority."""\n'+''.join(k+' = '+repr(v)+'\n' for k,v in values.items()))
