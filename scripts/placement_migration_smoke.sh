#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="/tmp/koutend_placement_migration"

cd "$ROOT"
echo "[placement-migration] build server"
nim c -d:release \
  --nimcache:/tmp/nimcache_koutend_placement_migration \
  -o:"$SERVER" src/koutend.nim

echo "[placement-migration] run topology migration integration test"
KOUTEN_TEST_SERVER="$SERVER" \
  nim c --nimcache:/tmp/nimcache_kouten_tplacement_migration \
    -o:/tmp/tplacement_migration \
    -r tests/tplacement_migration.nim

echo "[placement-migration] OK"
