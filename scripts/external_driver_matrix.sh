#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER_ROOT="${KOUTEN_EXTERNAL_DRIVER_ROOT:-$(cd "$ROOT/.." && pwd)}"
RUST_DIR="${KOUTEN_RUST_DRIVER_DIR:-$DRIVER_ROOT/koutendb-rust}"
JS_DIR="${KOUTEN_JS_DRIVER_DIR:-$DRIVER_ROOT/koutendb-js}"
PHP_DIR="${KOUTEN_PHP_DRIVER_DIR:-$DRIVER_ROOT/koutendb-php}"
CPP_DIR="${KOUTEN_CPP_DRIVER_DIR:-$DRIVER_ROOT/koutendb-cpp}"
PYTHON_DIR="${KOUTEN_PYTHON_DRIVER_DIR:-$DRIVER_ROOT/koutendb-python}"
RUN_DRIVER_SUITES="${KOUTEN_EXTERNAL_DRIVER_SUITES:-1}"
WORK="${KOUTEN_EXTERNAL_DRIVER_WORK_ROOT:-$ROOT/.tmp}/external-driver-matrix-$$"
CPP_BUILD="$WORK/cpp-build"
PHP_IMAGE="koutendb-external-driver-php-$$:local"
PORT="${KOUTEN_EXTERNAL_DRIVER_PORT:-$((18600 + ($$ % 1000)))}"
PEERS="localhost:$PORT"
SERVER_PEERS="0.0.0.0:$PORT"
CA_CERT="$WORK/ca.crt"
CA_KEY="$WORK/ca.key"
WRONG_CA="$WORK/wrong-ca.crt"
CERT="$WORK/server.crt"
KEY="$WORK/server.key"
LOG="$WORK/koutend.log"
PID=""
PHP_IMAGE_BUILT=0
declare -a FAILURES=()

log() {
  printf '\n[external-drivers] %s\n' "$*"
}

record_failure() {
  FAILURES+=("$1")
  printf '[external-drivers] FAIL: %s\n' "$1" >&2
}

require_dir() {
  if [[ ! -d "$2" ]]; then
    printf '[external-drivers] missing %s driver directory: %s\n' "$1" "$2" >&2
    exit 1
  fi
}

