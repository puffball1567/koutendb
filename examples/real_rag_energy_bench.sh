#!/usr/bin/env bash
# Run this in a local terminal; the sudo helper reads its password from the TTY.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BENCH_WORK=.tmp/rag-energy
BENCH_PYTHON="$BENCH_WORK/venv/bin/python"
if [[ ! -x "$BENCH_PYTHON" ]]; then
  python3 -m venv --system-site-packages "$BENCH_WORK/venv"
fi
"$BENCH_PYTHON" -c 'import torch' || { printf '%s\n' 'An existing PyTorch installation is required.' >&2; exit 1; }
if ! "$BENCH_PYTHON" -c 'from importlib.metadata import version; assert all(version(k) == v for k, v in {"transformers":"4.57.6", "sentencepiece":"0.2.3", "safetensors":"0.8.0"}.items())' >/dev/null 2>&1; then
  "$BENCH_PYTHON" -m pip install -r examples/real_rag_requirements.txt
fi
if [[ "${1:-}" == "--help" ]]; then
  exec "$BENCH_PYTHON" examples/real_rag_energy_bench.py --help
fi
if [[ ! -f "$BENCH_WORK/sources.json" || ! -f "$BENCH_WORK/dev-v1.1.json" || \
      ! -f "$BENCH_WORK/models/generator/model.safetensors" || \
      ! -f "$BENCH_WORK/models/embedding/model.safetensors" ]]; then
  "$BENCH_PYTHON" examples/real_rag_prepare.py --work="$BENCH_WORK"
fi
bash scripts/build_capi.sh
ENERGY_ARGS=(--sudo-energy --require-energy)
if [[ "${1:-}" == "--no-energy" ]]; then
  ENERGY_ARGS=()
  shift
fi
printf '%s\n' 'Real-data RAG: query embedding -> routing -> KoutenDB -> trained model -> answer.'
if [[ ${#ENERGY_ARGS[@]} -gt 0 ]]; then
  printf '%s\n' 'Only the energy counter reader uses sudo. Enter its password in this terminal.'
fi
"$BENCH_PYTHON" examples/real_rag_energy_bench.py --work="$BENCH_WORK" \
  "${ENERGY_ARGS[@]}" "$@" | tee "$BENCH_WORK/output.log"
