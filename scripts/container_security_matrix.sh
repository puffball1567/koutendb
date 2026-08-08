#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v docker >/dev/null 2>&1; then
  echo "[container-security] docker command is required" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "[container-security] docker daemon is unavailable" >&2
  exit 1
fi

PREFIX="kouten-v012-security-$$"
IMAGE="$PREFIX:local"
NETWORK="$PREFIX-net"
SERVER="$PREFIX-server"
EXPIRED_SERVER="$PREFIX-expired"
VOLUME="$PREFIX-data"
EXPIRED_VOLUME="$PREFIX-expired-data"
WORK="${KOUTEN_CONTAINER_WORK_ROOT:-$ROOT/.tmp}/$PREFIX"
PASSWORD="container-password"
SECRET="container-secret"
ROTATED_PASSWORD="rotated-password"
ROTATED_SECRET="rotated-secret"

cleanup() {
  docker rm -f "$SERVER" "$EXPIRED_SERVER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME" "$EXPIRED_VOLUME" >/dev/null 2>&1 || true
  if [[ "${KOUTEN_CONTAINER_KEEP_IMAGE:-0}" != "1" ]]; then
    docker image rm "$IMAGE" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/certs" "$WORK/secrets" "$WORK/expired-ca/newcerts"
printf '%s\n' "$PASSWORD" >"$WORK/secrets/password"
printf '%s\n' "$SECRET" >"$WORK/secrets/secret-key"
chmod 600 "$WORK/secrets/password" "$WORK/secrets/secret-key"

echo "[container-security] generate test CA and server certificates"
openssl req -x509 -nodes -newkey rsa:2048 -days 2 \
  -keyout "$WORK/certs/ca.key" -out "$WORK/certs/ca.crt" \
  -subj "/CN=KoutenDB Container Test CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
openssl req -nodes -newkey rsa:2048 \
  -keyout "$WORK/certs/server.key" -out "$WORK/certs/server.csr" \
  -subj "/CN=$SERVER" >/dev/null 2>&1
cat >"$WORK/certs/server.ext" <<EXT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:$SERVER,DNS:$EXPIRED_SERVER,DNS:localhost,IP:127.0.0.1
EXT
openssl x509 -req -in "$WORK/certs/server.csr" \
  -CA "$WORK/certs/ca.crt" -CAkey "$WORK/certs/ca.key" -CAcreateserial \
  -out "$WORK/certs/server.crt" -days 2 -sha256 \
  -extfile "$WORK/certs/server.ext" >/dev/null 2>&1

openssl req -x509 -nodes -newkey rsa:2048 -days 2 \
  -keyout "$WORK/certs/wrong-ca.key" -out "$WORK/certs/wrong-ca.crt" \
  -subj "/CN=Wrong Container Test CA" >/dev/null 2>&1

cat >"$WORK/expired-ca/openssl.cnf" <<EOF
[ ca ]
default_ca = test_ca

[ test_ca ]
dir = $WORK/expired-ca
database = \$dir/index.txt
new_certs_dir = \$dir/newcerts
certificate = $WORK/certs/ca.crt
private_key = $WORK/certs/ca.key
serial = \$dir/serial
default_md = sha256
policy = test_policy
copy_extensions = copy

[ test_policy ]
commonName = supplied
EOF
: >"$WORK/expired-ca/index.txt"
printf '1000\n' >"$WORK/expired-ca/serial"
openssl ca -batch -config "$WORK/expired-ca/openssl.cnf" \
  -in "$WORK/certs/server.csr" -out "$WORK/certs/expired.crt" \
  -startdate 20200101000000Z -enddate 20200102000000Z >/dev/null 2>&1

echo "[container-security] build TLS-enabled image"
docker build -f examples/compose/Dockerfile -t "$IMAGE" . >/dev/null
docker network create "$NETWORK" >/dev/null
docker volume create "$VOLUME" >/dev/null
docker volume create "$EXPIRED_VOLUME" >/dev/null

start_server() {
  docker run -d --name "$SERVER" --network "$NETWORK" \
    -v "$VOLUME:/data" -v "$WORK/certs:/certs:ro" \
    -v "$WORK/secrets:/run/kouten-secrets:ro" \
    "$IMAGE" \
    --id=0 --peers="$SERVER:7301" --data=/data/secure \
    --galaxy=secure --disk-backed --durability=strong \
    --user=app --password-file=/run/kouten-secrets/password \
    --secret-key-file=/run/kouten-secrets/secret-key \
    --allow-ring=secure \
    --tls-cert=/certs/server.crt --tls-key=/certs/server.key \
    --tls-ca=/certs/ca.crt --tls-server-name="$SERVER" \
    --slow-tick=0.05 >/dev/null
}

client() {
  docker run --rm --network "$NETWORK" -v "$WORK/certs:/certs:ro" \
    --entrypoint koutencli "$IMAGE" "$@"
}

health() {
  client health --peers="$SERVER:7301" --galaxy=secure \
    --user=app --password="$1" --secret-key="$2" \
    --tls --tls-ca=/certs/ca.crt --tls-server-name="$SERVER"
}

wait_for_health() {
  for _ in $(seq 1 60); do
    if health "$1" "$2" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  docker logs "$SERVER" >&2 || true
  return 1
}

expect_failure() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "[container-security] unexpectedly succeeded: $description" >&2
    exit 1
  fi
}

