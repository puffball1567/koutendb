#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IMAGE="${KOUTEN_CONTAINER_IMAGE:-koutendb:container-smoke}"
UPGRADE_IMAGE="${IMAGE}-upgrade"
FAILING_IMAGE="${IMAGE}-failing"
PREFIX="koutendb-selfhost-smoke-$$"
WORK="${KOUTEN_SELFHOST_TEST_ROOT:-$ROOT/.tmp}/$PREFIX"
BUNDLE="$WORK/bundle"
CONTAINER="$PREFIX-node"
PROJECT="$PREFIX"

cleanup() {
  if [[ -f "$BUNDLE/compose.yaml" ]]; then
    KOUTENDB_IMAGE="$IMAGE" KOUTENDB_CONTAINER_NAME="$CONTAINER" \
      docker compose -p "$PROJECT" --project-directory "$BUNDLE" \
      -f "$BUNDLE/compose.yaml" down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  docker image rm "$UPGRADE_IMAGE" "$FAILING_IMAGE" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "[self-host] generate isolated bundle"
mkdir -p "$WORK"

if KOUTENDB_VERSION=not-a-version \
    deploy/self-hosted/bootstrap.sh "$WORK/invalid-version" >/dev/null 2>&1; then
  echo "[self-host] bootstrap accepted an invalid image version" >&2
  exit 1
fi

mkdir -p "$WORK/non-empty"
printf 'keep\n' >"$WORK/non-empty/existing-file"
if deploy/self-hosted/bootstrap.sh "$WORK/non-empty" >/dev/null 2>&1; then
  echo "[self-host] bootstrap overwrote a non-empty directory" >&2
  exit 1
fi
test "$(cat "$WORK/non-empty/existing-file")" = "keep"

mkdir -p "$WORK/symlink-target"
ln -s "$WORK/symlink-target" "$WORK/symlink-output"
if deploy/self-hosted/bootstrap.sh "$WORK/symlink-output" >/dev/null 2>&1; then
  echo "[self-host] bootstrap accepted a symlink output directory" >&2
  exit 1
fi

KOUTENDB_VERSION=0.14.0 deploy/self-hosted/bootstrap.sh "$BUNDLE" >/dev/null
sed -i "s|^KOUTENDB_IMAGE=.*|KOUTENDB_IMAGE=$IMAGE|" "$BUNDLE/.env"
test -x "$BUNDLE/operator.sh"
test "$(stat -c '%a' "$BUNDLE/secrets/password")" = "600"
test "$(stat -c '%a' "$BUNDLE/operator/ca.key")" = "600"
test "$(stat -c '%a' "$BUNDLE/certs/server.key")" = "600"
openssl verify -CAfile "$BUNDLE/certs/ca.crt" "$BUNDLE/certs/server.crt" |
  grep ': OK' >/dev/null
openssl x509 -in "$BUNDLE/certs/server.crt" -noout -ext subjectAltName |
  grep 'DNS:koutendb' >/dev/null
if grep -R -E 'change-me|password"[[:space:]]*:' "$BUNDLE/config"; then
  echo "[self-host] plaintext secret found in config" >&2
  exit 1
fi

echo "[self-host] validate and start hardened Compose service"
KOUTENDB_IMAGE="$IMAGE" KOUTENDB_CONTAINER_NAME="$CONTAINER" \
  docker compose -p "$PROJECT" --project-directory "$BUNDLE" \
  -f "$BUNDLE/compose.yaml" config >/dev/null
if ! KOUTENDB_IMAGE="$IMAGE" KOUTENDB_CONTAINER_NAME="$CONTAINER" \
    docker compose -p "$PROJECT" --project-directory "$BUNDLE" \
    -f "$BUNDLE/compose.yaml" up -d >/dev/null; then
  KOUTENDB_IMAGE="$IMAGE" KOUTENDB_CONTAINER_NAME="$CONTAINER" \
    docker compose -p "$PROJECT" --project-directory "$BUNDLE" \
    -f "$BUNDLE/compose.yaml" logs koutendb-secrets >&2 || true
  exit 1
fi

for _ in $(seq 1 60); do
  STATUS="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$CONTAINER")"
  [[ "$STATUS" == "healthy" ]] && break
  sleep 0.5
