# Experimental local USB session (opt-in developer reference)

This directory preserves a local native USB helper, native one-shot supervisor,
and ordinary-user session/lease controller. It is **not** the app's USB feature,
a portable production driver, a publisher/enrollment service, or a flashing tool.
Nothing here runs from OmacVM's build, launcher, installer or GUI by default.
The app's existing `usb-host` path and HID policy are unchanged.

## Authority model

The administrator reviews **one complete build-time profile and the resulting
exact compiled binaries**. The profile pins the ordinary UID/GID, executable
path and realpath, SHA-256, CDHash, complete argv (including VM name, disk,
network and QMP arguments), one physical device's VID/PID/location/bus,
serial/product, and exact device/configuration/report bytes. The profile is
compiled into C. The helper hash is derived from its signed build before the
supervisor is compiled. The install script then embeds both actual hashes.

This is the same explicit local administrator trust as installing previously
reviewed hard-coded pins. Moving those pins to a **build input** does not give
an ordinary user runtime authority: changing JSON, environment, Python values,
CLI arguments or files in the checkout cannot change the installed native
policy. Only a new reviewed build and explicit root installation can do that.
The root code never loads JSON, Python, a user configuration or a plugin.
The root-created immutable `peer.conf` is a per-activation process generation
manifest, not an enrollment/configuration input. It is created after native
authentication in protected ancestry and parsed with a strict bounded schema.

No Apple developer identity is needed. Ad-hoc signing applies only to the new
standalone helper/supervisor; it grants neither publisher trust nor privileges.
Both link only system dylibs (the two third-party libraries are linked
statically), with hardened-runtime signing and no entitlements/RPATH. We do
not sign or replace the app or its VM executable. Existing exact QEMU signing
and loading behavior remains a separately reviewed prerequisite.

### Limits inherited from the local model

* Trust the administrator and the selected ordinary account. This does not
  defend against hostile same-UID code injection, QMP writers, altered loaded
  libraries, or a malicious administrator. Exact image/CDHash checks are not
  whole-process loaded-code attestation. Never claim otherwise.
* Only the reviewed single vendor-defined HID topology is supported: one
  configuration, interface 0/alternate 0, one interrupt IN endpoint 0x81,
  64-byte maximum packet, vendor usage page 0xff00/usage 1, and the supported
  33-byte report layout. The profile validator rejects other layouts.
  It does not auto-enroll devices or loosen protection for keyboards/mice.
* The frame gate bounds parsing and denies bulk/vendor requests, but allowed
  HID reports can still carry device commands. This is **not a read-only or
  firmware-write prevention boundary**. No flash/calibration safety or support
  is asserted. Independently review the physical device and guest software.
* The Python device observer recognizes only the compiled boot/application
  identities. It cannot authorize root capture. Failed/ambiguous observation
  is `unknown`, never proof of physical removal.

## Build and offline tests (ordinary UID only)

Requires Apple Silicon macOS with a compatible Xcode Command Line Tools clang,
SDK, make, ar, codesign and Python 3.9+. It uses only Python's standard library.
Do not run a build, downloader, test runner or Python controller with sudo.
Choose a new private output directory; the build refuses an existing one.

From this directory:

```sh
python3 -B build.py --profile profiles/fixture.json \
  --out build-fixture --cache cache --download
python3 -B build-fixture/source/test.py
```

CI runs these same fixture build/test commands in its own temporary directory,
without sudo or a physical profile. Its existing runner selection and fork
approval rules stay unchanged. `app/runtime/Tests/usbredir/test-ci.py` guards
this wiring; the runtime recipe tests are a separate, download-free step.

The initial `--download` fetches the public, SHA-256-pinned upstream archives.
Subsequent builds omit it and use checksum-verified cache files. Nothing is
fetched at install time. If the selected SDK is incompatible with clang, set
`SDKROOT` to a compatible installed SDK; do not change system tools or skip
compile/link verification. Jobs are bounded to four.

The fixture has invented non-personal identities and nonexistent paths.
`PROFILE_FIXTURE` makes **both native activation entrypoints refuse even if
someone mistakenly installs them**. Its controller also refuses runtime use.
No installer is generated for it. It is runnable *as a build/test fixture*,
not a placeholder advertised as hardware support. The tests may inject fakes
into individual functions; they never disable native runtime guards in the
production binaries.

The offline runner covers strict manifest/generation/peer checks, malformed
frames and maintained-parser serialization, registry/descriptor policy with
fake IOKit/libusb, handoff ownership, postcheck rejection, budgets, exec ACK,
child reaping, EOF/cancel, TERM/KILL, release events, quarantine and reconnect.
It uses real owned AF_UNIX inodes, pipes and inert child executables for the
supervisor/controller lifecycle. QMP replies, USB and identity APIs are mocked.
It runs ordinary-UID refusal probes, not a USB initializer or a real VM/QMP
connection. Native static analyzer diagnostics fail the gate.

## Private physical profile

