# Phase 0 report — WASI PGlite feasibility

Date: 2026-08-25. Machine: Apple M4 Max, macOS (Darwin 25.5.0), arm64.

## Verdict: GO

A WASI-targeted PGlite module — real PostgreSQL 17.5 parser/planner/executor —
**with pgvector 0.8.0 statically linked** was built reproducibly on this Mac
and ran `initdb`, DDL, DML, vector similarity queries, and HNSW index builds
under two stock WASI runtimes (Node `node:wasi`/uvwasi for the full wire flow;
wasmtime 48 CLI for module boot). Data persists across module restarts on the
host filesystem. **Every import is `wasi_snapshot_preview1`** — zero
Emscripten/custom imports. The wasm2c → C path also works (see §wasm2c).

Caveats that don't block the gate (details in §Risks):

1. `pgl_shutdown` traps on the *first boot after in-guest initdb* (resume
   boots shut down cleanly). Workaround used: end sessions with `CHECKPOINT`,
   or seed PGDATA from the build's `pgdata-pristine.tar.xz` so initdb never
   runs in production.
2. The session inherits `search_path` residue (`information_schema` on the
   initdb boot, `pg_catalog` on resume boots). One `SET search_path` after
   connect fixes it.
3. The viable build is **not upstream main**. It is the
   `REL_17_5_WASM-pglite` branch of electric-sql/postgres-pglite plus the
   wasipg patch set (see §Survey). Upstream's current branches are
   Emscripten-only; the WASI flavor is community-maintained.

## Survey: where WASI support lives

- **electric-sql/pglite** (main, `faa505ad`, 2026-08-23): npm packages
  0.5.x are Emscripten-only. WASI build scripts (`cibuild/linkwasi.sh`, 796
  lines) existed from PR #311 ("chore: wasi build routing", 2024-09-25,
  author pmp-p) and PR #439 ("wasi comms"), then left this repo in
  `ac7622c` ("Postgres-pglite as submodule", 2025-01-16). PR #433
  ("WIP: wasi-native") was closed 2025-03-31 as "too intrusive".
- **electric-sql/postgres-pglite**: the real home. Branch
  **`REL_17_5_WASM-pglite`** (head `2194acf356e9b7bf7cff29c4ed4bd6b82b93895d`,
  "sync", 2025-07-31) is a pre-patched PG 17.5 tree with an in-tree WASI
  builder (`wasm-build.sh`, `pglite-wasm/`, WASI dlopen shim in
  `wasm-build/sdk_port-wasi/`). The current default branch
  (`REL_18_3-pglite`) and `main` have **no WASI support** — Emscripten only
  (`build-pglite.sh` is pure emcc).
