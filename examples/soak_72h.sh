#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_PORT="${KOUTEN_SOAK_BASE_PORT:-18411}"
PEERS="127.0.0.1:${BASE_PORT},127.0.0.1:$((BASE_PORT + 1)),127.0.0.1:$((BASE_PORT + 2))"
WORKDIR="${KOUTEN_SOAK_WORKDIR:-${TMPDIR:-/tmp}/koutendb-soak-$(date +%Y%m%d-%H%M%S)-$$}"
SECONDS_TO_RUN="${KOUTEN_SOAK_SECONDS:-259200}"
INTERVAL_MS="${KOUTEN_SOAK_INTERVAL_MS:-250}"
REPORT_EVERY="${KOUTEN_SOAK_REPORT_EVERY_SECONDS:-60}"
SYSTEM_EVERY="${KOUTEN_SOAK_SYSTEM_EVERY_SECONDS:-60}"
AUTO_PACK_INTERVAL="${KOUTEN_SOAK_AUTO_PACK_INTERVAL_SECONDS:-60}"
AUTO_PACK_STALE_RATIO="${KOUTEN_SOAK_AUTO_PACK_STALE_RATIO:-0.20}"
AUTO_PACK_MIN_STALE="${KOUTEN_SOAK_AUTO_PACK_MIN_STALE_RECORDS:-32}"
AUTO_PACK_MAX_RINGS="${KOUTEN_SOAK_AUTO_PACK_MAX_RINGS:-1}"
AUTO_PACK_MAX_BYTES="${KOUTEN_SOAK_AUTO_PACK_MAX_BYTES:-67108864}"
AUTO_PACK_MAX_ELAPSED_MS="${KOUTEN_SOAK_AUTO_PACK_MAX_ELAPSED_MS:-1000}"
QUIESCE_TIMEOUT="${KOUTEN_SOAK_QUIESCE_TIMEOUT_SECONDS:-120}"
BIN_DIR="$WORKDIR/bin"
KOUTEND="$BIN_DIR/koutend"
KOUTENCLI="$BIN_DIR/koutencli"
SOAK_RUNNER="$BIN_DIR/soak_runner"
PIDS=()
RUNNER_PID=""
MONITOR_PID=""

stop_runner() {
  if [[ -n "$RUNNER_PID" ]]; then
    kill "$RUNNER_PID" 2>/dev/null || true
    wait "$RUNNER_PID" 2>/dev/null || true
    RUNNER_PID=""
  fi
}

stop_monitor() {
  touch "$WORKDIR/monitor.stop" 2>/dev/null || true
  if [[ -n "$MONITOR_PID" ]]; then
    wait "$MONITOR_PID" 2>/dev/null || true
    MONITOR_PID=""
  fi
}

