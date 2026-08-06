#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORK="${TMPDIR:-/tmp}/kouten-checkpoint-smoke-$$"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK" "$ROOT/bin"

echo "[checkpoint] build kouten"
nim c -d:release --nimcache:/tmp/nimcache_kouten_checkpoint_smoke \
  -o:bin/kouten src/koutencli.nim >/dev/null

echo "[checkpoint] seed persistent data"
bin/kouten put --data="$WORK/source" --ring=users/123 \
  --payload='{"kind":"profile","name":"Alice"}' --codec=json >/dev/null
bin/kouten put --data="$WORK/source" --ring=users/123/orders \
  --payload='{"kind":"order","number":"A-1"}' --codec=json >/dev/null

echo "[checkpoint] create and verify"
created="$(bin/kouten checkpoint-create --data="$WORK/source" \
  --checkpoint-root="$WORK/checkpoints" --checkpoint-id=smoke-1 --json)"
grep -q '"verified": true' <<<"$created"
grep -q '"id": "smoke-1"' <<<"$created"
bin/kouten checkpoint-verify \
  --checkpoint="$WORK/checkpoints/smoke-1" --json |
  grep -q '"reason": "verified"'
bin/kouten checkpoint-list --checkpoint-root="$WORK/checkpoints" --json |
  grep -q '"count": 1'

echo "[checkpoint] restore selected generation"
bin/kouten checkpoint-restore \
  --checkpoint="$WORK/checkpoints/smoke-1" \
  --data="$WORK/restored" --json |
  grep -q '"reason": "restored"'
bin/kouten get --data="$WORK/restored" --ring=users/123 --limit=10 |
  grep -q '"name": "Alice"'
bin/kouten get --data="$WORK/restored" --ring=users/123/orders --limit=10 |
  grep -q '"number": "A-1"'

echo "[checkpoint] cleanup keeps the final verified generation"
bin/kouten checkpoint-clean --checkpoint-root="$WORK/checkpoints" \
  --keep=1 --json | grep -q '"kept": 1'
if bin/kouten checkpoint-clean --checkpoint-root="$WORK/checkpoints" \
    --keep=0 >/dev/null 2>&1; then
  echo "checkpoint cleanup accepted keep=0" >&2
  exit 1
fi

echo "[checkpoint] OK"
