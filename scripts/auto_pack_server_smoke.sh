#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORK="${TMPDIR:-/tmp}/koutendb-auto-pack-smoke-$$"
DATA="$WORK/data"
PID=""

cleanup() {
  if [[ -n "$PID" ]]; then
    kill "$PID" >/dev/null 2>&1 || true
    wait "$PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK"

PORT=""
for attempt in $(seq 0 99); do
  candidate=$((31000 + (($$ + attempt) % 25000)))
  if ! nc -z 127.0.0.1 "$candidate" >/dev/null 2>&1; then
    PORT="$candidate"
    break
  fi
done
test -n "$PORT"

echo "[auto-pack] build fixture, server, and CLI"
nim c -d:release --nimcache:/tmp/nimcache_kouten_auto_pack_fixture \
  -o:"$WORK/fixture" tests/tauto_pack_fixture.nim >/dev/null
nim c -d:release --nimcache:/tmp/nimcache_kouten_auto_pack_server \
  -o:"$WORK/koutend" src/koutend.nim >/dev/null
nim c -d:release --nimcache:/tmp/nimcache_kouten_auto_pack_cli \
  -o:"$WORK/kouten" src/koutencli.nim >/dev/null

"$WORK/fixture" "$DATA"

echo "[auto-pack] start opt-in bounded scheduler"
"$WORK/koutend" --id=0 --peers="127.0.0.1:$PORT" --data="$DATA" \
  --disk-backed --auto-pack --slow-tick=0.05 --auto-pack-interval=0.1 \
  --auto-pack-stale-ratio=0.5 --auto-pack-min-stale-records=4 \
  --auto-pack-max-rings=1 --auto-pack-max-bytes=1048576 \
  --auto-pack-max-elapsed-ms=1000 >"$WORK/server.log" 2>&1 &
PID=$!

METRICS=""
auto_pack_ready=false
for _ in $(seq 1 600); do
  if ! kill -0 "$PID" >/dev/null 2>&1; then
    echo "auto-pack server exited before completing maintenance" >&2
    cat "$WORK/server.log" >&2
    exit 1
  fi
  if METRICS="$("$WORK/kouten" metrics --peers="127.0.0.1:$PORT" 2>/dev/null)" &&
      grep -Eq 'autoPackRings [1-9][0-9]*' <<<"$METRICS"; then
    auto_pack_ready=true
    break
  fi
  sleep 0.05
done
if [[ "$auto_pack_ready" != true ]]; then
  echo "auto-pack did not complete within 30 seconds" >&2
  printf '%s\n' "$METRICS" >&2
  cat "$WORK/server.log" >&2
  exit 1
fi
grep -Eq 'autoPackCompleted [1-9][0-9]*' <<<"$METRICS"
grep -Eq 'autoPackRings [1-9][0-9]*' <<<"$METRICS"

echo "[auto-pack] verify disk-backed remote count and cursor pagination"
count_output="$("$WORK/kouten" count-ring --peers="127.0.0.1:$PORT" \
  --ring=pagination/paged)"
if ! grep -q 'count=659' <<<"$count_output"; then
  echo "unexpected remote ring count: $count_output" >&2
  cat "$WORK/server.log" >&2
  exit 1
fi
cursor=""
previous_cursor=-1
: >"$WORK/raw-ids"
for _ in $(seq 1 10); do
  args=(list-ring --peers="127.0.0.1:$PORT" --ring=pagination/paged \
        --limit=128)
  if [[ -n "$cursor" ]]; then
    args+=(--cursor="$cursor")
  fi
  page="$("$WORK/kouten" "${args[@]}")"
  sed -n 's/^[[:space:]]*"rawId": "\([^"]*\)",*$/\1/p' \
    <<<"$page" >>"$WORK/raw-ids"
  cursor="$(sed -n 's/^[[:space:]]*"nextCursor": "\([^"]*\)",*$/\1/p' \
    <<<"$page")"
  if [[ -z "$cursor" ]]; then
    break
  fi
  if ((cursor <= previous_cursor)); then
    echo "remote list cursor did not advance: $previous_cursor -> $cursor" >&2
    exit 1
  fi
  previous_cursor=$cursor
done
listed_count="$(wc -l <"$WORK/raw-ids")"
unique_count="$(sort -u "$WORK/raw-ids" | wc -l)"
if [[ "$listed_count" -ne 659 || "$unique_count" -ne 659 ]]; then
  echo "unexpected remote page rows: listed=$listed_count unique=$unique_count" >&2
  exit 1
fi
if [[ -n "$cursor" ]]; then
  echo "remote list pagination did not terminate: cursor=$cursor" >&2
  exit 1
fi

kill "$PID"
wait "$PID" || true
PID=""

echo "[auto-pack] verify durable result and reopen"
maintenance_output="$("$WORK/kouten" maintenance-status --data="$DATA" --json)"
if ! grep -Eq '"outcome": "(completed|no-work)"' <<<"$maintenance_output"; then
  echo "unexpected maintenance status: $maintenance_output" >&2
  exit 1
fi
segment_output="$("$WORK/kouten" segment-status --data="$DATA" \
  --stale-ratio=0.5 --min-stale-records=4 --json)"
if ! grep -q '"recommendedRings": 0' <<<"$segment_output"; then
  echo "unexpected segment status: $segment_output" >&2
  exit 1
fi
verify_output="$("$WORK/kouten" verify --data="$DATA" --segments)"
if ! grep -q 'verify status: ok' <<<"$verify_output"; then
  echo "unexpected verify result: $verify_output" >&2
  exit 1
fi

echo "[auto-pack] reject unbounded automatic configuration"
if "$WORK/koutend" --id=0 --peers="127.0.0.1:$PORT" --data="$DATA" \
    --disk-backed --auto-pack --auto-pack-max-rings=0 >/dev/null 2>&1; then
  echo "automatic packing accepted an unbounded ring budget" >&2
  exit 1
fi

echo "[auto-pack] OK"
