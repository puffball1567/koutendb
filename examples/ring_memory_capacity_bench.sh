#!/usr/bin/env bash
# Generated data stays under the project's .tmp and is removed after each case.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BENCH_PYTHON="${KOUTEN_BENCH_PYTHON:-python3}"
if [[ -z "${KOUTEN_BENCH_PYTHON:-}" && -x .tmp/rag-energy/venv/bin/python ]]; then
  BENCH_PYTHON=.tmp/rag-energy/venv/bin/python
fi
if [[ "${1:-}" == "--help" ]]; then
  exec "$BENCH_PYTHON" examples/ring_memory_capacity_bench.py --help
fi
if [[ ! -f lib/libkoutendb.so ]]; then
  mkdir -p .tmp
  BENCH_BUILD_CACHE="$(mktemp -d "$ROOT/.tmp/ring-memory-capacity-build.XXXXXX")"
  trap 'rm -rf -- "$BENCH_BUILD_CACHE"' EXIT
  KOUTENDB_CAPI_NIMCACHE="$BENCH_BUILD_CACHE" bash scripts/build_capi.sh
  rm -rf -- "$BENCH_BUILD_CACHE"
  trap - EXIT
fi
exec "$BENCH_PYTHON" examples/ring_memory_capacity_bench.py "$@"
