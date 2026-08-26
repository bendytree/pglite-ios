# Phase 1 report — native iOS module + Swift bridge

Date: 2026-08-26. Machine: Apple M4 Max, macOS (Darwin 25.5.0), Xcode 26.6
(iOS SDK 26.5), wabt 1.0.41.

## Verdict: COMPLETE

The wasm2c-compiled PGlite module (PostgreSQL 17.5 + pgvector 0.8.0, from
Phase 0) runs natively on macOS and the **iOS simulator**, driven from
**Swift**. All Phase 1 exit criteria met and exceeded: not just `SELECT 1` —
the full SQL suite (DDL/DML, error recovery, transactions, pgvector + HNSW,
restart persistence) passes as XCTests on an iPhone 16 Pro simulator
(iOS 18.6):

```
Test Case '-[PGliteKitTests.PGliteKitTests testPgvector]' passed (1.901 seconds).
Test Case '-[PGliteKitTests.PGliteKitTests testSelectOne]' passed (1.516 seconds).
Test Case '-[PGliteKitTests.PGliteKitTests testSQLAndPersistence]' passed (1.727 seconds).
** TEST SUCCEEDED **
```

Each test boots a fresh cluster — in-guest **initdb takes ~1.5 s** in the
simulator (~1 s native macOS; it was ~10 s under Node/V8 in Phase 0 — the
AOT build is ~6–7× faster than the JIT runtime path).

## What was built

```
phase1/
  gen/            wasm2c output: 16 C shards (182 MB total) + headers
  shim/           WASI preview1 → POSIX shim (~700 lines): the module's 36
                  imports; preopens /tmp + /dev under a caller-chosen root;
                  lowest-free fd table (initdb's close(0)/open replay needs
                  it); readdir cookies; poll_oneoff as sleep/always-ready
  bridge/         pgl_open/pgl_exec/pgl_exec_wire/pgl_close: instantiate,
                  _start → pgl_initdb → pgl_backend → MD5 auth → socket-file
                  wire pump (port of the Phase 0 host); every guest entry is
                  wrapped in wasm_rt_impl_try() + a proc_exit longjmp
  test/           native macOS smoke suite (22 statements, 2 boots)
  swift/PGliteKit Swift package: PGliteC.xcframework (ios-arm64,
                  ios-arm64-simulator, macos-arm64) + PGlite class + XCTests;
                  4.9 MB runtime FS as package resources (share/, lib/ —
                  bin/ and base/ excluded: the module is compiled in and
                  PGDATA is created on device)
  scripts/        build-lib.sh (per-flavor), build-xcframework.sh
```

Swift call surface today:

```swift
let db = try PGlite(root: sandboxDir)   // seeds runtime FS, initdb/resume
try db.rows("SELECT 1")                  // [["1"]]
db.close()                               // CHECKPOINT + teardown, resumable
```

## Evidence chain

