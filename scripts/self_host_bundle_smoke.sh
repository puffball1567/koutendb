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

KOUTENDB_VERSION=0.14.2 deploy/self-hosted/bootstrap.sh "$BUNDLE" >/dev/null
sed -i "s|^KOUTENDB_IMAGE=.*|KOUTENDB_IMAGE=$IMAGE|" "$BUNDLE/.env"
test -x "$BUNDLE/operator.sh"
test -x "$BUNDLE/capacity.sh"
test -f "$BUNDLE/systemd/koutendb-backup.service"
test -f "$BUNDLE/systemd/koutendb-backup.timer"
test "$(stat -c '%a' "$BUNDLE/systemd/backup.env")" = "600"
grep -F 'Persistent=true' "$BUNDLE/systemd/koutendb-backup.timer" >/dev/null
grep -F 'scheduled-backup ${KOUTENDB_BACKUP_DESTINATION} ${KOUTENDB_BACKUP_KEEP}' \
  "$BUNDLE/systemd/koutendb-backup.service" >/dev/null
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

echo "[self-host] validate scheduled backup retention and recovery"
SCHEDULED_ROOT="$WORK/scheduled"
mkdir -p "$SCHEDULED_ROOT"
if run_operator scheduled-backup "$SCHEDULED_ROOT" 0 \
    scheduled-20260825T010000Z >/dev/null 2>&1; then
  echo "[self-host] scheduled backup accepted zero retention" >&2
  exit 1
fi
if run_operator scheduled-backup / 1 \
    scheduled-20260825T010000Z >/dev/null 2>&1; then
  echo "[self-host] scheduled backup accepted filesystem root" >&2
  exit 1
fi
ln -s "$SCHEDULED_ROOT" "$WORK/scheduled-link"
if run_operator scheduled-backup "$WORK/scheduled-link" 1 \
    scheduled-20260825T010000Z >/dev/null 2>&1; then
  echo "[self-host] scheduled backup accepted a symlink destination" >&2
  exit 1
fi
mkdir "$BUNDLE/state/operator/.lock"
if run_operator scheduled-backup "$SCHEDULED_ROOT" 1 \
    scheduled-20260825T010000Z >/dev/null 2>&1; then
  echo "[self-host] scheduled backup bypassed the operator lock" >&2
  exit 1
fi
rmdir "$BUNDLE/state/operator/.lock"

run_operator scheduled-backup "$SCHEDULED_ROOT" 1 \
  scheduled-20260825T010000Z >/dev/null
test -f "$SCHEDULED_ROOT/scheduled-20260825T010000Z/checkpoint.complete"
run_operator scheduled-backup "$SCHEDULED_ROOT" 1 \
  scheduled-20260825T020000Z >/dev/null
test ! -e "$SCHEDULED_ROOT/scheduled-20260825T010000Z"
test -f "$SCHEDULED_ROOT/scheduled-20260825T020000Z/checkpoint.complete"

printf 'corrupt\n' >>"$SCHEDULED_ROOT/scheduled-20260825T020000Z/kouten.log"
run_operator scheduled-backup "$SCHEDULED_ROOT" 1 \
  scheduled-20260825T030000Z >/dev/null
test -d "$SCHEDULED_ROOT/scheduled-20260825T020000Z"
test -d "$SCHEDULED_ROOT/scheduled-20260825T030000Z"
run_operator scheduled-backup "$SCHEDULED_ROOT" 1 \
  scheduled-20260825T040000Z >/dev/null
test -d "$SCHEDULED_ROOT/scheduled-20260825T020000Z"
test ! -e "$SCHEDULED_ROOT/scheduled-20260825T030000Z"
test -d "$SCHEDULED_ROOT/scheduled-20260825T040000Z"
if run_operator scheduled-backup "$SCHEDULED_ROOT" 1 \
    scheduled-20260825T040000Z >/dev/null 2>&1; then
  echo "[self-host] scheduled backup accepted a duplicate identity" >&2
  exit 1
fi
mkdir "$SCHEDULED_ROOT/scheduled-20260825T050000Z"
if run_operator scheduled-backup "$SCHEDULED_ROOT" 1 \
    scheduled-20260825T050000Z >/dev/null 2>&1; then
  echo "[self-host] scheduled backup accepted a pre-existing destination" >&2
  exit 1
fi
if docker exec "$CONTAINER" test -e \
    /var/lib/koutendb/scheduled-checkpoints/scheduled-20260825T050000Z; then
  echo "[self-host] destination preflight left an internal checkpoint" >&2
  exit 1
fi
rmdir "$SCHEDULED_ROOT/scheduled-20260825T050000Z"
if find "$SCHEDULED_ROOT" -mindepth 1 -maxdepth 1 -name '.tmp-*' |
    grep . >/dev/null; then
  echo "[self-host] scheduled backup left a staging directory" >&2
  exit 1
