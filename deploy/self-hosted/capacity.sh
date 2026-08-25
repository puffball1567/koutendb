#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE=(docker compose --project-directory "$ROOT" -f "$ROOT/compose.yaml")
STATE_DIR="${KOUTENDB_OPERATOR_STATE_DIR:-$ROOT/state/operator}"
CAPACITY_DIR="$STATE_DIR/capacity"
HISTORY_FILE="$CAPACITY_DIR/samples.tsv"
PLAN_DIR="$CAPACITY_DIR/plans"
APPROVAL_DIR="$CAPACITY_DIR/approvals"
EXECUTION_DIR="$CAPACITY_DIR/executions"
MAX_SAMPLES="${KOUTENDB_CAPACITY_MAX_SAMPLES:-1000}"
MAX_PLANS="${KOUTENDB_CAPACITY_MAX_PLANS:-1000}"
MIN_WINDOW_SECONDS="${KOUTENDB_CAPACITY_MIN_WINDOW_SECONDS:-3600}"
MAX_SAMPLE_AGE_SECONDS="${KOUTENDB_CAPACITY_MAX_SAMPLE_AGE_SECONDS:-900}"
PLAN_TTL_SECONDS="${KOUTENDB_CAPACITY_PLAN_TTL_SECONDS:-86400}"
RESERVE_PERCENT="${KOUTENDB_CAPACITY_RESERVE_PERCENT:-10}"
MIN_RESERVE_BYTES="${KOUTENDB_CAPACITY_MIN_RESERVE_BYTES:-1073741824}"
MEMORY_HEADROOM_PERCENT="${KOUTENDB_CAPACITY_MEMORY_HEADROOM_PERCENT:-50}"
CPU_HEADROOM_PERCENT="${KOUTENDB_CAPACITY_CPU_HEADROOM_PERCENT:-50}"
LOCK_DIR=""
TEMP_FILE=""

fail() {
  echo "[koutendb-capacity] $*" >&2
  exit 1
}

is_uint() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]
}

validate_plan_id() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]] || fail "invalid plan ID"
}

finish() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n "$LOCK_DIR" ]]; then
    rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
  fi
  if [[ -n "$TEMP_FILE" && "$TEMP_FILE" == "$CAPACITY_DIR"/.tmp-* ]]; then
    rm -f "$TEMP_FILE" || status=1
  fi
  exit "$status"
}

acquire_lock() {
  command -v docker >/dev/null 2>&1 || fail "docker is required"
  command -v openssl >/dev/null 2>&1 || fail "openssl is required"
  for value in "$MAX_SAMPLES" "$MAX_PLANS" "$MIN_WINDOW_SECONDS" \
      "$MAX_SAMPLE_AGE_SECONDS" "$PLAN_TTL_SECONDS" "$RESERVE_PERCENT" \
      "$MIN_RESERVE_BYTES" "$MEMORY_HEADROOM_PERCENT" \
      "$CPU_HEADROOM_PERCENT"; do
    is_uint "$value" || fail "capacity settings must be non-negative integers"
  done
  (( MAX_SAMPLES >= 2 )) || fail "capacity sample limit must be at least 2"
  (( MAX_PLANS > 0 )) || fail "capacity plan limit must be positive"
  (( MIN_WINDOW_SECONDS > 0 )) || fail "minimum sample window must be positive"
  (( MAX_SAMPLE_AGE_SECONDS > 0 )) || fail "maximum sample age must be positive"
  (( PLAN_TTL_SECONDS > 0 )) || fail "plan TTL must be positive"
  (( RESERVE_PERCENT <= 100 )) || fail "reserve percent must be at most 100"
  (( MEMORY_HEADROOM_PERCENT <= 1000 )) ||
    fail "memory headroom percent is too large"
  (( CPU_HEADROOM_PERCENT <= 1000 )) ||
    fail "CPU headroom percent is too large"
  [[ ! -L "$STATE_DIR" && ! -L "$CAPACITY_DIR" ]] ||
    fail "capacity state directories must not be symlinks"
  install -d -m 0700 "$STATE_DIR" "$CAPACITY_DIR" "$PLAN_DIR" \
    "$APPROVAL_DIR" "$EXECUTION_DIR"
  LOCK_DIR="$STATE_DIR/.lock"
  mkdir "$LOCK_DIR" 2>/dev/null || fail "another operator action is active"
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

container_id() {
  "${COMPOSE[@]}" ps -q koutendb
}

metric_value() {
  local metrics="$1"
  local key="$2"
  local value
  value="$(printf '%s\n' "$metrics" | awk -v wanted="$key" '
    NF == 0 { next }
    NF % 2 != 0 { exit 2 }
    {
      for (i = 1; i <= NF; i += 2) {
        if ($i == wanted) {
          if (found) exit 3
          value = $(i + 1)
          found = 1
        }
      }
    }
    END {
      if (!found || value !~ /^[0-9]+$/) exit 4
      print value
    }
  ')" || fail "missing or invalid metric: $key"
  printf '%s\n' "$value"
}

size_to_bytes() {
  awk -v raw="$1" 'BEGIN {
    if (raw !~ /^[0-9]+([.][0-9]+)?(B|kB|KB|KiB|MB|MiB|GB|GiB|TB|TiB)$/)
      exit 1
    value = raw + 0
    unit = raw
    sub(/^[0-9]+([.][0-9]+)?/, "", unit)
    factor = 1
    if (unit == "kB" || unit == "KB") factor = 1000
    else if (unit == "KiB") factor = 1024
    else if (unit == "MB") factor = 1000000
    else if (unit == "MiB") factor = 1048576
    else if (unit == "GB") factor = 1000000000
    else if (unit == "GiB") factor = 1073741824
    else if (unit == "TB") factor = 1000000000000
    else if (unit == "TiB") factor = 1099511627776
    printf "%.0f\n", value * factor
  }'
}

