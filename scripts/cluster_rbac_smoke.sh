#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_PORT="${KOUTEN_CLUSTER_TEST_BASE_PORT:-17811}"
PEERS="127.0.0.1:${BASE_PORT}"
DATA="${TMPDIR:-/tmp}/koutendb-cluster-rbac-smoke-$$"
PID=""

cleanup() {
  if [[ -n "$PID" ]]; then
    kill "$PID" >/dev/null 2>&1 || true
    wait "$PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$DATA"
}
trap cleanup EXIT

cd "$ROOT"
mkdir -p "$DATA"

echo "[cluster-rbac] build koutend"
nim c -d:release --nimcache:/tmp/nimcache_koutend_rbac -o:src/koutend src/koutend.nim

echo "[cluster-rbac] build koutencli"
nim c -d:release --nimcache:/tmp/nimcache_koutencli_rbac -o:src/koutencli src/koutencli.nim

echo "[cluster-rbac] start node on $PEERS"
printf 'read\n' > "$DATA/reader-password"
cat >"$DATA/server.json" <<JSON
{
  "id": 0,
  "peers": "$PEERS",
  "data": "$DATA/node0",
  "slow-tick": 0.05,
  "roles": [
    {
      "user": "reader",
      "passwordFile": "$DATA/reader-password",
      "role": "reader",
      "prefixes": ["allowed"]
    },
    "writer:write:writer:allowed",
    "admin:admin:admin:allowed"
  ]
}
JSON
src/koutend --config="$DATA/server.json" &
PID="$!"

echo "[cluster-rbac] wait for health"
for _ in $(seq 1 50); do
  if src/koutencli health --peers="$PEERS" --user=admin --password=admin >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

echo "[cluster-rbac] cli drain/snapshot/resume"
src/koutencli drain --peers="$PEERS" --user=admin --password=admin |
  grep -q "draining"
src/koutencli snapshot --peers="$PEERS" --user=admin --password=admin |
  grep -q "pendingTx"
src/koutencli metrics --peers="$PEERS" --user=admin --password=admin |
  grep -q "draining 1"
src/koutencli resume --peers="$PEERS" --user=admin --password=admin |
  grep -q "resumed"
src/koutencli metrics --peers="$PEERS" --user=admin --password=admin |
  grep -q "draining 0"

echo "[cluster-rbac] run tcluster_rbac"
KOUTEN_TEST_PEERS="$PEERS" nim c --nimcache:/tmp/nimcache_kouten_tcluster_rbac -r tests/tcluster_rbac.nim

echo "[cluster-rbac] OK"