echo "[container-security] start persistent TLS/auth server"
start_server
wait_for_health "$PASSWORD" "$SECRET"

echo "[container-security] reject invalid TLS and credential paths"
expect_failure "plain client against TLS listener" \
  client health --peers="$SERVER:7301" --user=app --password="$PASSWORD" \
    --secret-key="$SECRET"
expect_failure "untrusted CA" \
  client health --peers="$SERVER:7301" --user=app --password="$PASSWORD" \
    --secret-key="$SECRET" --tls --tls-ca=/certs/wrong-ca.crt \
    --tls-server-name="$SERVER"
expect_failure "wrong TLS hostname" \
  client health --peers="$SERVER:7301" --user=app --password="$PASSWORD" \
    --secret-key="$SECRET" --tls --tls-ca=/certs/ca.crt \
    --tls-server-name=not-the-server
expect_failure "wrong username" \
  client health --peers="$SERVER:7301" --user=other --password="$PASSWORD" \
    --secret-key="$SECRET" --tls --tls-ca=/certs/ca.crt \
    --tls-server-name="$SERVER"
expect_failure "wrong password" \
  client health --peers="$SERVER:7301" --user=app --password=wrong \
    --secret-key="$SECRET" --tls --tls-ca=/certs/ca.crt \
    --tls-server-name="$SERVER"
expect_failure "wrong secret key" \
  client health --peers="$SERVER:7301" --user=app --password="$PASSWORD" \
    --secret-key=wrong --tls --tls-ca=/certs/ca.crt \
    --tls-server-name="$SERVER"
expect_failure "missing secret key" \
  client health --peers="$SERVER:7301" --user=app --password="$PASSWORD" \
    --tls --tls-ca=/certs/ca.crt --tls-server-name="$SERVER"

echo "[container-security] write allowed ring and reject denied ring"
PUT_OUTPUT="$(client put --peers="$SERVER:7301" --galaxy=secure \
  --user=app --password="$PASSWORD" --secret-key="$SECRET" \
  --tls --tls-ca=/certs/ca.crt --tls-server-name="$SERVER" \
  --ring=secure/profile --codec=json \
  --payload='{"name":"container","persisted":true}')"
RAW_ID="$(printf '%s\n' "$PUT_OUTPUT" | sed -n 's/.*rawId=\([^ ]*\).*/\1/p')"
test -n "$RAW_ID"
expect_failure "ring authorization denial" \
  client put --peers="$SERVER:7301" --galaxy=secure \
    --user=app --password="$PASSWORD" --secret-key="$SECRET" \
    --tls --tls-ca=/certs/ca.crt --tls-server-name="$SERVER" \
    --ring=denied/profile --payload='{"denied":true}' --codec=json

echo "[container-security] restart the same container and retain data"
docker restart "$SERVER" >/dev/null
wait_for_health "$PASSWORD" "$SECRET"
client get --peers="$SERVER:7301" --galaxy=secure \
  --user=app --password="$PASSWORD" --secret-key="$SECRET" \
  --tls --tls-ca=/certs/ca.crt --tls-server-name="$SERVER" \
  --ring=secure/profile --filter="{\"id\":\"$RAW_ID\"}" |
  grep -q '"persisted": true'

