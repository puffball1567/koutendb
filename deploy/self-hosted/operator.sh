#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE=(docker compose --project-directory "$ROOT" -f "$ROOT/compose.yaml")
ENV_FILE="$ROOT/.env"
CERT_DIR="$ROOT/certs"
STATE_DIR="${KOUTENDB_OPERATOR_STATE_DIR:-$ROOT/state/operator}"
HEALTH_ATTEMPTS="${KOUTENDB_OPERATOR_HEALTH_ATTEMPTS:-60}"
ROLLBACK_HEALTH_ATTEMPTS="${KOUTENDB_OPERATOR_ROLLBACK_HEALTH_ATTEMPTS:-60}"
HEALTH_DELAY="${KOUTENDB_OPERATOR_HEALTH_DELAY:-1}"
EVIDENCE_MAX_RECORDS="${KOUTENDB_OPERATOR_EVIDENCE_MAX_RECORDS:-1000}"
CERT_MIN_VALID_SECONDS="${KOUTENDB_OPERATOR_CERT_MIN_VALID_SECONDS:-86400}"

# The bundle .env file is the lifecycle source of truth for image replacement.
unset KOUTENDB_IMAGE

LOCK_DIR=""
DRILL_VOLUME=""
DRAINED=0
STOPPED=0
IMAGE_CHANGED=0
CERTS_CHANGED=0
OPERATION=""
CHECKPOINT_ID=""
SUCCEEDED=0
PREVIOUS_IMAGE=""
CERT_BACKUP_DIR=""
CERT_STAGE_DIR=""

fail() {
  echo "[koutendb-operator] $*" >&2
  exit 1
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

validate_checkpoint_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] ||
    fail "invalid checkpoint ID"
}

validate_image_reference() {
  local image="$1"
  [[ ${#image} -le 255 &&
     "$image" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@+-]*$ ]] ||
    fail "invalid image reference"
  [[ "$image" != *:latest ]] || fail "upgrade image must not use latest"
  if [[ "$image" == *@* ]]; then
    [[ "$image" =~ @sha256:[0-9a-fA-F]{64}$ ]] ||
      fail "upgrade image digest must be sha256"
  else
    [[ "${image##*/}" == *:* ]] ||
      fail "upgrade image must use an explicit tag or digest"
  fi
}