done
if [[ "${STATUS:-}" != "healthy" ]]; then
  docker inspect --format '{{json .State}}' "$CONTAINER" >&2 || true
  docker logs "$CONTAINER" >&2 || true
  echo "[self-host] service did not become healthy" >&2
  exit 1
fi
test "$(docker inspect --format '{{.Config.User}}' "$CONTAINER")" = "10001:10001"
test "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$CONTAINER")" = "true"
docker exec "$CONTAINER" sh -ec '
  test "$(stat -c %u:%g /run/secrets/koutendb_password)" = "10001:10001"
  test "$(stat -c %a /run/secrets/koutendb_password)" = "400"
  test "$(stat -c %a /run/secrets/koutendb_server_key)" = "400"
'

docker exec "$CONTAINER" kouten put --config=/etc/koutendb/client.json \
  --ring=ops/selfhost --payload='{"survives":true}' --codec=json >/dev/null
BEFORE_RESTARTS="$(docker inspect --format '{{.RestartCount}}' "$CONTAINER")"
docker exec "$CONTAINER" sh -c '
  for proc_dir in /proc/[0-9]*; do
    if [ "$(cat "$proc_dir/comm" 2>/dev/null)" = "koutend" ]; then
      kill -9 "${proc_dir##*/}"
      exit 0
    fi
  done
  exit 1
' >/dev/null
for _ in $(seq 1 80); do
  RUNNING="$(docker inspect --format '{{.State.Running}}' "$CONTAINER")"
  STATUS="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$CONTAINER")"
  AFTER_RESTARTS="$(docker inspect --format '{{.RestartCount}}' "$CONTAINER")"
  if [[ "$RUNNING" == "true" && "$STATUS" == "healthy" &&
        "$AFTER_RESTARTS" -gt "$BEFORE_RESTARTS" ]]; then
    break
  fi
  sleep 0.5
done
if [[ "$RUNNING" != "true" || "$STATUS" != "healthy" ||
      "$AFTER_RESTARTS" -le "$BEFORE_RESTARTS" ]]; then
  docker inspect --format '{{json .State}}' "$CONTAINER" >&2 || true
  docker logs "$CONTAINER" >&2 || true
  echo "[self-host] process crash did not recover" >&2
  exit 1
fi
docker exec "$CONTAINER" kouten get --config=/etc/koutendb/client.json \
  --ring=ops/selfhost | grep '"survives": true' >/dev/null

run_operator() {
  COMPOSE_PROJECT_NAME="$PROJECT" KOUTENDB_CONTAINER_NAME="$CONTAINER" \
    KOUTENDB_OPERATOR_EVIDENCE_MAX_RECORDS=6 \
    KOUTENDB_OPERATOR_HEALTH_DELAY=0.5 "$BUNDLE/operator.sh" "$@"
}

run_operator_with_health_limit() {
  local attempts="$1"
  shift
  COMPOSE_PROJECT_NAME="$PROJECT" KOUTENDB_CONTAINER_NAME="$CONTAINER" \
    KOUTENDB_OPERATOR_EVIDENCE_MAX_RECORDS=20 \
    KOUTENDB_OPERATOR_HEALTH_ATTEMPTS="$attempts" \
    KOUTENDB_OPERATOR_ROLLBACK_HEALTH_ATTEMPTS=60 \
    KOUTENDB_OPERATOR_HEALTH_DELAY=0.5 "$BUNDLE/operator.sh" "$@"
}

echo "[self-host] validate checkpoint export and independent restore"
if run_operator checkpoint-create '../invalid' >/dev/null 2>&1; then
  echo "[self-host] operator accepted an invalid checkpoint ID" >&2
  exit 1
fi
run_operator checkpoint-create smoke-1 >/dev/null
test "$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER")" = "healthy"
docker exec "$CONTAINER" kouten get --config=/etc/koutendb/client.json \
  --ring=ops/selfhost | grep '"survives": true' >/dev/null

