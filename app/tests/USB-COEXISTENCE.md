# USB coexistence checks

Run from the repository root on an Apple Silicon Mac with Xcode. These commands
build or run inert fixtures only. They do not start the app, QEMU or a VM, scan
USB, change VM choices or install anything.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# Use an existing scratch directory you own; short paths help Unix sockets.
export TMPDIR="${TMPDIR:-/tmp}"
bash app/tests/run-usb-coexistence-offline.sh
python3 app/tests/test-rootguard-owned-release.py
```

The runner prints its new output directory. It compiles actual OmacVMUSB sources
with injected process, transport, registry and guard APIs, then checks typed QMP
socket envelopes and bounded controller input. The combined runner log includes 253 PASS
lines, a 97-case guard matrix and four pre-adoption interop controls. It also checks
canonical uncertain STATUS arriving before guard loss: local authority is revoked,
the session leaves Connected, and no guard Close occurs before a matching drain. Interop
peers model the wire contract; the separate runtime handler tests execute C.
None of these counts is a hardware claim.

Compile all release products and the direct-child live controller, without
executing them:

```sh
export COEX_BUILD_OUT="$(mktemp -d "$TMPDIR/usb-build-parent.XXXXXX")/build"
bash app/tests/build-live-coexistence.sh
```

This builds OmacVM, the Touch ID panel, Dock tile and legacy usb-tests with two
jobs, then links the controller to the actual release OmacVMUSB objects. Do not
run legacy `usb-tests --offline`: that executable does not implement an offline
mode and can read real IORegistry.

Runtime patch/checksum/roundtrip and C fixtures are documented in
[Tests/coexistence/README.md](../runtime/Tests/coexistence/README.md). Existing CI
also runs the HID report-dispatch fixture. New Swift DI checks are in the normal
check job; a fork's workflow may require maintainer approval.

## Hardware tests are opt-in

`build-usb-coexistence-live.sh OUTPUT_DIRECTORY` only compiles the source-linked
controller. Executing it is a separate, explicitly authorised hardware action.
The controller directly spawns its QEMU child: it must not attach to somebody
else's QEMU PID. Its command/target files and stdin operations are bounded and
validated; target input is a hint, never an admission receipt.

Use disposable VM disks, private QMP/QGA sockets, no network or shares, and the
paired runtime. Keep the normal VM and installed app unchanged. Read HID → bulk
→ fresh HID in one process, with unrelated ordinary-device reads throughout.
Record PID/start, exact source/artifact identity, release receipts and restoration.
Do not flash firmware merely to test coexistence. Real firmware flashing, visible
USB UI, physical removal, crash/sleep, installation and update survival are
independent acceptance gates.
