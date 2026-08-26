/*
 * Embedding bridge for the wasm2c-compiled pglite.wasi module.
 * Boot recipe and socket-file wire pump ported from phase0/host/pglite-host.mjs
 * (which follows wasipg's wazero engine).
 */
#include "pglite_bridge.h"

#include <errno.h>
#include <fcntl.h>
#include <setjmp.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <CommonCrypto/CommonDigest.h>

#include "pglite.h"
#include "wasi_shim.h"
#include "wasm-rt-impl.h"

/* Size of the module's low-memory communication zone (CMA_MB=12 at build
 * time; requests start at guest offset 1, replies at request_len+2). */
#define CMA_ZONE_BYTES (12u * 1024u * 1024u)

struct pgl_db {
  wasi_shim_t wasi;
  w2c_pglite inst;
  bool instantiated;
  char root[512];
  char io_in[640];
  char io_out[640];
  bool dead;
  /* stable storage for argv/env pointers passed to the shim */
  const char* argv[4];
  const char* envp[16];
};

/* ---------------- guarded guest calls ---------------- */

/* Every entry into generated code must arm both the trap/unwind target
 * (wasm_rt_impl_try) and the shim's proc_exit jump. */
#define GUEST_CALL(db, expr, on_fail)                        \
  do {                                                       \
    wasm_rt_trap_t _code = (wasm_rt_trap_t)wasm_rt_impl_try(); \
    if (_code != WASM_RT_TRAP_NONE) {                        \
      on_fail;                                               \
    } else if (setjmp((db)->wasi.exit_jmp) == 0) {           \
      (db)->wasi.exit_jmp_armed = true;                      \
      expr;                                                  \
      (db)->wasi.exit_jmp_armed = false;                     \
    } else {                                                 \
      (db)->wasi.exit_jmp_armed = false;                     \
    }                                                        \
  } while (0)

/* ---------------- small utils ---------------- */

static void be32(uint8_t* p, uint32_t v) {
  p[0] = (uint8_t)(v >> 24);
  p[1] = (uint8_t)(v >> 16);
  p[2] = (uint8_t)(v >> 8);
  p[3] = (uint8_t)v;
}

static uint32_t rd32(const uint8_t* p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
         ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static int write_file(const char* path, const void* data, size_t len) {
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return -1;
  ssize_t r = write(fd, data, len);
  close(fd);
  return r == (ssize_t)len ? 0 : -1;
}

/* read whole file and unlink it; returns bytes or -1 if absent */
static long read_and_remove(const char* path, uint8_t** buf_io, size_t* cap_io,
                            size_t used) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return -1;
  struct stat st;
  if (fstat(fd, &st) < 0) {
    close(fd);
    return -1;
  }
  size_t need = used + (size_t)st.st_size;
  if (need > *cap_io) {
    size_t ncap = *cap_io ? *cap_io : 4096;
    while (ncap < need) ncap *= 2;
    uint8_t* nb = realloc(*buf_io, ncap);
    if (!nb) {
      close(fd);
      return -1;
    }
    *buf_io = nb;
    *cap_io = ncap;
  }
  ssize_t r = read(fd, *buf_io + used, (size_t)st.st_size);
  close(fd);
  unlink(path);
  return r < 0 ? -1 : (long)r;
}

/* does buf contain a complete ReadyForQuery ('Z') frame? */
static bool has_rfq(const uint8_t* buf, size_t len) {
  size_t off = 0;
  while (len - off >= 5) {
    uint32_t n = rd32(buf + off + 1);
    if (n < 4 || off + 1 + n > len) break;
    if (buf[off] == 'Z') return true;
    off += 1 + n;
  }
  return false;
}

/* ---------------- wire pump (in-memory CMA channel) ---------------- */

/* Request bytes go into the module's communication zone at guest offset 1
 * (interactive_write(len) publishes them); the reply appears at guest
 * offset get_channel() with length interactive_read(). Oversized replies
 * and deferred ReadyForQuery flushes spill to the socket-out file, so both
 * sources are drained (CMA first — file bytes are always the tail). */

/* grow-and-append helper */
static int append_bytes(uint8_t** buf_io, size_t* cap_io, size_t* used_io,
                        const void* src, size_t n) {
  size_t need = *used_io + n;
  if (need > *cap_io) {
    size_t ncap = *cap_io ? *cap_io : 4096;
    while (ncap < need) ncap *= 2;
    uint8_t* nb = realloc(*buf_io, ncap);
    if (!nb) return -1;
    *buf_io = nb;
    *cap_io = ncap;
  }
  memcpy(*buf_io + *used_io, src, n);
  *used_io = need;
  return 0;
}

