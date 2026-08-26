#!/usr/bin/env bash
# Package device + simulator + macOS static libs as PGliteC.xcframework at
# build/PGliteC.xcframework (the path the root Package.swift references).
set -euo pipefail
cd "$(dirname "$0")/.."   # native/
ROOT=..

./scripts/build-lib.sh macos
./scripts/build-lib.sh ios
./scripts/build-lib.sh iossim

HDRS=$ROOT/build/headers
rm -rf "$HDRS" "$ROOT/build/PGliteC.xcframework"
mkdir -p "$HDRS"
cp bridge/pglite_bridge.h "$HDRS/"
cat > "$HDRS/module.modulemap" <<'EOF'
module PGliteC {
    header "pglite_bridge.h"
    export *
}
EOF

xcodebuild -create-xcframework \
  -library "$ROOT/build/ios/libpglite.a" -headers "$HDRS" \
  -library "$ROOT/build/iossim/libpglite.a" -headers "$HDRS" \
  -library "$ROOT/build/macos/libpglite.a" -headers "$HDRS" \
  -output "$ROOT/build/PGliteC.xcframework"
echo "built: build/PGliteC.xcframework"
