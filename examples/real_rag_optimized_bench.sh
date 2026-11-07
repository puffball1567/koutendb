#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ENERGY_ARGS=()
if [[ "${1:-}" == "--no-energy" ]]; then
  ENERGY_ARGS+=(--no-energy)
  shift
fi
if [[ "${1:-}" == "--help" ]]; then
  exec bash examples/real_rag_energy_bench.sh --help
fi
# Keep the previous 40-question result and all development questions separate.
# Share the context policy with a global control so its benefit is not falsely
# attributed to ring routing.
exec bash examples/real_rag_energy_bench.sh "${ENERGY_ARGS[@]}" \
  --queries=100 --query-offset=200 --repeats=3 \
  --arms=global_3,global_compact_3,oracle_ring_3,oracle_compact_3,auto_ring_3,auto_compact_3 \
  --output=.tmp/rag-energy/optimized-results.json "$@"