echo "[container-security] disconnect and reconnect the Docker network"
docker network disconnect "$NETWORK" "$SERVER"
expect_failure "network interruption" \
  client health --peers="$SERVER:7301" --user=app --password="$PASSWORD" \
    --secret-key="$SECRET" --tls --tls-ca=/certs/ca.crt \
    --tls-server-name="$SERVER"
docker network connect --alias "$SERVER" "$NETWORK" "$SERVER"
wait_for_health "$PASSWORD" "$SECRET"

echo "[container-security] replace container, rotate credentials, retain volume"
docker rm -f "$SERVER" >/dev/null
printf '%s\n' "$ROTATED_PASSWORD" >"$WORK/secrets/password"
printf '%s\n' "$ROTATED_SECRET" >"$WORK/secrets/secret-key"
start_server
wait_for_health "$ROTATED_PASSWORD" "$ROTATED_SECRET"
expect_failure "old credentials after rotation" health "$PASSWORD" "$SECRET"
client get --peers="$SERVER:7301" --galaxy=secure \
  --user=app --password="$ROTATED_PASSWORD" --secret-key="$ROTATED_SECRET" \
  --tls --tls-ca=/certs/ca.crt --tls-server-name="$SERVER" \
  --ring=secure/profile --filter="{\"id\":\"$RAW_ID\"}" |
  grep -q '"name": "container"'

echo "[container-security] expired certificate fails closed"
docker run -d --name "$EXPIRED_SERVER" --network "$NETWORK" \
  -v "$EXPIRED_VOLUME:/data" -v "$WORK/certs:/certs:ro" \
  -v "$WORK/secrets:/run/kouten-secrets:ro" \
  "$IMAGE" \
  --id=0 --peers="$EXPIRED_SERVER:7301" --data=/data/expired \
  --disk-backed --durability=strong \
  --user=app --password-file=/run/kouten-secrets/password \
  --secret-key-file=/run/kouten-secrets/secret-key \
  --tls-cert=/certs/expired.crt --tls-key=/certs/server.key \
  --tls-ca=/certs/ca.crt --tls-server-name="$EXPIRED_SERVER" \
  --slow-tick=0.05 >/dev/null
EXPIRED_READY=0
for _ in $(seq 1 40); do
  if docker run --rm --network "$NETWORK" --entrypoint /bin/sh "$IMAGE" \
      -c "printf '' | openssl s_client -connect '$EXPIRED_SERVER:7301' -servername '$EXPIRED_SERVER' -no_check_time >/dev/null 2>&1"; then
    EXPIRED_READY=1
    break
  fi
  sleep 0.25
done
if [[ "$EXPIRED_READY" != "1" ]]; then
  docker logs "$EXPIRED_SERVER" >&2 || true
  echo "[container-security] expired-certificate listener did not become ready" >&2
  exit 1
fi
test "$(docker inspect -f '{{.State.Running}}' "$EXPIRED_SERVER")" = "true"
expect_failure "expired certificate" \
  client health --peers="$EXPIRED_SERVER:7301" --user=app \
    --password="$ROTATED_PASSWORD" --secret-key="$ROTATED_SECRET" \
    --tls --tls-ca=/certs/ca.crt --tls-server-name="$EXPIRED_SERVER"
docker rm -f "$EXPIRED_SERVER" >/dev/null

echo "[container-security] offline verify persisted volume and audit evidence"
docker stop "$SERVER" >/dev/null
docker run --rm -v "$VOLUME:/data" --entrypoint koutencli "$IMAGE" \
  verify --data=/data/secure --segments --json | grep -q '"kind": "data"'
docker run --rm -v "$VOLUME:/data" --entrypoint /bin/sh "$IMAGE" \
  -c "grep -q '\"event\":\"auth-failure\"' /data/secure/kouten.audit.jsonl && grep -q '\"event\":\"authz-denied\"' /data/secure/kouten.audit.jsonl"

echo "[container-security] OK"
