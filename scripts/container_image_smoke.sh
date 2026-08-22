#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IMAGE="${KOUTEN_CONTAINER_IMAGE:-koutendb:container-smoke}"
BUILD_IMAGE="${KOUTEN_CONTAINER_BUILD_IMAGE:-1}"
VOLUME="koutendb-container-smoke-$$"

cleanup() {
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
  if [[ "$BUILD_IMAGE" == "1" && "${KOUTEN_CONTAINER_KEEP_IMAGE:-0}" != "1" ]]; then
    docker image rm "$IMAGE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if ! command -v docker >/dev/null 2>&1; then
  echo "[container-image] docker command is required" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "[container-image] docker daemon is unavailable" >&2
  exit 1
fi

if [[ "$BUILD_IMAGE" == "1" ]]; then
  echo "[container-image] build official image"
  docker build --build-arg VCS_REF=container-smoke \
    --build-arg VERSION=container-smoke -t "$IMAGE" .
fi

echo "[container-image] verify runtime identity and CLI"
docker run --rm --entrypoint id "$IMAGE" | grep -q 'uid=10001(koutendb)'
docker run --rm --entrypoint kouten "$IMAGE" --help | grep -q 'KoutenDB command-line client'

echo "[container-image] verify named-volume persistence across containers"
docker volume create "$VOLUME" >/dev/null
docker run --rm -v "$VOLUME:/var/lib/koutendb" --entrypoint kouten "$IMAGE" \
  put --data=/var/lib/koutendb/data --ring=ops/container \
  --payload='{"status":"persisted"}' --codec=json >/dev/null
docker run --rm -v "$VOLUME:/var/lib/koutendb" --entrypoint kouten "$IMAGE" \
  get --data=/var/lib/koutendb/data --ring=ops/container |
  grep -q '"status": "persisted"'

echo "[container-image] verify persisted data offline"
docker run --rm -v "$VOLUME:/var/lib/koutendb" --entrypoint kouten "$IMAGE" \
  verify --data=/var/lib/koutendb/data --segments --json |
  grep -q '"kind": "data"'

echo "[container-image] OK"