/* Drain reply bytes from the CMA channel, then the spill file. */
static int drain(pgl_db* db, uint8_t** buf, size_t* cap, size_t* used) {
  int got_any = 0;
  uint32_t wsize = 0;
  bool trapped = false;
  GUEST_CALL(db, wsize = w2c_pglite_interactive_read(&db->inst),
             { trapped = true; });
  if (trapped) return -1;
  if (wsize > 0) {
    uint32_t ch = 0;
    GUEST_CALL(db, ch = (uint32_t)w2c_pglite_get_channel(&db->inst),
               { trapped = true; });
    if (trapped) return -1;
    wasm_rt_memory_t* mem = db->wasi.mem;
    if ((int32_t)ch > 0 && (uint64_t)ch + wsize <= mem->size) {
      if (append_bytes(buf, cap, used, mem->data + ch, wsize)) return -1;
      got_any = 1;
    }
    /* reset cma_wsize so the next drain doesn't re-collect */
    GUEST_CALL(db, w2c_pglite_interactive_write(&db->inst, 0),
               { trapped = true; });
    if (trapped) return -1;
  }
  long got = read_and_remove(db->io_out, buf, cap, *used);
  if (got > 0) {
    *used += (size_t)got;
    got_any = 1;
  }
  return got_any;
}

/* Send one client message; tick until ReadyForQuery or quiescence.
 * Returns malloc'd reply bytes (caller frees) or NULL on engine death. */
static uint8_t* exchange(pgl_db* db, const void* payload, size_t payload_len,
                         size_t* reply_len) {
  *reply_len = 0;
  if (db->dead) return NULL;

  wasm_rt_memory_t* mem = db->wasi.mem;
  /* leave room for the in-place reply region (input+2 .. CMA end) */
  if (payload_len == 0 || payload_len > (CMA_ZONE_BYTES / 2)) return NULL;

  bool trapped = false;
  GUEST_CALL(db, w2c_pglite_use_wire(&db->inst, 1), { trapped = true; });
  if (trapped) {
    db->dead = true;
    return NULL;
  }
  memcpy(mem->data + 1, payload, payload_len);
  GUEST_CALL(db, w2c_pglite_interactive_write(&db->inst, (u32)payload_len),
             { trapped = true; });
  if (trapped) {
    db->dead = true;
    return NULL;
  }

  uint8_t* buf = NULL;
  size_t cap = 0, used = 0;
  int idle = 0;
  while (idle < 10 && !has_rfq(buf, used)) {
    GUEST_CALL(db, w2c_pglite_interactive_one(&db->inst), { trapped = true; });
    if (!trapped)
      GUEST_CALL(db, w2c_pglite_wasipg_flush(&db->inst), { trapped = true; });
    if (trapped) {
      db->dead = true;
      free(buf);
      return NULL;
    }
    int got = drain(db, &buf, &cap, &used);
    if (got < 0) {
      db->dead = true;
      free(buf);
      return NULL;
    }
    if (got > 0)
      idle = 0;
    else
      idle++;
  }
  *reply_len = used;
  return buf ? buf : calloc(1, 1);
}

/* ---------------- auth ---------------- */

