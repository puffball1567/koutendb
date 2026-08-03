#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_PORT="${KOUTEN_SOAK_BASE_PORT:-18411}"
PEERS="127.0.0.1:${BASE_PORT},127.0.0.1:$((BASE_PORT + 1)),127.0.0.1:$((BASE_PORT + 2))"
WORKDIR="${KOUTEN_SOAK_WORKDIR:-${TMPDIR:-/tmp}/koutendb-soak-$(date +%Y%m%d-%H%M%S)-$$}"
SECONDS_TO_RUN="${KOUTEN_SOAK_SECONDS:-259200}"
INTERVAL_MS="${KOUTEN_SOAK_INTERVAL_MS:-250}"
REPORT_EVERY="${KOUTEN_SOAK_REPORT_EVERY_SECONDS:-60}"
BIN_DIR="$WORKDIR/bin"
KOUTEND="$BIN_DIR/koutend"
KOUTENCLI="$BIN_DIR/koutencli"
SOAK_RUNNER="$BIN_DIR/soak_runner"
PIDS=()
RUNNER_PID=""

cleanup() {
  if [[ -n "$RUNNER_PID" ]]; then
    kill "$RUNNER_PID" 2>/dev/null || true
    wait "$RUNNER_PID" 2>/dev/null || true
    RUNNER_PID=""
  fi
  if ((${#PIDS[@]} > 0)); then
    kill "${PIDS[@]}" 2>/dev/null || true
    wait "${PIDS[@]}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

cd "$ROOT"
mkdir -p "$WORKDIR" "$BIN_DIR"

echo "[soak] workdir: $WORKDIR"
echo "[soak] peers: $PEERS"
echo "[soak] duration seconds: $SECONDS_TO_RUN"
{
  echo "commit=$(git rev-parse HEAD)"
  echo "startedAt=$(date --iso-8601=seconds)"
  echo "peers=$PEERS"
  echo "durationSec=$SECONDS_TO_RUN"
  echo "intervalMs=$INTERVAL_MS"
  echo "reportEverySec=$REPORT_EVERY"
} >"$WORKDIR/run-config.txt"

echo "[soak] build koutend"
nim c -d:release --nimcache:/tmp/nimcache_koutend_soak -o:"$KOUTEND" src/koutend.nim

echo "[soak] build koutencli"
nim c -d:release --nimcache:/tmp/nimcache_koutencli_soak -o:"$KOUTENCLI" src/koutencli.nim

echo "[soak] build soak runner"
nim c -d:release --nimcache:/tmp/nimcache_kouten_soak_runner -o:"$SOAK_RUNNER" examples/soak_runner.nim

echo "[soak] start 3 nodes"
for id in 0 1 2; do
  mkdir -p "$WORKDIR/node$id"
  "$KOUTEND" --id="$id" --peers="$PEERS" --data="$WORKDIR/node$id" --slow-tick=0.05 >"$WORKDIR/node$id.log" 2>&1 &
  PIDS+=("$!")
done
printf '%s\n' "${PIDS[@]}" >"$WORKDIR/node-pids.txt"

echo "[soak] wait for health"
for _ in $(seq 1 100); do
  if "$KOUTENCLI" health --peers="$PEERS" >"$WORKDIR/health-start.txt" 2>&1; then
    break
  fi
  sleep 0.1
done
"$KOUTENCLI" health --peers="$PEERS" | tee "$WORKDIR/health-start.txt"

echo "[soak] run workload"
KOUTEN_SOAK_PEERS="$PEERS" \
KOUTEN_SOAK_SECONDS="$SECONDS_TO_RUN" \
KOUTEN_SOAK_INTERVAL_MS="$INTERVAL_MS" \
KOUTEN_SOAK_REPORT_EVERY_SECONDS="$REPORT_EVERY" \
KOUTEN_SOAK_OUT="$WORKDIR/soak-progress.jsonl" \
  "$SOAK_RUNNER" &
RUNNER_PID="$!"
echo "$RUNNER_PID" >"$WORKDIR/runner.pid"
wait "$RUNNER_PID"
RUNNER_PID=""

echo "[soak] snapshot and metrics before shutdown"
"$KOUTENCLI" snapshot --peers="$PEERS" | tee "$WORKDIR/snapshot-final.txt"
"$KOUTENCLI" metrics --peers="$PEERS" | tee "$WORKDIR/metrics-final.txt"

echo "[soak] stop nodes for offline verify"
cleanup
PIDS=()

echo "[soak] verify node data directories"
for id in 0 1 2; do
  "$KOUTENCLI" verify --data="$WORKDIR/node$id" --json >"$WORKDIR/verify-node$id.json"
done

touch "$WORKDIR/completed.ok"
echo "[soak] OK"
echo "[soak] progress: $WORKDIR/soak-progress.jsonl"
echo "[soak] logs: $WORKDIR/node*.log"