if run_operator checkpoint-create smoke-1 >/dev/null 2>&1; then
  echo "[self-host] duplicate checkpoint identity was accepted" >&2
  exit 1
fi
test "$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER")" = "healthy"
docker exec "$CONTAINER" kouten put --config=/etc/koutendb/client.json \
  --ring=ops/after-failed-checkpoint \
  --payload='{"writable":true}' --codec=json >/dev/null

mkdir -p "$WORK/exported"
run_operator checkpoint-export smoke-1 "$WORK/exported" >/dev/null
test -f "$WORK/exported/smoke-1/checkpoint.json"
test -f "$WORK/exported/smoke-1/checkpoint.complete"
if find "$WORK/exported" -mindepth 1 -maxdepth 1 -name '.tmp-*' |
    grep . >/dev/null; then
  echo "[self-host] successful export left a staging directory" >&2
  exit 1
fi
run_operator restore-drill "$WORK/exported/smoke-1" >/dev/null

if run_operator checkpoint-export smoke-1 "$WORK/exported" >/dev/null 2>&1; then
  echo "[self-host] checkpoint export overwrote an existing destination" >&2
  exit 1
fi
cp -a "$WORK/exported/smoke-1" "$WORK/exported/corrupt-1"
printf 'corrupt\n' >>"$WORK/exported/corrupt-1/kouten.log"
if run_operator restore-drill "$WORK/exported/corrupt-1" >/dev/null 2>&1; then
  echo "[self-host] restore drill accepted a corrupt checkpoint" >&2
  exit 1
fi
test "$(grep -c '"outcome":"completed"' \
  "$BUNDLE/state/operator/operations.jsonl")" -ge 3
test "$(grep -c '"outcome":"failed"' \
  "$BUNDLE/state/operator/operations.jsonl")" -ge 3
if run_operator checkpoint-export smoke-1 "$WORK/exported" >/dev/null 2>&1; then
  echo "[self-host] repeated export unexpectedly succeeded" >&2
  exit 1
fi
test "$(wc -l <"$BUNDLE/state/operator/operations.jsonl")" = "6"
test "$(grep -c '"outcome":"completed"' \
  "$BUNDLE/state/operator/operations.jsonl")" = "2"
test "$(grep -c '"outcome":"failed"' \
  "$BUNDLE/state/operator/operations.jsonl")" = "4"
if docker volume ls --quiet --filter name=koutendb-restore-drill- | grep . >/dev/null; then
  echo "[self-host] restore drill left a temporary volume" >&2
  exit 1
fi

echo "[self-host] validate image upgrade and rollback"
docker tag "$IMAGE" "$UPGRADE_IMAGE"
cat >"$WORK/failing.Dockerfile" <<'DOCKERFILE'
ARG BASE_IMAGE=koutendb:container-smoke
FROM ${BASE_IMAGE}
USER 0:0
RUN mv /usr/local/bin/koutend /usr/local/bin/koutend.real \
 && printf '%s\n' '#!/bin/sh' \
      'if [ "${1:-}" = "--help" ]; then' \
      '  exec /usr/local/bin/koutend.real --help' \
      'fi' \
      'exit 42' > /usr/local/bin/koutend \
 && chmod 0755 /usr/local/bin/koutend
USER 10001:10001
DOCKERFILE
docker build --build-arg BASE_IMAGE="$IMAGE" -f "$WORK/failing.Dockerfile" \
  -t "$FAILING_IMAGE" "$WORK" >/dev/null

if run_operator upgrade 'koutendb:latest' invalid-latest >/dev/null 2>&1; then
  echo "[self-host] upgrade accepted a mutable latest tag" >&2
  exit 1
fi
grep -Fx "KOUTENDB_IMAGE=$IMAGE" "$BUNDLE/.env" >/dev/null