- **moznion/wasipg** (`fa290be`, 2026-08-05): pinned, Dockerized,
  sha256-verified build of that branch with a 5-patch series that makes the
  WASI build production-shaped: real setjmp/longjmp error recovery on
  standardized wasm EH (exnref, wasi-sdk 33/LLVM 22), an 8 MiB shadow stack
  (stock wrapper hardcodes 128 KiB → silent memory corruption under parser
  recursion), an fd-level `freopen(stdin)` fix, and wire-loop fixes plus a
  side-effect-free `wasipg_flush` export. Documented in upstream issue
  [pglite#1071](https://github.com/electric-sql/pglite/issues/1071).
  Without these patches the stock branch build **aborts the instance on any
  SQL ERROR** (verified upstream; issue #1071 shows the A/B) — unusable for
  an app. We built on wasipg.
- **Published artifacts**: none. No npm package or GitHub release (electric-sql
  or moznion) ships a WASI `.wasm`; building from source is required.

## Toolchain (recorded versions)

| tool | version | source |
|---|---|---|
| wasmtime | 48.0.1 (7bac2c277) | Homebrew |
| wabt (wasm2c/objdump/validate) | 1.0.41 | Homebrew |
| node | v24.14.1 (`--experimental-wasm-exnref` required) | preinstalled |
| Docker | 29.1.3, linux/aarch64 (no emulation) | preinstalled |
| portable-sdk (in container) | 3.1.74.12.0 | pinned by wasipg |
| wasi-sdk (in container) | 33.0, clang 22.1.0-wasi-sdk | pinned by wasipg |
| Go (for wasipg's mkdata/smoke) | present | preinstalled |

wasi-sdk was **not** needed on the host — it lives inside the wasipg builder
image (`debian:12` + portable-sdk with its wasi-sdk 25 swapped for stock 33).

## Build

```sh
cd phase0/wasipg && ./build/build.sh        # base bundle, ~3.5 min cold
cd phase0/pgvector-wasi && ./run.sh         # + pgvector, ~1 min warm
```

Artifacts (sha256):

```
6e4f4d38…  wasipg/build/out/pglite.wasi            15,858,654 B  (base)
bd188015…  pgvector-wasi/out/pglite.wasi           16,001,219 B  (with pgvector)
d61457b5…  pgvector-wasi/out/pglite-wasi.tar.xz     3,574,436 B  (runtime FS bundle)
0eaa8422…  wasipg/build/out/pgdata-pristine.tar.xz  1,049,356 B  (pre-initdb'd PGDATA)
```

## Module facts (wasm-objdump/wasm-validate, wabt 1.0.41)

- `wasm-validate --enable-all pglite.wasi` → valid.
- **Imports: 36, all `wasi_snapshot_preview1`** — args/environ get,
  clock_time_get, fd_{advise,allocate,close,datasync,fdstat_get,
  fdstat_set_flags,filestat_get,filestat_set_size,pread,prestat_get,
  prestat_dir_name,pwrite,read,readdir,renumber,seek,sync,tell,write},
  path_{create_directory,filestat_get,open,readlink,remove_directory,rename,
  symlink,unlink_file}, poll_oneoff, proc_exit, sched_yield, random_get.
  No sockets, no threads, no Emscripten JS glue.
- Exports: `memory`, `_start`, `pgl_initdb`, `pgl_backend`, `pgl_shutdown`,
  `pgl_closed`, `use_wire`, `interactive_one`, `interactive_read/write`,
  `get_buffer_size/addr`, `get_channel`, `clear_error`, `wasipg_flush`.
- Memory: single 32-bit memory, initial 363 pages (~22.7 MiB), growable.
- One exception **Tag** — the module uses the standardized exnref
  exception-handling instructions (sjlj lowering). Runtimes must support the
  wasm EH proposal (uvwasi/V8: flag; wasmtime: `-W exceptions=y`; wazero ≥1.12).

## Entry model

WASI *command* with returning `_start`: `_start` runs `main()` which, with
`REPL=N` in the environment, boots and returns without looping. The host then
drives exports directly:

1. `pgl_initdb()` — runs initdb into `$PGDATA` if absent (~10 s), else resumes
   the existing cluster (~0.5 s).
2. `pgl_backend()`, `use_wire(1)` — start the single-connection backend.
3. Wire protocol over a socket-file pump: host writes client bytes to
   `$PGDATA/.s.PGSQL.5432.in`, calls `interactive_one()` (one tick), reads
   server bytes from `.s.PGSQL.5432.out`. Startup/auth (MD5) then normal
   simple/extended protocol. (`interactive_read/write` + `get_buffer_addr`
   exist as an in-memory channel alternative.)
4. Preopens: workdir `tmp/` → `/tmp` (contains `/tmp/pglite` runtime FS +
   PGDATA), a `dev/` dir with a `urandom` file → `/dev`.

Host used: `phase0/host/pglite-host.mjs` (Node ≥ 24,
`--experimental-wasm-exnref`), derived from moznion's published host and
wasipg's wazero engine.

## SQL evidence (verbatim host output)

First boot (in-guest initdb, PG 17.5-wasm32):

```
-> SELECT version()
   row : PostgreSQL 17.5 on aarch64-unknown-none, compiled by clang version
         22.1.0-wasi-sdk (…) , 32-bit
-> CREATE TABLE fruit (id serial primary key, name text, qty int)
   done: CREATE TABLE
-> INSERT INTO fruit (name, qty) VALUES ('apple', 3), ('pear', 7) RETURNING id
   row : 1
   row : 2
   done: INSERT 0 2
-> SELECT * FROM fruit ORDER BY id
   row : 1 | apple | 3
   row : 2 | pear | 7
-> UPDATE fruit SET qty = qty + 10 WHERE name = 'apple' RETURNING name, qty
   row : apple | 13
   done: UPDATE 1
-> SELECT 1/0
   ERR : division by zero (SQLSTATE 22012)
-> SELECT count(*) AS still_alive FROM fruit
   row : 2                                  ← instance survived the ERROR
```

Persistence across three separate module instantiations (same workdir):

```
boot 1: CREATE TABLE fruit …; INSERT ('apple',3),('pear',7); CHECKPOINT
boot 2: SELECT * FROM fruit → apple|3, pear|7 ✓; INSERT ('cherry',42); CHECKPOINT
boot 3: SELECT * FROM fruit → apple|3, cherry|42, pear|7 ✓
```

wasmtime 48 CLI boot (module instantiation + `_start` under the flagship WASI
runtime): `wasmtime run -W exceptions=y --dir …::/tmp --dir …::/dev --env … pglite.wasi`
→ exit 0. (The interactive flow needs export calls between ticks, which the
CLI can't orchestrate; the full SQL runs above used Node's built-in WASI.)

## pgvector: included and working

The WASI flavor has no dynamic loading; its dlopen is a shim that resolves
symbols from a hardcoded table (stock: snowball + plpgsql only). We statically
linked pgvector behind that shim:

- Compiled pgvector 0.8.0 (sha256-pinned tarball) with the SDK's `wasi-c`
  against the installed PG server headers; `_PG_init`/`Pg_magic_func` renamed
  via `-D` to avoid colliding with plpgsql's statically-linked copies.
- Generated a 327-entry dlsym table from `llvm-nm` of `libvector.a`
  (`vector_dlsym.c`), exposed through two new **weak** hooks patched into the
  dlopen shim (`pglite_extra_dlsym`, `pglite_extra_dlopen` — the latter calls
  `vector_PG_init` when `$libdir/vector.so` is "opened"). Weak defaults keep
  the stock build behavior when the object isn't linked.
- Link line gained `${EXTRA_PG_LIBS:-}`; `vector.control` +
  `vector--0.8.0.sql` staged into `share/postgresql/extension/`, plus an empty
  `lib/postgresql/vector.so` so `expand_dynamic_library_name()` finds a file.
- Patches: `pgvector-wasi/patches-pgios.diff` (~30 lines on top of wasipg's
  work tree); build: `pgvector-wasi/run.sh`. Cost: +142 KB module size.

Evidence:

```
-> CREATE EXTENSION vector
   done: CREATE EXTENSION
-> CREATE TABLE items (id serial primary key, e vector(3))
-> INSERT INTO items (e) VALUES ('[1,2,3]'), ('[4,5,6]'), ('[0,0,1]')
-> SELECT id, e, e <-> '[1,2,3]' AS dist FROM items ORDER BY e <-> '[1,2,3]' LIMIT 2
   row : 1 | [1,2,3] | 0
   row : 3 | [0,0,1] | 3
--- restart (new module instance, same workdir) ---
-> SELECT extname, extversion FROM pg_extension
   row : vector | 0.8.0                      ← extension persisted
-> SELECT id, e <-> '[1,2,3]' AS dist FROM items ORDER BY dist
   row : 1 | 0    row : 3 | 3    row : 2 | 5.196152422706632
-> CREATE INDEX ON items USING hnsw (e vector_l2_ops)
   done: CREATE INDEX
-> SET enable_seqscan = off
-> SELECT id FROM items ORDER BY e <-> '[4,5,6]' LIMIT 1
   row : 2                                   ← HNSW index scan works
```

## wasm2c smoke test (Phase 1 preview)

- `wasm2c pglite.wasi --enable-exceptions -o pglite.c` (wabt 1.0.41): OK in
  1.7 s → **182 MB** `pglite.c` + 50 KB header. Note `--enable-all` is
  rejected ("limited set of features") — pass exactly `--enable-exceptions`.
- Host clang (macOS arm64, Apple clang) compiles the generated C:
  `-O0` in 25.8 s (75 MB object), **`-O2` in 89 s (23.7 MB object)** on the
  M4 Max. `nm -u` on the object shows exactly the 36 WASI imports
  (`w2c_wasi__snapshot__preview1_*`), libc basics, and `wasm_rt_*` runtime
  functions — nothing else to implement.
- wabt ships the wasm-rt runtime (`wasm-rt-impl.c`, `wasm-rt-mem-impl.c`,
  **`wasm-rt-exceptions-impl.c`**) — exception support exists in the C
  runtime, so the exnref-based error recovery carries over to the AOT path.
  A WASI shim (uvwasi or wabt's `wasi-rt`) is Phase 1 work.

## Risks for Phase 1 (iOS)

1. **exnref is load-bearing.** PostgreSQL error recovery = setjmp/longjmp
   lowered onto wasm EH. Whatever executes the module on iOS (wasm2c output,
   or an interpreter/AOT runtime) must implement the standardized EH proposal.
   wasm2c's support is marked *experimental* — its correctness under PG's
   error storm needs the wasipg conformance-style test early in Phase 1.
   (A no-sjlj build avoids EH entirely but any ERROR kills the instance —
   not acceptable.)
2. **Shadow stack.** The module was linked with an 8 MiB shadow stack after
   128 KiB was shown to silently corrupt globals under parser recursion
   (issue #1071 §2). The wasm2c/native build must preserve ≥8 MiB and PG's
   `max_stack_depth` should be set below it.
3. **Memory.** ~23 MiB initial, grows with work (HNSW builds, sorts;
   `maintenance_work_mem` etc. apply). wasm32 caps at 4 GiB. Budget ~64–256
   MiB resident for real workloads — fine for iOS, but memory-pressure
   handling is Phase 3 as planned.
4. **First-boot shutdown trap + search_path residue** (caveats 1–2 above).
   For iOS, ship `pgdata-pristine.tar.xz` (1 MB) and only ever use the resume
   path — this also cuts first-launch time from ~10 s (in-guest initdb) to
   ~0.5 s. Still worth root-causing the trap (indirect call through a stale
   atexit/on_proc_exit pointer) upstream.
5. **Filesystem semantics.** All I/O is plain WASI preopens — maps cleanly to
   an app-sandbox directory. No mmap, no threads, no sockets, no signals
   imports. `poll_oneoff`, `fd_datasync`, `path_rename` must behave correctly
   in the chosen WASI shim (uvwasi does). The socket-file wire pump does
   real file I/O per exchange; Phase 2 should prefer the in-memory
   `interactive_read/write` + `get_buffer_addr` channel.
6. **Wire-loop discipline.** `interactive_one()` is not an idempotent poll —
   drive it exactly per the wasipg findings (use `wasipg_flush` for drains,
   seal exchanges at ReadyForQuery). Reuse their pump logic in the Swift
   bridge.
7. **Single connection, single session.** One in-flight query; app-side
   serialization required (fine for the stated use case).
8. **Maintenance surface.** The WASI flavor lives on a non-default branch
   (PG 17.5) + a third-party patch set; PG 18 upstream has no WASI support
   yet. Pin everything (wasipg already does) and budget for owning the patch
   stack. Licenses: PostgreSQL License (ship COPYRIGHT), pgvector same.

## Recommended next step

Proceed to Phase 1 with the wasm2c path:

1. Vendor `pgvector-wasi/out/pglite.wasi` + bundle; wasm2c → C; compile for
   arm64 device + simulator (measured host cost: 89 s at `-O2`; a single
   ~24 MB object — check post-strip binary size against App Store limits,
   and `wasm2c --num-outputs` if incremental builds matter).
2. Link uvwasi (or wabt's wasi-rt) mapped to the app sandbox; port
   `pglite-host.mjs`'s boot/pump logic to Swift; `SELECT 1` end-to-end.
3. Gate on a PG-error-storm test against the wasm2c build (exnref
   correctness), mirroring wasipg's conformance suite.

Effort estimate for Phase 1: **1–2 weeks**. The unknowns that made this risky
are resolved (module exists, imports are pure WASI, EH strategy known); the
remaining work is mechanical (wasm2c build plumbing, WASI shim wiring, Swift
pump port), with one real risk to burn down early: wasm2c's experimental
exception handling under load.
