#!/usr/bin/env bash
# One-command reproducible build of pglite.wasi (PostgreSQL 17.5 + pgvector,
# WASI, sjlj/exnref error recovery) and its runtime filesystem bundle.
#
#   ./module/build.sh              # artifacts land in module/out/
#
# Recipe derived from moznion/wasipg (Apache-2.0; see NOTICE). All external
# inputs are pinned in versions.env, fetched once into cache/, and verified
# by sha256. Requires Docker.
set -euo pipefail
cd "$(dirname "$0")"
. ./versions.env

case "$(uname -m)" in
  arm64|aarch64) UARCH=aarch64 ;;
  x86_64)        UARCH=x86_64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac
if [ "$UARCH" = aarch64 ]; then
  SDK_SHA256=$SDK_SHA256_AARCH64
  WASI_SDK_OVERLAY_SHA256=$WASI_SDK_OVERLAY_SHA256_AARCH64
  WASI_SDK_OVERLAY_ARCH=arm64
else
  SDK_SHA256=$SDK_SHA256_X86_64
  WASI_SDK_OVERLAY_SHA256=$WASI_SDK_OVERLAY_SHA256_X86_64
  WASI_SDK_OVERLAY_ARCH=x86_64
fi

mkdir -p cache out work

fetch() { # <url> <dest-file> <sha256>
  local url=$1 dest=cache/$2 sha=$3
  if [ ! -f "$dest" ]; then
    echo "fetching $url"
    curl -fL --retry 3 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi
  if [ "$sha" = "__FILLED_BY_FIRST_BUILD__" ]; then
    echo "WARNING: no pinned sha256 for $2 on this arch:"
    shasum -a 256 "$dest"
  else
    echo "$sha  $dest" | shasum -a 256 -c -
  fi
}

SDK_TARBALL="python3.13-wasm-sdk-debian12-${UARCH}.tar.lz4"
fetch "https://github.com/electric-sql/portable-sdk/releases/download/${SDK_VERSION}/${SDK_TARBALL}" \
      "$SDK_TARBALL" "$SDK_SHA256"
WASI_SDK_OVERLAY="wasi-sdk-${WASI_SDK_OVERLAY_VERSION}-${UARCH}-linux.tar.gz"
fetch "https://github.com/WebAssembly/wasi-sdk/releases/download/${WASI_SDK_OVERLAY_TAG}/wasi-sdk-${WASI_SDK_OVERLAY_VERSION}-${WASI_SDK_OVERLAY_ARCH}-linux.tar.gz" \
      "$WASI_SDK_OVERLAY" "$WASI_SDK_OVERLAY_SHA256"
fetch "https://github.com/pgvector/pgvector/archive/refs/tags/v${PGVECTOR_VERSION}.tar.gz" \
      "pgvector-${PGVECTOR_VERSION}.tar.gz" "$PGVECTOR_SHA256"

rm -rf cache/vector-src
mkdir -p cache/vector-src
tar xf "cache/pgvector-${PGVECTOR_VERSION}.tar.gz" -C cache/vector-src --strip-components=1

# Source checkout pinned to PGLITE_REF, with the wasipg patch series and
# our pgios patches applied (in that order).
SRC=work/postgres-pglite
STAMP="$PGLITE_REF-$(cat patches/wasipg/*.patch patches/pgios/*.patch | shasum -a 256 | cut -c1-16)"
if [ ! -f "$SRC/.pgios-ref" ] || [ "$(cat "$SRC/.pgios-ref")" != "$STAMP" ]; then
  rm -rf "$SRC"
  mkdir -p "$SRC"
  git -C "$SRC" init -q
  git -C "$SRC" remote add origin "$PGLITE_REPO"
  git -C "$SRC" fetch -q --depth 1 origin "$PGLITE_REF"
  git -C "$SRC" checkout -q FETCH_HEAD
  for p in patches/wasipg/*.patch patches/pgios/*.patch; do
    echo "applying $p"
    git -C "$SRC" apply "../../$p"
  done
  echo "$STAMP" > "$SRC/.pgios-ref"
fi

IMG=pgios-module-builder:${SDK_VERSION}-wasisdk${WASI_SDK_OVERLAY_VERSION}-${UARCH}
docker build -t "$IMG" \
  --build-arg SDK_TARBALL="$SDK_TARBALL" \
  --build-arg WASI_SDK_OVERLAY="$WASI_SDK_OVERLAY" \
  .

# FAST=true keeps the PG core install and build tree in named docker
# volumes so a rerun skips straight to the final link.
VOLARGS=()
if [ "${FAST:-false}" = true ]; then
  VOLARGS=(-v pgios-pgroot:/tmp/pglite -v pgios-buildstate:/tmp/sdk/build)
fi

# Pass 1 builds PG core + links the stock module; vector-build.sh compiles
# pgvector and generates its dlsym table; pass 2 relinks with pgvector and
# packs the runtime FS bundle.
docker run --rm \
  ${VOLARGS[@]+"${VOLARGS[@]}"} \
  -e WASI=true -e CI=true -e SJLJ="${SJLJ:-true}" -e DEBUG="${DEBUG:-false}" \
  -e PG_VERSION=17.5 -e PG_BRANCH=REL_17_5_WASM \
  -e SDKROOT=/tmp/sdk -e GETZIC=false -e ZIC=/usr/sbin/zic \
  -v "$(pwd)/$SRC:/workspace:rw" \
  -v "$(pwd)/out:/tmp/sdk/dist:rw" \
  -v "$(pwd)/vector-build.sh:/vector/inside.sh:ro" \
  -v "$(pwd)/cache/vector-src:/vector/src:ro" \
  -v "$(pwd)/pack.sh:/pack.sh:ro" \
  -w /workspace \
  "$IMG" \
  bash -c './wasm-build.sh; /vector/inside.sh && EXTRA_PG_LIBS="/tmp/sdk/build/wasi/vector/libvector.a /tmp/sdk/build/wasi/vector/vector_dlsym.o" bash -c "./wasm-build.sh; /pack.sh"'

echo
echo "module artifacts:"
(cd out && shasum -a 256 pglite.wasi pglite-wasi.tar.xz)
