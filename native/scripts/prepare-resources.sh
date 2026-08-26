#!/usr/bin/env bash
# Regenerate the Swift package resources from module/out/:
#   Sources/PGliteKit/Resources/pgroot/            runtime FS (share/, lib/)
#   Sources/PGliteKit/Resources/pgdata-pristine.aar  pre-initdb'd PGDATA
# Run after a module rebuild. Requires the macOS native build (mkdata).
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

RES=Sources/PGliteKit/Resources
BUNDLE=module/out/pglite-wasi.tar.xz
[ -f "$BUNDLE" ] || { echo "missing $BUNDLE — run module/build.sh first" >&2; exit 1; }
[ -x build/macos/mkdata ] || { echo "missing build/macos/mkdata — run native/scripts/build-lib.sh macos" >&2; exit 1; }

# runtime FS: everything except the wasm binary (compiled in) and base/
# (created on device or seeded from the pristine archive)
rm -rf "$RES/pgroot" build/pgroot-stage
mkdir -p build/pgroot-stage "$RES/pgroot/tmp"
tar xf "$BUNDLE" -C build/pgroot-stage
rm -rf build/pgroot-stage/tmp/pglite/lib/postgresql/pgxs
rm -rf build/pgroot-stage/tmp/pglite/bin build/pgroot-stage/tmp/pglite/base
cp -R build/pgroot-stage/tmp/pglite "$RES/pgroot/tmp/"

# pristine PGDATA: boot once (in-guest initdb) with the freshly built
# native engine, then pack base/ as an Apple Archive
rm -rf build/pristine-stage
mkdir -p build/pristine-stage
tar xf "$BUNDLE" -C build/pristine-stage
./build/macos/mkdata build/pristine-stage
rm -f build/pristine-stage/tmp/pglite/base/.s.PGSQL.5432* build/pristine-stage/pg.log
rm -f "$RES/pgdata-pristine.aar"
STAGE=build/pristine-stage/tmp/pglite-pack
mkdir -p "$STAGE"
cp -R build/pristine-stage/tmp/pglite/base "$STAGE/base"
# marker proving a PGDATA was seeded from this archive (vs device initdb);
# asserted by testFastBootUsedPristineSeed
touch "$STAGE/base/.pgios-pristine"
aa archive -d "$STAGE" -o "$RES/pgdata-pristine.aar" -a lzma
du -h "$RES/pgdata-pristine.aar"
echo "resources refreshed"