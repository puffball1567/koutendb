#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="${KOUTENDB_CAPI_OUT:-lib/libkoutendb.so}"
NIMCACHE="${KOUTENDB_CAPI_NIMCACHE:-/tmp/nimcache_kouten_capi}"

mkdir -p "$(dirname "$OUT")"

NIM_FLAGS=(--app:lib -d:ssl -d:release)

NIMSODIUM_PATH="${KOUTENDB_NIMSODIUM_PATH:-}"
if [[ -z "$NIMSODIUM_PATH" ]] && command -v nimble >/dev/null 2>&1; then
  NIMSODIUM_PATH="$(nimble path nimsodium 2>/dev/null || true)"
  NIMSODIUM_PATH="${NIMSODIUM_PATH%%$'\n'*}"
fi
if [[ -n "$NIMSODIUM_PATH" ]]; then
  if [[ ! -f "$NIMSODIUM_PATH/nimsodium.nim" ]]; then
    echo "nimsodium module not found under: $NIMSODIUM_PATH" >&2
    exit 1
  fi
  NIM_FLAGS+=(--path:"$NIMSODIUM_PATH")
fi

if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
  for formula in libsodium openssl@3 openssl; do
    prefix="$(brew --prefix "$formula" 2>/dev/null || true)"
    if [[ -n "$prefix" ]]; then
      NIM_FLAGS+=(--passC:"-I$prefix/include" --passL:"-L$prefix/lib")
    fi
  done
fi

nim c "${NIM_FLAGS[@]}" \
  --nimcache:"$NIMCACHE" \
  -o:"$OUT" \
  src/koutendb_capi.nim

echo "built $OUT with -d:ssl"
