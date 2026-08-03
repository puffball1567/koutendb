#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_PORT="${KOUTEN_CLUSTER_TEST_BASE_PORT:-17611}"
PEERS="127.0.0.1:${BASE_PORT},127.0.0.1:$((BASE_PORT + 1)),127.0.0.1:$((BASE_PORT + 2))"
DATA="${TMPDIR:-/tmp}/koutendb-cluster-authz-smoke-$$"
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
mkdir -p "$DATA"

echo "[cluster-authz] build koutend"
nim c -d:release --nimcache:/tmp/nimcache_koutend_authz -o:src/koutend src/koutend.nim

echo "[cluster-authz] build koutencli"
nim c -d:release --nimcache:/tmp/nimcache_koutencli_authz -o:src/koutencli src/koutencli.nim

echo "[cluster-authz] unusable auth config fails closed"
if src/koutend --id=0 --peers="127.0.0.1:1" --data="$DATA/bad-secret" \
    --secret-key=secret >/dev/null 2>&1; then
  echo "koutend accepted --secret-key without --user/--password" >&2
  exit 1
fi
if src/koutend --id=0 --peers="127.0.0.1:1" --data="$DATA/bad-password" \
    --user=alice >/dev/null 2>&1; then
  echo "koutend accepted --user without --password" >&2
  exit 1
fi
cat >"$DATA/bad-server-config.json" <<JSON
{
  "id": 0,
  "peers": ["127.0.0.1:1"],
  "data": "$DATA/bad-config-secret",
  "secretKey": "secret"
}
JSON
if src/koutend --config="$DATA/bad-server-config.json" >/dev/null 2>&1; then
  echo "koutend accepted server config secretKey without user/password" >&2
  exit 1
fi

echo "[cluster-authz] start 3 nodes on $PEERS"
printf 'secret\n' > "$DATA/password"
for id in 0 1 2; do
  cat >"$DATA/server-$id.json" <<JSON
{
  "id": $id,
  "peers": ["127.0.0.1:${BASE_PORT}", "127.0.0.1:$((BASE_PORT + 1))", "127.0.0.1:$((BASE_PORT + 2))"],
  "dataDir": "$DATA/node$id",
  "slowTick": 0.05,
  "user": "alice",
  "passwordFile": "$DATA/password",
  "allowRing": ["allowed"]
}
JSON
  if [[ "$id" == "1" ]]; then
    KOUTEN_SERVER_CONFIG="$DATA/server-$id.json" src/koutend &
  else
    src/koutend --config="$DATA/server-$id.json" &
  fi
  PIDS+=("$!")
done

echo "[cluster-authz] wait for health"
for _ in $(seq 1 50); do
  if KOUTEN_PASSWORD=secret src/koutencli health --peers="$PEERS" --user=alice >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
KOUTEN_PASSWORD=secret src/koutencli health --peers="$PEERS" --user=alice

echo "[cluster-authz] generate denied auth audit event"
KOUTEN_PASSWORD=wrong src/koutencli health --peers="$PEERS" --user=alice >/dev/null 2>&1 || true

echo "[cluster-authz] run tcluster_authz"
KOUTEN_TEST_PEERS="$PEERS" nim c --nimcache:/tmp/nimcache_kouten_tcluster_authz -r tests/tcluster_authz.nim

echo "[cluster-authz] verify server audit events"
if ! grep -R '"event":"auth-failure"' "$DATA"/node*/kouten.audit.jsonl >/dev/null 2>&1; then
  echo "missing auth-failure server audit event" >&2
  exit 1
fi
if ! grep -R '"event":"authz-denied"' "$DATA"/node*/kouten.audit.jsonl >/dev/null 2>&1; then
  echo "missing authz-denied server audit event" >&2
  exit 1
fi

echo "[cluster-authz] OK"
