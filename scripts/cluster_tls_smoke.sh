#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DATA="${TMPDIR:-/tmp}/koutendb-cluster-tls-smoke-$$"
PORT="${KOUTEN_TLS_SMOKE_PORT:-$((17651 + ($$ % 1000)))}"
PEERS="localhost:${PORT},localhost:$((PORT + 1)),localhost:$((PORT + 2))"
CERT="$DATA/server.crt"
KEY="$DATA/server.key"
CA_CERT="$DATA/ca.crt"
CA_KEY="$DATA/ca.key"
CSR="$DATA/server.csr"
EXT="$DATA/server.ext"
PIDS=()

cleanup() {
  if ((${#PIDS[@]} > 0)); then
    kill "${PIDS[@]}" >/dev/null 2>&1 || true
    wait "${PIDS[@]}" >/dev/null 2>&1 || true
  fi
  rm -rf "$DATA"
}
trap cleanup EXIT

for id in 0 1 2; do
  mkdir -p "$DATA/node$id"
done

echo "[cluster-tls] generate test CA and server certificate"
openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
  -keyout "$CA_KEY" \
  -out "$CA_CERT" \
  -subj "/CN=KoutenDB Test CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
openssl req -nodes -newkey rsa:2048 \
  -keyout "$KEY" \
  -out "$CSR" \
  -subj "/CN=localhost" >/dev/null 2>&1
cat >"$EXT" <<'EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
EXT
openssl x509 -req -in "$CSR" \
  -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
  -out "$CERT" -days 1 -sha256 -extfile "$EXT" >/dev/null 2>&1

echo "[cluster-tls] build TLS-enabled koutend"
nim c -d:ssl -d:release --nimcache:/tmp/nimcache_koutend_tls \
  -o:src/koutend src/koutend.nim >/dev/null

echo "[cluster-tls] build TLS-enabled kouten CLI"
nim c -d:ssl -d:release --nimcache:/tmp/nimcache_koutencli_tls \
  -o:src/koutencli src/koutencli.nim >/dev/null

echo "[cluster-tls] start 3 TLS koutend nodes on $PEERS"
for id in 0 1 2; do
  src/koutend --id="$id" --peers="$PEERS" --data="$DATA/node$id" \
    --user=alice --password=secret --secret-key=shared-secret \
    --tls-cert="$CERT" --tls-key="$KEY" --tls-ca="$CA_CERT" \
    --tls-server-name=localhost \
    --slow-tick=0.05 >"$DATA/node$id.log" 2>&1 &
  PIDS+=("$!")
done

for _ in $(seq 1 60); do
  if src/koutencli health --peers="$PEERS" --user=alice --password=secret \
      --secret-key=shared-secret --tls --tls-ca="$CA_CERT" \
      --tls-server-name=localhost >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

echo "[cluster-tls] health over TLS"
src/koutencli health --peers="$PEERS" --user=alice --password=secret \
  --secret-key=shared-secret --tls --tls-ca="$CA_CERT" \
  --tls-server-name=localhost

echo "[cluster-tls] put JSON over TLS"
PUT_OUTPUT="$(src/koutencli put --peers="$PEERS" --user=alice --password=secret \
  --secret-key=shared-secret --tls --tls-ca="$CA_CERT" \
  --tls-server-name=localhost \
  --ring=secure/demo --codec=json --payload='{"title":"tls smoke","ok":true}')"
echo "$PUT_OUTPUT"
RAW_ID="$(printf '%s\n' "$PUT_OUTPUT" | sed -n 's/.*rawId=\([^ ]*\).*/\1/p')"
test -n "$RAW_ID"

echo "[cluster-tls] get JSON over TLS"
GET_OUTPUT="$(src/koutencli get --peers="$PEERS" --user=alice --password=secret \
  --secret-key=shared-secret --tls --tls-ca="$CA_CERT" \
  --tls-server-name=localhost \
  --ring=secure/demo --filter="{\"id\":\"$RAW_ID\"}" --selection='{ title ok }')"
echo "$GET_OUTPUT"
printf '%s\n' "$GET_OUTPUT" | grep -q '"title": "tls smoke"'
printf '%s\n' "$GET_OUTPUT" | grep -q '"ok": true'

echo "[cluster-tls] verify authenticated handoff mutation ordering"
nim c -d:ssl -d:release --nimcache:/tmp/nimcache_kouten_handoff_tls \
  -o:bin/handoff_ordering_remote tests/thandoff_ordering_remote.nim >/dev/null
KOUTEN_TEST_PEERS="$PEERS" \
KOUTEN_TEST_CA="$CA_CERT" \
KOUTEN_TEST_USER=alice \
KOUTEN_TEST_PASSWORD=secret \
KOUTEN_TEST_SECRET_KEY=shared-secret \
KOUTEN_TEST_SERVER_NAME=localhost \
  bin/handoff_ordering_remote

echo "[cluster-tls] query the same ID after authenticated transfer checks"
QUERY_OUTPUT="$(src/koutencli query --peers="$PEERS" --user=alice --password=secret \
  --secret-key=shared-secret --tls --tls-ca="$CA_CERT" \
  --tls-server-name=localhost \
  --ring=secure/demo --id="$RAW_ID" --selection='{ title ok }')"
echo "$QUERY_OUTPUT"
printf '%s\n' "$QUERY_OUTPUT" | grep -q '"title": "tls smoke"'
printf '%s\n' "$QUERY_OUTPUT" | grep -q '"ok": true'

echo "[cluster-tls] plain client must not pass against TLS listener"
if src/koutencli health --peers="$PEERS" --user=alice --password=secret \
    --secret-key=shared-secret >/dev/null 2>&1; then
  echo "plain client unexpectedly succeeded against TLS listener" >&2
  exit 1
fi

echo "[cluster-tls] OK"
