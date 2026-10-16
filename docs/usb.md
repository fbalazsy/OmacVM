# USB devices in OmacVM.app

USB passthrough is experimental and off by default. In the VM window turn on
**USB devices**, then start the VM. The app asks whether to connect a free device
to Omarchy or keep it on the Mac. It waits until the app or VM is in front.

**Always do this for this device** remembers the answer. **Devices…** lists
remembered devices, plugged-in devices and devices kept by macOS. A remembered
choice applies on the next plug-in; Connect and Disconnect act on the current
attachment. Forget removes the remembered choice. Devices with serial numbers
have separate entries; ordinary devices without one share their model's entry.

A Linux restart keeps a connected device. After a reset, ordinary USB has a
four-second reconnect grace period. A device with another product ID is a new
device and has its own choice. At most four devices connect at once.

## Ordinary USB

Ordinary USB uses QEMU's existing `usb-host` backend and the pinned, unmodified
libusb dependency. Only devices that macOS does not use are offered. Examples
include standalone ST-Link V2 probes, some SDRs, logic analysers, ADB-only phones
and DFU boards. A serial port, mounted disk, audio interface, camera, keyboard,
mouse or security key stays on the Mac, including when it is part of a composite
board. Quit any Mac tool using a device before connecting it.

This is whole-device access: Linux can send commands, reset the device and write
firmware. Connect only devices you would plug into that Linux machine. The
backend can enumerate other devices and retain macOS metadata; selection by bus
and address is not a claim that libusb never touches another device.

## Vendor HID devices

**Vendor HID devices** is a separate per-VM experimental switch, also off by
default. Turn it on before starting the VM. It adds eligible vendor-report HID
boards to the same question, list and remembered-choice flow. No root process,
USB helper, new permission dialog or separate guest service is required.

Eligibility remains narrow: one non-boot HID interface, vendor usage pages,
serial number, bounded coherent descriptor and no protected device or foreign
owner. Keyboards, mice, controllers, security keys and mixed-function devices
remain unavailable. QEMU rechecks the exact registry generation and descriptor
before opening it. A discovery row alone is not permission to open a device.

The guest sees the board's vendor/product/serial and report descriptor, with
reports up to 64 bytes, normally through `/dev/hidraw*`. The native HID open is
nonseizing: macOS retains its driver, and another Mac reader can receive the same
input reports. Do not run a competing Mac device tool. The input queue keeps the
newest 16 reports and drops older or malformed reports rather than disconnecting.

### Switching between HID and ordinary USB

Some boards disappear and return in ordinary bulk/bootloader mode, then return
as HID. Keeping QEMU's ordinary libusb context alive can retain a metadata client
on that returning HID generation. The runtime and launcher coordinate this case
without replacing the ordinary transport or changing libusb.

The launcher and its direct QEMU child bind a lease to measured PID/start times,
a launch identifier, exact root/interface/HID IDs, raw serial, descriptor hash
and session epoch. QEMU attributes its retained cache client and fences its own
ordinary operations. A separate launcher task obtains a nonseizing root-open
witness. Only the combination permits native HID adoption. A PID, client class,
empty transfer count or successful HID open alone is not an admission receipt.

On revocation, new target submissions stop. Native cancellation, queued work and
callbacks drain asynchronously before guard release. Unknown status, a foreign
client, incomplete registry data or an unconfirmed close retains ownership;
Disconnect can retry unresolved release. A new generation cannot inherit an old
lease. A vanished generation may retire only after complete exact-ID absence
checks and executed owned-reference disposal. This is a distinct terminal proof,
not a successful Close return and not permission to thaw a replacement.

This is bounded application coordination, not an atomic kernel USB firewall.
The watchdog revokes after detecting a change. There is one active coordinated
HID lease at a time, and fail-closed bounds of 4096 distinct sessions and retired
leases per process. An unrelated ordinary device keeps its existing path.

The normal runtime build applies the checksum-pinned HID, busy-device and
coexistence patches in that order. The Vendor HID switch still defaults to OFF:
no HID discovery, notifications or native attachment is enabled for that VM.

## Files and troubleshooting

The VM folder contains `usb-enabled`, `usb-vendor-hid` and `usb.json` (remembered
choices, mode 0600). A one-time answer is not saved. Old `usb` choices migrate to
`usb.json` and the original becomes `usb.before-3.0.4`.

`logs/qemu.log` records this start's switches and connection decisions. In Linux,
`lsusb` lists USB devices; drivers and tool-specific udev rules are still needed.
A list entry or QMP object is not proof that the guest tool can transfer data.

Do not interrupt a write or firmware operation to recover USB. If release stays
unresolved, finish the tool's work first, then shut down the VM completely before
retrying. Restarting Linux alone does not destroy QEMU's libusb context. OmacVM
neither restarts the VM automatically nor weakens admission to recover a device.

## Tests and remaining acceptance

See [the offline test instructions](../app/tests/USB-COEXISTENCE.md). Pure Swift
DI/socket fixtures and production-C inert fixtures cover admission, protocol,
ordinary-device continuity, cancellation, failed closes, stale replies and
old-generation disposal without capturing hardware. They do not establish native
driver timing, guest transfers, GUI behaviour or firmware safety.

Physical acceptance must use an isolated test VM and the exact paired launcher
and runtime: read HID, switch to bulk and read, return to a fresh HID generation
and read again without changing QEMU PID/start. Repeat while an unrelated ordinary
device stays attached and transfers before, during and after the transition.
Keep GUI/remembered-choice acceptance, unplug/replug, sleep/crash, firmware flash,
installation and update survival as separate gates. A manual headless controller
using production classes is not a test of the app's visible USB list.

### Qualified physical validation

An isolated ROOT launcher/QEMU pair built from production sources at
`6a1a1345b613c69a04d945221ccbe32a5b532d85` completed two HID -> bulk -> HID
cycles under the same process identities while an unrelated ordinary `usb-host`
storage device remained attached and transferring. ECU reads used guest UID 1000;
the storage reader required guest root and held one O_DIRECT descriptor per
stream, recording 179 and 119 successful samples. Repeated application-page and
fresh native reads matched. The second-cycle trace recorded 3,702 storage data
requests and completions, with no storage reset/open/close/claim/release events.
Checked native and guard Close0, lease retirement, storage removal and test-process
exit were verified. Three host-side 1 MiB storage samples matched their baseline
after return; the primary VM was unchanged. These continuity runs sent no RAM or
flash writes.

This separately authorized root fixture is not acceptance of normal nonroot GUI
storage capture. Earlier nonroot capture was refused as host-owned; initial
storage capture in the root fixture revoked its first native guard, and the two
accepted cycles ran after storage capture was established.

The subsequent live-root resolver correction has behavioral RED/GREEN, 15 inert
resolver/presence cases, the complete offline gate and an optimized controller
build, but no new exact-binary hardware run. It resolves only a positively matched
published USB root; matching misses remain unknown and complete registry traversal
is still required for unregistered-client/absence proofs. Do not attribute the
earlier physical cycles to these new bytes. Firmware-flash acceptance, actual GUI
automatic routing, normal nonroot storage capture, installation, sleep/crash and
update survival remain unverified. This validation update does not deploy a
candidate or require a privileged application helper.
