#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_PORT="${KOUTEN_CONCURRENCY_TEST_PORT:-17841}"
PEERS="127.0.0.1:${BASE_PORT}"
WRITERS="${KOUTEN_CONCURRENCY_WRITERS:-4}"
WRITES="${KOUTEN_CONCURRENCY_WRITES:-12}"
READER_LOOPS="${KOUTEN_CONCURRENCY_READER_LOOPS:-40}"
OBSERVER_LOOPS="${KOUTEN_CONCURRENCY_OBSERVER_LOOPS:-30}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kouten-concurrency.XXXXXX")"
DATA="$WORK/data"
SERVER="$WORK/koutend"
MATRIX="$WORK/concurrency-matrix"
SERVER_PID=""
WORKER_PIDS=()

cleanup() {
  if ((${#WORKER_PIDS[@]} > 0)); then
    kill "${WORKER_PIDS[@]}" >/dev/null 2>&1 || true
  fi
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ "${KOUTEN_KEEP_TEST_DATA:-0}" == "1" ]]; then
    echo "[concurrency-backpressure] kept test data at $WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

cd "$ROOT"
nim c -d:release -d:koutenTestBackpressure \
  --nimcache:/tmp/nimcache_kouten_concurrency_server \
  -o:"$SERVER" src/koutend.nim >/dev/null
nim c -d:release --nimcache:/tmp/nimcache_kouten_concurrency_matrix \
  -o:"$MATRIX" examples/concurrency_backpressure_matrix.nim >/dev/null

"$SERVER" --id=0 --peers="$PEERS" --data="$DATA" --disk-backed \
  --durability=strong --slow-tick=0.02 --auto-pack \
  --auto-pack-interval=0.05 --auto-pack-stale-ratio=0.01 \
  --auto-pack-min-stale=1 --auto-pack-max-rings=2 \
  --auto-pack-max-bytes=33554432 --auto-pack-max-ms=1000 \
  >"$WORK/server.log" 2>&1 &
SERVER_PID=$!

ready=0
for _ in $(seq 1 100); do
  if "$MATRIX" --mode=health --peers="$PEERS" >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "$WORK/server.log" >&2
    exit 1
  fi
  sleep 0.05
done
if [[ "$ready" -ne 1 ]]; then
  cat "$WORK/server.log" >&2
  exit 1
fi

echo "[concurrency-backpressure] connection admission"
"$MATRIX" --mode=admission --peers="$PEERS"
echo "[concurrency-backpressure] slow request body"
"$MATRIX" --mode=slow-input --peers="$PEERS"
echo "[concurrency-backpressure] bounded ring list"
"$MATRIX" --mode=list-limit --peers="$PEERS"
echo "[concurrency-backpressure] slow response reader"
"$MATRIX" --mode=slow-output --peers="$PEERS"

for worker in $(seq 0 $((WRITERS - 1))); do
  "$MATRIX" --mode=writer --peers="$PEERS" --worker="$worker" --count="$WRITES" \
    >"$WORK/writer-$worker.log" 2>&1 &
  WORKER_PIDS+=("$!")
done
for reader in 0 1 2; do
  "$MATRIX" --mode=reader --peers="$PEERS" --loops="$READER_LOOPS" \
    >"$WORK/reader-$reader.log" 2>&1 &
  WORKER_PIDS+=("$!")
done
"$MATRIX" --mode=observer --peers="$PEERS" --loops="$OBSERVER_LOOPS" \
  >"$WORK/observer.log" 2>&1 &
WORKER_PIDS+=("$!")

failed=0
for pid in "${WORKER_PIDS[@]}"; do
  if ! wait "$pid"; then
    failed=1
  fi
done
WORKER_PIDS=()
if [[ "$failed" -ne 0 ]]; then
  cat "$WORK"/writer-*.log "$WORK"/reader-*.log "$WORK/observer.log" >&2
  cat "$WORK/server.log" >&2
  exit 1
fi

echo "[concurrency-backpressure] final online verification"
if ! "$MATRIX" --mode=verify --peers="$PEERS" --writers="$WRITERS" \
    --count="$WRITES"; then
  cat "$WORK"/writer-*.log "$WORK"/reader-*.log "$WORK/observer.log" >&2
  cat "$WORK/server.log" >&2
  exit 1
fi
"$MATRIX" --mode=shutdown --peers="$PEERS"
wait "$SERVER_PID"
SERVER_PID=""
"$MATRIX" --mode=offline --data="$DATA" --writers="$WRITERS" --count="$WRITES"

echo "[concurrency-backpressure] concurrent writers/readers/maintenance passed"
echo "[concurrency-backpressure] admission, request, and response bounds passed"
