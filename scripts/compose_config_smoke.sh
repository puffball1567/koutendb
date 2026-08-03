#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v docker >/dev/null 2>&1; then
  echo "[compose-config] SKIP docker command not found"
  exit 0
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "[compose-config] SKIP docker compose plugin not available"
  exit 0
fi

echo "[compose-config] validate compose files"
for file in examples/compose/*.compose.yml; do
  echo "[compose-config] $file"
  docker compose -f "$file" config >/dev/null
  docker compose -f "$file" --profile tools config >/dev/null
done

echo "[compose-config] OK"
