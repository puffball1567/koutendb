#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kouten-process-crash.XXXXXX")"
BIN="$WORK_DIR/process-crash-matrix"
PID=""

cleanup() {
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    kill -KILL "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

cd "$ROOT_DIR"
nim c -d:release -d:koutenTestCrashPoints \
  --nimcache:/tmp/nimcache_kouten_process_crash_matrix \
  -o:"$BIN" examples/process_crash_matrix.nim >/dev/null

points=(
  segment-output
  segment-after-data-publish
  segment-before-manifest
  segment-after-manifest
  segment-cleanup
  checkpoint-before-publish
  checkpoint-after-publish
  backup-before-publish
  backup-after-publish
)

for point in "${points[@]}"; do
  case_root="$WORK_DIR/case-$point"
  ready="$WORK_DIR/ready-$point"
  log="$WORK_DIR/worker-$point.log"
  mkdir -p "$case_root"

  "$BIN" --mode=worker --root="$case_root" --point="$point" \
    --ready="$ready" >"$log" 2>&1 &
  PID=$!

  reached=0
  for _ in $(seq 1 1000); do
    if [[ -f "$ready" ]]; then
      reached=1
      break
    fi
    if ! kill -0 "$PID" 2>/dev/null; then
      echo "[process-crash-matrix] worker exited before $point" >&2
      cat "$log" >&2
      exit 1
    fi
    sleep 0.01
  done

  if [[ "$reached" -ne 1 ]]; then
    echo "[process-crash-matrix] timed out waiting for $point" >&2
    cat "$log" >&2
    exit 1
  fi
  if [[ "$(tr -d '\r\n' < "$ready")" != "$point" ]]; then
    echo "[process-crash-matrix] readiness marker mismatch for $point" >&2
    exit 1
  fi

  kill -KILL "$PID"
  wait "$PID" 2>/dev/null || true
  PID=""

  "$BIN" --mode=verify --root="$case_root" --point="$point"
done

echo "[process-crash-matrix] all publication boundaries passed"
