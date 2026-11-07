#!/usr/bin/env bash
# Accuracy only: generated data, no downloads or privileged counters.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BENCH_PYTHON="${KOUTEN_BENCH_PYTHON:-python3}"
if [[ -z "${KOUTEN_BENCH_PYTHON:-}" && -x .tmp/rag-energy/venv/bin/python ]]; then
  BENCH_PYTHON=.tmp/rag-energy/venv/bin/python
fi
if [[ "${1:-}" == "--help" ]]; then
  exec "$BENCH_PYTHON" examples/ring_memory_quality_bench.py --help
fi
if [[ ! -f lib/libkoutendb.so ]]; then
  printf '%s\n' 'Build the C ABI first: bash scripts/build_capi.sh' >&2
  exit 1
fi
exec "$BENCH_PYTHON" examples/ring_memory_quality_bench.py "$@"
