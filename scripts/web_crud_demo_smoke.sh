#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "[web-crud] SKIP docker compose is not available"
  exit 0
fi

cleanup_all() {
  env REKT_PORT=0 docker compose --project-name koutendb-rekt-crud-smoke \
    -f examples/rekt-crud/compose.yml down -v --remove-orphans >/dev/null 2>&1 || true
  env PRK_PORT=0 docker compose --project-name koutendb-prk-crud-smoke \
    -f examples/prk-crud/compose.yml down -v --remove-orphans >/dev/null 2>&1 || true
}

trap cleanup_all EXIT

run_stack() {
  local name="$1"
  local compose_file="examples/${name}-crud/compose.yml"
  local project="koutendb-${name}-crud-smoke"
  local port_variable
  if [[ "$name" == "rekt" ]]; then
    port_variable="REKT_PORT=0"
  else
    port_variable="PRK_PORT=0"
  fi

  echo "[web-crud] build and start ${name^^}"
  env "$port_variable" docker compose --project-name "$project" -f "$compose_file" \
    down -v --remove-orphans >/dev/null 2>&1 || true
  env "$port_variable" docker compose --project-name "$project" -f "$compose_file" \
    up -d --build --wait
  env "$port_variable" docker compose --project-name "$project" -f "$compose_file" \
    --profile test run --rm --build smoke
  echo "[web-crud] ${name^^} OK"
  env "$port_variable" docker compose --project-name "$project" -f "$compose_file" \
    down -v --remove-orphans >/dev/null
}

run_stack rekt
run_stack prk

echo "[web-crud] all CRUD contracts passed"
