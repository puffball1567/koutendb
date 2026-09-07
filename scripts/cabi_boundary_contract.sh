#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kouten-cabi-boundary.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -pedantic \
  "$ROOT/examples/cabi_boundary_contract.c" -I"$ROOT/include" \
  -L"$ROOT/lib" -lkoutendb -o "$WORK/contract"
LD_LIBRARY_PATH="$ROOT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
DYLD_LIBRARY_PATH="$ROOT/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
  "$WORK/contract" "$WORK"
