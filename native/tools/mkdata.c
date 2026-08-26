/* Boot the engine once against a fresh root (running in-guest initdb),
 * checkpoint, and exit — producing a pristine, resumable PGDATA that
 * make-pristine.sh packs as the pgdata-pristine.aar package resource. */
#include <stdio.h>

#include "pglite_bridge.h"

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <root>\n", argv[0]);
    return 2;
  }
  char err[256];
  pgl_db* db = pgl_open(argv[1], err, sizeof err);
  if (!db) {
    fprintf(stderr, "pgl_open: %s\n", err);
    return 1;
  }
  char out[256];
  if (pgl_exec(db, "SELECT 1", out, sizeof out) != 0) {
    fprintf(stderr, "smoke query failed: %s\n", out);
    return 1;
  }
  pgl_close(db); /* CHECKPOINT + teardown */
  puts("pristine PGDATA ready");
  return 0;
}
