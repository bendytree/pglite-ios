/*
 * Minimal embedding API for the wasm2c-compiled pglite.wasi module.
 *
 * One handle = one booted single-connection PostgreSQL instance rooted at a
 * host directory `root` that contains the extracted runtime bundle:
 *   <root>/tmp/pglite/...        (from pglite-wasi.tar.xz)
 *   <root>/tmp/pglite/base/...   (PGDATA; created by initdb on first boot,
 *                                 or seeded from pgdata-pristine.tar.xz)
 *
 * Phase 1 surface: simple-protocol text queries. Phase 2 replaces this with
 * a real wire-protocol bridge.
 */
#ifndef PGIOS_PGLITE_BRIDGE_H_
#define PGIOS_PGLITE_BRIDGE_H_

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pgl_db pgl_db;

/* Boot the engine (initdb on first run, resume otherwise), authenticate,
 * and normalize search_path. Returns NULL on failure with a message in
 * errbuf. */
pgl_db* pgl_open(const char* root, char* errbuf, size_t errcap);

/* Execute one simple-protocol query. Result rows are appended to `out` as
 * lines of tab-separated column text ("1\thello\n"), followed by the command
 * tag line ("#SELECT 1\n"). Returns 0 on success; -1 on SQL error (message
 * in `out`); -2 on engine death (instance must be closed). */
int pgl_exec(pgl_db* db, const char* sql, char* out, size_t outcap);

/* Raw wire exchange: send client-message bytes, receive backend bytes.
 * Returns number of reply bytes written to out, or -1 on engine death. */
long pgl_exec_wire(pgl_db* db, const void* payload, size_t payload_len,
                   void* out, size_t outcap);

/* As pgl_exec_wire, but returns a malloc'd reply in *out (caller must
 * pgl_free it). Returns reply length, or -1 on engine death. */
long pgl_exec_wire_alloc(pgl_db* db, const void* payload, size_t payload_len,
                         void** out);

void pgl_free(void* p);

/* Checkpoint and tear down. The data directory remains resumable. */
void pgl_close(pgl_db* db);

#ifdef __cplusplus
}
#endif

#endif /* PGIOS_PGLITE_BRIDGE_H_ */
