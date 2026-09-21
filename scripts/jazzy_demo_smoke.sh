#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
: "${JAZZY_DIR:?Set JAZZY_DIR to a jazzy-framework checkout; see examples/web/jazzy-crud/README.md}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kouten-jazzy-build.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
nim c --skipParentCfg:on --mm:arc --panics:on -d:release -d:ssl \
  --nimcache:"$WORK/core-cache" -o:"$WORK/koutend" src/koutend.nim
nim c --skipParentCfg:on --mm:atomicArc --threads:on --panics:on \
  -d:useMalloc -d:release -d:ssl --path:src --path:"$JAZZY_DIR/src" \
  "$@" --nimcache:"$WORK/api-cache" -o:"$WORK/api" examples/web/jazzy-crud/api/app.nim
python3 examples/web/jazzy-crud/tests/integration.py "$WORK/koutend" "$WORK/api"
