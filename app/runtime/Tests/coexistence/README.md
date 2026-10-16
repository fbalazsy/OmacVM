# Darwin USB coexistence runtime tests

The normal runtime recipe applies `qemu-usb-session-accounting.patch` after the
existing HID and busy-device patches. `inputs.json` contains only portable source
pins and affected-file checksums, not developer paths or historical test results.
The feature remains behind the VM's default-OFF Vendor HID switch.

## Small inert checks

```sh
python3 app/runtime/Tests/coexistence/test-recipe.py
# QEMU_BASE: read-only QEMU c3d48b7d1e89604920e5b81b91140c2ad39a1943
# after OmacVM's exact-bus, HID and busy-device patches.
python3 app/runtime/Tests/coexistence/verify-finish.py --source "$QEMU_BASE"
python3 app/runtime/Tests/coexistence/run-candidate.py \
  --source "$QEMU_BASE" --out "$NEW_OUTPUT"
```

The verifier checks the baseline and patch, applies a temporary roundtrip, then
reconstructs and executes the exact normal recipe's USB patch block and checksum
helper. It compares all eight resulting source files with their pins. It never
sources the whole build script. The candidate runner copies the three affected
baseline files and runs eight actual ordinary function-path cases plus the
pthread ledger under ASan/UBSan. Both require only Python's standard library,
`patch`, a C compiler and macOS's normal command-line tools.

`run-dispatch.py --source PATCHED_HW_USB --out NEW_OUTPUT` checks ISO completion;
add `--completions` for control/data completion. `run-native.py` extracts native
close with inert cancel/drain/close APIs. No libusb context, IOKit scan or QEMU
main is invoked by these fixtures.

## Actual QEMU-core fixtures

For reviewers retaining a build of the pinned QEMU, these runners accept explicit
read-only build paths. A build record is a JSON array of `{name, command}` rows;
`host-coexistence` supplies the actual compiler argv, including absolute include
paths to that reviewer's source/build/dependencies, before `-c`. The link-command
file contains that build's QEMU link argv as shell-quoted text. Neither file is
committed. Output directories must be new and owned by the caller.

```sh
python3 app/runtime/Tests/coexistence/run-qmp.py \
  --source "$PATCHED_HW_USB" --build-record "$BUILD_RECORD" --out "$QMP_OUTPUT"
python3 app/runtime/Tests/coexistence/run-native-tree.py \
  --source "$PATCHED_HW_USB" --build-record "$BUILD_RECORD" --out "$TREE_OUTPUT"
python3 app/runtime/Tests/coexistence/run-native-bridge.py \
  --source "$PATCHED_HW_USB" --build-record "$BUILD_RECORD" --out "$BRIDGE_OUTPUT"
python3 app/runtime/Tests/coexistence/run-core-cycle.py \
  --source "$PATCHED_HW_USB" --build-record "$BUILD_RECORD" \
  --link-command "$LINK_COMMAND" --runtime-lib "$RUNTIME_LIB" --out "$CORE_OUTPUT"
```

QMP tests execute actual handlers and QDict/JSON against inert task, registry,
clock and USB boundaries. Tree/bridge tests extract unchanged production bodies.
The core fixture compiles whole changed ordinary/native units with real QEMU
QOM, USBPacket, BH and dispatch. Every public libusb export is inert; the real
libusb dylib is removed from the copied fixture closure. Unresolved imports are
checked and unexpected registry fallthrough aborts. It covers same-process
HID/bulk/HID, unrelated ordinary B traffic, held drains, reentrant completion,
failed submit/config/reset/stream cleanup, foreign clients and gone-generation
proofs. Changed fixture units use ASan/UBSan; retained QEMU core/dependency objects
are not sanitizer-rebuilt and leak detection is disabled for lifetime tombstones.

These runners are optional retained-build developer checks, not a claim that a
fresh checkout has a prebuilt QEMU core or that every CI run executes them.
The unconditional CI job runs recipe checks, Swift DI and HID report dispatch.
See [the launcher tests](../../../tests/USB-COEXISTENCE.md) for release compilation
and hardware boundaries. A passing inert B cycle is not physical B continuity.
