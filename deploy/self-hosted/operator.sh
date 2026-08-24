#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE=(docker compose --project-directory "$ROOT" -f "$ROOT/compose.yaml")
STATE_DIR="${KOUTENDB_OPERATOR_STATE_DIR:-$ROOT/state/operator}"
HEALTH_ATTEMPTS="${KOUTENDB_OPERATOR_HEALTH_ATTEMPTS:-60}"
HEALTH_DELAY="${KOUTENDB_OPERATOR_HEALTH_DELAY:-1}"
EVIDENCE_MAX_RECORDS="${KOUTENDB_OPERATOR_EVIDENCE_MAX_RECORDS:-1000}"

LOCK_DIR=""
DRILL_VOLUME=""
DRAINED=0
STOPPED=0
OPERATION=""
CHECKPOINT_ID=""
SUCCEEDED=0

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

container_id() {
  "${COMPOSE[@]}" ps -q koutendb
}

wait_healthy() {
  local id status
  for _ in $(seq 1 "$HEALTH_ATTEMPTS"); do
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
  is_uint "$HEALTH_ATTEMPTS" && (( HEALTH_ATTEMPTS > 0 )) ||
    fail "health attempts must be a positive integer"
  [[ "$HEALTH_DELAY" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
    fail "health delay must be a non-negative number"
  is_uint "$EVIDENCE_MAX_RECORDS" && (( EVIDENCE_MAX_RECORDS > 0 )) ||
    fail "evidence record limit must be a positive integer"
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
      mkdir "/transfer/$stage"
      cp -a "/var/lib/koutendb/checkpoints/$checkpoint_id/." \
        "/transfer/$stage/"
      chown -R "$uid:$gid" "/transfer/$stage"
    ' sh "$checkpoint_id" "$(basename "$stage")" "$uid" "$gid" >/dev/null

  restore_drill "$stage" "$checkpoint_id"
  mv "$stage" "$final"
  SUCCEEDED=1
  echo "[koutendb-operator] checkpoint exported and restore-tested id=$checkpoint_id"
}

usage() {
  cat <<'USAGE'
Usage:
  ./operator.sh checkpoint-create CHECKPOINT_ID
  ./operator.sh checkpoint-export CHECKPOINT_ID DESTINATION_ROOT
  ./operator.sh restore-drill CHECKPOINT_DIRECTORY
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
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