Start a private file outside the repository using `profiles/fixture.json` only
as the **schema**, replacing every value with independently reviewed real
values and choosing `kind: "physical"`. Merely changing `kind` is not setup.
Do not commit that file, generated headers, binaries, logs or `BUILD.json`.
There is deliberately no automatic probing, enrollment, pin update or trust
fallback. The administrator/developer must obtain and review exact values;
this contribution does not measure hardware for them.

`argv` is the complete ordered vector including argv[0]. Duplicate critical
flags, missing pinned disk arguments and any extra/different running argument
fail native admission. `qemu_path` may be a launcher alias only if it resolves
to `qemu_real`. `qmp_path` is exact; a changed socket path requires a new
reviewed profile. Device descriptors are exact raw bytes, not a measurement
inferred from the synthetic fixture. The application-mode identity is only
for observing a transition; no capture or mode-changing command is sent to it.
`user_state` is a private absolute user directory, separate from the root
state hierarchy. All keys are required; unknown keys fail validation.

```sh
python3 -B build.py --profile /absolute/private/profile.json \
  --out /absolute/private/new-build --cache /absolute/private/source-cache
```

Build produces native binaries, generated user-side modules, actual hashes,
LGPL relinking objects/source, and `install-reviewed.sh` only for a physical
profile. **Build success is not permission to install.** Read [INSTALL.md](INSTALL.md).

## Explicit use after separately accepted installation

First verify the exact running VM/runtime has `usb-redir`, the configured USB
bus and authenticated QMP endpoint. The VM must already be running; this code
never boots/restarts a VM, discovers a PID or changes disk/network/GUI policy.
Use the generated controller under `new-build/source/activation`, not the
unconfigured source checkout. As the pinned ordinary UID, with an existing
reviewed `SUDO_ASKPASS` executable:

```sh
python3 -B /absolute/private/new-build/source/activation/baldur_session.py run --pid PID
# In another terminal, same ordinary account:
python3 -B /absolute/private/new-build/source/activation/baldur_session.py status
python3 -B /absolute/private/new-build/source/activation/baldur_session.py stop
```

`run` stays in the foreground. Ctrl-C and control `stop` close the exact
cancellation pipe. Each capture/reconnect invokes the fixed native supervisor
through real sudo; no sudoers rule or persistent launch job is installed.
Only sudo starts root C, never Python. Bounded diagnostic leases are available
via `baldur_lease.py --pid PID --lease 5..120 --sudo-askpass`. Session lease 0
means until explicit stop, peer loss or helper failure, not a fixed time lease.
Failed or uncertain release may retain supervision indefinitely to fail closed;
there is no promise of bounded successful device restoration.

A connection report requires native postcheck plus observed QOM attachment;
it is **not** guest usability, physical reconnect acceptance or proof of
exclusive ownership against hostile same-UID writers. Successful reconnect
requires prior connected/removal evidence and a clean release, then fresh
IDs and a new native authorization/generation. Unknown creation/deletion
outcomes preserve QMP objects; they never grant deletion authority.

## Socket/release ABI retained

The supervisor alone creates the listener and records its inode, passes it on
**fd 3** through fork/exec, and retains cleanup authority. The helper validates
the inherited bound stream and only closes its copy. Darwin's unsupported
`SO_ACCEPTCONN` check is not used. No preexisting socket is adopted/unlinked.
After `waitpid` confirms the exact child is reaped, only the recorded matching
inode can be removed. Replacement/symlink/unknown inode or uncertain reap
quarantines the session. No recycled PID is signalled after reaping.

`BALDUR2` is the retained private wire schema name, not a publisher namespace.
`started`, `postcheck`, and `released` JSON events retain their exact fields,
including `child_status`. The user controller needs release evidence, accepted
supervisor exit, and observable socket absence before attributable QMP cleanup.
A stale user control socket also requires manual reconciliation, not adoption.

## Controller regression coverage

* An unreadable, malformed or non-object prior journal is preserved. Repeated
  starts refuse unknown ownership instead of overwriting its evidence.
* Readiness rechecks cancellation and child liveness before publishing
  `connected=true`. Publication and cancellation use the same mutex.

The lifecycle suite covers two consecutive starts after journal failures,
stop/child exit during readiness, and concurrent cancellation/publication.
These tests do not replace the separate hardware acceptance below.

## Acceptance boundary

Fixture build/tests establish only the source/build/offline behaviors above.
Root installation, real signature/peer admission, actual IOKit ownership,
USB capture, guest access, unplug/replug, hardware restoration, VM/app/GUI
integration and firmware operations require separate authorization and real
platform testing. They are not accepted by this fixture. Upstream contribution
rules require real test-VM evidence for a supported behavior change; maintainers
must review this as an inert developer/reference addon, not a shipped feature.
No `features.tsv` entry or `omacvm check` feature is added because no normal
feature is enabled or offered. Future integration needs those checks and real
VM acceptance, not just a change to this label.

Our source is covered by the repository's MIT license, except the attributed
Darwin ABI declaration headers, which retain APSL-2.0. Downloaded third-party
source retains its own license; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
