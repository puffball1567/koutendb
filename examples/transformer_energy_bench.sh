#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/koutendb-transformer.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Keep the report outside temporary data so it remains available after exit.
OUTPUT="${OUTPUT:-transformer-energy-results.json}"
PROMPTS_OUT="$WORK/prompts.jsonl" bash examples/ai_rag_case_study.sh
python3 examples/transformer_energy_bench.py \
  --prompts="$WORK/prompts.jsonl" --output="$OUTPUT" "$@"