1. **Native suite** (`build/macos/native_test`): 22 statements across two
   boots, `PASSED (0 failures)`, 1.5 s wall including initdb. Covers:
   version check (`PostgreSQL 17.5 … 32-bit`), CREATE/INSERT/SELECT/UPDATE
   with RETURNING, `SELECT 1/0` → `SQLSTATE 22012` with the instance
   surviving (wasm2c's exception handling carries the exnref sjlj recovery),
   `CREATE EXTENSION vector`, HNSW index build + index scan, BEGIN/ROLLBACK,
   and cross-boot persistence.
2. **swift test** (macOS slice): 3 tests, 0 failures, 3.5 s.
3. **xcodebuild test** on iPhone 16 Pro simulator: `** TEST SUCCEEDED **`
   (log: `phase1/ios-test.log`).

## Numbers

| metric | value |
|---|---|
| wasm2c generation | 1.7 s → 182 MB C (16 shards) |
| compile, all shards -O2 (per flavor) | ~26–39 s wall (parallel) |
| linked test binary (simulator, incl. XCTest glue) | 23.5 MB (18.4 MB __TEXT) |
| stripped native binary | 21.0 MB |
| runtime FS resources | 4.9 MB (share 2.8 + lib 1.0 + tz 1.3) |
| initdb boot | ~1 s native, ~1.5 s simulator |
| resume boot + queries (testSQLAndPersistence, 2 boots) | 1.1 s macOS / 1.7 s simulator |
| app-size budget | ~21 MB binary + 4.9 MB resources (or 1 MB pgdata-pristine to skip initdb) |

## Design decisions

- **Custom WASI shim over uvwasi.** iOS is POSIX; the module's 36 imports
  map directly (openat/renameat/preadv/…). This avoids building libuv for
  iOS. Semantics were validated by running the identical module + suite that
  passed under uvwasi (node) and wazero in Phase 0 — same behavior observed
  through this shim on both platforms.
- **wasm-rt config: defaults** — guard-page memory checks + signal-handler
  stack exhaustion (mmap ~8 GiB VA reservation, SIGSEGV/SIGBUS handler
  installed by `wasm_rt_init`). Fastest option; verified on macOS +
  simulator.
- **Close = `CHECKPOINT` + teardown**, never `pgl_shutdown` (Phase 0 finding:
  its exit hooks trap through a stale indirect call on first-boot
  instances). The data directory is crash-consistent at every commit anyway;
  CHECKPOINT just makes the next boot's redo trivial.
- **`SET search_path = public, "$user"`** issued by `pgl_open` (Phase 0
  finding: initdb/single-user boots leave `information_schema` /
  `pg_catalog` residue).

## Risks / open items for Phase 2–3

1. **Physical-device validation.** Everything iOS-side ran on the simulator
   (no device attached to this Mac). Two things to verify on hardware, both
   with documented fallbacks:
   - the ~8 GiB PROT_NONE reservation for guard pages (fallback:
     `-DWASM_RT_USE_MMAP=0 -DWASM_RT_MEMCHECK_BOUNDS_CHECK=1`);
   - in-process SIGSEGV handler coexistence with crash reporters (fallback:
     `-DWASM_RT_STACK_DEPTH_COUNT=1` with a raised
     `WASM_RT_MAX_CALL_STACK_DEPTH`, run on a dedicated big-stack thread).
2. **Wire transport is still file-based** (`.s.PGSQL.5432.in/.out` under the
   sandbox). Works, but every exchange is 2 file writes + reads. The module
   exports an in-memory channel (`interactive_read/write`,
   `get_buffer_addr/size`) — switch in Phase 2 and drop per-query I/O.
3. **Simple protocol only.** `pgl_exec` returns text rows. Phase 2: speak
   the extended protocol through `pgl_exec_wire` (already exposed) with
   PostgresNIO's codecs — parameterized queries, binary formats, typed
   decoding, async API.
4. **Single connection, not thread-safe.** One in-flight query per instance;
   confine to an actor.
5. **Memory ceiling not yet enforced**: linear memory grows on demand
   (wasm32 cap 4 GiB). Phase 3: cap max_pages + configure PG's
   shared_buffers/work_mem for mobile budgets.
6. **xcframework carries -g objects** (523 MB on disk). Harmless to app size
   (linker strips), but CI should build a stripped variant for distribution.

## Recommended Phase 2 scope

Swift wire-protocol bridge on `pgl_exec_wire`/in-memory channel:
parameterized queries (Parse/Bind/Execute), type codecs (reuse PostgresNIO),
error mapping, async actor API, plus the pgdata-pristine fast-boot path.
Estimate: **~1 week**, no known unknowns left in the stack.

---

# Phase 2 addendum — wire bridge, typed API, device validation

Date: 2026-08-26 (same day, continued).

## Verdict: COMPLETE — including physical-device validation

All 11 XCTests (extended protocol, typed params, transactions, error
mapping, pgvector KNN with vector parameters, persistence, pristine fast
boot) pass on **macOS**, the **iPhone 16 Pro simulator**, and a **physical
iPhone 17 Pro** (`** TEST SUCCEEDED **`, ~0.8 s per test on device,
`phase1/ios-device-test.log`).

## What changed since the Phase 1 report

1. **In-memory transport.** The bridge now uses the module's CMA channel
   instead of socket files: request bytes are written into guest memory at
   offset 1 + `interactive_write(len)`; the reply appears in-place at
   offset `get_channel()` (= request len + 2) with length
   `interactive_read()`. Oversized replies and deferred ReadyForQuery
   flushes still spill to the `.out` file, so the pump drains CMA first,
   then the file. Zero file I/O on the hot path.
2. **Guest bug found & fixed (upstreamable).** The WASI dlopen shim's
   library table was a tentative **1-element array** (`dict_t* dltab[]`)
   indexed past its end, with slot 0 never assigned — lookups dereferenced
   a NULL dict, i.e. guest address 0, which under the CMA transport holds
   live request bytes → wild loads → trap on `CREATE EXTENSION`. Fixed in
   the guest (`pgvector-wasi/patches-pgios.diff`); under socket files it
   silently read zeros, which is why Phase 0/1 never saw it.
3. **Swift wire bridge** (no third-party deps): `Wire.swift` encodes
   Parse/Bind/Describe/Execute/Sync and decodes RowDescription/DataRow/
   CommandComplete/ErrorResponse. `PGliteDatabase` (an actor) exposes
   `execute(sql, [PGValue?])` with text-format parameters (`$1…`), typed
   row access (`int/double/bool/text/uuid/bytes/vector`), `PGError` with
   SQLSTATE, `withTransaction`, and `exec` for multi-statement scripts.
4. **Pristine fast boot.** `pgdata-pristine` ships as a 2.4 MB Apple
   Archive resource (`aa archive -a lzma`), extracted with the
   AppleArchive framework on first boot — no in-guest initdb. Boot cost
   dropped from ~1.5 s to ~0.3 s (test-observed, includes runtime-FS
   copy). Verified by asserting PG_VERSION's mtime is archive-time, not
   now.
5. **Device validation (the Phase 1 open risk — confirmed and closed).**
   On iPhone hardware the wasm-rt default config (8 GiB guard-page
   reservation + SIGSEGV stack probe) **aborts at startup**, exactly as
   flagged. The device slice now builds with `WASM_RT_USE_MMAP=0`,
   `WASM_RT_MEMCHECK_BOUNDS_CHECK=1`, `WASM_RT_STACK_DEPTH_COUNT=1`
   (depth 1500), `WASM_RT_INSTALL_SIGNAL_HANDLER=0` — explicit bounds
   checks, malloc/realloc memory, no signal handlers. Simulator and macOS
   keep the fast guard-page config. Device throughput with bounds checks
   is ~0.8 s per full test — no perceptible penalty at this workload.
6. **Device test harness.** SwiftPM test bundles can't run on device
   destinations ("tool-hosted testing is unavailable"), so
   `phase1/devicehost/` (xcodegen spec) generates a minimal signed host
   app + hosted unit-test target reusing the same test sources. Signing:
   automatic, team 768Z86F8ET (the `com.allstarapps.*` wildcard team
   profile already covered the device).

## Remaining for Phase 3 (hardening)

- Binary formats + richer type codecs (arrays, numeric, jsonb) — text
  format is correct but costs parsing on both sides.
- Memory ceiling (`max_pages`) + PG tuning (shared_buffers, work_mem) for
  mobile budgets; background/foreground checkpoint policy.
- Root-cause the first-boot `pgl_shutdown` trap upstream (harmless with
  the CHECKPOINT-close + pristine-seed flow, but worth fixing).
- CI: scripted rebuild of module → wasm2c → xcframework; stripped
  distribution build; upstream the dltab and sjlj patches.
- Depth-1500 stack ceiling: exercise worst-case recursion (deeply nested
  expressions) on-device; raise with a dedicated big-stack thread if hit.

## Localhost wire server (added on request)

`PGliteServer` (Network.framework) exposes the engine as a real PostgreSQL
server on `127.0.0.1` so ordinary Postgres drivers can connect with a
normal connection string. Verified over real TCP by four XCTests (macOS +
simulator): query round-trip via simple protocol, wrong-password
rejection, actor/TCP clients sharing one database, and rollback of a
transaction abandoned by a vanished client.

Security model (iOS loopback is device-global — any app on the device can
reach an open port):
- **Possession of `server.connectionString` is the capability.** The MD5
  handshake is verified host-side (constant-time) against app-configured
  credentials before any byte reaches the engine; default credentials are
  a random 72-char per-launch password. The engine's own password check is
  a stub upstream, which is why auth lives in the server layer.
- Ephemeral random port by default; server runs only while started; one
  client at a time (a second connection is refused).
- All clients (and the app's own `PGliteDatabase` calls) share the single
  backend session, serialized through the actor. A client that disconnects
  mid-transaction gets its transaction rolled back automatically.
- SSLRequest/GSSENCRequest answered with "no" (plaintext loopback);
  drivers must use `sslmode=disable` or default-negotiate.
