# Rootless vendor-HID runtime patch

`usb-host-hid` is an explicitly selected Darwin report transport. It does not
replace `usb-host`, alter controllers/input, add default device arguments,
dependencies, helpers, services or privilege machinery.

The single policy specification and executable cross-language regression
instructions are in [HID-ADMISSION-CONTRACT.md](HID-ADMISSION-CONTRACT.md).

QEMU commit: `c3d48b7d1e89604920e5b81b91140c2ad39a1943`.
Archive SHA256: `7563781d7dec46f11509801e027f852597235d29ca7afa44a07ed9d8b108b8cd`.
Patch hash is pinned in the recipe, SHA256SUMS and recipe tests.

Run `python3 app/runtime/Tests/test-rootless-hid-recipe.py -v`; optionally set
QEMU_SOURCE_ARCHIVE to the pinned archive. These execute real patch validation
and packaging fragments. The optional compiled shared corpus uses fake native
APIs and actual Swift discovery, never physical USB access. See the contract
for its explicit build inputs and sanitizer variants.

The USB-core transfer/BH/ASYNC/NAK/cancel/reset/SET-length checks are unchanged.
Native SET/GET run synchronously on the existing serial dispatch queue, while
QEMU still receives ASYNC immediately. This avoids report completions consuming
IOHID's single-slot input-notification Mach port. Queued work checks closing,
liveness and transfer epoch before I/O; the existing close barrier drains the
worker before releasing the device or its single transfer buffer. No retry,
queue enlargement, second IOHIDDevice or diagnostic counters are used.

The public synchronous API has no per-request timeout parameter. Apple's
`AppleUserHIDDevice::processReport` uses a driver deadline: the default is
1000 ms, but a valid `RequestTimeout` property can change it (SDK maximum
1200000 ms). Cancel does not interrupt a running block; close must wait for that
operation, not free its state early. This is a source-backed driver bound, not a
universal timeout guarantee for third-party drivers. No timeout property is set.

Run `python3 app/runtime/Tests/test-hid-native-dispatch.py --output NEW_DIR` for
the actual native-wrapper/shared-port regression, API error/GET-length controls,
and queued/running-close checks. It needs only Apple clang/CoreFoundation;
`--variant ubsan` and `--variant asan` enable sanitizers. The unconditional CI
job runs it without QEMU or hardware. `test-hid-sync-core.py --help` describes
the additional real USB-core lifecycle, shipped, scope and native-policy tests
against a retained QEMU build; these are separate from full-runtime builds.

Historical assertions remain preserved: two old busy-control cases expect
obsolete NAK/held-callback scheduling and fail; the separately retained
ASYNC-scheduled oracles passed the prior callback implementation. They must not
be relabeled as current synchronous-worker coverage. The old empty-serial
positive fixture intentionally fails; its separate contract oracle refuses it.

A compiled runtime/capability PASS is not first-use hardware, guest, TCC,
production-signing or deployment acceptance. Open is non-seizing and the
admission check is observational, not a device-purpose attestation or lease.