run_operator upgrade "$UPGRADE_IMAGE" upgrade-ok >/dev/null
grep -Fx "KOUTENDB_IMAGE=$UPGRADE_IMAGE" "$BUNDLE/.env" >/dev/null
test "$(docker inspect --format '{{.Config.Image}}' "$CONTAINER")" = "$UPGRADE_IMAGE"
docker exec "$CONTAINER" kouten get --config=/etc/koutendb/client.json \
  --ring=ops/selfhost | grep '"survives": true' >/dev/null

if run_operator_with_health_limit 25 upgrade "$FAILING_IMAGE" upgrade-rollback \
    >/dev/null 2>&1; then
  echo "[self-host] failing upgrade unexpectedly succeeded" >&2
  exit 1
fi
grep -Fx "KOUTENDB_IMAGE=$UPGRADE_IMAGE" "$BUNDLE/.env" >/dev/null
test "$(docker inspect --format '{{.Config.Image}}' "$CONTAINER")" = "$UPGRADE_IMAGE"
test "$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER")" = "healthy"
docker exec "$CONTAINER" kouten put --config=/etc/koutendb/client.json \
  --ring=ops/after-upgrade-rollback \
  --payload='{"writable":true}' --codec=json >/dev/null

echo "[self-host] validate certificate rotation and rollback"
mkdir -p "$WORK/rotation"
openssl req -nodes -newkey rsa:3072 -sha256 \
  -keyout "$WORK/rotation/server.key" -out "$WORK/rotation/server.csr" \
  -subj "/CN=koutendb" >/dev/null 2>&1
openssl x509 -req -sha256 -days 397 \
  -in "$WORK/rotation/server.csr" \
  -CA "$BUNDLE/certs/ca.crt" -CAkey "$BUNDLE/operator/ca.key" \
  -CAserial "$BUNDLE/certs/ca.srl" -out "$WORK/rotation/server.crt" \
  -extfile "$BUNDLE/operator/server.ext" >/dev/null 2>&1
ORIGINAL_CERT="$(openssl x509 -in "$BUNDLE/certs/server.crt" \
  -noout -fingerprint -sha256)"
if run_operator certificate-rotate "$WORK/rotation/server.crt" \
    "$BUNDLE/certs/server.key" >/dev/null 2>&1; then
  echo "[self-host] mismatched certificate and key were accepted" >&2
  exit 1
fi
test "$(openssl x509 -in "$BUNDLE/certs/server.crt" \
  -noout -fingerprint -sha256)" = "$ORIGINAL_CERT"
if run_operator certificate-rotate "$WORK/rotation/server.crt" \
    "$WORK/rotation/server.key" "$WORK/rotation/server.crt" \
    >/dev/null 2>&1; then
  echo "[self-host] non-CA certificate was accepted as a CA" >&2
  exit 1
fi
test "$(openssl x509 -in "$BUNDLE/certs/server.crt" \
  -noout -fingerprint -sha256)" = "$ORIGINAL_CERT"

if run_operator_with_health_limit 1 certificate-rotate \
    "$WORK/rotation/server.crt" "$WORK/rotation/server.key" \
    >/dev/null 2>&1; then
  echo "[self-host] forced certificate health timeout unexpectedly succeeded" >&2
  exit 1
fi
test "$(openssl x509 -in "$BUNDLE/certs/server.crt" \
  -noout -fingerprint -sha256)" = "$ORIGINAL_CERT"
test "$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER")" = "healthy"

run_operator certificate-rotate "$WORK/rotation/server.crt" \
  "$WORK/rotation/server.key" >/dev/null
test "$(openssl x509 -in "$BUNDLE/certs/server.crt" \
  -noout -fingerprint -sha256)" != "$ORIGINAL_CERT"
docker exec "$CONTAINER" kouten put --config=/etc/koutendb/client.json \
  --ring=ops/after-cert-rotation \
  --payload='{"writable":true}' --codec=json >/dev/null
if find "$BUNDLE/state/operator" -mindepth 1 -maxdepth 1 \
    \( -name 'cert-stage-*' -o -name 'cert-rollback-*' \) | grep . >/dev/null; then
  echo "[self-host] certificate lifecycle left temporary state" >&2
  exit 1