static void md5hex(const void* data, size_t len, char out[33]) {
  unsigned char d[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CC_MD5(data, (CC_LONG)len, d);
#pragma clang diagnostic pop
  static const char* hex = "0123456789abcdef";
  for (int i = 0; i < 16; i++) {
    out[i * 2] = hex[d[i] >> 4];
    out[i * 2 + 1] = hex[d[i] & 15];
  }
  out[32] = 0;
}

static int authenticate(pgl_db* db) {
  /* StartupMessage: protocol 3.0, user postgres, database template1 */
  static const char kv[] = "user\0postgres\0database\0template1\0";
  uint8_t msg[8 + sizeof kv];
  be32(msg, sizeof msg);
  be32(msg + 4, 196608);
  memcpy(msg + 8, kv, sizeof kv);

  size_t rlen;
  uint8_t* reply = exchange(db, msg, sizeof msg, &rlen);
  if (!reply) return -1;

  /* find AuthenticationRequest frame */
  uint32_t authtype = 0;
  uint8_t salt[4] = {0};
  size_t off = 0;
  while (rlen - off >= 5) {
    uint32_t n = rd32(reply + off + 1);
    if (n < 4 || off + 1 + n > rlen) break;
    if (reply[off] == 'R' && n >= 8) {
      authtype = rd32(reply + off + 5);
      if (authtype == 5 && n >= 12) memcpy(salt, reply + off + 9, 4);
    }
    off += 1 + n;
  }
  free(reply);

  if (authtype == 0) return 0; /* trust / already ok */
  if (authtype == 5) {
    /* md5(md5(password + user) + salt) */
    char inner[33];
    md5hex("passwordpostgres", 16, inner);
    uint8_t outer_in[36];
    memcpy(outer_in, inner, 32);
    memcpy(outer_in + 32, salt, 4);
    char outer[33];
    md5hex(outer_in, 36, outer);
    char pw[36];
    snprintf(pw, sizeof pw, "md5%s", outer);

    size_t bodylen = strlen(pw) + 1;
    uint8_t pmsg[5 + 36];
    pmsg[0] = 'p';
    be32(pmsg + 1, (uint32_t)(4 + bodylen));
    memcpy(pmsg + 5, pw, bodylen);
    reply = exchange(db, pmsg, 5 + bodylen, &rlen);
    if (!reply) return -1;
    free(reply);
    return 0;
  }
  if (authtype == 3) {
    static const char pw[] = "password";
    uint8_t pmsg[5 + sizeof pw];
    pmsg[0] = 'p';
    be32(pmsg + 1, 4 + sizeof pw);
    memcpy(pmsg + 5, pw, sizeof pw);
    reply = exchange(db, pmsg, sizeof pmsg, &rlen);
    if (!reply) return -1;
    free(reply);
    return 0;
  }
  return -1;
}

/* ---------------- public API ---------------- */

static long simple_query(pgl_db* db, const char* sql, uint8_t** reply);

pgl_db* pgl_open(const char* root, char* errbuf, size_t errcap) {
  static bool rt_ready = false;
  if (!rt_ready) {
    wasm_rt_init();
    rt_ready = true;
  }

  pgl_db* db = calloc(1, sizeof(pgl_db));
  if (!db) return NULL;
  snprintf(db->root, sizeof db->root, "%s", root);
  snprintf(db->io_in, sizeof db->io_in,
           "%s/tmp/pglite/base/.s.PGSQL.5432.in", root);
  snprintf(db->io_out, sizeof db->io_out,
           "%s/tmp/pglite/base/.s.PGSQL.5432.out", root);

#define FAIL(...)                                \
  do {                                           \
    if (errcap) snprintf(errbuf, errcap, __VA_ARGS__); \
    pgl_close(db);                               \
    return NULL;                                 \
  } while (0)

  db->argv[0] = "/tmp/pglite/bin/postgres";
  db->argv[1] = "--single";
  db->argv[2] = "postgres";
  db->envp[0] = "PREFIX=/tmp/pglite";
  db->envp[1] = "PGDATA=/tmp/pglite/base";
  db->envp[2] = "PGSYSCONFDIR=/tmp/pglite";
  db->envp[3] = "PGUSER=postgres";
  db->envp[4] = "PGDATABASE=template1";
  db->envp[5] = "REPL=N";
  db->envp[6] = "TZ=UTC";
  db->envp[7] = "PGTZ=UTC";
  db->envp[8] = "PATH=/tmp/pglite/bin";

  if (wasi_shim_init(&db->wasi, root, db->argv, 3, db->envp, 9))
    FAIL("wasi_shim_init failed: %s", strerror(errno));

  wasm2c_pglite_instantiate(&db->inst, &db->wasi);
  db->instantiated = true;
  db->wasi.mem = w2c_pglite_memory(&db->inst);

  /* stale transport files confuse the pump */
  unlink(db->io_in);
  unlink(db->io_out);
  char p[700];
  snprintf(p, sizeof p, "%s/tmp/pglite/base/.s.PGSQL.5432.lock.in", root);
  unlink(p);
  snprintf(p, sizeof p, "%s/tmp/pglite/base/.s.PGSQL.5432.lock.out", root);
  unlink(p);

  bool failed = false;
  GUEST_CALL(db, w2c_pglite_0x5Fstart(&db->inst), { failed = true; });
  if (failed) FAIL("_start trapped");
  GUEST_CALL(db, w2c_pglite_pgl_initdb(&db->inst), { failed = true; });
  if (failed) FAIL("pgl_initdb trapped");
  GUEST_CALL(db, w2c_pglite_pgl_backend(&db->inst), { failed = true; });
  if (failed) FAIL("pgl_backend trapped");

  if (authenticate(db)) FAIL("authentication failed (engine dead: %d)", db->dead);

  /* normalize initdb/single-user search_path residue */
  uint8_t* reply = NULL;
  if (simple_query(db, "SET search_path = public, \"$user\"", &reply) < 0)
    FAIL("search_path setup failed");
  free(reply);
#undef FAIL
  return db;
}

static long simple_query(pgl_db* db, const char* sql, uint8_t** reply_out) {
  size_t n = strlen(sql) + 1;
  uint8_t* msg = malloc(5 + n);
  if (!msg) return -1;
  msg[0] = 'Q';
  be32(msg + 1, (uint32_t)(4 + n));
  memcpy(msg + 5, sql, n);
  size_t rlen;
  uint8_t* reply = exchange(db, msg, 5 + n, &rlen);
  free(msg);
  if (!reply) return -1;
  *reply_out = reply;
  return (long)rlen;
}

long pgl_exec_wire(pgl_db* db, const void* payload, size_t payload_len,
                   void* out, size_t outcap) {
  size_t rlen;
  uint8_t* reply = exchange(db, payload, payload_len, &rlen);
  if (!reply) return -1;
  size_t n = rlen < outcap ? rlen : outcap;
  memcpy(out, reply, n);
  free(reply);
  return (long)n;
}

long pgl_exec_wire_alloc(pgl_db* db, const void* payload, size_t payload_len,
                         void** out) {
  size_t rlen;
  uint8_t* reply = exchange(db, payload, payload_len, &rlen);
  if (!reply) return -1;
  *out = reply;
  return (long)rlen;
}

void pgl_free(void* p) {
  free(p);
}

/* append to out with bounds */
static void sappend(char* out, size_t outcap, size_t* used, const char* s,
                    size_t n) {
  if (*used + n >= outcap) n = outcap - *used - 1;
  memcpy(out + *used, s, n);
  *used += n;
  out[*used] = 0;
}

int pgl_exec(pgl_db* db, const char* sql, char* out, size_t outcap) {
  if (outcap) out[0] = 0;
  uint8_t* reply;
  long rlen = simple_query(db, sql, &reply);
  if (rlen < 0) return -2;

  int rc = 0;
  size_t used = 0;
  size_t off = 0;
  while ((size_t)rlen - off >= 5) {
    uint8_t type = reply[off];
    uint32_t n = rd32(reply + off + 1);
    if (n < 4 || off + 1 + n > (size_t)rlen) break;
    const uint8_t* body = reply + off + 5;
    uint32_t blen = n - 4;

    if (type == 'D') { /* DataRow: u16 ncols, then (i32 len, bytes)* */
      uint16_t ncols = (uint16_t)((body[0] << 8) | body[1]);
      uint32_t p = 2;
      for (uint16_t c = 0; c < ncols; c++) {
        if (c) sappend(out, outcap, &used, "\t", 1);
        if (p + 4 > blen) break;
        int32_t vlen = (int32_t)rd32(body + p);
        p += 4;
        if (vlen < 0) {
          sappend(out, outcap, &used, "NULL", 4);
        } else {
          sappend(out, outcap, &used, (const char*)body + p, (size_t)vlen);
          p += (uint32_t)vlen;
        }
      }
      sappend(out, outcap, &used, "\n", 1);
    } else if (type == 'C') { /* CommandComplete */
      sappend(out, outcap, &used, "#", 1);
      size_t tl = strnlen((const char*)body, blen);
      sappend(out, outcap, &used, (const char*)body, tl);
      sappend(out, outcap, &used, "\n", 1);
    } else if (type == 'E') { /* ErrorResponse */
      rc = -1;
      used = 0;
      if (outcap) out[0] = 0;
      /* fields: <type byte><cstr>... find S/M/C */
      const uint8_t* f = body;
      const uint8_t* end = body + blen;
      char sev[64] = "", msgtxt[512] = "", code[16] = "";
      while (f < end && *f) {
        uint8_t k = *f++;
        size_t l = strnlen((const char*)f, (size_t)(end - f));
        if (k == 'S') snprintf(sev, sizeof sev, "%.*s", (int)l, f);
        if (k == 'M') snprintf(msgtxt, sizeof msgtxt, "%.*s", (int)l, f);
        if (k == 'C') snprintf(code, sizeof code, "%.*s", (int)l, f);
        f += l + 1;
      }
      char line[640];
      int ln = snprintf(line, sizeof line, "%s: %s (SQLSTATE %s)", sev,
                        msgtxt, code);
      sappend(out, outcap, &used, line, (size_t)ln);
    }
    off += 1 + n;
  }
  free(reply);
  return rc;
}

void pgl_close(pgl_db* db) {
  if (!db) return;
  if (!db->dead && db->instantiated) {
    /* durable stopping point; pgl_shutdown's exit hooks trap on
     * first-boot instances, so checkpoint and drop instead */
    char scratch[256];
    (void)pgl_exec(db, "CHECKPOINT", scratch, sizeof scratch);
  }
  if (db->instantiated) wasm2c_pglite_free(&db->inst);
  wasi_shim_dispose(&db->wasi);
  free(db);
}
