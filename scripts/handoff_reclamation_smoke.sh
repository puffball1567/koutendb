#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="/tmp/koutend_handoff_reclamation"

cd "$ROOT"

echo "[handoff-reclamation] build fast-reclamation server"
nim c -d:release -d:koutenTestFastTombstoneGc \
  --nimcache:/tmp/nimcache_koutend_handoff_reclamation \
  -o:"$SERVER" src/koutend.nim

echo "[handoff-reclamation] run integration test"
KOUTEN_TEST_SERVER="$SERVER" \
  nim c --nimcache:/tmp/nimcache_kouten_thandoff_reclamation \
    -r tests/thandoff_reclamation.nim

echo "[handoff-reclamation] OK"