fi

echo "[self-host] validate watchdog threshold and restart-loop guard"
mkdir -p "$WORK/mock-bin" "$WORK/mock-state"
cat >"$WORK/mock-bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  inspect)
    cat "$MOCK_DOCKER_HEALTH"
    ;;
  restart)
    [[ "${2:-}" == "--timeout" ]]
    [[ "${3:-}" == "30" ]]
    [[ "${4:-}" == "$KOUTENDB_CONTAINER_NAME" ]]
    [[ "$#" == "4" ]]
    printf '%s\n' "$*" >>"$MOCK_DOCKER_RESTARTS"
    ;;
  *)
    echo "unexpected docker command: $*" >&2
    exit 1
    ;;
esac
MOCK
chmod +x "$WORK/mock-bin/docker"
printf 'unhealthy\n' >"$WORK/mock-health"
: >"$WORK/mock-restarts"
for _ in 1 2 3; do
  PATH="$WORK/mock-bin:$PATH" MOCK_DOCKER_HEALTH="$WORK/mock-health" \
    MOCK_DOCKER_RESTARTS="$WORK/mock-restarts" \
    KOUTENDB_CONTAINER_NAME=watchdog-test \
    KOUTENDB_WATCHDOG_STATE_DIR="$WORK/mock-state" \
    KOUTENDB_WATCHDOG_FAILURE_THRESHOLD=3 \
    deploy/self-hosted/watchdog.sh >/dev/null
done
test "$(wc -l <"$WORK/mock-restarts")" = "1"

printf 'healthy\n' >"$WORK/mock-health"
printf '2\n' >"$WORK/mock-state/consecutive-failures"
PATH="$WORK/mock-bin:$PATH" MOCK_DOCKER_HEALTH="$WORK/mock-health" \
  MOCK_DOCKER_RESTARTS="$WORK/mock-restarts" \
  KOUTENDB_CONTAINER_NAME=watchdog-test \
  KOUTENDB_WATCHDOG_STATE_DIR="$WORK/mock-state" \
  deploy/self-hosted/watchdog.sh >/dev/null
test "$(cat "$WORK/mock-state/consecutive-failures")" = "0"
test "$(wc -l <"$WORK/mock-restarts")" = "1"

printf 'starting\n' >"$WORK/mock-health"
printf '2\n' >"$WORK/mock-state/consecutive-failures"
PATH="$WORK/mock-bin:$PATH" MOCK_DOCKER_HEALTH="$WORK/mock-health" \
  MOCK_DOCKER_RESTARTS="$WORK/mock-restarts" \
  KOUTENDB_CONTAINER_NAME=watchdog-test \
  KOUTENDB_WATCHDOG_STATE_DIR="$WORK/mock-state" \
  deploy/self-hosted/watchdog.sh >/dev/null
test "$(cat "$WORK/mock-state/consecutive-failures")" = "2"
test "$(wc -l <"$WORK/mock-restarts")" = "1"

NOW="$(date +%s)"
printf 'unhealthy\n' >"$WORK/mock-health"
printf '%s\n%s\n%s\n' "$NOW" "$NOW" "$NOW" >"$WORK/mock-state/restarts"
printf '2\n' >"$WORK/mock-state/consecutive-failures"
if PATH="$WORK/mock-bin:$PATH" MOCK_DOCKER_HEALTH="$WORK/mock-health" \
    MOCK_DOCKER_RESTARTS="$WORK/mock-restarts" \
    KOUTENDB_CONTAINER_NAME=watchdog-test \
    KOUTENDB_WATCHDOG_STATE_DIR="$WORK/mock-state" \
    KOUTENDB_WATCHDOG_FAILURE_THRESHOLD=3 \
    deploy/self-hosted/watchdog.sh >/dev/null 2>&1; then
  echo "[self-host] watchdog bypassed restart-loop limit" >&2
  exit 1
fi
test "$(wc -l <"$WORK/mock-restarts")" = "1"

echo "[self-host] OK"
