#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${KOUTEN_CHURN_WORKDIR:-${TMPDIR:-/tmp}/koutendb-churn-$(date +%Y%m%d-%H%M%S)-$$}"
DURATION="${KOUTEN_CHURN_SECONDS:-3600}"
OPERATIONS="${KOUTEN_CHURN_OPERATIONS:-0}"
BIN="$WORKDIR/accelerated_churn"

cd "$ROOT"
mkdir -p "$WORKDIR"

echo "[accelerated-churn] workdir: $WORKDIR"
echo "[accelerated-churn] duration seconds: $DURATION"
echo "[accelerated-churn] maximum operations: $OPERATIONS"

nim c -d:release --nimcache:/tmp/nimcache_kouten_accelerated_churn \
  -o:"$BIN" examples/accelerated_churn.nim

"$BIN" \
  --data="$WORKDIR/data" \
  --out="$WORKDIR/report.jsonl" \
  --duration-sec="$DURATION" \
  --operations="$OPERATIONS"

echo "[accelerated-churn] report: $WORKDIR/report.jsonl"
echo "[accelerated-churn] completed: $WORKDIR/completed.ok"
