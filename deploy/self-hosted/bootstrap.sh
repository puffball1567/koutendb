#!/usr/bin/env bash
set -euo pipefail

SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${1:-$PWD/koutendb-selfhost}"
VERSION="${KOUTENDB_VERSION:-0.14.0}"

fail() {
  echo "[self-host-bootstrap] $*" >&2
  exit 1
}

command -v openssl >/dev/null 2>&1 || fail "openssl is required"
command -v install >/dev/null 2>&1 || fail "install is required"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.-]+)?$ ]] ||
  fail "invalid KOUTENDB_VERSION: $VERSION"

if [[ -e "$OUTPUT" ]]; then
  [[ ! -L "$OUTPUT" ]] || fail "output directory must not be a symlink"
  [[ -d "$OUTPUT" ]] || fail "output exists and is not a directory: $OUTPUT"
  [[ -z "$(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
    fail "output directory is not empty: $OUTPUT"
fi

umask 077
install -d -m 0700 "$OUTPUT" "$OUTPUT/config" "$OUTPUT/certs" \
  "$OUTPUT/secrets" "$OUTPUT/operator" "$OUTPUT/state" "$OUTPUT/systemd"
install -m 0644 "$SOURCE/compose.yaml" "$OUTPUT/compose.yaml"
install -m 0644 "$SOURCE/config/server.json" "$OUTPUT/config/server.json"
install -m 0644 "$SOURCE/config/client.json" "$OUTPUT/config/client.json"
install -m 0755 "$SOURCE/watchdog.sh" "$OUTPUT/watchdog.sh"
install -m 0644 "$SOURCE/systemd/koutendb-watchdog.service" \
  "$OUTPUT/systemd/koutendb-watchdog.service"
install -m 0644 "$SOURCE/systemd/koutendb-watchdog.timer" \
  "$OUTPUT/systemd/koutendb-watchdog.timer"
install -m 0600 "$SOURCE/systemd/watchdog.env" \
  "$OUTPUT/systemd/watchdog.env"

openssl rand -hex 32 >"$OUTPUT/secrets/password"
openssl rand -hex 32 >"$OUTPUT/secrets/secret-key"
chmod 0600 "$OUTPUT/secrets/password" "$OUTPUT/secrets/secret-key"

openssl req -x509 -nodes -newkey rsa:3072 -sha256 -days 3650 \
  -keyout "$OUTPUT/operator/ca.key" -out "$OUTPUT/certs/ca.crt" \
  -subj "/CN=KoutenDB Self-Host CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
openssl req -nodes -newkey rsa:3072 -sha256 \
  -keyout "$OUTPUT/certs/server.key" -out "$OUTPUT/operator/server.csr" \
  -subj "/CN=koutendb" >/dev/null 2>&1
cat >"$OUTPUT/operator/server.ext" <<'EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:koutendb,DNS:localhost,IP:127.0.0.1
EXT
openssl x509 -req -sha256 -days 397 \
  -in "$OUTPUT/operator/server.csr" \
  -CA "$OUTPUT/certs/ca.crt" -CAkey "$OUTPUT/operator/ca.key" \
  -CAcreateserial -out "$OUTPUT/certs/server.crt" \
  -extfile "$OUTPUT/operator/server.ext" >/dev/null 2>&1
chmod 0600 "$OUTPUT/operator/ca.key" "$OUTPUT/certs/server.key"
chmod 0644 "$OUTPUT/certs/ca.crt" "$OUTPUT/certs/server.crt"

cat >"$OUTPUT/.env" <<ENV
KOUTENDB_IMAGE=ghcr.io/puffball1567/koutendb:${VERSION}
KOUTENDB_CONTAINER_NAME=koutendb-selfhost
KOUTENDB_BIND_ADDRESS=127.0.0.1
KOUTENDB_PORT=7301
ENV
chmod 0600 "$OUTPUT/.env"

echo "[self-host-bootstrap] created $OUTPUT"
echo "[self-host-bootstrap] review .env and config before starting"
echo "[self-host-bootstrap] start with: docker compose --project-directory $OUTPUT up -d"
