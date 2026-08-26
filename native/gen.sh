#!/usr/bin/env bash
# wasm2c the module into native/gen/ (16 C shards + headers).
# Requires wabt >= 1.0.41 (brew install wabt) for the wasm2c binary; the
# wasm-rt runtime sources are vendored in native/runtime/.
set -euo pipefail
cd "$(dirname "$0")"

WASM=${1:-../module/out/pglite.wasi}
mkdir -p gen
wasm2c "$WASM" --enable-exceptions --module-name=pglite --num-outputs=16 -o gen/pglite.c
echo "generated: $(ls gen | wc -l | tr -d ' ') files in native/gen/"
