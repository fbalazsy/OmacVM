# Native app-owned USB helper — frozen v1

## Packaging interface (implemented)

```sh
python3 app/usb-helper/build.py --out DIR --cache CACHE [--download]
python3 app/usb-helper/test.py [--out DIR --cache CACHE] [--sanitize]
```

Both run as an ordinary user. Build produces **DIR/omacvm-usb-helper** and
**DIR/relink/**. `--download` only fetches missing SHA-256-pinned public archives;
it never installs anything. Cached source archives are read-only inputs. Maximum
build parallelism is four. No Homebrew dylibs: libusb 1.0.30 and usbredir 0.15.0
are linked statically; system Apple frameworks/libSystem/libobjc/libbsm remain
dynamic. Production payload is ad-hoc signed with hardened runtime and no
entitlements. Do not run or distribute a sanitizer payload as root.

**Bundle the complete `relink/` directory with the release**, not just the
executable. It contains LGPL sources, license texts, application object archive,
relink script and instructions. The original native sources are MIT (repository
LICENSE). No Developer ID is required by this local trust model.

## Install prerequisites — app-owned installer

Fixed root: `/Library/PrivilegedHelperTools/org.omacvm.usb`.
Payload: `releases/<lowercase SHA256 of final signed payload>/omacvm-usb-helper`.
The payload must be a single-link regular file, **root-owned mode 0555**. Every
ancestor must be root-owned, non-symlink and not group/other writable; extended
ALLOW ACL entries are refused. The executable independently hashes its installed
bytes against the release directory name. No environment redirects production
paths. The `run` directory, if supplied by the installer, must be **root-owned
0711**. If absent, the helper creates it with this mode after validating the root.

The app installer is in `OmacVMUSB/USBHelperInstall.swift`. Copying into the app bundle
is not privileged installation. Do not execute a user-writable staging binary as
root. Source signing changes the SHA: compute the installed release name after
all signing is finished. Keep the reviewed existing installation untouched.

## CLI

```
--inspect-process PID
--session ATTEMPT_UUID UID APP_PID APP_START_SEC APP_START_USEC APP_VERSION
```

`--inspect-process` does no USB/registry access and returns one JSON object:
`{"schema":1,"pid":123,"uid":501,"start_sec":1,"start_usec":2,"version":3}`.
`version` is Darwin kernel exec generation (flavor17 SPI), not signing version.
All numeric arguments use canonical unsigned decimal; PID/version fit INT_MAX,
UID must be nonzero. UUID is exactly 36 lowercase hex/dash characters.

Session stays foreground and supervises a separately exec'd copy of the same
protected payload. Private `--worker` is root-only, requires inherited FD3 USB
listener and FD4 authenticated parent channel, and is not an application API.
No stdin/FD inheritance is assumed across osascript. Worker launch uses
posix_spawn, CLOEXEC_DEFAULT, only the two explicit descriptors, fixed executable
and minimal environment; no shell or user-provided exec/path is accepted.

## Control stream

Paths: `<root>/run/<uuid>/control.sock` and `usb.sock`. Native attempt directories
are root-owned0711. Sockets are mode0600, owned by the authorized UID. Root
checks app peer PID, real/effective UID, process start and exec generation using
LOCAL_PEERTOKEN plus independent proc_pidinfo. App must verify native root peer.

UTF-8 newline-delimited JSON; maximum **16384 bytes excluding newline**. Exact
keys/types; duplicate keys, floats, booleans as numbers, negative numbers,
overflows, trailing bytes and unknown commands are refused.

First request (numbers are real JSON integers):

```json
{"schema":1,"command":"capture","attempt":"01234567-89ab-cdef-0123-456789abcdef","device":{"registry_id":123,"location":16777216,"vendor":4660,"product":1,"serial":"raw serial"},"qemu":{"pid":1234,"uid":501,"start_sec":1,"start_usec":2,"version":3}}
```

Serial must be nonempty UTF-8, at most255 bytes, without NUL; it is never trimmed.
Registry ID is uint64; location uint32; vendor/product uint16. Vendor/location/
registry ID must be nonzero. QEMU UID equals the authorized app UID. No device
access happens before an authenticated valid capture request. A first cancel is
also accepted, with no USB initialization:

```json
{"schema":1,"command":"cancel","attempt":"01234567-89ab-cdef-0123-456789abcdef"}
```

After capture, only cancel is valid. Any other input, EOF, app/VM generation
change or signal causes release, never a new capture. QEMU actual USB peer is
independently checked against PID/UID/start/exec generation; its executable
path/inode/size/mtime/ctime snapshot is checked throughout the worker lifetime.

## Events

Every event has `schema:1`, exact `attempt`, and `event`:

- `listening`: selected-device prevalidation passed, USB listener is ready. **Not
  transport readiness.** App may now create its own QMP chardev/frontend.
- `postcheck`: exact QEMU socket peer, usbredir ownership handoff, full raw/cached
  descriptor checks and physical-generation postcheck succeeded. App must still
  prove QOM attachment and backend connected; guest read is separate.
- `releasing`: cancellation/teardown is in progress; late child admission is
  reconciled but never forwarded as new readiness after cancellation.
- `released`, with boolean `hid_restored`: worker normal exit after library
  cleanup, confirmed reap, exact owned USB socket inode removed. `false` means
  no proof of same-generation native HID restoration, not that handles persist.
- `failed`, with bounded constant `message`: clean refusal before capture.
- `uncertain`, with bounded constant `message`: cleanup/ownership not proven;
  never substitute helper exit for a release event.

Native transport is single-use, no reconnect. Parent helper retains socket inode
ownership until child reap. Foreign replacement paths are preserved, not deleted.
Physical-location root lock files have a durable active marker before spawn;
only clean native cleanup clears it. Crash/uncertainty blocks reuse pending
explicit maintenance. Empty attempt directories intentionally remain as replay
tombstones. **No automatic quarantine repair/uninstall is provided.**

Startup bounds:30s app rendezvous,10s first request,30s worker readiness. These
are not a transport lease. No total frame count or active lifetime cutoff.
Cancellation grants8s for clean teardown, then TERM and after10s KILL. Forced
termination is uncertain, never released. Wait ownership errors retain root
arbitration without signalling a possibly reused PID.

## Deliberately narrow device policy

One configuration, one nonboot class3/subclass0/protocol0 interface, alt0; one
interrupt IN and optionally one interrupt OUT endpoint, max64-byte packets.
Configuration/interface/endpoint numbers are descriptor-derived, not device pins.
One vendor-defined application collection (pages0xff00–0xffff); byte-aligned
input/output/feature reports up to64 bytes. No report IDs, push/pop, nested/
physical collections, long/unknown HID items, composite devices, keyboard/mouse,
FIDO, consumer/system usages. Unknown topologies are refused, not guessed safe.

Root independently validates registry/interface/session/address identity before
open, after open, after capture and during transport. Raw device/config/report
bytes and libusb cached configuration topology must agree before and after
handoff. Control/interrupt protocol gates derive interface/endpoint/report bounds
from that policy. Vendor device commands, descriptor writes, boot SET_PROTOCOL,
bulk/iso are refused. HID SET_REPORT **can change device state**; this is not a
read-only or flash-safe transport. Firmware/calibration operations are untested.

## Trust and verification boundary

Administrator explicitly trusts the local authorized account/app. These checks
are anti-mistarget and cross-UID controls, not protection from hostile same-UID
code injection or cryptographic device authentication. No publisher identity or
per-machine build profiles are claimed.

Offline tests use real Darwin stream sockets, peer credentials, subprocesses,
ACLs and statically linked usbredirhost without initializing libusb or scanning
IORegistry. They do not prove root install/admin authorization, actual USB claim,
registry layout on a connected device, QEMU integration, HID restore, sleep,
replug, flash, GUI or Intel/universal acceptance. Those gates remain separately
authorized integration tests.
