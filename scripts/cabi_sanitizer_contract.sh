#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Linux ]]; then
  echo "This ASan/UBSan/LSan contract currently requires Linux." >&2
  exit 2
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kouten-cabi-sanitizer.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

KOUTENDB_CAPI_OUT="$WORK/libkoutendb.so" \
KOUTENDB_CAPI_NIMCACHE="$WORK/nimcache" \
  bash "$ROOT/scripts/build_capi.sh" --cc:clang -d:useMalloc \
    --passC:-g --passC:-fsanitize=address,undefined \
    --passC:-fno-omit-frame-pointer --passL:-fsanitize=address,undefined

clang -std=c11 -Wall -Wextra -Werror -g \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  "$ROOT/examples/cabi_boundary_contract.c" -I"$ROOT/include" \
  -L"$WORK" -lkoutendb -o "$WORK/contract"
mkdir "$WORK/data"
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
LD_LIBRARY_PATH="$WORK${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  "$WORK/contract" "$WORK/data"
