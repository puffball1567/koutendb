#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

run_nim_test() {
  local file="$1"
  local name
  name="$(basename "$file" .nim)"
  echo "[test-core] $file"
  nim c --nimcache="/tmp/nimcache_kouten_${name}" -r "$file"
}

run_nim_test tests/tcore.nim
run_nim_test tests/tauth.nim
run_nim_test tests/tselect.nim
run_nim_test tests/tfield.nim
run_nim_test tests/tstore.nim
run_nim_test tests/tapi.nim

echo "[test-core] tests/tsegment_failpoints.nim"
nim c -d:koutenTestFailpoints \
  --nimcache="/tmp/nimcache_kouten_tsegment_failpoints" \
  -r tests/tsegment_failpoints.nim

echo "[test-core] OK"
