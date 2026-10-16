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
socket envelopes and bounded controller input. The combined runner log includes 254 PASS
lines, a 97-case guard matrix and four pre-adoption interop controls. It also checks
canonical uncertain STATUS arriving before guard loss: local authority is revoked,
the session leaves Connected, and no guard Close occurs before a matching drain. Interop
peers model the wire contract; the separate runtime handler tests execute C.
The runner also extracts the actual live-root resolver and registry binding into
a fake-SDK fixture: 15 cases cover positive published-root lookup despite unrelated
global-iterator invalidation, refusal/unknown results, reference balance and the
unchanged complete global presence proof. Its summary adds one PASS record; the
15 cases are not 15 additional PASS records. None of these counts is a hardware
claim.

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

## Qualified physical evidence and current limits

Production sources at `6a1a1345b613c69a04d945221ccbe32a5b532d85` completed two
same-QEMU HID/bulk/HID cycles with an unrelated ordinary USB storage attachment
transferring through one O_DIRECT descriptor per stream in an isolated ROOT
launcher/QEMU fixture. ECU reads ran as guest UID 1000; storage reads required
guest root. Matching reads, no storage reset/reopen/close in the second-cycle
trace, checked Close0, lease retirement, process cleanup and unchanged sampled
host storage were verified. Initial root-fixture capture revoked the first guard;
accepted cycles followed established storage capture. This is not normal nonroot
GUI storage-capture acceptance. See [USB acceptance qualifications](../../docs/usb.md#qualified-physical-validation).

The later positive published-live-root resolver fix has offline/build coverage
only, not a new physical execution of its controller bytes. Firmware flashing and
actual GUI automatic routing remain unverified. No installation or deployment is
part of this evidence update.
