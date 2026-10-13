# USB redirection runtime support

The runtime recipe builds checksum-pinned usbredir 0.15.0 and enables QEMU's
`usb-redir` device. `--without-default-features` otherwise leaves it out even
when libusb is available. The existing `usb-host` path stays enabled.

Only `libusbredirparser.1.dylib` and usbredir's `COPYING.LIB` are added to the
runtime. The host library and test client may be compiled in the private build
but are not shipped. The parser is dynamically linked, relocated and checked
by the existing runtime closure and signing gates. The packager now requires
`--source-usbredir` and `--usbredir-license`; the build script supplies both.
The package fails validation without either USB device capability or a
nonempty regular license file. See `app/THIRD_PARTY_NOTICES.md` for the source
URL, checksum and license.

## Offline regression tests

From the repository root, with Python 3.9 or newer and `/bin/bash`:

```sh
python3 app/runtime/Tests/usbredir/test-ci.py
python3 app/runtime/Tests/usbredir/test-runtime.py
```

These execute the archive validator, argument parser, configure argument
construction, staging, file-set and capability gates in temporary directories.
They do not build QEMU, launch a guest, enumerate USB, or talk to QMP. Text
fixtures exercise packaging logic only, not Mach-O loading or signatures.
CI runs these checks unconditionally in the `check` job, including fork PRs.

The full runtime build also compiles usbredir and runs its upstream filter
and serializer test executables before installing it into a private prefix.
Use the existing runtime build entry point; `OMARCHY_RUNTIME_BUILD_JOBS`
bounds compilation and the usbredir tests (four test workers by default).
The normal build still has to pass all existing QEMU and graphics gates.

## Integration boundary

The recipe supplies a capability, not permission to capture a device. The app
keeps `usb-host` for ordinary devices and uses a separate app-owned native
helper for its narrow vendor-HID route; see [USB devices](../../../../docs/usb.md)
and [ADR 0045](../../../../docs/adr/0045-app-owned-vendor-hid.md). USB remains
experimental and off by default. Explicit Connect and administrator consent,
not the presence of `usb-redir`, authorize the native route.

Recipe tests do not establish helper installation, physical capture, guest
reads or restoration. Existing ad-hoc runtime signing does not solve
hardened-runtime library validation or change netd authorization. Contributors
need no Apple signing identity to run these offline recipe tests.
