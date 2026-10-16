#!/bin/bash
# Pure DI + inert socketpair checks. Never invokes usb-tests or USBScan.devices.
set -euo pipefail
: "${TMPDIR:?Set TMPDIR to an owned scratch directory}"
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
python3 app/tests/test-rootguard-interest.py
python3 app/tests/test-rootguard-registry.py
python3 app/tests/test-rootguard-live-root.py
out=$(mktemp -d "$TMPDIR/omacvm-usb-coexistence.XXXXXX")
printf 'Evidence directory: %s\n' "$out"
swiftc -num-threads 2 -j2 -warnings-as-errors -DCOEXISTENCE_DI app/app/Sources/OmacVMUSB/*.swift \
  app/tests/LiveControl.swift app/tests/LiveCoexistenceController.swift \
  app/tests/USBRootGuard*.swift app/tests/USBCoexistence*.swift -o "$out/di-tests"
"$out/di-tests" | tee "$out/di.log"
swiftc -num-threads 2 -j2 -warnings-as-errors -emit-library -emit-module -module-name OmacVMUSB \
  app/app/Sources/OmacVMUSB/*.swift -o "$out/libOmacVMUSB.dylib" \
  -emit-module-path "$out/OmacVMUSB.swiftmodule"
swiftc -num-threads 2 -j2 -warnings-as-errors -I "$out" -L "$out" -lOmacVMUSB \
  -Xlinker -rpath -Xlinker "$out" app/app/Sources/OmacVM/QMPConnection.swift \
  app/tests/CoexistenceSocketTests.swift -o "$out/socket-tests"
"$out/socket-tests" | tee "$out/socket.log"
swiftc -num-threads 2 -j2 -warnings-as-errors -I "$out" -L "$out" -lOmacVMUSB \
  -Xlinker -rpath -Xlinker "$out" app/tests/LiveControl.swift app/tests/LiveControlTests.swift -o "$out/control-tests"
"$out/control-tests" | tee "$out/control.log"
