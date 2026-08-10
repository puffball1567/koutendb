#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/koutendb-cluster-disk-reads-$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
cd "$ROOT"

PORT=""
for attempt in $(seq 0 99); do
  candidate=$((31000 + (($$ + attempt) % 25000)))
  if ! nc -z 127.0.0.1 "$candidate" >/dev/null 2>&1; then
    PORT="$candidate"
    break
  fi
done
test -n "$PORT"

nim c -d:release --nimcache:"$WORK/nimcache-server" \
  -o:"$WORK/koutend" src/koutend.nim >/dev/null
nim c -d:release --nimcache:"$WORK/nimcache-test" \
  -o:"$WORK/test" tests/tcluster_disk_backed_reads.nim >/dev/null

KOUTEN_TEST_KOUTEND="$WORK/koutend" KOUTEN_DISK_READ_PORT="$PORT" \
  "$WORK/test"
