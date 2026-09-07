#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kouten-runner-contract.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
mkdir "$WORK/bin" "$WORK/state"
cp "$ROOT/tests/fixtures/core-runner/nim" "$WORK/bin/nim"
chmod +x "$WORK/bin/nim"
export PATH="$WORK/bin:$PATH"
export KOUTEN_RUNNER_STATE="$WORK/state"
export KOUTEN_RUNNER_OVERLAP="$WORK/overlap"
export KOUTEN_RUNNER_LOG="$WORK/calls"

for jobs in 1 2; do
  : > "$KOUTEN_RUNNER_LOG"
  rm -f "$KOUTEN_RUNNER_OVERLAP"
  KOUTEN_TEST_JOBS="$jobs" bash "$ROOT/scripts/test_core.sh" > "$WORK/output"
  [[ $(wc -l < "$KOUTEN_RUNNER_LOG") -eq 12 ]]
  if [[ $jobs -eq 1 ]]; then
    [[ ! -e "$KOUTEN_RUNNER_OVERLAP" ]]
  else
    [[ -e "$KOUTEN_RUNNER_OVERLAP" ]]
  fi
  grep -q -- '-d:koutenTestFailpoints' "$KOUTEN_RUNNER_LOG"
  [[ $(grep -c -- '-o:.*kouten-core-tests\.' "$KOUTEN_RUNNER_LOG") -eq 12 ]]
done

: > "$KOUTEN_RUNNER_LOG"
if KOUTEN_TEST_JOBS=2 KOUTEN_RUNNER_FAIL=tapi.nim \
    bash "$ROOT/scripts/test_core.sh" > "$WORK/output" 2>&1; then
  echo "runner hid a failed child" >&2
  exit 1
fi
grep -q 'injected compiler failure: tapi.nim' "$WORK/output"
[[ $(wc -l < "$KOUTEN_RUNNER_LOG") -eq 12 ]]
for invalid in 0 -1 17 abc; do
  : > "$KOUTEN_RUNNER_LOG"
  if KOUTEN_TEST_JOBS="$invalid" bash "$ROOT/scripts/test_core.sh" > "$WORK/output" 2>&1; then
    echo "runner accepted invalid concurrency" >&2
    exit 1
  fi
  [[ ! -s "$KOUTEN_RUNNER_LOG" ]]
done
echo "Core test runner contract OK"
