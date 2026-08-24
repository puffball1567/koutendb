#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IMAGE="${KOUTEN_CONTAINER_IMAGE:-koutendb:container-smoke}"
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
