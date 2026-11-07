#!/usr/bin/env bash
# No model or dataset download: train on generated relational data when needed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BENCH_WORK="${KOUTEN_RING_WORK:-.tmp/ring-memory-model}"
BENCH_PYTHON="${KOUTEN_BENCH_PYTHON:-python3}"
if [[ -z "${KOUTEN_BENCH_PYTHON:-}" && -x .tmp/rag-energy/venv/bin/python ]]; then
  BENCH_PYTHON=.tmp/rag-energy/venv/bin/python
fi
ENERGY_ARGS=(--sudo-energy --require-energy)
if [[ "${1:-}" == "--no-energy" ]]; then
  ENERGY_ARGS=()
  shift
fi
if [[ "${1:-}" == "--help" ]]; then
  exec "$BENCH_PYTHON" examples/ring_memory_experiment.py --help
fi
"$BENCH_PYTHON" -c 'import torch, numpy' || { printf '%s\n' 'This experiment requires local PyTorch and NumPy.' >&2; exit 1; }
mkdir -p "$BENCH_WORK"
bash scripts/build_capi.sh
printf '%s\n' 'Internal learned-memory experiment: dense layer / full tensor / sparse tensor / real KoutenDB.'
if [[ ${#ENERGY_ARGS[@]} -gt 0 ]]; then
  printf '%s\n' 'Only the read-only energy helper requests sudo in this terminal.'
fi
"$BENCH_PYTHON" examples/ring_memory_experiment.py --work="$BENCH_WORK" \
  "${ENERGY_ARGS[@]}" "$@" | tee "$BENCH_WORK/output.log"
