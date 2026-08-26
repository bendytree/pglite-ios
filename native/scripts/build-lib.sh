#!/usr/bin/env bash
# Build libpglite.a (wasm2c module + wasm-rt + WASI shim + bridge) for one
# flavor: macos | ios | iossim. Output: build/<flavor>/libpglite.a
# (relative to the repo root).
set -euo pipefail
cd "$(dirname "$0")/.."   # native/
ROOT=..

FLAVOR=${1:?usage: build-lib.sh macos|ios|iossim}
RT=runtime
OUT=$ROOT/build/$FLAVOR
mkdir -p "$OUT/obj"

case "$FLAVOR" in
  macos)
    TARGET_FLAGS=(-mmacosx-version-min=13.0) ;;
  ios)
    # Physical-device config: no 8 GiB guard-page reservation, no
    # SIGSEGV-based stack probe — explicit bounds checks + depth counting.
    # (The mmap+signal default aborts at wasm_rt_init on iOS hardware.)
    TARGET_FLAGS=(-target arm64-apple-ios15.0
                  -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)"
                  -DWASM_RT_USE_MMAP=0
                  -DWASM_RT_MEMCHECK_BOUNDS_CHECK=1
                  -DWASM_RT_STACK_DEPTH_COUNT=1
                  -DWASM_RT_MAX_CALL_STACK_DEPTH=1500
                  -DWASM_RT_INSTALL_SIGNAL_HANDLER=0) ;;
  iossim)
    TARGET_FLAGS=(-target arm64-apple-ios15.0-simulator
                  -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)") ;;
  *) echo "unknown flavor $FLAVOR" >&2; exit 2 ;;
esac

CFLAGS=(-O2 -g "${TARGET_FLAGS[@]}" -I"$RT" -Igen -Ishim -Ibridge)

for f in wasm-rt-impl wasm-rt-mem-impl wasm-rt-exceptions-impl; do
  [ -f "$OUT/obj/$f.o" ] || clang "${CFLAGS[@]}" -c "$RT/$f.c" -o "$OUT/obj/$f.o" &
done
for f in gen/pglite_*.c; do
  o="$OUT/obj/$(basename "${f%.c}").o"
  [ -f "$o" ] && [ "$o" -nt "$f" ] && continue
  clang "${CFLAGS[@]}" -c "$f" -o "$o" &
done
wait
clang "${CFLAGS[@]}" -c shim/wasi_shim.c -o "$OUT/obj/wasi_shim.o"
clang "${CFLAGS[@]}" -c bridge/pglite_bridge.c -o "$OUT/obj/pglite_bridge.o"

if [ "$FLAVOR" = macos ]; then
  ar rcs "$OUT/libpglite.a" "$OUT"/obj/*.o
  clang "${CFLAGS[@]}" test/native_test.c "$OUT/libpglite.a" -o "$OUT/native_test"
  clang "${CFLAGS[@]}" tools/mkdata.c "$OUT/libpglite.a" -o "$OUT/mkdata"
else
  xcrun libtool -static -o "$OUT/libpglite.a" "$OUT"/obj/*.o 2>/dev/null \
    || ar rcs "$OUT/libpglite.a" "$OUT"/obj/*.o
fi
echo "built: $OUT/libpglite.a"
