#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="/tmp/koutend_scale_in_migration"

cd "$ROOT"
echo "[scale-in-migration] build server"
nim c -d:release \
  --nimcache:/tmp/nimcache_koutend_scale_in_migration \
  -o:"$SERVER" src/koutend.nim

echo "[scale-in-migration] run explicit scale-in integration test"
KOUTEN_TEST_SERVER="$SERVER" \
  nim c --nimcache:/tmp/nimcache_kouten_tscale_in_migration \
    -o:/tmp/tscale_in_migration \
    -r tests/tscale_in_migration.nim

echo "[scale-in-migration] OK"
