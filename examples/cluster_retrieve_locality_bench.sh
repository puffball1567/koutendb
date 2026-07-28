#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_PORT="${KOUTEN_CLUSTER_LOCALITY_BASE_PORT:-17881}"
PEERS="127.0.0.1:${BASE_PORT},127.0.0.1:$((BASE_PORT + 1))"
DATA="${TMPDIR:-/tmp}/koutendb-cluster-locality-bench-$$"
PIDS=()

cleanup() {
  if ((${#PIDS[@]} > 0)); then
    kill "${PIDS[@]}" 2>/dev/null || true
    wait "${PIDS[@]}" 2>/dev/null || true
  fi
  rm -rf "$DATA"
}
trap cleanup EXIT

cd "$ROOT"
mkdir -p "$DATA" bin

nim c -d:release --nimcache:/tmp/nimcache_kouten_cluster_locality_server \
  -o:src/koutend src/koutend.nim
nim c -d:release --nimcache:/tmp/nimcache_kouten_cluster_locality_bench \
  -o:bin/cluster_retrieve_locality_bench \
  examples/cluster_retrieve_locality_bench.nim

for id in 0 1; do
  src/koutend --id="$id" --peers="$PEERS" --data="$DATA/node$id" \
    --slow-tick=1000 >"$DATA/node$id.log" 2>&1 &
  PIDS+=("$!")
done

KOUTEN_BENCH_PEERS="$PEERS" bin/cluster_retrieve_locality_bench
