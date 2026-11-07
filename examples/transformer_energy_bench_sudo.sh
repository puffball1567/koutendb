#!/usr/bin/env bash
# Run from a user's terminal so sudo can request a password there.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ "${1:-}" == "--help" ]]; then
  exec python3 examples/transformer_energy_bench.py --help
fi
mkdir -p .tmp/transformer-energy
export OUTPUT="${OUTPUT:-.tmp/transformer-energy/results.json}"
printf '%s\n' 'Preparing retrieval prompts, then measuring CPU package joules/request.' \
  'When sudo asks, enter your password in this terminal.' \
  'Only the read-only energy helper uses administrator privileges.'
bash examples/transformer_energy_bench.sh \
  --sudo-energy --require-energy --rounds=12 --min-block-seconds=0.5 "$@" \
  | tee .tmp/transformer-energy/output.log
