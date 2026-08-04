#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kouten-recovery-matrix.XXXXXX")"
WORKER_PID=""
cleanup() {
  if [[ -n "$WORKER_PID" ]] && kill -0 "$WORKER_PID" 2>/dev/null; then
    kill -KILL "$WORKER_PID" 2>/dev/null || true
    wait "$WORKER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

BIN="$WORK/recovery-matrix"
ROUNDS="${KOUTEN_RECOVERY_ROUNDS:-3}"

if [[ ! "$ROUNDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "KOUTEN_RECOVERY_ROUNDS must be a positive integer" >&2
  exit 1
fi

nim c -d:release --nimcache:/tmp/nimcache_kouten_recovery_matrix \
  -o:"$BIN" examples/disk_backed_recovery_matrix.nim >/dev/null

for round in $(seq 1 "$ROUNDS"); do
  DATA="$WORK/data-$round"
  READY="$WORK/ready-$round"
  echo "[disk-backed-recovery] round $round/$ROUNDS"
  "$BIN" --mode=worker --data="$DATA" --ready="$READY" >/dev/null 2>&1 &
  WORKER_PID="$!"
  for _ in $(seq 1 500); do
    if [[ -f "$READY" ]]; then
      break
    fi
    if ! kill -0 "$WORKER_PID" 2>/dev/null; then
      echo "recovery worker exited before readiness in round $round" >&2
      exit 1
    fi
    sleep 0.01
  done
  if [[ ! -f "$READY" ]]; then
    echo "recovery worker did not reach readiness in round $round" >&2
    exit 1
  fi

  kill -KILL "$WORKER_PID"
  wait "$WORKER_PID" 2>/dev/null || true
  WORKER_PID=""

  "$BIN" --mode=verify --data="$DATA"
done
