#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

scripts/test_core.sh
scripts/cli_crud_smoke.sh
scripts/cluster_tx_smoke.sh
scripts/cluster_failure_smoke.sh
scripts/cluster_authz_smoke.sh
scripts/cluster_rbac_smoke.sh
scripts/cluster_wire_driver_smoke.sh
scripts/cluster_wire_fuzz_smoke.sh
scripts/handoff_reclamation_smoke.sh
scripts/cluster_tls_smoke.sh
scripts/recovery_smoke.sh
scripts/universe_sync_failure_smoke.sh
scripts/universe_sync_remote_smoke.sh
scripts/demo_smoke.sh
scripts/compose_config_smoke.sh

if [[ "${KOUTEN_TEST_DRIVERS:-0}" == "1" ]]; then
  scripts/driver_compat.sh
else
  echo "[test-all-smoke] driver compatibility skipped; set KOUTEN_TEST_DRIVERS=1 to run it"
fi

echo "[test-all-smoke] OK"
