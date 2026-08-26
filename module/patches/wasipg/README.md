# Patches

Local fixups applied by `build/build.sh` to the pinned
[electric-sql/postgres-pglite](https://github.com/electric-sql/postgres-pglite)
checkout (`build/versions.env`), kept minimal and intended for
upstreaming.

## Licensing

These files are diffs against — and therefore modifications of —
PostgreSQL / `postgres-pglite` source. **They are governed by the
PostgreSQL License, not by this repository's Apache-2.0 grant**:

    Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
    Portions Copyright (c) 1994, The Regents of the University of California

    Permission to use, copy, modify, and distribute this software and its
    documentation for any purpose, without fee, and without a written
    agreement is hereby granted, provided that the above copyright notice
    and this paragraph and the following two paragraphs appear in all
    copies.

The full text is in the source tree's `COPYRIGHT`, reproduced next to the
build artifacts (`build/out/COPYRIGHT`) and inside
`pglite-wasi.tar.xz`. See also the repository `NOTICE`.

## Contents

| Patch | Touches | What |
| --- | --- | --- |
| `0002-wasi-error-abort-instrumentation-and-sjlj-gate.patch` | `src/backend/utils/error/elog.c` | Gates the WASI `abort()`-on-ERROR path on `WASIPG_SJLJ` so sjlj builds reach `PG_RE_THROW()`; reports the error before dying in non-sjlj builds. |
| `0003-avoid-freopen-stdin-for-wazero.patch` | `pglite-wasm/pg_main.c` | Replaces `freopen(stdin)` (which wazero rejects: `fd_renumber` onto a preopened stdio fd) with an fd-level `close(0)` + `open()`. |
| `0004-sjlj-exnref-build-wiring.patch` | `wasm-build.sh`, `wasm-build/build-pgcore.sh`, `pglite-wasm/build.sh` | `SJLJ=true` build wiring: `-mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false`, `-lsetjmp`, `-DWASIPG_SJLJ`. |
| `0005-enable-sjlj-recovery-block-on-wasi.patch` | `pglite-wasm/pgl_sjlj.c` | Compiles the `sigsetjmp` recovery block (the `PG_exception_stack` hookup) back in for `WASIPG_SJLJ` builds. |
| `0006-arm-sjlj-recovery-for-whole-tick.patch` | `pglite-wasm/interactive_one.c` | Arms the sjlj recovery block at the top of `interactive_one` so the whole tick is covered; adds the side-effect-free `wasipg_flush` export; sends the deferred `ReadyForQuery`, drains a partially-consumed pq receive buffer, and never strands reply bytes in the lock file. |

Patches are applied in order against the same checkout, so each one must
diff against the tree **as left by its predecessors** — not against a
pristine checkout. Regenerating a patch from a clean tree silently
duplicates earlier hunks and makes `git apply` fail at build time.
