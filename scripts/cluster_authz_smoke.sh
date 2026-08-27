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
nim c -d:release -d:koutenTestAuthThrottle \
  --nimcache:/tmp/nimcache_koutend_authz -o:src/koutend src/koutend.nim

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
if src/koutend --id=0 --peers="127.0.0.1:1" --data="$DATA/bad-open-authz" \
    --allow-ring=allowed >/dev/null 2>&1; then
  echo "koutend accepted ring authorization without authentication" >&2
  exit 1
fi
cat >"$DATA/bad-open-authz.json" <<JSON
{
  "id": 0,
  "peers": ["127.0.0.1:1"],
  "data": "$DATA/bad-open-authz-config",
  "allowRing": ["allowed"]
}
JSON
if src/koutencli verify --server-config="$DATA/bad-open-authz.json" \
    >/dev/null 2>&1; then
  echo "config verifier accepted ring authorization without authentication" >&2
  exit 1
fi
if src/koutend --id=0 --peers="0.0.0.0:1" --data="$DATA/bad-plaintext-auth" \
    --user=alice --password=secret >/dev/null 2>&1; then
  echo "koutend accepted remote plaintext password auth without opt-in" >&2
  exit 1
fi
cat >"$DATA/bad-peer-missing.json" <<JSON
{
  "id": 0,
  "peers": ["127.0.0.1:1", "127.0.0.1:2"],
  "roles": ["writer:write:writer", "sync:replicate:replicator"]
}
JSON
if src/koutend --config="$DATA/bad-peer-missing.json" >/dev/null 2>&1; then
  echo "koutend accepted multi-node roles without peerAuth" >&2
  exit 1
fi
if src/koutencli verify --server-config="$DATA/bad-peer-missing.json" \
    >/dev/null 2>&1; then
  echo "config verifier accepted multi-node roles without peerAuth" >&2
  exit 1
fi
for scenario in unknown writer; do
  peer_user="missing"
  if [[ "$scenario" == "writer" ]]; then
    peer_user="writer"
  fi
  cat >"$DATA/bad-peer-$scenario.json" <<JSON
{
  "id": 0,
  "peers": ["127.0.0.1:1", "127.0.0.1:2"],
  "roles": ["writer:write:writer", "sync:replicate:replicator"],
  "peerAuth": {"user": "$peer_user"}
}
JSON
  if src/koutend --config="$DATA/bad-peer-$scenario.json" >/dev/null 2>&1; then
    echo "koutend accepted invalid peerAuth $scenario user" >&2
    exit 1
  fi
  if src/koutencli verify --server-config="$DATA/bad-peer-$scenario.json" \
      >/dev/null 2>&1; then
    echo "config verifier accepted invalid peerAuth $scenario user" >&2
    exit 1
  fi
done
cat >"$DATA/bad-peer-password.json" <<JSON
{
  "id": 0,
  "peers": ["127.0.0.1:1", "127.0.0.1:2"],
  "roles": ["sync:replicate:replicator"],
  "peerAuth": {"user": "sync", "password": "duplicate"}
}
JSON
if src/koutend --config="$DATA/bad-peer-password.json" >/dev/null 2>&1; then
  echo "koutend accepted duplicate password inside peerAuth" >&2
  exit 1
fi
cat >"$DATA/bad-peer-secret-only.json" <<JSON
{
  "id": 0,
  "peers": ["127.0.0.1:1", "127.0.0.1:2"],
  "roles": ["sync:replicate:replicator"],
  "peerAuth": {"user": "sync", "secretKey": "outbound-only"}
}
JSON
if src/koutend --config="$DATA/bad-peer-secret-only.json" >/dev/null 2>&1; then
  echo "koutend accepted peer secret without inbound secret-key gate" >&2
  exit 1
fi
if src/koutencli verify --server-config="$DATA/bad-peer-secret-only.json" \
    >/dev/null 2>&1; then
  echo "config verifier accepted peer secret without inbound gate" >&2
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
  "galaxy": "authz",
  "slowTick": 0.05,
  "coordinatorEpoch": 1,
  "coordinatorNode": 0,
  "coordinatorReplica": 1,
  "roles": [
    {
      "user": "alice",
      "passwordFile": "$DATA/password",
      "role": "writer",
      "prefixes": ["allowed"]
    },
    "sync:replicate:replicator:allowed",
    "admin:admin:admin"
  ],
  "peerAuth": {"user": "sync"}
}
JSON
  src/koutencli verify --server-config="$DATA/server-$id.json" >/dev/null
  if [[ "$id" == "1" ]]; then
    KOUTEN_SERVER_CONFIG="$DATA/server-$id.json" src/koutend &
  else
    src/koutend --config="$DATA/server-$id.json" &
  fi
  PIDS+=("$!")
done

echo "[cluster-authz] wait for health"
for _ in $(seq 1 50); do
  if KOUTEN_PASSWORD=secret src/koutencli health --peers="$PEERS" --user=alice --galaxy=authz >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
KOUTEN_PASSWORD=secret src/koutencli health --peers="$PEERS" --user=alice --galaxy=authz

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
if ! grep -R '"event":"auth-throttled"' "$DATA"/node*/kouten.audit.jsonl >/dev/null 2>&1; then
  echo "missing auth-throttled server audit event" >&2
  exit 1
fi

echo "[cluster-authz] OK"
