#!/bin/bash
# Runs inside the builder container after wasm-build.sh: packs the
# minimal runtime filesystem the pglite.wasi module expects at
# /tmp/pglite into dist. (The source branch references a wasmfs.txt
# manifest that does not exist in-tree; this replaces it. We pack the
# whole share/ + lib/ trees rather than a cherry-picked list —
# correctness first, size later.)
set -euo pipefail

PGROOT=/tmp/pglite
OUT=/tmp/sdk/dist

# wasm-build.sh's tail steps fail on harmless missing optional pieces,
# so we run unconditionally after it; the real success signal is the
# linked module.
if [ ! -f "$PGROOT/bin/pglite.wasi" ]; then
  echo "pack: $PGROOT/bin/pglite.wasi missing — build failed" >&2
  exit 1
fi

# Placeholders the boot path expects to exist (argv[0] is
# $PREFIX/bin/postgres; initdb is probed by pgl_initdb).
touch "$PGROOT/bin/initdb" "$PGROOT/bin/postgres"

# License compliance: the module and the share/ tree are PostgreSQL
# binaries, and the PostgreSQL License requires its copyright notice to
# travel with every copy. Ship the source tree's COPYRIGHT both inside
# the runtime filesystem and next to the artifacts (the release attaches
# it as a standalone file). Fail loudly rather than silently shipping a
# notice-less bundle.
if [ ! -f /workspace/COPYRIGHT ]; then
  echo "pack: /workspace/COPYRIGHT missing — refusing to pack PostgreSQL binaries without their copyright notice" >&2
  exit 1
fi
cp /workspace/COPYRIGHT "$PGROOT/COPYRIGHT"
cp /workspace/COPYRIGHT "$OUT/COPYRIGHT"

cd /
tar -cJf "$OUT/pglite-wasi.tar.xz" \
  tmp/pglite/COPYRIGHT \
  tmp/pglite/bin/pglite.wasi \
  tmp/pglite/bin/initdb \
  tmp/pglite/bin/postgres \
  tmp/pglite/password \
  tmp/pglite/etc/postgresql/locale \
  tmp/pglite/lib/postgresql \
  tmp/pglite/share/postgresql

du -h "$OUT/pglite-wasi.tar.xz"