fi
test "$(docker exec "$CONTAINER" sh -ec \
  "find /var/lib/koutendb/scheduled-checkpoints -mindepth 1 -maxdepth 1 -type d | wc -l")" = "1"
test "$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER")" = "healthy"
docker exec "$CONTAINER" kouten get --config=/etc/koutendb/client.json \
  --ring=ops/selfhost | grep '"survives": true' >/dev/null

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

run_capacity() {
  COMPOSE_PROJECT_NAME="$PROJECT" KOUTENDB_CONTAINER_NAME="$CONTAINER" \
    KOUTENDB_CAPACITY_MIN_WINDOW_SECONDS=1 \
    KOUTENDB_CAPACITY_MAX_SAMPLE_AGE_SECONDS="${CAPACITY_MAX_SAMPLE_AGE_SECONDS:-60}" \
    KOUTENDB_CAPACITY_MAX_SAMPLES="${CAPACITY_MAX_SAMPLES:-2}" \
    KOUTENDB_CAPACITY_RESERVE_PERCENT="${CAPACITY_RESERVE_PERCENT:-0}" \
    KOUTENDB_CAPACITY_MIN_RESERVE_BYTES="${CAPACITY_MIN_RESERVE_BYTES:-1}" \
    KOUTENDB_CAPACITY_PLAN_TTL_SECONDS="${CAPACITY_PLAN_TTL_SECONDS:-60}" \
    "$BUNDLE/capacity.sh" "$@"
}

plan_id_from_output() {
  sed -n 's/.*"planId":"\([0-9a-f]\{64\}\)".*/\1/p'
}

echo "[self-host] validate capacity history, plans, approval, and execution"
run_capacity sample >/dev/null
if run_capacity plan 3600 >/dev/null 2>&1; then
  echo "[self-host] capacity plan accepted insufficient history" >&2
  exit 1
fi
sleep 1
docker exec "$CONTAINER" kouten put --config=/etc/koutendb/client.json \
  --ring=ops/capacity --payload='{"growth":true}' --codec=json >/dev/null
run_capacity sample >/dev/null
PLAN_ID="$(run_capacity plan 3600 | plan_id_from_output)"
[[ "$PLAN_ID" =~ ^[0-9a-f]{64}$ ]]
run_capacity status "$PLAN_ID" | grep '"status":"planned"' >/dev/null
WRONG_PLAN_ID="${PLAN_ID%?}$(if [[ "${PLAN_ID: -1}" == "0" ]]; then printf 1; else printf 0; fi)"
if run_capacity approve "$WRONG_PLAN_ID" >/dev/null 2>&1; then
  echo "[self-host] capacity approval accepted the wrong plan ID" >&2
  exit 1
fi
if run_capacity execute "$PLAN_ID" >/dev/null 2>&1; then
  echo "[self-host] unapproved capacity plan was executed" >&2
  exit 1
fi
cp "$BUNDLE/state/operator/capacity/plans/$PLAN_ID.plan" \
  "$WORK/capacity-plan.backup"
printf 'tampered=1\n' >>"$BUNDLE/state/operator/capacity/plans/$PLAN_ID.plan"
if run_capacity approve "$PLAN_ID" >/dev/null 2>&1; then
  echo "[self-host] modified capacity plan was approved" >&2
  exit 1
fi
cp "$WORK/capacity-plan.backup" \
  "$BUNDLE/state/operator/capacity/plans/$PLAN_ID.plan"
run_capacity approve "$PLAN_ID" >/dev/null
run_capacity status "$PLAN_ID" | grep '"status":"approved"' >/dev/null
run_capacity execute "$PLAN_ID" >/dev/null
run_capacity status "$PLAN_ID" | grep '"status":"executed"' >/dev/null
if run_capacity execute "$PLAN_ID" >/dev/null 2>&1; then
  echo "[self-host] capacity plan executed twice" >&2
  exit 1
fi

sleep 1
run_capacity sample >/dev/null
test "$(wc -l <"$BUNDLE/state/operator/capacity/samples.tsv")" = "2"
CAPACITY_RESERVE_PERCENT=100
SHORTAGE_ID="$(run_capacity plan 7200 | plan_id_from_output)"
run_capacity approve "$SHORTAGE_ID" >/dev/null
if run_capacity execute "$SHORTAGE_ID" >/dev/null 2>&1; then
  echo "[self-host] capacity execution ignored a disk shortage" >&2
  exit 1
fi
CAPACITY_RESERVE_PERCENT=0

CAPACITY_PLAN_TTL_SECONDS=1
EXPIRED_ID="$(run_capacity plan 10800 | plan_id_from_output)"
run_capacity approve "$EXPIRED_ID" >/dev/null
sleep 2
if run_capacity execute "$EXPIRED_ID" >/dev/null 2>&1; then
  echo "[self-host] expired capacity plan was executed" >&2
  exit 1
