#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "[coordinator-failover] build koutend"
nim c -d:release --nimcache:/tmp/nimcache_koutend_v013 -o:src/koutend src/koutend.nim

echo "[coordinator-failover] run failure matrix"
nim c --nimcache:/tmp/nimcache_kouten_coordinator_failover \
  -r tests/tcoordinator_failover.nim

echo "[coordinator-failover] OK"
