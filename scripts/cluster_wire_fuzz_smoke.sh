#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_PORT="${KOUTEN_CLUSTER_TEST_BASE_PORT:-17711}"
PEERS="127.0.0.1:${BASE_PORT},127.0.0.1:$((BASE_PORT + 1)),127.0.0.1:$((BASE_PORT + 2))"
DATA="${TMPDIR:-/tmp}/koutendb-cluster-wire-fuzz-smoke-$$"
PIDS=()

cleanup() {
  if ((${#PIDS[@]} > 0)); then
    kill "${PIDS[@]}" >/dev/null 2>&1 || true
  fi
  rm -rf "$DATA"
}
trap cleanup EXIT

cd "$ROOT"
mkdir -p "$DATA"

echo "[cluster-wire-fuzz] build koutend"
nim c -d:release -d:koutenTestSmallLimits --nimcache:/tmp/nimcache_koutend_wire_fuzz -o:src/koutend src/koutend.nim

echo "[cluster-wire-fuzz] build koutencli"
nim c -d:release --nimcache:/tmp/nimcache_koutencli_wire_fuzz -o:src/koutencli src/koutencli.nim

echo "[cluster-wire-fuzz] start 3 nodes on $PEERS"
for id in 0 1 2; do
  src/koutend --id="$id" --peers="$PEERS" --data="$DATA/node$id" \
    --slow-tick=0.05 --user=alice --password=secret --allow-ring=allowed &
  PIDS+=("$!")
done

echo "[cluster-wire-fuzz] wait for health"
for _ in $(seq 1 50); do
  if src/koutencli health --peers="$PEERS" --user=alice --password=secret >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
src/koutencli health --peers="$PEERS" --user=alice --password=secret

echo "[cluster-wire-fuzz] run tcluster_wire_fuzz"
KOUTEN_TEST_PEERS="$PEERS" nim c --nimcache:/tmp/nimcache_kouten_tcluster_wire_fuzz -r tests/tcluster_wire_fuzz.nim

echo "[cluster-wire-fuzz] verify retrieve guard audit event"
if ! grep -R '"event":"broad-scan-denied"' "$DATA"/node*/kouten.audit.jsonl >/dev/null 2>&1; then
  echo "missing broad-scan-denied server audit event" >&2
  exit 1
fi

echo "[cluster-wire-fuzz] OK"
