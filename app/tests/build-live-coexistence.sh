#!/bin/bash
# Build only: never executes OmacVM, usb-tests, QEMU or the live harness.
set -euo pipefail
: "${TMPDIR:?Set TMPDIR to an owned scratch directory}"
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
out=${COEX_BUILD_OUT:?Set COEX_BUILD_OUT to a new owned absolute directory}
case "$out" in /*) ;; *) printf 'COEX_BUILD_OUT must be absolute\n' >&2; exit 2;; esac
# Never overwrite an earlier build.
if [ -e "$out" ]; then printf 'COEX_BUILD_OUT already exists; choose a new directory\n' >&2; exit 2; fi
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
sdk=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p "$out/live"
for product in OmacVM OmacVMTouchIDPanel OmacVMDockTile usb-tests; do
  xcrun swift build --package-path app/app --scratch-path "$out/release" \
    --build-system native --configuration release --jobs 2 \
    -Xswiftc -num-threads -Xswiftc 2 -Xswiftc -j2 --product "$product" \
    > "$out/build-$product.log" 2>&1
  printf 'BUILD_PASS %s\n' "$product"
done
release="$out/release/arm64-apple-macosx/release"
# Exact production release objects, no source stub/replacement module.
xcrun swiftc -sdk "$sdk" -target arm64-apple-macosx15.0 -O -warnings-as-errors \
  -num-threads 2 -j2 -emit-library "$release"/OmacVMUSB.build/*.o \
  -o "$out/live/libOmacVMUSB.dylib" > "$out/build-live-module.log" 2>&1
xcrun swiftc -sdk "$sdk" -target arm64-apple-macosx15.0 -O -warnings-as-errors \
  -num-threads 2 -j2 -I "$release/Modules" -L "$out/live" -lOmacVMUSB \
  -Xlinker -rpath -Xlinker "$out/live" \
  app/app/Sources/OmacVM/QMPConnection.swift app/app/Sources/OmacVM/USBQMPSocket.swift \
  app/tests/LiveControl.swift app/tests/LiveCoexistenceController.swift app/tests/LiveCoexistence.swift \
  -o "$out/live/live-coexistence" > "$out/build-LIVEHARNESS.log" 2>&1
printf 'BUILD_PASS LIVEHARNESS %s/live/live-coexistence (NOT RUN)\n' "$out"