cleanup() {
  if [[ -n "$PID" ]]; then
    kill "$PID" >/dev/null 2>&1 || true
    wait "$PID" >/dev/null 2>&1 || true
  fi
  if [[ "$PHP_IMAGE_BUILT" == "1" ]]; then
    docker image rm "$PHP_IMAGE" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

run_case() {
  local label="$1"
  shift
  log "$label"
  if "$@"; then
    printf '[external-drivers] PASS: %s\n' "$label"
  else
    record_failure "$label"
  fi
}

rust_suite() {
  cd "$RUST_DIR" && KOUTENDB_CORE_DIR="$ROOT" cargo test
}

js_suite() {
  cd "$JS_DIR" && \
    KOUTENDB_CORE_DIR="$ROOT" npm run build && \
    LD_LIBRARY_PATH="$ROOT/lib" npm run test:node
}

js_build() {
  cd "$JS_DIR" && KOUTENDB_CORE_DIR="$ROOT" npm run build
}

php_suite() {
  docker run --rm \
    -v "$PHP_DIR:/driver" -v "$ROOT:/koutendb" -w /driver \
    -e LD_LIBRARY_PATH=/koutendb/lib "$PHP_IMAGE" \
    sh -lc 'php -d ffi.enable=1 tests/driver_test.php && php -d ffi.enable=1 examples/embedded.php'
}

cpp_suite() {
  cmake -S "$CPP_DIR" -B "$CPP_BUILD" -DKOUTENDB_CORE_DIR="$ROOT" && \
    cmake --build "$CPP_BUILD" && \
    LD_LIBRARY_PATH="$ROOT/lib" "$CPP_BUILD/koutendb_cpp_contract_smoke"
}

python_suite() {
  cd "$PYTHON_DIR" && \
    KOUTENDB_CORE_DIR="$ROOT" python3 -m unittest discover -s tests
}

start_server() {
  "$ROOT/src/koutend" --id=0 --peers="$SERVER_PEERS" \
    --data="$WORK/data" --disk-backed --durability=strong \
    --user=alice --password=secret --secret-key=shared-secret \
    --allow-ring=secure --tls-cert="$CERT" --tls-key="$KEY" \
    --slow-tick=0.05 >"$LOG" 2>&1 &
  PID=$!
  for _ in $(seq 1 80); do
    if ! kill -0 "$PID" >/dev/null 2>&1; then
      cat "$LOG" >&2
      return 1
    fi
    if grep -q 'listening' "$LOG" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  cat "$LOG" >&2
  return 1
}

stop_server() {
  if [[ -n "$PID" ]]; then
    kill "$PID" >/dev/null 2>&1 || true
    wait "$PID" >/dev/null 2>&1 || true
    PID=""
  fi
}

rust_probe() {
  cd "$RUST_DIR" && LD_LIBRARY_PATH="$ROOT/lib" \
    timeout 15s env \
      ORBP_PEERS="$KOUTEN_PROBE_PEERS" ORBP_USER="$KOUTEN_PROBE_USER" \
      ORBP_PASS="$KOUTEN_PROBE_PASSWORD" ORBP_SECRET="$KOUTEN_PROBE_SECRET_KEY" \
      ORBP_CA="$KOUTEN_PROBE_CA_FILE" ORBP_SNI="$KOUTEN_PROBE_SERVER_NAME" \
      ORBP_TLS="$KOUTEN_PROBE_TLS" ORBP_INSECURE="$KOUTEN_PROBE_INSECURE" \
      "$RUST_DIR/target/debug/examples/sec_probe"
}

js_probe() {
  cd "$JS_DIR" && LD_LIBRARY_PATH="$ROOT/lib" \
    timeout 15s env \
      ORBP_PEERS="$KOUTEN_PROBE_PEERS" ORBP_USER="$KOUTEN_PROBE_USER" \
      ORBP_PASS="$KOUTEN_PROBE_PASSWORD" ORBP_SECRET="$KOUTEN_PROBE_SECRET_KEY" \
      ORBP_CA="$KOUTEN_PROBE_CA_FILE" ORBP_SNI="$KOUTEN_PROBE_SERVER_NAME" \
      ORBP_TLS="$KOUTEN_PROBE_TLS" ORBP_INSECURE="$KOUTEN_PROBE_INSECURE" \
      node examples/sec_probe.mjs
}

php_probe() {
  local container_ca=""
  if [[ "$KOUTEN_PROBE_CA_FILE" == "$CA_CERT" ]]; then
    container_ca=/matrix/ca.crt
  elif [[ "$KOUTEN_PROBE_CA_FILE" == "$WRONG_CA" ]]; then
    container_ca=/matrix/wrong-ca.crt
  fi
  timeout 20s docker run --rm --add-host=host.docker.internal:host-gateway \
    -v "$PHP_DIR:/driver" -v "$ROOT:/koutendb" -v "$WORK:/matrix:ro" \
    -w /driver -e LD_LIBRARY_PATH=/koutendb/lib \
    -e ORBP_PEERS="host.docker.internal:$PORT" \
    -e ORBP_USER="$KOUTEN_PROBE_USER" -e ORBP_PASS="$KOUTEN_PROBE_PASSWORD" \
    -e ORBP_SECRET="$KOUTEN_PROBE_SECRET_KEY" -e ORBP_TLS="$KOUTEN_PROBE_TLS" \
    -e ORBP_SNI="$KOUTEN_PROBE_SERVER_NAME" \
    -e ORBP_INSECURE="$KOUTEN_PROBE_INSECURE" \
    -e ORBP_CA="$container_ca" "$PHP_IMAGE" \
    php -d ffi.enable=1 examples/sec_probe.php
}

cpp_probe() {
  LD_LIBRARY_PATH="$ROOT/lib" timeout 15s env \
    ORBP_PEERS="$KOUTEN_PROBE_PEERS" ORBP_USER="$KOUTEN_PROBE_USER" \
    ORBP_PASS="$KOUTEN_PROBE_PASSWORD" ORBP_SECRET="$KOUTEN_PROBE_SECRET_KEY" \
    ORBP_CA="$KOUTEN_PROBE_CA_FILE" ORBP_SNI="$KOUTEN_PROBE_SERVER_NAME" \
    ORBP_TLS="$KOUTEN_PROBE_TLS" ORBP_INSECURE="$KOUTEN_PROBE_INSECURE" \
    "$CPP_BUILD/koutendb_cpp_sec_probe"
}

python_probe() {
  PYTHONPATH="$PYTHON_DIR" timeout 15s \
    python3 "$ROOT/scripts/driver_probes/python_security_probe.py"
}

probe_expect() {
  local label="$1"
  local expected="$2"
  local command="$3"
  local output
  if output="$($command 2>&1)" && grep -q "^${expected}" <<<"$output"; then
    printf '[external-drivers] PASS: %s\n' "$label"
  else
    printf '%s\n' "$output" >&2
    record_failure "$label"
  fi
}

run_probe_row() {
  local row="$1"
  local expected="$2"
  local password="$3"
  local secret="$4"
  local ca="$5"
  local tls="$6"
  export KOUTEN_PROBE_PEERS="$PEERS"
  export KOUTEN_PROBE_USER=alice
  export KOUTEN_PROBE_PASSWORD="$password"
  export KOUTEN_PROBE_SECRET_KEY="$secret"
  export KOUTEN_PROBE_CA_FILE="$ca"
  export KOUTEN_PROBE_SERVER_NAME=localhost
  export KOUTEN_PROBE_TLS="$tls"
  export KOUTEN_PROBE_INSECURE=0
  for driver in rust js php cpp python; do
    probe_expect "$driver: $row" "$expected" "${driver}_probe"
  done
}

for pair in \
  "Rust:$RUST_DIR" "JavaScript:$JS_DIR" "PHP:$PHP_DIR" \
  "C++:$CPP_DIR" "Python:$PYTHON_DIR"; do
  require_dir "${pair%%:*}" "${pair#*:}"
done
for command in cargo npm docker cmake python3 openssl timeout; do
  command -v "$command" >/dev/null 2>&1 || {
    printf '[external-drivers] required command is unavailable: %s\n' "$command" >&2
    exit 1
  }
done

mkdir -p "$WORK" "$ROOT/lib"

log "build TLS-enabled core C ABI and server"
"$ROOT/scripts/build_capi.sh" || exit 1
nim c -d:ssl -d:release --nimcache:/tmp/nimcache_koutend_external_drivers \
  -o:"$ROOT/src/koutend" "$ROOT/src/koutend.nim" >/dev/null || exit 1
nim c -d:ssl -d:release --nimcache:/tmp/nimcache_koutencli_external_drivers \
  -o:"$ROOT/src/koutencli" "$ROOT/src/koutencli.nim" >/dev/null || exit 1

log "build isolated PHP FFI image"
if docker build -t "$PHP_IMAGE" "$PHP_DIR"; then
  PHP_IMAGE_BUILT=1
else
  exit 1
fi

if [[ "$RUN_DRIVER_SUITES" == "1" ]]; then
  run_case "Rust driver suite" rust_suite
  run_case "JavaScript/TypeScript driver suite" js_suite
  run_case "PHP driver suite" php_suite
  run_case "C++ driver suite" cpp_suite
  run_case "Python driver suite" python_suite
else
  log "driver-owned suites skipped by KOUTEN_EXTERNAL_DRIVER_SUITES=$RUN_DRIVER_SUITES"
  run_case "JavaScript/TypeScript driver build" js_build
  run_case "C++ driver build" cpp_suite
fi

log "build shared security probes"
if ! (cd "$RUST_DIR" && KOUTENDB_CORE_DIR="$ROOT" cargo build --example sec_probe); then
  record_failure "Rust security probe build"
fi
if [[ ! -x "$CPP_BUILD/koutendb_cpp_sec_probe" ]]; then
  record_failure "C++ security probe build"
fi

log "generate CA material"
openssl req -x509 -nodes -newkey rsa:2048 -days 2 \
  -keyout "$CA_KEY" -out "$CA_CERT" -subj '/CN=KoutenDB Driver Matrix CA' \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
openssl req -nodes -newkey rsa:2048 -keyout "$KEY" -out "$WORK/server.csr" \
  -subj '/CN=localhost' >/dev/null 2>&1
cat >"$WORK/server.ext" <<'EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,DNS:host.docker.internal,IP:127.0.0.1
EXT
openssl x509 -req -in "$WORK/server.csr" -CA "$CA_CERT" -CAkey "$CA_KEY" \
  -CAcreateserial -out "$CERT" -days 2 -sha256 -extfile "$WORK/server.ext" \
  >/dev/null 2>&1
openssl req -x509 -nodes -newkey rsa:2048 -days 2 \
  -keyout "$WORK/wrong-ca.key" -out "$WRONG_CA" \
  -subj '/CN=Wrong Driver Matrix CA' >/dev/null 2>&1

log "start persistent TLS/auth server"
start_server || exit 1
run_probe_row "verified TLS/auth CRUD" SUCCESS secret shared-secret "$CA_CERT" 1
run_probe_row "wrong password rejected" REJECT wrong shared-secret "$CA_CERT" 1
run_probe_row "wrong secret rejected" REJECT secret wrong "$CA_CERT" 1
run_probe_row "foreign CA rejected" REJECT secret shared-secret "$WRONG_CA" 1
run_probe_row "plaintext rejected by TLS listener" REJECT secret shared-secret "" 0

log "restart the persistent server and repeat verified CRUD"
stop_server
start_server || exit 1
run_probe_row "verified CRUD after restart" SUCCESS secret shared-secret "$CA_CERT" 1
stop_server

log "verify persistent data and audit evidence"
if ! "$ROOT/src/koutencli" verify --data="$WORK/data" --segments --json | \
    grep -q '"kind": "data"'; then
  record_failure "offline persistent-store verification"
fi
if ! grep -q '"event":"auth-failure"' "$WORK/data/kouten.audit.jsonl"; then
  record_failure "persistent auth-failure audit evidence"
fi

if (( ${#FAILURES[@]} > 0 )); then
  printf '\n[external-drivers] %d failure(s):\n' "${#FAILURES[@]}" >&2
  printf '  - %s\n' "${FAILURES[@]}" >&2
  exit 1
fi

log "OK"
