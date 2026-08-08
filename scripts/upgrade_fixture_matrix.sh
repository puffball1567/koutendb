#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "[upgrade-fixtures] v0.10.1 and v0.11.0 compatibility matrix"
nim c --nimcache:/tmp/nimcache_kouten_upgrade_fixtures \
  -r tests/tupgrade_fixtures.nim

echo "[upgrade-fixtures] OK"
