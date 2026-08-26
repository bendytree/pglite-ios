# syntax=docker/dockerfile:1
# Builder image for the wasipg bundle: debian:12 + the electric-sql
# portable-sdk, which is fully self-contained under /tmp/sdk (emsdk,
# wasi-sdk 25 clang + sysroot, host python, wasmtime, node). The SDK
# tarball comes from build/cache/ (fetched and sha256-verified by
# build.sh); no network access is needed during docker build or run.
FROM debian:12

RUN apt-get update && apt-get install -y --no-install-recommends \
    git wget curl ca-certificates lz4 xz-utils bison flex pkg-config \
    autoconf automake libtool make patch file python3 \
    && rm -rf /var/lib/apt/lists/*

ARG SDK_TARBALL

# portable-sdk unpacks to /tmp/sdk.
RUN --mount=type=bind,source=cache,target=/cache \
    tar xf /cache/${SDK_TARBALL} --use-compress-program=lz4 -C /

# Replace the bundled wasi-sdk 25 (LLVM 19, legacy-EH-only sjlj) with
# wasi-sdk 33 (LLVM 22, exnref-capable) — see versions.env. The wasi-c
# wrapper execs upstream/bin/clang, and clang resolves its sysroot
# relative to its own path, so a wholesale swap of upstream/ suffices.
# The bundled wasi-sdk 25 is a custom (pygame-web) build whose sysroot
# also carries extra prebuilt libraries the PG build links against
# (zlib, libxml2, uuid, and a custom libwasi-emulated-pthread). Carry
# those over into the stock wasi-sdk 33 sysroot without clobbering any
# of its own libc/crt files.
ARG WASI_SDK_OVERLAY
RUN --mount=type=bind,source=cache,target=/cache \
    tar xzf /cache/${WASI_SDK_OVERLAY} -C /opt \
    && old=/tmp/sdk/wasisdk/upstream new=$(echo /opt/wasi-sdk-*-linux) \
    && sysold=$old/share/wasi-sysroot sysnew=$new/share/wasi-sysroot \
    && for f in libwasi-emulated-pthread.a libwasi-emulated-pthread.so \
                libz.a libxml2.a libuuid.a libbz2.a; do \
         if [ -e $sysold/lib/wasm32-wasip1/$f ] && [ ! -e $sysnew/lib/wasm32-wasip1/$f ]; then \
           cp -v $sysold/lib/wasm32-wasip1/$f $sysnew/lib/wasm32-wasip1/; fi; \
       done \
    && cp -rn $sysold/lib/wasm32-wasip1/pkgconfig $sysnew/lib/wasm32-wasip1/ 2>/dev/null; \
       for h in zlib.h zconf.h; do \
         [ -e $sysold/include/$h ] && [ ! -e $sysnew/include/$h ] && cp -v $sysold/include/$h $sysnew/include/; \
       done; \
       cp -rn $sysold/include/libxml2 $sysnew/include/ 2>/dev/null; \
       cp -rn $sysold/include/uuid $sysnew/include/ 2>/dev/null; \
       cp -v $sysold/include/wasm32-wasip1/__struct_sockaddr_un.h /tmp/sdk/wasisdk/hotfix/; \
       cp -v $sysold/include/wasm32-wasip1/__wasi_snapshot.h /tmp/sdk/wasisdk/hotfix/; \
       cp -v $sysold/include/wasm32-wasip1/sys/shm.h /tmp/sdk/wasisdk/hotfix/sys/; \
       cp -v $sysold/include/wasm32-wasip1/bits/shm.h $sysold/include/wasm32-wasip1/bits/ipcstat.h /tmp/sdk/wasisdk/hotfix/bits/; \
       rm -rf $old && mv $new /tmp/sdk/wasisdk/upstream

# wasipg shadow headers resolving custom-wasi-sdk-25 vs stock-33
# conflicts; the hotfix dir is on every compile's -isystem path.
COPY hotfix/ /tmp/sdk/wasisdk/hotfix/

# The SDK's hotfix/patch.h (force-included into every compile) is the
# toolchain-level "sjlj off" switch: it stubs sigsetjmp to `return 0`
# and siglongjmp to a no-op. Gate those stubs on WASIPG_SJLJ so sjlj
# builds get the real setjmp/longjmp (lowered onto exnref EH), exactly
# like PostgreSQL's own no-sigsetjmp fallback. Editing patch.h itself
# (rather than a later -include) is load-bearing: patch.h is injected
# after user CFLAGS, so a header of ours could not reliably win the
# macro-redefinition race.
# The SDK's wasi-c/wasi-c++ wrappers hardcode `-z stack-size=131072`
# AFTER user flags (so a build-script override can never win). 128 KiB
# of shadow stack sits directly above the data section in the
# no-stack-first layout, and PostgreSQL's parser/planner recursion
# overflows it long before PG's own max_stack_depth check (2 MB
# default) can fire — silently corrupting globals below. Raise it to
# 8 MiB: overflow paths now hit PG's clean, *recoverable* "stack depth
# limit exceeded" ERROR instead of trampling memory.
RUN python3 - <<'PYEOF'
import glob
edited = 0
for p in glob.glob('/tmp/sdk/wasisdk/bin/*'):
    try:
        s = open(p).read()
    except (UnicodeDecodeError, IsADirectoryError):
        continue
    if 'stack-size=131072' in s:
        open(p, 'w').write(s.replace('stack-size=131072', 'stack-size=8388608'))
        edited += 1
        print('stack-size raised to 8MiB in', p)
assert edited >= 1, "no wrapper with stack-size=131072 found"
PYEOF

RUN python3 - <<'PYEOF'
p = '/tmp/sdk/wasisdk/hotfix/patch.h'
s = open(p).read()
old_set = '#   define sigsetjmp(env, savesigs) sdk_sigsetjmp(env, savesigs)'
old_long = '#   define siglongjmp(env, val) sdk_siglongjmp(env, val)'
assert s.count(old_set) == 1, "patch.h sigsetjmp stub not found"
assert s.count(old_long) == 1, "patch.h siglongjmp stub not found"
new_set = '''#   if defined(WASIPG_SJLJ)
#       define sigsetjmp(env, savesigs) setjmp(env)
#   else
#       define sigsetjmp(env, savesigs) sdk_sigsetjmp(env, savesigs)
#   endif'''
new_long = '''#   if defined(WASIPG_SJLJ)
#       define siglongjmp(env, val) longjmp(env, val)
#   else
#       define siglongjmp(env, val) sdk_siglongjmp(env, val)
#   endif'''
s = s.replace(old_set, new_set).replace(old_long, new_long)
open(p, 'w').write(s)
print('patch.h: sigsetjmp/siglongjmp stubs gated on WASIPG_SJLJ')
PYEOF

WORKDIR /workspace
