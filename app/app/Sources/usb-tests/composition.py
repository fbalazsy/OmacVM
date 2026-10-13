#!/usr/bin/env python3
"""Source composition gate (no GUI, authorization, QMP or USB execution)."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
run = (root/'OmacVM/USBRun.swift').read_text()
main = (root/'usb-tests/main.swift').read_text()
assert main.index('Offline mode cannot be combined') < main.index('if CommandLine.arguments.contains("--list")'), '--offline must reject live flags before discovery'
assert 'onUnplugExact' in run, 'registry-generation removal must not unplug a replacement generation'
assert 'USBPrivilegedMachine(' in run, 'USBRun default composition still ordinary-only'
assert 'qemuPID: pid' in run, 'default privileged machine must pin this VM process'
qmp = (root/'OmacVM/USBPrivilegedQMP.swift').read_text()
assert 'expectedPeerPID: identity.pid' in qmp
assert 'executeValue(' in qmp
assert 'defer { q.close() }' in qmp
assert 'USBHelperProcess.inspect' in qmp
machine = (root/'OmacVM/USBPrivilegedMachine.swift').read_text()
assert 'USBHelperLauncher(' in machine and 'USBNativeOperation(' in machine
assert 'Unavailable' not in machine
view = (root/'OmacVM/USBView.swift').read_text()
assert 'captureCandidate' in view, 'ordinary Always picker still misleading for privileged HID'
assert 'administrator' in view.lower(), 'UI must explain administrator trust before Connect'
wire = (root/'OmacVMUSB/USBNativeWire.swift').read_text()
assert 'info.st_uid == getuid()' in wire, 'native creates UID-owned 0600 socket in root directory; root peer is checked separately'
connect_body = wire[wire.index('let fd = Darwin.socket(AF_UNIX'):wire.index('try self.init(connectedDescriptor: fd')]
assert 'F_SETFL, O_NONBLOCK' in connect_body, 'pathname connect itself must be nonblocking, not only established stream'
assert 'visible[location] == nil' not in run, 'active original capture identity must survive incomplete registry re-enumeration'
print('PASS concrete helper/default list composition; short authenticated QMP wiring')