read_env_image() {
  local count
  [[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || return 1
  count="$(grep -c '^KOUTENDB_IMAGE=' "$ENV_FILE" || true)"
  [[ "$count" == "1" ]] || return 1
  sed -n 's/^KOUTENDB_IMAGE=//p' "$ENV_FILE"
}

write_env_image() {
  local image="$1"
  local output="$STATE_DIR/.env.tmp.$$"
  local found=0 line
  [[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || return 1
  : >"$output"
  chmod 0600 "$output"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == KOUTENDB_IMAGE=* ]]; then
      (( found == 0 )) || { rm -f "$output"; return 1; }
      printf 'KOUTENDB_IMAGE=%s\n' "$image" >>"$output"
      found=1
    else
      printf '%s\n' "$line" >>"$output"
    fi
  done <"$ENV_FILE"
  (( found == 1 )) || { rm -f "$output"; return 1; }
  mv "$output" "$ENV_FILE"
}

recreate_service() {
  local attempts="${1:-$HEALTH_ATTEMPTS}"
  "${COMPOSE[@]}" up -d --force-recreate koutendb-secrets koutendb >/dev/null
  wait_healthy "$attempts"
}

checkpoint_verify_image() {
  local image="$1"
  local checkpoint_id="$2"
  KOUTENDB_IMAGE="$image" "${COMPOSE[@]}" run --rm --no-deps \
    --entrypoint kouten koutendb checkpoint-verify \
    --checkpoint="/var/lib/koutendb/checkpoints/$checkpoint_id" \
    --json >/dev/null
}

preflight_image() {
  local image="$1"
  docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image" >/dev/null
  docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges:true --entrypoint kouten "$image" \
    --help >/dev/null
  docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges:true --entrypoint koutend "$image" \
    --help >/dev/null
  KOUTENDB_IMAGE="$image" "${COMPOSE[@]}" config >/dev/null
}

validate_certificate_set() {
  local cert="$1"
  local key="$2"
  local ca="$3"
  local work="$4"
  openssl x509 -in "$ca" -noout -checkend "$CERT_MIN_VALID_SECONDS" \
    >/dev/null
  openssl x509 -in "$ca" -noout -text >"$work/ca.txt"
  grep -q 'CA:TRUE' "$work/ca.txt"
  openssl x509 -in "$cert" -noout -checkend "$CERT_MIN_VALID_SECONDS" \
    >/dev/null
  openssl pkey -in "$key" -check -noout >/dev/null
  openssl verify -purpose sslserver -verify_hostname koutendb \
    -CAfile "$ca" "$cert" >/dev/null
  openssl x509 -in "$cert" -pubkey -noout >"$work/cert.pub"
  openssl pkey -pubin -in "$work/cert.pub" -outform DER >"$work/cert.der"
  openssl pkey -in "$key" -pubout -outform DER >"$work/key.der"
  cmp -s "$work/cert.der" "$work/key.der"
}

rollback_lifecycle() {
  local changed=0
  if (( IMAGE_CHANGED == 1 )); then
    write_env_image "$PREVIOUS_IMAGE" || return 1
    changed=1
  fi
  if (( CERTS_CHANGED == 1 )); then
    install -m 0644 "$CERT_BACKUP_DIR/server.crt" "$CERT_DIR/server.crt" ||
      return 1
    install -m 0600 "$CERT_BACKUP_DIR/server.key" "$CERT_DIR/server.key" ||
      return 1
    install -m 0644 "$CERT_BACKUP_DIR/ca.crt" "$CERT_DIR/ca.crt" ||
      return 1
    changed=1
  fi
  if (( changed == 1 )); then
    recreate_service "$ROLLBACK_HEALTH_ATTEMPTS" || return 1
  fi
  IMAGE_CHANGED=0
  CERTS_CHANGED=0
}

container_id() {
  "${COMPOSE[@]}" ps -q koutendb
}

wait_healthy() {
  local attempts="${1:-$HEALTH_ATTEMPTS}"
  local id status
  for _ in $(seq 1 "$attempts"); do
    id="$(container_id)"
    if [[ -n "$id" ]]; then
      status="$(docker inspect --format \
        '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id" 2>/dev/null || true)"
      [[ "$status" == "healthy" ]] && return 0
    fi
    sleep "$HEALTH_DELAY"
  done
  return 1
}

client() {
  "${COMPOSE[@]}" exec -T koutendb \
    kouten "$@" --config=/etc/koutendb/client.json
}

record_evidence() {
  local outcome="$1"
  local evidence="$STATE_DIR/operations.jsonl"
  local trimmed="$STATE_DIR/.operations.jsonl.tmp.$$"
  [[ -n "$OPERATION" ]] || return 0
  mkdir -p "$STATE_DIR"
  chmod 0700 "$STATE_DIR"
  [[ ! -L "$evidence" ]] || return 1
  printf '{"timestamp":%s,"operation":"%s","checkpointId":"%s","outcome":"%s"}\n' \
    "$(date +%s)" "$OPERATION" "$CHECKPOINT_ID" "$outcome" \
    >>"$evidence"
  chmod 0600 "$evidence"
  if (( $(wc -l <"$evidence") > EVIDENCE_MAX_RECORDS )); then
    tail -n "$EVIDENCE_MAX_RECORDS" "$evidence" >"$trimmed"
    chmod 0600 "$trimmed"
    mv "$trimmed" "$evidence"
  fi
}

finish() {
  local status=$?
  trap - EXIT INT TERM

  if (( status != 0 )) &&
      (( IMAGE_CHANGED == 1 || CERTS_CHANGED == 1 )); then
    rollback_lifecycle || status=1
  fi
  if (( STOPPED == 1 )); then
    if "${COMPOSE[@]}" up -d koutendb >/dev/null 2>&1 && wait_healthy; then
      STOPPED=0
    else
      status=1
    fi
  fi
  if (( DRAINED == 1 )) && (( STOPPED == 0 )); then
    if client resume >/dev/null 2>&1; then
      DRAINED=0
    else
      status=1
    fi
  fi
  if [[ -n "$DRILL_VOLUME" ]]; then
    docker volume rm "$DRILL_VOLUME" >/dev/null 2>&1 || true
  fi
  if [[ -n "$CERT_STAGE_DIR" && "$CERT_STAGE_DIR" == "$STATE_DIR"/cert-stage-* ]]; then
    rm -rf "$CERT_STAGE_DIR" || status=1
  fi
  if (( CERTS_CHANGED == 0 )) && [[ -n "$CERT_BACKUP_DIR" ]] &&
      [[ "$CERT_BACKUP_DIR" == "$STATE_DIR"/cert-rollback-* ]]; then
    rm -rf "$CERT_BACKUP_DIR" || status=1
  fi

  if (( status == 0 && SUCCEEDED == 1 )); then
    record_evidence "completed" || status=1
  else
    record_evidence "failed" || status=1
  fi
  if [[ -n "$LOCK_DIR" ]]; then
    rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
  fi
  exit "$status"
}

acquire_lock() {
  command -v docker >/dev/null 2>&1 || fail "docker is required"
  command -v realpath >/dev/null 2>&1 || fail "realpath is required"
  command -v openssl >/dev/null 2>&1 || fail "openssl is required"
  is_uint "$HEALTH_ATTEMPTS" && (( HEALTH_ATTEMPTS > 0 )) ||
    fail "health attempts must be a positive integer"
  is_uint "$ROLLBACK_HEALTH_ATTEMPTS" &&
      (( ROLLBACK_HEALTH_ATTEMPTS > 0 )) ||
    fail "rollback health attempts must be a positive integer"
  [[ "$HEALTH_DELAY" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
    fail "health delay must be a non-negative number"
  is_uint "$EVIDENCE_MAX_RECORDS" && (( EVIDENCE_MAX_RECORDS > 0 )) ||
    fail "evidence record limit must be a positive integer"
  is_uint "$CERT_MIN_VALID_SECONDS" ||
    fail "certificate validity threshold must be a non-negative integer"
  [[ ! -L "$STATE_DIR" ]] || fail "operator state directory must not be a symlink"
  mkdir -p "$STATE_DIR"
  chmod 0700 "$STATE_DIR"
  LOCK_DIR="$STATE_DIR/.lock"
  mkdir "$LOCK_DIR" 2>/dev/null || fail "another operator action is active"
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

checkpoint_verify_local() {
  local checkpoint_id="$1"
  "${COMPOSE[@]}" run --rm --no-deps --entrypoint kouten koutendb \
    checkpoint-verify \
    --checkpoint="/var/lib/koutendb/checkpoints/$checkpoint_id" \
    --json >/dev/null
}

checkpoint_create() {
  local checkpoint_id="$1"
  validate_checkpoint_id "$checkpoint_id"
  OPERATION="checkpoint-create"
  CHECKPOINT_ID="$checkpoint_id"
  acquire_lock

  client health >/dev/null || fail "service is not healthy"
  DRAINED=1
  client drain >/dev/null
  client snapshot >/dev/null
  STOPPED=1
  "${COMPOSE[@]}" stop -t 30 koutendb >/dev/null

  "${COMPOSE[@]}" run --rm --no-deps --entrypoint kouten koutendb \
    checkpoint-create --data=/var/lib/koutendb/data \
    --checkpoint-root=/var/lib/koutendb/checkpoints \
    --checkpoint-id="$checkpoint_id" --durability=strong --json >/dev/null
  checkpoint_verify_local "$checkpoint_id"

  "${COMPOSE[@]}" up -d koutendb >/dev/null
  wait_healthy || fail "service did not become healthy after checkpoint"
  STOPPED=0
  client resume >/dev/null
  DRAINED=0
  SUCCEEDED=1
  echo "[koutendb-operator] checkpoint verified id=$checkpoint_id"
}

restore_drill() {
  local checkpoint_path="$1"
  local expected_id="${2:-}"
  local id image container
  [[ -d "$checkpoint_path" ]] || fail "checkpoint directory does not exist"
  [[ ! -L "$checkpoint_path" ]] || fail "checkpoint directory must not be a symlink"
  [[ "$checkpoint_path" != *:* && "$checkpoint_path" != *$'\n'* ]] ||
    fail "checkpoint path contains unsupported characters"
  checkpoint_path="$(realpath "$checkpoint_path")"
  id="${expected_id:-$(basename "$checkpoint_path")}"
  validate_checkpoint_id "$id"
  CHECKPOINT_ID="$id"

  container="$(container_id)"
  [[ -n "$container" ]] || fail "KoutenDB service is not running"
  image="$(docker inspect --format '{{.Config.Image}}' "$container")"
  [[ -n "$image" ]] || fail "cannot resolve the KoutenDB image"
  DRILL_VOLUME="koutendb-restore-drill-$$-$RANDOM"
  docker volume create "$DRILL_VOLUME" >/dev/null

  docker run --rm --network none --read-only --cap-drop ALL \
    --cap-add DAC_READ_SEARCH --user 0:0 \
    -v "$checkpoint_path:/checkpoint:ro" \
    -v "$DRILL_VOLUME:/drill" --entrypoint kouten "$image" \
    checkpoint-restore --checkpoint=/checkpoint --data=/drill/data \
    --json >/dev/null
  docker run --rm --network none --read-only --cap-drop ALL --user 0:0 \
    -v "$DRILL_VOLUME:/drill" --entrypoint kouten "$image" \
    verify --data=/drill/data --segments --json >/dev/null

  docker volume rm "$DRILL_VOLUME" >/dev/null
  DRILL_VOLUME=""
}

checkpoint_export() {
  local checkpoint_id="$1"
  local destination="$2"
  local stage final uid gid
  validate_checkpoint_id "$checkpoint_id"
  OPERATION="checkpoint-export"
  CHECKPOINT_ID="$checkpoint_id"
  acquire_lock
  checkpoint_verify_local "$checkpoint_id"

  [[ ! -L "$destination" ]] || fail "destination root must not be a symlink"
  [[ "$destination" != *:* && "$destination" != *$'\n'* ]] ||
    fail "destination root contains unsupported characters"
  mkdir -p "$destination"
  [[ -d "$destination" ]] || fail "destination root is not a directory"
  destination="$(realpath "$destination")"
  [[ "$destination" != "/" ]] || fail "destination root must not be filesystem root"
  stage="$destination/.tmp-$checkpoint_id-$$"
  final="$destination/$checkpoint_id"
  [[ ! -e "$stage" && ! -L "$stage" ]] || fail "export staging path already exists"
  [[ ! -e "$final" && ! -L "$final" ]] || fail "export destination already exists"
  uid="$(id -u)"
  gid="$(id -g)"

  "${COMPOSE[@]}" run --rm --no-deps --user 0:0 \
    --cap-add DAC_OVERRIDE --cap-add DAC_READ_SEARCH --cap-add CHOWN \
    -v "$destination:/transfer" --entrypoint /bin/sh koutendb -ec '
      checkpoint_id="$1"
      stage="$2"
      uid="$3"
      gid="$4"
      stage_path="/transfer/$stage"
      finish_copy() {
        status="$?"
        trap - EXIT
        chown -R "$uid:$gid" "$stage_path" 2>/dev/null || status=1
        exit "$status"
      }
      trap finish_copy EXIT
      mkdir "$stage_path"
      cp -R "/var/lib/koutendb/checkpoints/$checkpoint_id/." \
        "$stage_path/"
    ' sh "$checkpoint_id" "$(basename "$stage")" "$uid" "$gid" >/dev/null

  restore_drill "$stage" "$checkpoint_id"
  mv "$stage" "$final"
  SUCCEEDED=1
  echo "[koutendb-operator] checkpoint exported and restore-tested id=$checkpoint_id"
}

upgrade_image() {
  local target_image="$1"
  local checkpoint_id="$2"
  local running_image
  validate_image_reference "$target_image"
  validate_checkpoint_id "$checkpoint_id"
  OPERATION="upgrade"
  CHECKPOINT_ID="$checkpoint_id"
  acquire_lock

  client health >/dev/null || fail "service is not healthy"
  PREVIOUS_IMAGE="$(read_env_image)" || fail "cannot read image from .env"
  validate_image_reference "$PREVIOUS_IMAGE"
  running_image="$(docker inspect --format '{{.Config.Image}}' "$(container_id)")"
  [[ "$running_image" == "$PREVIOUS_IMAGE" ]] ||
    fail "running image does not match .env"
  [[ "$target_image" != "$PREVIOUS_IMAGE" ]] ||
    fail "target image is already active"
  preflight_image "$target_image"

  DRAINED=1
  client drain >/dev/null
  client snapshot >/dev/null
  STOPPED=1
  "${COMPOSE[@]}" stop -t 30 koutendb >/dev/null
  KOUTENDB_IMAGE="$PREVIOUS_IMAGE" "${COMPOSE[@]}" run --rm --no-deps \
    --entrypoint kouten koutendb checkpoint-create \
    --data=/var/lib/koutendb/data \
    --checkpoint-root=/var/lib/koutendb/checkpoints \
    --checkpoint-id="$checkpoint_id" --durability=strong --json >/dev/null
  checkpoint_verify_image "$PREVIOUS_IMAGE" "$checkpoint_id"
  checkpoint_verify_image "$target_image" "$checkpoint_id"

  write_env_image "$target_image" || fail "cannot update image in .env"
  IMAGE_CHANGED=1
  STOPPED=0
  recreate_service || fail "target image did not become healthy"
  client resume >/dev/null
  DRAINED=0
  IMAGE_CHANGED=0
  SUCCEEDED=1
  echo "[koutendb-operator] upgrade verified checkpoint=$checkpoint_id"
}

resolve_certificate_input() {
  local input="$1"
  [[ "$input" != *$'\n'* && -f "$input" && ! -L "$input" ]] ||
    return 1
  realpath "$input"
}

rotate_certificate() {
  local cert_input="$1"
  local key_input="$2"
  local ca_input="${3:-$CERT_DIR/ca.crt}"
  local cert key ca
  OPERATION="certificate-rotate"
  acquire_lock

  client health >/dev/null || fail "service is not healthy"
  cert="$(resolve_certificate_input "$cert_input")" ||
    fail "server certificate must be a regular non-symlink file"
  key="$(resolve_certificate_input "$key_input")" ||
    fail "server key must be a regular non-symlink file"
  ca="$(resolve_certificate_input "$ca_input")" ||
    fail "CA certificate must be a regular non-symlink file"
  [[ -f "$CERT_DIR/server.crt" && ! -L "$CERT_DIR/server.crt" &&
     -f "$CERT_DIR/server.key" && ! -L "$CERT_DIR/server.key" &&
     -f "$CERT_DIR/ca.crt" && ! -L "$CERT_DIR/ca.crt" ]] ||
    fail "active certificate files are missing or unsafe"

  CERT_STAGE_DIR="$STATE_DIR/cert-stage-$$"
  CERT_BACKUP_DIR="$STATE_DIR/cert-rollback-$$"
  mkdir -m 0700 "$CERT_STAGE_DIR" "$CERT_BACKUP_DIR"
  install -m 0644 "$cert" "$CERT_STAGE_DIR/server.crt"
  install -m 0600 "$key" "$CERT_STAGE_DIR/server.key"
  install -m 0644 "$ca" "$CERT_STAGE_DIR/ca.crt"
  validate_certificate_set "$CERT_STAGE_DIR/server.crt" \
    "$CERT_STAGE_DIR/server.key" "$CERT_STAGE_DIR/ca.crt" "$CERT_STAGE_DIR"
  install -m 0644 "$CERT_DIR/server.crt" "$CERT_BACKUP_DIR/server.crt"
  install -m 0600 "$CERT_DIR/server.key" "$CERT_BACKUP_DIR/server.key"
  install -m 0644 "$CERT_DIR/ca.crt" "$CERT_BACKUP_DIR/ca.crt"

  DRAINED=1
  client drain >/dev/null
  client snapshot >/dev/null
  CERTS_CHANGED=1
  install -m 0644 "$CERT_STAGE_DIR/server.crt" "$CERT_DIR/server.crt"
  install -m 0600 "$CERT_STAGE_DIR/server.key" "$CERT_DIR/server.key"
  install -m 0644 "$CERT_STAGE_DIR/ca.crt" "$CERT_DIR/ca.crt"
  recreate_service || fail "rotated certificate did not pass TLS health"
  client resume >/dev/null
  DRAINED=0
  CERTS_CHANGED=0
  SUCCEEDED=1
  echo "[koutendb-operator] certificate rotation verified"
}

usage() {
  cat <<'USAGE'
Usage:
  ./operator.sh checkpoint-create CHECKPOINT_ID
  ./operator.sh checkpoint-export CHECKPOINT_ID DESTINATION_ROOT
  ./operator.sh restore-drill CHECKPOINT_DIRECTORY
  ./operator.sh upgrade TARGET_IMAGE CHECKPOINT_ID
  ./operator.sh certificate-rotate SERVER_CERT SERVER_KEY [CA_CERT]
USAGE
}

case "${1:-}" in
  checkpoint-create)
    [[ "$#" == "2" ]] || { usage >&2; exit 2; }
    checkpoint_create "$2"
    ;;
  checkpoint-export)
    [[ "$#" == "3" ]] || { usage >&2; exit 2; }
    checkpoint_export "$2" "$3"
    ;;
  restore-drill)
    [[ "$#" == "2" ]] || { usage >&2; exit 2; }
    OPERATION="restore-drill"
    acquire_lock
    restore_drill "$2"
    SUCCEEDED=1
    echo "[koutendb-operator] independent restore verified id=$CHECKPOINT_ID"
    ;;
  upgrade)
    [[ "$#" == "3" ]] || { usage >&2; exit 2; }
    upgrade_image "$2" "$3"
    ;;
  certificate-rotate)
    [[ "$#" == "3" || "$#" == "4" ]] || { usage >&2; exit 2; }
    rotate_certificate "$2" "$3" "${4:-$CERT_DIR/ca.crt}"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
