/*
 * Minimal WASI preview1 host shim for wasm2c-generated modules, backed by
 * POSIX (macOS / iOS). Implements exactly the 36 imports of pglite.wasi.
 *
 * The guest sees two preopened directories:
 *   /tmp -> <root>/tmp   (PGlite runtime FS + PGDATA)
 *   /dev -> <root>/dev   (must contain a `urandom` file; created by init)
 *
 * Guest stdout/stderr are appended to <root>/pg.log.
 */
#ifndef PGIOS_WASI_SHIM_H_
#define PGIOS_WASI_SHIM_H_

#include <setjmp.h>
#include <stdbool.h>
#include <stdint.h>

#include "wasm-rt.h"

#ifdef __cplusplus
extern "C" {
#endif

#define WASI_SHIM_MAX_FDS 256
#define WASI_SHIM_MAX_PREOPENS 4

typedef struct wasi_fd_entry {
  int host_fd;       /* -1 = free slot */
  uint8_t filetype;  /* WASI filetype */
  uint16_t fdflags;  /* WASI fdflags (append tracked here) */
  int preopen;       /* index into preopens, or -1 */
} wasi_fd_entry;

typedef struct wasi_preopen {
  const char* guest_path; /* e.g. "/tmp" */
  char host_path[1024];   /* absolute host directory */
  int host_fd;            /* O_DIRECTORY fd, kept open */
} wasi_preopen;

/* This IS `struct w2c_wasi__snapshot__preview1` (typedef'd in wasi_shim.c);
 * the generated code treats it as opaque. */
struct w2c_wasi__snapshot__preview1 {
  wasm_rt_memory_t* mem; /* guest linear memory; set after instantiate */

  const char** argv;
  int argc;
  const char** envp; /* "K=V" strings */
  int envc;

  wasi_preopen preopens[WASI_SHIM_MAX_PREOPENS];
  int n_preopens;

  wasi_fd_entry fds[WASI_SHIM_MAX_FDS];

  int log_fd; /* host fd receiving guest stdout/stderr; -1 = discard */

  /* proc_exit support: longjmps here when the guest calls proc_exit. */
  bool exit_jmp_armed;
  jmp_buf exit_jmp;
  uint32_t exit_code;
  bool exited;

  bool trace; /* log each syscall to stderr (debug) */
};

typedef struct w2c_wasi__snapshot__preview1 wasi_shim_t;

/* Initialize the shim: opens <root>/tmp and <root>/dev as preopens (creating
 * <root>/dev/urandom), opens <root>/pg.log for guest stdio. argv/envp arrays
 * must outlive the shim. Returns 0 on success, -1 on error (errno set). */
int wasi_shim_init(wasi_shim_t* w,
                   const char* root,
                   const char** argv, int argc,
                   const char** envp, int envc);

void wasi_shim_dispose(wasi_shim_t* w);

#ifdef __cplusplus
}
#endif

#endif /* PGIOS_WASI_SHIM_H_ */
