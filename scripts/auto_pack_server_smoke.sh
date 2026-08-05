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
for _ in $(seq 1 100); do
  if METRICS="$("$WORK/kouten" metrics --peers="127.0.0.1:$PORT" 2>/dev/null)" &&
      grep -Eq 'autoPackCompleted [1-9][0-9]*' <<<"$METRICS"; then
    break
  fi
  sleep 0.05
done
grep -Eq 'autoPackCompleted [1-9][0-9]*' <<<"$METRICS"
grep -Eq 'autoPackRings [1-9][0-9]*' <<<"$METRICS"

kill "$PID"
wait "$PID" || true
PID=""

echo "[auto-pack] verify durable result and reopen"
"$WORK/kouten" maintenance-status --data="$DATA" --json |
  grep -q '"outcome": "completed"'
"$WORK/kouten" segment-status --data="$DATA" \
  --stale-ratio=0.5 --min-stale-records=4 --json |
  grep -q '"recommendedRings": 0'
"$WORK/kouten" verify --data="$DATA" --segments |
  grep -q 'verify status: ok'

echo "[auto-pack] reject unbounded automatic configuration"
if "$WORK/koutend" --id=0 --peers="127.0.0.1:$PORT" --data="$DATA" \
    --disk-backed --auto-pack --auto-pack-max-rings=0 >/dev/null 2>&1; then
  echo "automatic packing accepted an unbounded ring budget" >&2
  exit 1
fi

echo "[auto-pack] OK"