live_sample() {
  local id metrics nonempty_lines wal segment index items rings disk stats
  local total free memory_usage cpu_percent rss cpu_milli memory_limit nano_cpus
  local available_memory available_cpu data_bytes now
  id="$(container_id)"
  [[ -n "$id" ]] || fail "KoutenDB service is not running"
  [[ "$(docker inspect --format '{{.State.Health.Status}}' "$id")" == "healthy" ]] ||
    fail "KoutenDB service is not healthy"
  metrics="$("${COMPOSE[@]}" exec -T koutendb \
    kouten metrics --config=/etc/koutendb/client.json --format=key-value)"
  nonempty_lines="$(printf '%s\n' "$metrics" | awk 'NF { count++ } END { print count + 0 }')"
  [[ "$nonempty_lines" == "1" ]] ||
    fail "single-node capacity sampling requires exactly one metrics line"
  wal="$(metric_value "$metrics" walBytes)"
  segment="$(metric_value "$metrics" segmentBytes)"
  index="$(metric_value "$metrics" segmentIndexBytes)"
  items="$(metric_value "$metrics" items)"
  rings="$(metric_value "$metrics" rings)"
  disk="$(docker exec "$id" df -B1 -P /var/lib/koutendb | \
    awk 'NR == 2 && $2 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ { print $2, $4 }')"
  read -r total free <<<"$disk"
  is_uint "${total:-}" && is_uint "${free:-}" ||
    fail "cannot read data-volume capacity"
  stats="$(docker stats --no-stream --format '{{.MemUsage}}|{{.CPUPerc}}' "$id")"
  [[ "$stats" == *'|'* ]] || fail "cannot read container resource usage"
  memory_usage="${stats%% / *}"
  cpu_percent="${stats##*|}"
  cpu_percent="${cpu_percent%%%}"
  rss="$(size_to_bytes "$memory_usage")" || fail "invalid memory usage"
  [[ "$cpu_percent" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "invalid CPU usage"
  cpu_milli="$(awk -v value="$cpu_percent" 'BEGIN { printf "%.0f\n", value * 10 }')"
  memory_limit="$(docker inspect --format '{{.HostConfig.Memory}}' "$id")"
  if [[ "$memory_limit" == "0" ]]; then
    memory_limit="$(docker info --format '{{.MemTotal}}')"
  fi
  nano_cpus="$(docker inspect --format '{{.HostConfig.NanoCpus}}' "$id")"
  if [[ "$nano_cpus" == "0" ]]; then
    available_cpu="$(docker info --format '{{.NCPU}}000')"
  else
    available_cpu="$(( (nano_cpus + 999999) / 1000000 ))"
  fi
  is_uint "$memory_limit" && is_uint "$available_cpu" ||
    fail "cannot read container resource limits"
  available_memory="$memory_limit"
  data_bytes="$(( wal + segment + index ))"
  now="$(date +%s)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$now" "$data_bytes" "$wal" "$segment" "$index" "$free" "$total" \
    "$rss" "$cpu_milli" "$available_memory" "$available_cpu" "$items" "$rings"
}

record_sample() {
  local sample last_timestamp output
  acquire_lock
  sample="$(live_sample)"
  if [[ -f "$HISTORY_FILE" ]]; then
    [[ ! -L "$HISTORY_FILE" ]] || fail "capacity history must not be a symlink"
    last_timestamp="$(tail -n 1 "$HISTORY_FILE" | cut -f1)"
    (( ${sample%%$'\t'*} > last_timestamp )) ||
      fail "capacity samples must have increasing timestamps"
  fi
  output="$CAPACITY_DIR/.tmp-samples.$$"
  TEMP_FILE="$output"
  { [[ -f "$HISTORY_FILE" ]] && cat "$HISTORY_FILE"; printf '%s\n' "$sample"; } |
    tail -n "$MAX_SAMPLES" >"$output"
  chmod 0600 "$output"
  mv "$output" "$HISTORY_FILE"
  TEMP_FILE=""
  printf '{"status":"sampled","timestamp":%s,"sampleCount":%s}\n' \
    "${sample%%$'\t'*}" "$(wc -l <"$HISTORY_FILE")"
}

history_forecast() {
  awk -F '\t' -v maxSamples="$MAX_SAMPLES" '
    NF != 13 { exit 2 }
    {
      for (i = 1; i <= NF; i++) if ($i !~ /^[0-9]+$/) exit 3
      if ($2 != $3 + $4 + $5 || $6 > $7 || $10 == 0 || $11 == 0) exit 7
      if (n > 0 && $1 <= lastTimestamp) exit 4
      if (n == 0) {
        firstTimestamp = $1
        firstData = $2
      }
      x = $1 - firstTimestamp
      # Subtracting the baseline preserves precision when a large data set has
      # comparatively small growth between samples.
      y = $2 - firstData
      sumX += x; sumY += y; sumXY += x * y; sumX2 += x * x
      if ($8 > peakRss) peakRss = $8
      if ($9 > peakCpu) peakCpu = $9
      lastTimestamp = $1
      latestData = $2; latestFree = $6; latestTotal = $7
      availableMemory = $10; availableCpu = $11
      n++
      if (n > maxSamples) exit 8
    }
    END {
      if (n < 2) exit 5
      denominator = n * sumX2 - sumX * sumX
      if (denominator <= 0) exit 6
      slope = (n * sumXY - sumX * sumY) / denominator
      if (slope < 0) slope = 0
      printf "%d %d %d %.9f %.0f %.0f %.0f %.0f %.0f %.0f %d\n", \
        n, firstTimestamp, lastTimestamp, slope, latestData, latestFree, \
        latestTotal, peakRss, peakCpu, availableMemory, availableCpu
    }
  ' "$HISTORY_FILE"
}

plan_field() {
  local plan="$1"
  local key="$2"
  local value
  value="$(awk -F= -v wanted="$key" '
    $1 == wanted { if (found) exit 2; value = $2; found = 1 }
    END { if (!found) exit 3; print value }
  ' "$plan")" || fail "plan is missing a unique $key field"
  printf '%s\n' "$value"
}

verify_plan_file() {
  local plan_id="$1"
  local plan="$PLAN_DIR/$plan_id.plan"
  local actual key value
  validate_plan_id "$plan_id"
  [[ -f "$plan" && ! -L "$plan" ]] || fail "plan does not exist"
  actual="$(openssl dgst -sha256 -r "$plan" | awk '{print $1}')"
  [[ "$actual" == "$plan_id" ]] || fail "plan content does not match its ID"
  [[ "$(wc -l <"$plan")" == "18" ]] || fail "plan has an invalid field count"
  for key in schemaVersion createdAt expiresAt horizonSeconds sampleCount \
      sampleStart sampleEnd latestDataBytes projectedDataBytes growthBytes \
      requiredFreeBytes shortageBytes requiredMemoryBytes availableMemoryBytes \
      requiredMilliCpu availableMilliCpu maxSampleAgeSeconds; do
    value="$(plan_field "$plan" "$key")"
    is_uint "$value" || fail "plan field is not an unsigned integer: $key"
  done
  [[ "$(plan_field "$plan" schemaVersion)" == "1" ]] ||
    fail "unsupported capacity plan schema"
  [[ "$(plan_field "$plan" action)" == "verify-prepared-capacity" ]] ||
    fail "unsupported capacity plan action"
  printf '%s\n' "$plan"
}

create_plan() {
  local horizon="$1"
  local forecast n first last slope latest free total peak_rss peak_cpu
  local available_memory available_cpu now span age growth projected reserve
  local required_free shortage required_memory required_cpu tmp plan_id final
  is_uint "$horizon" && (( horizon > 0 )) || fail "forecast horizon must be positive"
  (( horizon <= 315360000 )) || fail "forecast horizon must not exceed ten years"
  acquire_lock
  [[ -f "$HISTORY_FILE" && ! -L "$HISTORY_FILE" ]] ||
    fail "capacity history does not exist"
  forecast="$(history_forecast)" || fail "capacity history is invalid or insufficient"
  read -r n first last slope latest free total peak_rss peak_cpu \
    available_memory available_cpu <<<"$forecast"
  span="$(( last - first ))"
  (( span >= MIN_WINDOW_SECONDS )) || fail "capacity sample window is too short"
  now="$(date +%s)"
  age="$(( now - last ))"
  (( age >= 0 && age <= MAX_SAMPLE_AGE_SECONDS )) ||
    fail "latest capacity sample is stale"
  growth="$(awk -v rate="$slope" -v horizon="$horizon" \
    'BEGIN { value = rate * horizon; printf "%.0f\n", value == int(value) ? value : int(value) + 1 }')"
  projected="$(( latest + growth ))"
  reserve="$(( total * RESERVE_PERCENT / 100 ))"
  (( reserve >= MIN_RESERVE_BYTES )) || reserve="$MIN_RESERVE_BYTES"
  required_free="$(( growth + reserve ))"
  shortage=0
  (( free >= required_free )) || shortage="$(( required_free - free ))"
  required_memory="$(( peak_rss * (100 + MEMORY_HEADROOM_PERCENT) / 100 ))"
  required_cpu="$(( peak_cpu * (100 + CPU_HEADROOM_PERCENT) / 100 ))"
  (( required_cpu > 0 )) || required_cpu=100

  (( $(find "$PLAN_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.plan' |
       wc -l) < MAX_PLANS )) || fail "capacity plan limit reached"

  tmp="$CAPACITY_DIR/.tmp-plan.$$"
  TEMP_FILE="$tmp"
  cat >"$tmp" <<PLAN
schemaVersion=1
createdAt=$now
expiresAt=$(( now + PLAN_TTL_SECONDS ))
horizonSeconds=$horizon
sampleCount=$n
sampleStart=$first
sampleEnd=$last
latestDataBytes=$latest
projectedDataBytes=$projected
growthBytes=$growth
requiredFreeBytes=$required_free
shortageBytes=$shortage
requiredMemoryBytes=$required_memory
availableMemoryBytes=$available_memory
requiredMilliCpu=$required_cpu
availableMilliCpu=$available_cpu
maxSampleAgeSeconds=$MAX_SAMPLE_AGE_SECONDS
action=verify-prepared-capacity
PLAN
  chmod 0600 "$tmp"
  plan_id="$(openssl dgst -sha256 -r "$tmp" | awk '{print $1}')"
  final="$PLAN_DIR/$plan_id.plan"
  [[ ! -e "$final" && ! -L "$final" ]] || fail "identical capacity plan already exists"
  mv "$tmp" "$final"
  TEMP_FILE=""
  printf '{"planId":"%s","action":"verify-prepared-capacity","sampleCount":%s,"horizonSeconds":%s,"growthBytes":%s,"requiredFreeBytes":%s,"shortageBytes":%s,"requiredMemoryBytes":%s,"requiredMilliCpu":%s,"expiresAt":%s}\n' \
    "$plan_id" "$n" "$horizon" "$growth" "$required_free" "$shortage" \
    "$required_memory" "$required_cpu" "$(( now + PLAN_TTL_SECONDS ))"
}

approve_plan() {
  local plan_id="$1"
  local plan approval now tmp
  acquire_lock
  plan="$(verify_plan_file "$plan_id")"
  now="$(date +%s)"
  (( now <= $(plan_field "$plan" expiresAt) )) || fail "capacity plan has expired"
  (( now - $(plan_field "$plan" sampleEnd) <=
       $(plan_field "$plan" maxSampleAgeSeconds) )) ||
    fail "capacity plan observations are stale"
  approval="$APPROVAL_DIR/$plan_id.approved"
  [[ ! -e "$approval" && ! -L "$approval" ]] || fail "capacity plan is already approved"
  tmp="$CAPACITY_DIR/.tmp-approval.$$"
  TEMP_FILE="$tmp"
  printf 'schemaVersion=1\nplanId=%s\napprovedAt=%s\n' \
    "$plan_id" "$now" >"$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$approval"
  TEMP_FILE=""
  printf '{"planId":"%s","status":"approved","approvedAt":%s}\n' \
    "$plan_id" "$now"
}

execute_plan() {
  local plan_id="$1"
  local plan approval executed now current current_data current_free
  local required_free required_memory available_memory required_cpu available_cpu tmp
  acquire_lock
  plan="$(verify_plan_file "$plan_id")"
  approval="$APPROVAL_DIR/$plan_id.approved"
  executed="$EXECUTION_DIR/$plan_id.executed"
  [[ -f "$approval" && ! -L "$approval" ]] || fail "capacity plan is not approved"
  [[ "$(wc -l <"$approval")" == "3" ]] || fail "capacity approval is invalid"
  [[ "$(sed -n 's/^schemaVersion=//p' "$approval")" == "1" ]] ||
    fail "capacity approval schema is invalid"
  [[ "$(sed -n 's/^planId=//p' "$approval")" == "$plan_id" ]] ||
    fail "approval does not match the capacity plan"
  is_uint "$(sed -n 's/^approvedAt=//p' "$approval")" ||
    fail "capacity approval timestamp is invalid"
  [[ ! -e "$executed" && ! -L "$executed" ]] ||
    fail "capacity plan was already executed"
  now="$(date +%s)"
  (( now <= $(plan_field "$plan" expiresAt) )) || fail "capacity plan has expired"
  (( now - $(plan_field "$plan" sampleEnd) <=
       $(plan_field "$plan" maxSampleAgeSeconds) )) ||
    fail "capacity plan observations are stale"
  current="$(live_sample)"
  IFS=$'\t' read -r _ current_data _ _ _ current_free _ _ _ \
    available_memory available_cpu _ _ <<<"$current"
  (( current_data <= $(plan_field "$plan" projectedDataBytes) )) ||
    fail "capacity plan is stale because data growth exceeded its projection"
  required_free="$(plan_field "$plan" requiredFreeBytes)"
  required_memory="$(plan_field "$plan" requiredMemoryBytes)"
  required_cpu="$(plan_field "$plan" requiredMilliCpu)"
  (( current_free >= required_free )) || fail "prepared disk capacity is insufficient"
  (( available_memory >= required_memory )) ||
    fail "prepared memory capacity is insufficient"
  (( available_cpu >= required_cpu )) || fail "prepared CPU capacity is insufficient"
  tmp="$CAPACITY_DIR/.tmp-execution.$$"
  TEMP_FILE="$tmp"
  printf 'schemaVersion=1\nplanId=%s\nexecutedAt=%s\naction=verify-prepared-capacity\n' \
    "$plan_id" "$now" >"$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$executed"
  TEMP_FILE=""
  printf '{"planId":"%s","status":"executed","action":"verify-prepared-capacity","executedAt":%s}\n' \
    "$plan_id" "$now"
}

plan_status() {
  local plan_id="$1"
  local plan status="planned"
  acquire_lock
  plan="$(verify_plan_file "$plan_id")"
  if [[ -f "$EXECUTION_DIR/$plan_id.executed" ]]; then
    status="executed"
  elif [[ -f "$APPROVAL_DIR/$plan_id.approved" ]]; then
    status="approved"
  fi
  printf '{"planId":"%s","status":"%s","expiresAt":%s,"shortageBytes":%s}\n' \
    "$plan_id" "$status" "$(plan_field "$plan" expiresAt)" \
    "$(plan_field "$plan" shortageBytes)"
}

usage() {
  cat <<'USAGE'
Usage:
  ./capacity.sh sample
  ./capacity.sh plan HORIZON_SECONDS
  ./capacity.sh approve PLAN_ID
  ./capacity.sh execute PLAN_ID
  ./capacity.sh status PLAN_ID
USAGE
}

case "${1:-}" in
  sample)
    [[ "$#" == "1" ]] || { usage >&2; exit 2; }
    record_sample
    ;;
  plan)
    [[ "$#" == "2" ]] || { usage >&2; exit 2; }
    create_plan "$2"
    ;;
  approve)
    [[ "$#" == "2" ]] || { usage >&2; exit 2; }
    approve_plan "$2"
    ;;
  execute)
    [[ "$#" == "2" ]] || { usage >&2; exit 2; }
    execute_plan "$2"
    ;;
  status)
    [[ "$#" == "2" ]] || { usage >&2; exit 2; }
    plan_status "$2"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
