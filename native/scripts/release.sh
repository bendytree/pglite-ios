#!/usr/bin/env bash
# Build the release xcframework zip for a tag and print its SwiftPM
# checksum. Usage: release.sh v0.1.0
# Produces build/release/PGliteC.xcframework.zip (debug info stripped,
# COPYRIGHT + NOTICE included, as the PostgreSQL license requires).
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root
VERSION=${1:?usage: release.sh vX.Y.Z}

rm -rf build/ios build/iossim build/macos build/PGliteC.xcframework build/release
PGLITE_DBG=-g0 ./native/scripts/build-xcframework.sh

mkdir -p build/release
cp Sources/PGliteKit/Resources/pgroot/tmp/pglite/COPYRIGHT build/PGliteC.xcframework/
cp NOTICE build/PGliteC.xcframework/
ditto -c -k --keepParent build/PGliteC.xcframework build/release/PGliteC.xcframework.zip

echo
echo "asset : build/release/PGliteC.xcframework.zip ($(du -h build/release/PGliteC.xcframework.zip | cut -f1 | tr -d ' '))"
echo "url   : https://github.com/bendytree/pglite-ios/releases/download/$VERSION/PGliteC.xcframework.zip"
echo "sha   : $(swift package compute-checksum build/release/PGliteC.xcframework.zip)"
