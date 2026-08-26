/* Native (macOS) smoke test for the wasm2c pglite stack.
 * Usage: native_test <root>   (root contains extracted pglite-wasi bundle)
 * Exercises: boot, SELECT 1, DDL/DML, error recovery, pgvector, then
 * close + reopen to verify persistence.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pglite_bridge.h"

static pgl_db* g_db;
static int g_failures;

static void run(const char* sql, const char* expect_substr, int expect_rc) {
  char out[65536];
  int rc = pgl_exec(g_db, sql, out, sizeof out);
  const char* status = "ok";
  if (rc != expect_rc) {
    status = "FAIL(rc)";
    g_failures++;
  } else if (expect_substr && !strstr(out, expect_substr)) {
    status = "FAIL(output)";
    g_failures++;
  }
  printf("[%s] %s\n%s", status, sql, out);
  if (rc == -2) {
    printf("engine died; aborting\n");
    exit(1);
  }
}

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <root>\n", argv[0]);
    return 2;
  }
  char err[256];

  printf("=== boot 1 ===\n");
  g_db = pgl_open(argv[1], err, sizeof err);
  if (!g_db) {
    fprintf(stderr, "pgl_open: %s\n", err);
    return 1;
  }
  run("SELECT 1", "1\n", 0);
  run("SELECT version()", "PostgreSQL 17.5", 0);
  run("CREATE TABLE fruit (id serial primary key, name text, qty int)", "#CREATE TABLE", 0);
  run("INSERT INTO fruit (name, qty) VALUES ('apple', 3), ('pear', 7) RETURNING id", "#INSERT 0 2", 0);
  run("SELECT name, qty FROM fruit ORDER BY id", "apple\t3\npear\t7\n", 0);
  run("UPDATE fruit SET qty = qty + 10 WHERE name = 'apple' RETURNING qty", "13", 0);
  run("SELECT 1/0", "SQLSTATE 22012", -1);
  run("SELECT count(*) FROM fruit", "2\n", 0); /* survived the ERROR */
  run("CREATE EXTENSION IF NOT EXISTS vector", "#CREATE EXTENSION", 0);
  run("CREATE TABLE items (id serial primary key, e vector(3))", "#CREATE TABLE", 0);
  run("INSERT INTO items (e) VALUES ('[1,2,3]'), ('[4,5,6]'), ('[0,0,1]')", "#INSERT 0 3", 0);
  run("SELECT id FROM items ORDER BY e <-> '[1,2,3]' LIMIT 1", "1\n", 0);
  run("CREATE INDEX ON items USING hnsw (e vector_l2_ops)", "#CREATE INDEX", 0);
  run("BEGIN", "#BEGIN", 0);
  run("INSERT INTO fruit (name, qty) VALUES ('rolledback', 0)", "#INSERT 0 1", 0);
  run("ROLLBACK", "#ROLLBACK", 0);
  run("SELECT count(*) FROM fruit WHERE name = 'rolledback'", "0\n", 0);
  pgl_close(g_db);

  printf("=== boot 2 (persistence) ===\n");
  g_db = pgl_open(argv[1], err, sizeof err);
  if (!g_db) {
    fprintf(stderr, "pgl_open(2): %s\n", err);
    return 1;
  }
  run("SELECT name, qty FROM fruit ORDER BY id", "apple\t13\npear\t7\n", 0);
  run("SET enable_seqscan = off", "#SET", 0);
  run("SELECT id FROM items ORDER BY e <-> '[4,5,6]' LIMIT 1", "2\n", 0);
  pgl_close(g_db);

  printf("=== %s (%d failures) ===\n", g_failures ? "FAILED" : "PASSED",
         g_failures);
  return g_failures ? 1 : 0;
}
