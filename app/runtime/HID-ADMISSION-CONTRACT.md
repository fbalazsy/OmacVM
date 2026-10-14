# Shared narrow vendor-HID admission contract

This is an additive report transport, not a general HID driver, purpose
attestation, exclusive lease or permission framework. Ordinary `usb-host`,
controllers, input devices and app lifecycle are unchanged by this policy delta.
No VID/PID/product-name allowlist or user override is used.

## One bounded technical profile

* Read only the selected physical subtree. Native follows at most 16 parents;
  subtree budget is 64 nodes, depth at most 8. The admitted topology below is
  only four levels deep. Unreadable classes/properties/iterators fail closed.
* Exact `IOUSBHostDevice` root, exactly one direct `IOUSBHostInterface`
  (class/subclass/protocol integer 3/0/0), exactly one direct `IOHIDDevice` or
  `AppleUserHIDDevice`, and zero or one direct childless `IOHIDInterface`.
  Root may additionally have childless `AppleUSBHostCompositeDevice` providers
  within the node budget. Unknown subclasses, nested services, all clients and
  event/input/security/VM owners are not admitted. Entry **names** are not classes.
* `Built-In` absent, CFBoolean false or integer zero only, on every node.
  Numeric policy fields must be nonnegative **integer CFNumber**, not Bool,
  floating (even integral), string or data. Usage fields are bounded to UInt16.
* HID and optional HID leaf require primary vendor page ff00..ffff, usage
  0..ffff, and 1..16 usage pairs, all equal to that primary pair. Leaf and HID
  primary pairs must agree. Ancestors/provider metadata is optional: primary
  page and usage appear together; a present pairs array is nonempty and bounded.
  Pairs are vendor-only and match a primary pair if present. Optional ancestor
  metadata describes that node and need not equal the HID's primary pair.
* Nonzero UInt16 HID VID/PID match both the physical root and requested identity.
  Root device class may be absent; when present it is integer UInt8, not hub9
  or billboard17 (the existing app exclusions). Serial is raw, **nonempty**, at
  most126 UTF-16 units, without embedded NUL; product may be empty but has the
  same length/NUL bound. Transport is exactly USB. Registry generation is exact.
* Descriptor: 1..1024 bytes; one top-level Application Collection; every global
  page and extended local usage page is vendor-only; no unknown items, push/pop
  or long items. Depth<=8, report size1..32/count1..512, total<=64 bytes per
  type/report (including nonzero report ID), at least one input report, no mixed
  numbered/zero reports. The top-level local Usage's page is bound **when that
  Usage occurs**, not rewritten by a subsequent Global UsagePage. That local
  pair must equal HID primary metadata.
* After IOHIDDeviceCreate, re-read identity and require the final descriptor to
  be byte-identical to the descriptor admitted with the registry metadata before
  non-seizing IOHIDDeviceOpen. A changed descriptor is rejected, not reparsed
  under stale metadata. This is observational, not an atomic ownership promise.

The recorded ECU topology uses the admitted generic classes and vendor report
shape. That makes the profile technically compatible; only a future authorized
hardware/guest gate can establish first-use behavior.

## Shared executable oracle

`Tests/hid-policy/make-corpus.py` authors explicit expected cases; it never reads
production code. Its binary plist preserves CF numeric types, raw Unicode and
embedded NUL. Both adapters read the **same plist bytes**:

* `PolicyCorpus.swift`: actual USBScan.device → USBListRows.make → attachArguments,
  checking selectable/free row, exact registry/serial and no hostbus/hostaddr.
* `policy-test.c`: actual production native_open with fake IOKit boundary,
  asserting admission plus Create/Open counters. Post-Create descriptor changes
  correctly have Swift=true/native=false: the later snapshot changed. Static
  admission cases have one common allow/deny expectation.

Run `Tests/hid-policy/run.py --help` for required paths to an already configured
and built pinned QEMU, a staged runtime dependency closure, actual OmacVMUSB
sources, a new output directory, Ninja and SDK. `--variant plain|ubsan|asan`
controls sanitizers. It compiles serially, fences inherited discovery calls,
rejects real IOHID/IORegistry/IOService/IOObject/IOIterator imports in the test
object and executable before running, and never device_adds a real device.
Sanitizers instrument the backend/test translation unit, not all QEMU objects.

`test-rootless-hid-recipe.py` invokes the compiled driver when
HID_POLICY_QEMU_BUILD, HID_POLICY_RUNTIME, HID_POLICY_SWIFT_SOURCE,
HID_POLICY_NINJA and SDKROOT are provided; otherwise that gate explicitly skips.
CI always runs the cheap recipe/hash/negative-packaging and runner tests. Its
compiled shared-corpus gate runs only after a fresh runtime build, with an explicit
SKIP on runtime-cache hits. Relevant admission/runner changes require explicit
compiled validation; this is not automatic composition or transfer-test coverage.

Historical scheduling assertions remain separate from ASYNC-adjusted tests.
The previous empty-serial positive oracle now intentionally fails; its corrected
version rejects empty raw identity. Neither history is silently relabelled.
No offline result proves hardware, guest, TCC, production signing or deployment.
