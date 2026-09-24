#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kouten-wire-security.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
nim c -d:release --nimcache:"$WORK/client-cache" -o:"$WORK/client" tests/twire_security.nim
nim c -d:release -d:koutenTestSmallLimits -d:koutenTestWireDeadline \
  --nimcache:"$WORK/server-cache" -o:"$WORK/koutend" src/koutend.nim
"$WORK/client"
python3 tests/wire_security_matrix.py "$WORK/client" "$WORK/koutend"
