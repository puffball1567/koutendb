#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

JOBS="${KOUTEN_TEST_JOBS:-2}"
if [[ ! "$JOBS" =~ ^([1-9]|1[0-6])$ ]]; then
  echo "KOUTEN_TEST_JOBS must be an integer from 1 to 16" >&2
  exit 2
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kouten-core-tests.XXXXXX")"
pids=()
names=()
failed=0
cleanup() {
  # Never remove a compiler's cache while a child is still using it.
  for pid in "${pids[@]}"; do wait "$pid" || true; done
  rm -rf -- "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

finish_batch() {
  local i
  for ((i = 0; i < ${#pids[@]}; i++)); do
    if ! wait "${pids[$i]}"; then
      echo "[test-core] FAILED: ${names[$i]}" >&2
      failed=1
    fi
    cat "$WORK/${names[$i]}.log"
  done
  pids=()
  names=()
}

run_nim_test() {
  local file="$1"
  shift
  local name
  name="$(basename "$file" .nim)"
  echo "[test-core] $file"
  nim c "$@" --nimcache="$WORK/cache-$name" -o:"$WORK/$name" \
    -r "$file" >"$WORK/$name.log" 2>&1 &
  pids+=("$!")
  names+=("$name")
  if [[ ${#pids[@]} -ge $JOBS ]]; then finish_batch; fi
}

run_nim_test tests/tcore.nim
run_nim_test tests/tauth.nim
run_nim_test tests/tselect.nim
run_nim_test tests/tfield.nim
run_nim_test tests/tstore.nim
run_nim_test tests/tapi.nim
run_nim_test tests/tread_boundaries.nim
run_nim_test tests/tmaintenance_window.nim
run_nim_test tests/tcheckpoints.nim
run_nim_test tests/tmetrics.nim
run_nim_test tests/tupgrade_fixtures.nim

run_nim_test tests/tsegment_failpoints.nim -d:koutenTestFailpoints
finish_batch

if [[ $failed -ne 0 ]]; then exit 1; fi

echo "[test-core] OK"
