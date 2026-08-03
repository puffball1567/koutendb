#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

nim c --nimcache=/tmp/nimcache_kouten_cluster_retrieve \
  -o:src/koutend src/koutend.nim
nim c --nimcache=/tmp/nimcache_kouten_cluster_retrieve_test \
  -r tests/tcluster_retrieve_routing.nim

echo "[cluster-retrieve-routing-smoke] OK"