stop_nodes() {
  if ((${#PIDS[@]} > 0)); then
    kill "${PIDS[@]}" 2>/dev/null || true
    wait "${PIDS[@]}" 2>/dev/null || true
    PIDS=()
  fi
}

cleanup() {
  stop_runner
  stop_monitor
  stop_nodes
}

finish() {
  local status=$?
  cleanup
  if ((status != 0)) && [[ -d "$WORKDIR" && ! -e "$WORKDIR/completed.ok" ]]; then
    printf 'exitStatus=%s\nfailedAt=%s\n' "$status" "$(date --iso-8601=seconds)" \
      >"$WORKDIR/failed.txt"
  fi
  exit "$status"
}
trap finish EXIT

cd "$ROOT"
if [[ -e "$WORKDIR" ]] && [[ -n "$(find "$WORKDIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "[soak] refusing non-empty workdir: $WORKDIR" >&2
  exit 2
fi
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
  echo "systemEverySec=$SYSTEM_EVERY"
  echo "storage=disk-backed"
  echo "durability=strong"
  echo "autoPackIntervalSec=$AUTO_PACK_INTERVAL"
  echo "autoPackStaleRatio=$AUTO_PACK_STALE_RATIO"
  echo "autoPackMinStaleRecords=$AUTO_PACK_MIN_STALE"
  echo "autoPackMaxRings=$AUTO_PACK_MAX_RINGS"
  echo "autoPackMaxBytes=$AUTO_PACK_MAX_BYTES"
  echo "autoPackMaxElapsedMs=$AUTO_PACK_MAX_ELAPSED_MS"
  echo "quiesceTimeoutSec=$QUIESCE_TIMEOUT"
} >"$WORKDIR/run-config.txt"

echo "[soak] build koutend"
nim c -d:release --nimcache:"$WORKDIR/nimcache/koutend" -o:"$KOUTEND" src/koutend.nim

echo "[soak] build koutencli"
nim c -d:release --nimcache:"$WORKDIR/nimcache/koutencli" -o:"$KOUTENCLI" src/koutencli.nim

echo "[soak] build soak runner"
nim c -d:release --nimcache:"$WORKDIR/nimcache/runner" -o:"$SOAK_RUNNER" examples/soak_runner.nim

echo "[soak] start 3 nodes"
for id in 0 1 2; do
  mkdir -p "$WORKDIR/node$id"
  "$KOUTEND" --id="$id" --peers="$PEERS" --data="$WORKDIR/node$id" \
    --disk-backed --durability=strong --slow-tick=0.05 --auto-pack \
    --auto-pack-interval="$AUTO_PACK_INTERVAL" \
    --auto-pack-stale-ratio="$AUTO_PACK_STALE_RATIO" \
    --auto-pack-min-stale-records="$AUTO_PACK_MIN_STALE" \
    --auto-pack-max-rings="$AUTO_PACK_MAX_RINGS" \
    --auto-pack-max-bytes="$AUTO_PACK_MAX_BYTES" \
    --auto-pack-max-elapsed-ms="$AUTO_PACK_MAX_ELAPSED_MS" \
    >"$WORKDIR/node$id.log" 2>&1 &
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

record_system_sample() {
  local now elapsed first id pid alive rss bytes
  now="$(date +%s)"
  elapsed=$((now - START_EPOCH))
  printf '{"type":"system","timestamp":%s,"elapsedSec":%s,"nodes":[' \
    "$now" "$elapsed" >>"$WORKDIR/system-progress.jsonl"
  first=1
  for id in 0 1 2; do
    pid="${PIDS[$id]}"
    alive=0
    rss=0
    if [[ -r "/proc/$pid/status" ]]; then
      alive=1
      rss="$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status")"
      rss="${rss:-0}"
    fi
    bytes="$(du -sb "$WORKDIR/node$id" | awk '{print $1}')"
    if ((first == 0)); then printf ',' >>"$WORKDIR/system-progress.jsonl"; fi
    printf '{"id":%s,"pid":%s,"alive":%s,"rssKiB":%s,"dataBytes":%s}' \
      "$id" "$pid" "$alive" "$rss" "$bytes" \
      >>"$WORKDIR/system-progress.jsonl"
    first=0
  done
  printf ']}\n' >>"$WORKDIR/system-progress.jsonl"
}

monitor_system() {
  while [[ ! -e "$WORKDIR/monitor.stop" ]]; do
    record_system_sample
    sleep "$SYSTEM_EVERY"
  done
  record_system_sample
}

START_EPOCH="$(date +%s)"
monitor_system &
MONITOR_PID="$!"
echo "$MONITOR_PID" >"$WORKDIR/monitor.pid"

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

echo "[soak] wait for cluster queues to converge"
quiescent=false
for attempt in $(seq 0 "$QUIESCE_TIMEOUT"); do
  if "$KOUTENCLI" metrics --peers="$PEERS" \
      >"$WORKDIR/metrics-quiesce-current.txt" 2>/dev/null &&
      awk '
        BEGIN { bad = 0 }
        {
          for (i = 1; i < NF; i++) {
            if ($i == "handoffPending" || $i == "handoffQueueDepth" ||
                $i == "handoffWorkDepth" || $i == "clusterTxPending" ||
                $i == "migrationRemaining" ||
                $i == "activationMigrationPending") {
              if ($(i + 1) != 0) bad = 1
            }
          }
        }
        END { exit bad }
      ' "$WORKDIR/metrics-quiesce-current.txt"; then
    quiescent=true
    cp "$WORKDIR/metrics-quiesce-current.txt" \
      "$WORKDIR/metrics-quiesced.txt"
    echo "quiescedAfterSec=$attempt" >"$WORKDIR/quiesce.txt"
    break
  fi
  sleep 1
done
if [[ "$quiescent" != true ]]; then
  echo "[soak] cluster queues did not converge within ${QUIESCE_TIMEOUT}s" >&2
  cp "$WORKDIR/metrics-quiesce-current.txt" \
    "$WORKDIR/metrics-quiesce-timeout.txt" 2>/dev/null || true
  exit 1
fi

echo "[soak] snapshot and metrics before shutdown"
"$KOUTENCLI" health --peers="$PEERS" | tee "$WORKDIR/health-final.txt"
"$KOUTENCLI" snapshot --peers="$PEERS" | tee "$WORKDIR/snapshot-final.txt"
"$KOUTENCLI" metrics --peers="$PEERS" | tee "$WORKDIR/metrics-final.txt"

echo "[soak] stop nodes for offline verify"
stop_monitor
stop_nodes

echo "[soak] verify, checkpoint, restore, and compare node data directories"
for id in 0 1 2; do
  source_dir="$WORKDIR/node$id"
  checkpoint_root="$WORKDIR/checkpoints/node$id"
  checkpoint_dir="$checkpoint_root/final"
  restored_dir="$WORKDIR/restored/node$id"
  mkdir -p "$checkpoint_root" "$WORKDIR/restored"
  "$KOUTENCLI" verify --data="$source_dir" --segments --json \
    >"$WORKDIR/verify-node$id.json"
  "$KOUTENCLI" segment-status --data="$source_dir" --json \
    >"$WORKDIR/segment-status-node$id.json"
  "$KOUTENCLI" dump --data="$source_dir" --out="$WORKDIR/dump-node$id.jsonl"
  "$KOUTENCLI" checkpoint-create --data="$source_dir" \
    --checkpoint-root="$checkpoint_root" --checkpoint-id=final \
    --durability=strong --json >"$WORKDIR/checkpoint-node$id.json"
  "$KOUTENCLI" checkpoint-verify --checkpoint="$checkpoint_dir" --json \
    >"$WORKDIR/checkpoint-verify-node$id.json"
  "$KOUTENCLI" checkpoint-restore --checkpoint="$checkpoint_dir" \
    --data="$restored_dir" --json >"$WORKDIR/checkpoint-restore-node$id.json"
  "$KOUTENCLI" verify --data="$restored_dir" --segments --json \
    >"$WORKDIR/verify-restored-node$id.json"
  "$KOUTENCLI" dump --data="$restored_dir" \
    --out="$WORKDIR/dump-restored-node$id.jsonl"
  LC_ALL=C sort "$WORKDIR/dump-node$id.jsonl" \
    >"$WORKDIR/dump-node$id.sorted.jsonl"
  LC_ALL=C sort "$WORKDIR/dump-restored-node$id.jsonl" \
    >"$WORKDIR/dump-restored-node$id.sorted.jsonl"
  cmp "$WORKDIR/dump-node$id.sorted.jsonl" \
    "$WORKDIR/dump-restored-node$id.sorted.jsonl"
done

printf 'completedAt=%s\ncommit=%s\n' "$(date --iso-8601=seconds)" \
  "$(git rev-parse HEAD)" >"$WORKDIR/completed.ok"
echo "[soak] OK"
echo "[soak] progress: $WORKDIR/soak-progress.jsonl"
echo "[soak] logs: $WORKDIR/node*.log"
