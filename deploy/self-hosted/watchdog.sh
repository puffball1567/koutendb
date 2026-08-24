#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${KOUTENDB_CONTAINER_NAME:-koutendb-selfhost}"
STATE_DIR="${KOUTENDB_WATCHDOG_STATE_DIR:-./state/watchdog}"
FAILURE_THRESHOLD="${KOUTENDB_WATCHDOG_FAILURE_THRESHOLD:-3}"
MAX_RESTARTS="${KOUTENDB_WATCHDOG_MAX_RESTARTS:-3}"
WINDOW_SECONDS="${KOUTENDB_WATCHDOG_WINDOW_SECONDS:-3600}"
RESTART_TIMEOUT="${KOUTENDB_WATCHDOG_RESTART_TIMEOUT:-30}"

fail() {
  echo "[koutendb-watchdog] $*" >&2
  exit 1
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

[[ "$CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
  fail "invalid container name"
for value in "$FAILURE_THRESHOLD" "$MAX_RESTARTS" "$WINDOW_SECONDS" \
             "$RESTART_TIMEOUT"; do
  is_uint "$value" || fail "watchdog limits must be unsigned integers"
  (( value > 0 )) || fail "watchdog limits must be positive"
done
command -v docker >/dev/null 2>&1 || fail "docker is required"
[[ ! -L "$STATE_DIR" ]] || fail "state directory must not be a symlink"
mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR"

LOCK_DIR="$STATE_DIR/.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "[koutendb-watchdog] another check is active"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

FAILURES_FILE="$STATE_DIR/consecutive-failures"
RESTARTS_FILE="$STATE_DIR/restarts"
STATUS="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$CONTAINER" 2>/dev/null)" ||
  fail "container not found: $CONTAINER"

case "$STATUS" in
  healthy)
    printf '0\n' >"$FAILURES_FILE.tmp"
    mv "$FAILURES_FILE.tmp" "$FAILURES_FILE"
    echo "[koutendb-watchdog] healthy"
    exit 0
    ;;
  starting)
    echo "[koutendb-watchdog] health check is still starting"
    exit 0
    ;;
  unhealthy) ;;
  *) fail "container has no usable health status: $STATUS" ;;
esac

FAILURES=0
if [[ -f "$FAILURES_FILE" ]]; then
  read -r FAILURES <"$FAILURES_FILE" || fail "cannot read failure state"
  is_uint "$FAILURES" || fail "invalid failure state"
fi
FAILURES=$((FAILURES + 1))
printf '%s\n' "$FAILURES" >"$FAILURES_FILE.tmp"
mv "$FAILURES_FILE.tmp" "$FAILURES_FILE"

if (( FAILURES < FAILURE_THRESHOLD )); then
  echo "[koutendb-watchdog] unhealthy ($FAILURES/$FAILURE_THRESHOLD)"
  exit 0
fi

NOW="$(date +%s)"
CUTOFF=$((NOW - WINDOW_SECONDS))
touch "$RESTARTS_FILE"
RESTARTS=()
while IFS= read -r timestamp; do
  [[ -z "$timestamp" ]] && continue
  is_uint "$timestamp" || fail "invalid restart history"
  if (( timestamp >= CUTOFF )); then
    RESTARTS+=("$timestamp")
  fi
done <"$RESTARTS_FILE"

if (( ${#RESTARTS[@]} >= MAX_RESTARTS )); then
  fail "restart limit reached; operator intervention required"
fi

docker restart --timeout "$RESTART_TIMEOUT" "$CONTAINER" >/dev/null
RESTARTS+=("$NOW")
printf '%s\n' "${RESTARTS[@]}" >"$RESTARTS_FILE.tmp"
mv "$RESTARTS_FILE.tmp" "$RESTARTS_FILE"
printf '0\n' >"$FAILURES_FILE.tmp"
mv "$FAILURES_FILE.tmp" "$FAILURES_FILE"
echo "[koutendb-watchdog] restarted $CONTAINER after $FAILURES consecutive failures"
