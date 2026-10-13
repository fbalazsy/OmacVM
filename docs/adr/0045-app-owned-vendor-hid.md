# 0045: A narrow vendor-HID route in the USB Devices list

Status: proposed. OmacVM.app only, under the existing experimental USB switch,
off by default.

## Context

Ordinary `usb-host` deliberately leaves devices with macOS drivers alone.
Some vendor-defined HID devices have no keyboard, pointer or security-key
function, but still need a privileged owner to release the macOS HID driver.

[#391](https://github.com/gillesgoetsch/OmacVM/pull/391) was closed over the
scope of this use case and the cost of maintaining substantial root code.
This proposal changes how that path is owned and presented; it does not remove
that maintenance cost or imply that the scope decision has been accepted.

## Decision

- Use the existing USB Devices list and Connect/Disconnect controls. No
  device-specific command, second panel, enrollment or per-machine build.
- Keep ordinary `usb-host` unchanged. A preliminary registry-only check offers
  explicit Connect for a narrow vendor-HID candidate. Class 3 alone is never
  enough. Remembered Always cannot authorize this route; a new physical plug
  requires a new Connect and the macOS administrator prompt.
- Ship one native helper with the app. The app's inline bootstrap stages it
  into a protected root-owned release directory named by its final SHA-256.
  It checks ancestors and ACLs before privileged pathname use, then checks
  the copied bytes. QEMU and the app remain ordinary-user processes.
- The root helper independently validates the physical generation, raw serial,
  descriptors, topology and vendor-only report before and after capture.
  Peer admission uses PID, UID, process start and exec generation. The native
  worker owns libusb and usbredirhost; it receives neither arbitrary commands
  nor user-selected executable paths.
- Connect requires native postcheck and typed QMP attachment/connection evidence
  for the frontend and backend created by this attempt. Matched rejection
  grants no ownership; ambiguous delivery quarantines the attempt. Never delete
  a foreign or uncertain QMP object. Each monitor transaction is short-lived.
- Disconnect requests cleanup. Continue reading late release evidence; require
  native release, reap and owned QMP cleanup rather than treating EOF as success.
  Keep unresolved old generations visible while a replacement is plugged in.
  A missing restoration proof does not mean the Mac has the device again.

This extends an existing app-only switch rather than adding a guest feature,
installer or feature-table entry. Other VM routes are unchanged.

## Alternatives and consequences

Keeping the current refusal has no extra root code to maintain, but does not
serve these devices. Running QEMU as root or broadly detaching HID drivers is
not acceptable. A separate device-specific tool would split consent, lifecycle
and cleanup from the app's existing USB list.

The selected design still adds a privileged native codebase, a bootstrap,
Darwin SPI/registry dependencies and pinned USB libraries. Hashes bind staged
bytes, not a publisher. The administrator trusts the local account and app;
this is not a boundary against hostile code running as that same user.
No Apple Developer credential is needed for this local trust model.

Crash uncertainty fails closed. Root lock markers and replay tombstones can
remain; automatic quarantine repair and uninstall are not provided. Switching
windows does not end an active connection, and active transport has no total
lifetime cutoff. HID SET_REPORT can change device state: the transport is not
read-only and does not promise flash safety.

The runtime builds and packages only usbredir's parser for QEMU. The native
helper statically links libusb and usbredirhost/parser, with complete LGPL
source archives, object files and relinking instructions generated at build
time and bundled for distribution. No compiled dependencies belong in Git.

## Verification

[USB documentation](../usb.md#how-it-was-tested) lists the offline commands.
They exercise policy, streams, cancellation, replacement generations, typed
QMP responses, actual Darwin ACLs, installer predicates, recipe packaging and
fork-safe CI wiring without USB, administrator authorization or a VM.
Real app authorization, Connect, guest reads and same-generation HID restoration
remain separate integration tests; offline checks do not establish those results.
The [native protocol](../../app/usb-helper/PROTOCOL.md) defines the wire and
release contracts.
