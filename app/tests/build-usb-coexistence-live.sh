#!/bin/bash
# Compile only: this must never launch the live harness or QEMU.
set -euo pipefail
: "${TMPDIR:?Set TMPDIR to an owned scratch directory}"
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
out=${1:?Usage: build-usb-coexistence-live.sh OUTPUT_DIRECTORY}
mkdir -p "$out"
out=$(cd "$out" && pwd)
swiftc -num-threads 2 -j2 -warnings-as-errors -emit-library -emit-module -module-name OmacVMUSB \
  app/app/Sources/OmacVMUSB/*.swift -o "$out/libOmacVMUSB.dylib" \
  -emit-module-path "$out/OmacVMUSB.swiftmodule"
swiftc -num-threads 2 -j2 -warnings-as-errors -I "$out" -L "$out" -lOmacVMUSB \
  -Xlinker -rpath -Xlinker "$out" app/app/Sources/OmacVM/QMPConnection.swift \
  app/app/Sources/OmacVM/USBQMPSocket.swift app/tests/LiveControl.swift app/tests/LiveCoexistenceController.swift app/tests/LiveCoexistence.swift \
  -o "$out/live-coexistence"
shasum -a 256 "$out/live-coexistence" "$out/libOmacVMUSB.dylib"
