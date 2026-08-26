#!/bin/bash
# Runs INSIDE the wasipg builder container, after wasm-build.sh has
# installed PG core to /tmp/pglite. Compiles pgvector (mounted at
# /vector/src) with the SDK's wasi-c, archives it, generates a dlsym
# table from its defined symbols, and stages everything where the
# patched pglite-wasm/build.sh link line (${EXTRA_PG_LIBS}) picks it up.
set -euo pipefail

# wasi-c wrapper resolves hotfix/sysroot paths from these
export SDKROOT=/tmp/sdk
export PYBUILD=3.13
set +u
. /tmp/sdk/wasisdk/wasisdk_env.sh
set -u

CC=/tmp/sdk/wasisdk/bin/wasi-c
LLVM_BIN=$(echo /tmp/sdk/wasisdk/upstream/bin)
PGROOT=/tmp/pglite
OUTDIR=/tmp/sdk/build/wasi/vector

rm -rf /tmp/vector-build
cp -r /vector/src /tmp/vector-build
cd /tmp/vector-build

# _PG_init and Pg_magic_func collide with plpgsql's statically-linked
# copies; rename ours. The dlopen shim's stub magic/init are used for
CFLAGS="-O2 -fno-strict-aliasing -DPGDLLEXPORT= -DPYDK=1 \
  -D_PG_init=vector_PG_init -DPg_magic_func=vector_Pg_magic_func \
  -I./src -I${PGROOT}/include/postgresql/server -I${PGROOT}/include/postgresql/internal"

mkdir -p obj "$OUTDIR"
for f in src/*.c; do
  echo "wasi-c $f"
  $CC $CFLAGS -c "$f" -o "obj/$(basename "${f%.c}").o"
done
$LLVM_BIN/llvm-ar rcs "$OUTDIR/libvector.a" obj/*.o

# dlsym table: every externally-defined function in the archive.
$LLVM_BIN/llvm-nm --defined-only "$OUTDIR/libvector.a" \
  | awk '$2 == "T" { print $3 }' | sort -u > syms.txt
echo "pgvector exports $(wc -l < syms.txt) symbols"

python3 - <<'PYEOF'
syms = [s.strip() for s in open('syms.txt') if s.strip()]
with open('vector_dlsym.c', 'w') as f:
    f.write('/* generated: dlsym table for statically-linked pgvector */\n')
    f.write('#include <string.h>\n#include <stdio.h>\n')
    for s in syms:
        f.write(f'extern void {s}(void);\n')
    f.write('static const struct { const char *name; void *addr; } pgv_tab[] = {\n')
    for s in syms:
        f.write(f'    {{ "{s}", (void *)&{s} }},\n')
    f.write('};\n')
    f.write('''
void *
pglite_extra_dlsym(const char *symbol) {
    for (unsigned i = 0; i < sizeof(pgv_tab) / sizeof(pgv_tab[0]); i++)
        if (!strcmp(pgv_tab[i].name, symbol))
            return pgv_tab[i].addr;
    return NULL;
}

void
pglite_extra_dlopen(const char *filename) {
    size_t n = strlen(filename);
    if (n >= 10 && !strcmp(filename + n - 10, "/vector.so")) {
        fprintf(stderr, "pglite_extra_dlopen: vector_PG_init()\\n");
        vector_PG_init();
    }
}
''')
print('vector_dlsym.c generated with', len(syms), 'entries')
PYEOF

$CC -O2 -I${PGROOT}/include/postgresql/server -c vector_dlsym.c -o "$OUTDIR/vector_dlsym.o"

# Extension SQL + control into the runtime FS; dummy .so so PG's
# expand_dynamic_library_name finds a file to "load".
cp vector.control "$PGROOT/share/postgresql/extension/"
cp sql/vector.sql "$PGROOT/share/postgresql/extension/vector--0.8.0.sql"
touch "$PGROOT/lib/postgresql/vector.so"

echo "pgvector staged: $OUTDIR"
