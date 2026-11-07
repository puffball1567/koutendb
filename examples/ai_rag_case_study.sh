#!/usr/bin/env bash
set -euo pipefail

DOCS_PER_RING="${DOCS_PER_RING:-40}"
NOISE_DOCS="${NOISE_DOCS:-200}"
GLOBAL_BUDGET="${GLOBAL_BUDGET:-8}"
ROUTED_BUDGET="${ROUTED_BUDGET:-3}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/koutendb-ai-rag-case-$$"
CORPUS="$WORK/corpus.jsonl"
DATA="$WORK/data"

cleanup() {
  if [[ "${KEEP_CASE_STUDY:-0}" != "1" ]]; then
    rm -rf "$WORK"
  else
    echo "kept workdir: $WORK"
  fi
}
trap cleanup EXIT

mkdir -p "$WORK" "$ROOT/bin"
cd "$ROOT"

write_ring() {
  local ring="$1"
  local prefix="$2"
  local base="$3"
  local text="$4"
  local emb="$5"

  for ((i=0; i<DOCS_PER_RING; i++)); do
    local id
    printf -v id "%s-%03d" "$prefix" "$i"
    local title="$base reference $i"
    if [[ "$i" -eq 0 ]]; then
      title="$base canonical answer"
    fi
    printf '{"ring":"%s","body":{"id":"%s","title":"%s","text":"%s Case %03d includes routing keywords, operational context, and enough payload to make token estimates meaningful."},"embedding":[%s]}\n' \
      "$ring" "$id" "$title" "$text" "$i" "$emb" >> "$CORPUS"
  done
}

write_noise() {
  for ((i=0; i<NOISE_DOCS; i++)); do
    local id
    printf -v id "noise-general-%03d" "$i"
    printf '{"ring":"noise/general","body":{"id":"%s","title":"General background %03d","text":"Unrelated background material about office moves, lunch menus, meeting notes, and generic announcements. This document should not answer the focused RAG queries."},"embedding":[0.05,0.04,0.03,0.02,0.01,1.0]}\n' \
      "$id" "$i" >> "$CORPUS"
  done
}

echo "== Generate deterministic JSONL corpus =="
write_ring "docs/japan" "docs-japan" "Japanese refund support" \
  "Japanese documentation about refunds, invoices, account settings, product support, and regional support workflows." \
  "1.0,0.02,0.01,0.0,0.0,0.0"
write_ring "docs/us" "docs-us" "US enterprise onboarding" \
  "US documentation about enterprise onboarding, billing contacts, SSO setup, procurement, and support escalation." \
  "0.01,1.0,0.02,0.0,0.0,0.0"
write_ring "support/errors" "support-errors" "Database timeout incident" \
  "Support runbook about timeout errors, retry policies, database incidents, service degradation, and operator mitigation." \
  "0.0,0.02,1.0,0.02,0.0,0.0"
write_ring "papers/medicine" "papers-medicine" "Clinical trial safety" \
  "Biomedical research note about clinical trials, drug safety, adverse events, dosage, and patient monitoring." \
  "0.0,0.0,0.02,1.0,0.01,0.0"
write_ring "papers/water" "papers-water" "Membrane filtration" \
  "Water treatment research note about membrane filtration, activated carbon, pathogens, purification, and field deployment." \
  "0.0,0.0,0.0,0.01,1.0,0.02"
write_noise

echo "corpus: $CORPUS"
echo "docs:   $(wc -l < "$CORPUS")"
echo

echo "== Build case study runner =="
nim c -d:release --nimcache:/tmp/nimcache_kouten_ai_rag_case -o:bin/ai_rag_case_study examples/ai_rag_case_study.nim

echo
echo "== Run KoutenDB AI/RAG case study =="
EXPORT_ARGS=()
if [[ -n "${PROMPTS_OUT:-}" ]]; then
  EXPORT_ARGS+=("--export-prompts=$PROMPTS_OUT")
fi
bin/ai_rag_case_study \
  --corpus="$CORPUS" \
  --data="$DATA" \
  --global-budget="$GLOBAL_BUDGET" \
  --routed-budget="$ROUTED_BUDGET" \
  "${EXPORT_ARGS[@]}"
