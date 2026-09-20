#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ "$#" -eq 0 ]]; then
  echo 'Usage: bash scripts/native_driver_conformance.sh <JSONL adapter command> [args...]' >&2
  exit 2
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/kouten-native-build.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
NIMSODIUM_PATH="${KOUTENDB_NIMSODIUM_PATH:-}"
if [[ -z "$NIMSODIUM_PATH" ]]; then
  NIMSODIUM_PATH="$(nimble path nimsodium)"
fi
NIMSODIUM_PATH="${NIMSODIUM_PATH%%$'\n'*}"
nim c -d:release -d:ssl --path:"$NIMSODIUM_PATH" --nimcache:"$TMP/cache" \
  -o:"$TMP/koutend" src/koutend.nim
python3 scripts/native_driver_conformance.py --server "$TMP/koutend" -- "$@"
