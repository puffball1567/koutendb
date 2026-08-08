#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${TMPDIR:-/tmp}/kouten-storage-failure-matrix"

cleanup() {
  rm -f "$BIN"
}
trap cleanup EXIT

cd "$ROOT"
nim c -d:release -d:koutenTestStorageFailures \
  --nimcache:/tmp/nimcache_kouten_storage_failure_matrix \
  -o:"$BIN" tests/tstorage_failures.nim >/dev/null
"$BIN"

echo "[storage-failure-matrix] WAL and sidecar failure cases passed"