fi
CAPACITY_PLAN_TTL_SECONDS=60

sleep 1
run_capacity sample >/dev/null
CAPACITY_MAX_SAMPLE_AGE_SECONDS=2
STALE_ID="$(run_capacity plan 14400 | plan_id_from_output)"
run_capacity approve "$STALE_ID" >/dev/null
sleep 3
if run_capacity execute "$STALE_ID" >/dev/null 2>&1; then
  echo "[self-host] stale capacity observations were executed" >&2
  exit 1
fi
CAPACITY_MAX_SAMPLE_AGE_SECONDS=60

cp "$BUNDLE/state/operator/capacity/samples.tsv" "$WORK/capacity-history.backup"
IFS=$'\t' read -r SAMPLE_TS SAMPLE_DATA SAMPLE_WAL SAMPLE_SEGMENT SAMPLE_INDEX \
  SAMPLE_FREE SAMPLE_TOTAL SAMPLE_RSS SAMPLE_CPU SAMPLE_MEMORY SAMPLE_AVAILABLE_CPU \
  SAMPLE_ITEMS SAMPLE_RINGS < <(tail -n 1 \
    "$BUNDLE/state/operator/capacity/samples.tsv")
NOW="$(date +%s)"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(( NOW - 2 ))" "$(( SAMPLE_DATA + 1000 ))" "$(( SAMPLE_WAL + 1000 ))" \
  "$SAMPLE_SEGMENT" "$SAMPLE_INDEX" "$SAMPLE_FREE" "$SAMPLE_TOTAL" \
  "$SAMPLE_RSS" "$SAMPLE_CPU" "$SAMPLE_MEMORY" "$SAMPLE_AVAILABLE_CPU" \
  "$SAMPLE_ITEMS" "$SAMPLE_RINGS" \
  >"$BUNDLE/state/operator/capacity/samples.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(( NOW - 1 ))" "$SAMPLE_DATA" "$SAMPLE_WAL" "$SAMPLE_SEGMENT" \
  "$SAMPLE_INDEX" "$SAMPLE_FREE" "$SAMPLE_TOTAL" "$SAMPLE_RSS" "$SAMPLE_CPU" \
  "$SAMPLE_MEMORY" "$SAMPLE_AVAILABLE_CPU" "$SAMPLE_ITEMS" "$SAMPLE_RINGS" \
  >>"$BUNDLE/state/operator/capacity/samples.tsv"
run_capacity plan 18000 | grep '"growthBytes":0' >/dev/null

# Keep a large baseline out of the regression calculation. The expected
# 1,000-byte/second slope must survive floating-point cancellation.
BASELINE=8000000000000000
for OFFSET in 0 1 2 3 4 5; do
  DATA_BYTES="$(( BASELINE + OFFSET * 1000 ))"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(( NOW - 6 + OFFSET ))" "$DATA_BYTES" "$DATA_BYTES" 0 0 \
    "$SAMPLE_FREE" "$SAMPLE_TOTAL" "$SAMPLE_RSS" "$SAMPLE_CPU" \
    "$SAMPLE_MEMORY" "$SAMPLE_AVAILABLE_CPU" "$SAMPLE_ITEMS" "$SAMPLE_RINGS"
done >"$BUNDLE/state/operator/capacity/samples.tsv"
CAPACITY_MAX_SAMPLES=6 run_capacity plan 10 |
  grep '"growthBytes":10000' >/dev/null
cp "$WORK/capacity-history.backup" \
  "$BUNDLE/state/operator/capacity/samples.tsv"

if grep -F "$(cat "$BUNDLE/secrets/password")" \
    "$BUNDLE/state/operator/capacity/samples.tsv" \
    "$BUNDLE/state/operator/capacity/plans/"*.plan >/dev/null; then
  echo "[self-host] credential leaked into capacity state" >&2
  exit 1
fi
if find "$BUNDLE/state/operator/capacity" -maxdepth 1 -name '.tmp-*' |
    grep . >/dev/null; then
  echo "[self-host] capacity workflow left a temporary file" >&2
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
mkdir "$WORK/mock-operator-lock"
PATH="$WORK/mock-bin:$PATH" MOCK_DOCKER_HEALTH="$WORK/mock-health" \
  MOCK_DOCKER_RESTARTS="$WORK/mock-restarts" \
  KOUTENDB_CONTAINER_NAME=watchdog-test \
  KOUTENDB_WATCHDOG_STATE_DIR="$WORK/mock-state" \
  KOUTENDB_OPERATOR_LOCK_DIR="$WORK/mock-operator-lock" \
  deploy/self-hosted/watchdog.sh | grep 'operator action is active' >/dev/null
test ! -s "$WORK/mock-restarts"
rmdir "$WORK/mock-operator-lock"
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
