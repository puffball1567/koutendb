#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORK="${TMPDIR:-/tmp}/kouten-cli-crud-smoke-$$"
BASE_PORT="${KOUTEN_CLI_CRUD_BASE_PORT:-17991}"
PIDS=()
cleanup() {
  if ((${#PIDS[@]} > 0)); then
    kill "${PIDS[@]}" 2>/dev/null || true
    wait "${PIDS[@]}" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK" "$ROOT/bin"
export KOUTEN_DATA="$WORK/data"

echo "[cli-crud] build kouten"
nim c -d:release --nimcache:/tmp/nimcache_kouten_cli_crud \
  -o:bin/kouten src/koutencli.nim >/dev/null
nim c -d:release --nimcache:/tmp/nimcache_koutend_cli_crud \
  -o:src/koutend src/koutend.nim >/dev/null

echo "[cli-crud] help"
bin/kouten --help | grep -q "kouten put"

echo "[cli-crud] put"
put_out="$(bin/kouten put --ring=docs/japan \
  --payload='{"title":"Hello","status":"draft"}' --codec=json)"
grep -q "put OK" <<<"$put_out"
raw_id="$(sed -n 's/.*rawId=\([^ ]*\).*/\1/p' <<<"$put_out")"
if [[ -z "$raw_id" ]]; then
  echo "put did not print rawId" >&2
  exit 1
fi

echo "[cli-crud] atlas uses KOUTEN_DATA"
atlas_out="$(bin/kouten atlas)"
grep -q '"name": "docs/japan"' <<<"$atlas_out"
grep -q '"documents": 1' <<<"$atlas_out"

echo "[cli-crud] count/list/get/query"
bin/kouten count-ring --ring=docs/japan |
  grep -q "count=1"
bin/kouten get --ring=docs/japan |
  grep -q '"status": "draft"'
bin/kouten get --ring=docs/japan --limit=1 --rsort=time |
  grep -q '"items"'
bin/kouten get --ring=docs/japan --limit=1 --sort=id |
  grep -q '"sort": "id"'
bin/kouten get --ring=docs/japan --limit=1 --sort=id |
  grep -q '"sortDirection": "asc"'
bin/kouten list-ring --ring=docs/japan |
  grep -q '"rawId"'
bin/kouten get --ring=docs/japan --filter="{\"id\":\"$raw_id\"}" |
  grep -q '"status": "draft"'
bin/kouten get --ring=docs/japan --filter='{"status":"draft"}' --selection='{ title }' |
  grep -q '"title": "Hello"'
bin/kouten query --ring=docs/japan --filter="{\"id\":\"$raw_id\"}" --selection='{ title }' |
  grep -q '"title": "Hello"'

echo "[cli-crud] stellar-near ring reads"
bin/kouten put --ring=users/123 \
  --payload='{"kind":"user","name":"Alice"}' --codec=json >/dev/null
bin/kouten put --ring=orders --near=users/123 \
  --payload='{"kind":"order","orderNo":"A-001"}' --codec=json >/dev/null
bin/kouten put --ring=billing --near=users/123 \
  --payload='{"kind":"billing","plan":"pro"}' --codec=json >/dev/null
bin/kouten put --ring=users/999/orders \
  --payload='{"kind":"order","orderNo":"B-999"}' --codec=json >/dev/null
stellar_user="$(bin/kouten get --ring=users/123 --limit=10)"
grep -q '"ring": "users/123/orders"' <<<"$stellar_user"
grep -q '"ring": "users/123/billing"' <<<"$stellar_user"
if grep -q 'B-999' <<<"$stellar_user"; then
  echo "stellar user read included a distant ring" >&2
  exit 1
fi
stellar_order="$(bin/kouten get --ring=users/123/orders --limit=10)"
grep -q '"ring": "users/123"' <<<"$stellar_order"
grep -q '"orderNo": "A-001"' <<<"$stellar_order"
stellar_subring="$(bin/kouten get --ring=users/123 --subring=orders --limit=10)"
grep -q '"ring": "users/123/orders"' <<<"$stellar_subring"
if grep -q '"ring": "users/123/billing"' <<<"$stellar_subring"; then
  echo "subring read included billing" >&2
  exit 1
fi
stellar_named="$(bin/kouten get --stellar=users/123 --filter='{"kind":"order"}' --subring=orders --limit=10)"
grep -q '"ring": "users/123/orders"' <<<"$stellar_named"
grep -q '"orderNo": "A-001"' <<<"$stellar_named"
if grep -q '"ring": "users/123/billing"' <<<"$stellar_named"; then
  echo "stellar read included billing" >&2
  exit 1
fi
bin/kouten put --ring=orders --near=users/123 \
  --payload='{"kind":"order","orderNo":"A-002"}' --codec=json >/dev/null
bin/kouten put --ring=orders --near=users/123 \
  --payload='{"kind":"order","orderNo":"A-003"}' --codec=json >/dev/null
bin/kouten put --ring=billing --near=users/123 \
  --payload='{"kind":"billing","plan":"team"}' --codec=json >/dev/null
stellar_subring_limits="$(bin/kouten get --ring=users/123 \
  --subring=orders,billing --limit=10 \
  --subring-limit=orders:2,billing:1 --subring-sort=orders:id)"
grep -q '"orderNo": "A-001"' <<<"$stellar_subring_limits"
grep -q '"orderNo": "A-002"' <<<"$stellar_subring_limits"
if grep -q '"orderNo": "A-003"' <<<"$stellar_subring_limits"; then
  echo "subring limit included too many orders" >&2
  exit 1
fi
if grep -q '"plan": "pro"' <<<"$stellar_subring_limits" &&
   grep -q '"plan": "team"' <<<"$stellar_subring_limits"; then
  echo "subring limit included too many billing records" >&2
  exit 1
fi
bin/kouten put --ring=shops/1123 \
  --payload='{"kind":"shop","name":"Shop 1123"}' --codec=json >/dev/null
bin/kouten put --ring=orders/A-002 \
  --payload='{"kind":"order","orderNo":"A-002","userId":"123","shopId":"1123"}' --codec=json >/dev/null
bin/kouten stellar attach --stellar=commerce/order/A-002 --ring=users/123 |
  grep -q '"status": "attached"'
bin/kouten stellar attach --stellar=commerce/order/A-002 --ring=shops/1123 |
  grep -q '"status": "attached"'
bin/kouten stellar attach --stellar=commerce/order/A-002 --ring=orders/A-002 |
  grep -q '"status": "attached"'
stellar_attached="$(bin/kouten get --stellar=commerce/order/A-002 --filter='{"kind":"shop"}' --limit=10)"
grep -q '"ring": "shops/1123"' <<<"$stellar_attached"
bin/kouten stellar detach --stellar=commerce/order/A-002 --ring=shops/1123 |
  grep -q '"status": "detached"'
stellar_detached="$(bin/kouten get --stellar=commerce/order/A-002 --filter='{"kind":"shop"}' --limit=10)"
if grep -q '"ring": "shops/1123"' <<<"$stellar_detached"; then
  echo "detached stellar member remained visible" >&2
  exit 1
fi

echo "[cli-crud] explicit and profile-driven codecs"
printf '(object (title "NIF text"))' >"$WORK/payload.nif"
nif_out="$(bin/kouten put --ring=artifacts/nif \
  --in="$WORK/payload.nif" --codec=nif)"
nif_id="$(sed -n 's/.*rawId=\([^ ]*\).*/\1/p' <<<"$nif_out")"
bin/kouten get --ring=artifacts/nif --filter="{\"id\":\"$nif_id\"}" |
  grep -q '"codec": "nif"'
bin/kouten get --ring=artifacts/nif --filter="{\"id\":\"$nif_id\"}" |
  grep -q '"encoding": "text"'

bin/kouten ring-profile --ring=artifacts/auto-nif \
  --codec=nif --charset=UTF-8 --format-version=1 |
  grep -q '"defaultCodec": "nif"'
auto_nif_out="$(bin/kouten put --ring=artifacts/auto-nif \
  --payload='(object (title "Auto NIF"))' --codec=auto)"
auto_nif_id="$(sed -n 's/.*rawId=\([^ ]*\).*/\1/p' <<<"$auto_nif_out")"
bin/kouten get --ring=artifacts/auto-nif --filter="{\"id\":\"$auto_nif_id\"}" |
  grep -q '"codec": "nif"'

echo "[cli-crud] time orbit"
bin/kouten time-orbit --ring=logs/api --bucket-ms=1000 --bits=60 --phase=100 --salt=api |
  grep -q '"bucketMs": 1000'
bin/kouten time-put --ring=logs/api --time-ms=1200 \
  --payload='{"level":"info","message":"boot"}' >/dev/null
bin/kouten time-put --ring=logs/api --time-ms=2500 \
  --payload='{"level":"error","message":"timeout"}' >/dev/null
bin/kouten time-put --ring=logs/api --time-ms=4200 \
  --payload='{"level":"error","message":"too-late"}' >/dev/null
time_page="$(bin/kouten time-get --ring=logs/api --from-ms=1000 --to-ms=3000 \
  --filter='{"level":"error"}' --selection='{ level message eventTimeMs }' --limit=10 --sort=time)"
grep -q '"bucketsVisited": 3' <<<"$time_page"
grep -q '"logs/api/@time/102"' <<<"$time_page"
grep -q '"message": "timeout"' <<<"$time_page"
if grep -q 'too-late' <<<"$time_page"; then
  echo "time-get included an out-of-range event" >&2
  exit 1
fi

raw_out="$(bin/kouten put --ring=logs/raw --payload='plain text payload' --codec=raw)"
raw_text_id="$(sed -n 's/.*rawId=\([^ ]*\).*/\1/p' <<<"$raw_out")"
bin/kouten get --ring=logs/raw --filter="{\"id\":\"$raw_text_id\"}" |
  grep -q '"codec": "raw"'

echo "[cli-crud] binary codec display"
printf '\001\002\003\004' >"$WORK/payload.bif"
bif_out="$(bin/kouten put --ring=artifacts/bif \
  --in="$WORK/payload.bif" --codec=bif)"
bif_id="$(sed -n 's/.*rawId=\([^ ]*\).*/\1/p' <<<"$bif_out")"
bin/kouten get --ring=artifacts/bif --filter="{\"id\":\"$bif_id\"}" |
  grep -q '"codec": "bif"'
bin/kouten get --ring=artifacts/bif --filter="{\"id\":\"$bif_id\"}" |
  grep -q '"encoding": "base64"'
bin/kouten get --ring=artifacts/bif --filter="{\"id\":\"$bif_id\"}" --view=hex |
  grep -q '"encoding": "hex"'
cat >"$WORK/fake_nif_tool" <<'TOOL'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "decode" ]]; then
  exit 2
fi
out=""
for arg in "$@"; do
  case "$arg" in
    --out=*) out="${arg#--out=}" ;;
  esac
done
if [[ -z "$out" ]]; then
  exit 2
fi
printf '(decoded "from adapter")' >"$out"
TOOL
chmod +x "$WORK/fake_nif_tool"
KOUTENDB_NIF_TOOL="$WORK/fake_nif_tool" \
  bin/kouten get --ring=artifacts/bif --filter="{\"id\":\"$bif_id\"}" |
  grep -q '"encoding": "nif"'
KOUTENDB_NIF_TOOL="$WORK/fake_nif_tool" \
  bin/kouten get --ring=artifacts/bif --filter="{\"id\":\"$bif_id\"}" |
  grep -q '"adapter": "nif"'
KOUTENDB_NIF_TOOL="$WORK/fake_nif_tool" \
  bin/kouten get --ring=artifacts/bif --filter="{\"id\":\"$bif_id\"}" |
  grep -q 'decoded'

echo "[cli-crud] read validation"
bad_filter_out="$(bin/kouten get --ring=docs/japan --filter='[]' 2>&1 >/dev/null || true)"
grep -q 'filter must be a JSON object' <<<"$bad_filter_out"
bad_sort_out="$(bin/kouten get --ring=docs/japan --sort=payload 2>&1 >/dev/null || true)"
grep -q 'sort field must be id, time, or write' <<<"$bad_sort_out"
bad_selection_out="$(bin/kouten get --ring=artifacts/bif --selection='{ title }' 2>&1 >/dev/null || true)"
grep -q 'payload codec bif does not support JSON projection' <<<"$bad_selection_out"

echo "[cli-crud] dump/import JSONL roundtrip"
bin/kouten dump --data="$KOUTEN_DATA" --out="$WORK/koutendb-dump.jsonl" |
  grep -q "dump OK"
bin/kouten import-jsonl --data="$WORK/imported" --in="$WORK/koutendb-dump.jsonl" |
  grep -q "import-jsonl OK"
bin/kouten get --data="$WORK/imported" --ring=docs/japan --limit=1 |
  grep -q '"status": "draft"'
bin/kouten get --data="$WORK/imported" --ring=artifacts/nif --limit=1 |
  grep -q '"codec": "nif"'
bin/kouten get --data="$WORK/imported" --ring=artifacts/bif --limit=1 |
  grep -q '"codec": "bif"'

echo "[cli-crud] operational verify"
for i in $(seq 1 16); do
  bin/kouten put --ring=ops/packed \
    --payload="{\"i\":$i}" --codec=json >/dev/null
done
bin/kouten pack-ring --data="$KOUTEN_DATA" --ring=ops/packed |
  grep -q "pack-ring OK"
bin/kouten segment-status --data="$KOUTEN_DATA" --json |
  grep -q '"recommendedRings"'
bin/kouten segment-status --data="$KOUTEN_DATA" --metrics |
  grep -q '^segmentTotalBytes '
bin/kouten segment-status --data="$KOUTEN_DATA" --metrics |
  grep -q '^segmentWalFallbacks '
if bin/kouten segment-status --data="$KOUTEN_DATA" --stale-ratio=-0.01 >/dev/null 2>&1; then
  echo "segment-status accepted a negative stale ratio" >&2
  exit 1
fi
if bin/kouten segment-status --data="$KOUTEN_DATA" --min-stale-records=-1 >/dev/null 2>&1; then
  echo "segment-status accepted negative stale records" >&2
  exit 1
fi
if bin/kouten pack-recommended --data="$KOUTEN_DATA" --max-rings=-1 >/dev/null 2>&1; then
  echo "pack-recommended accepted a negative ring limit" >&2
  exit 1
fi
bin/kouten pack-recommended --data="$KOUTEN_DATA" \
  --min-stale-records=1 --stale-ratio=1.0 |
  grep -q "pack-recommended OK"
bin/kouten maintenance-plan --data="$KOUTEN_DATA" --json |
  grep -q '"outcome"'
bin/kouten maintenance-run --data="$KOUTEN_DATA" --json |
  grep -q '"schema": "koutendb.segment-maintenance.v1"'
bin/kouten maintenance-status --data="$KOUTEN_DATA" --json |
  grep -q '"outcome": "no-work"'
if bin/kouten maintenance-run --data="$KOUTEN_DATA" \
    --max-bytes=-1 >/dev/null 2>&1; then
  echo "maintenance-run accepted a negative byte budget" >&2
  exit 1
fi
bin/kouten get --ring=ops/packed --limit=16 |
  grep -q '"i": 16'
bin/kouten verify --data="$KOUTEN_DATA" |
  grep -q "verify status: ok"
bin/kouten verify --data="$KOUTEN_DATA" --metrics |
  grep -q "verifyOk 1"
bin/kouten verify --data="$KOUTEN_DATA" --json |
  grep -q '"kind": "data"'
if bin/kouten verify --data="$KOUTEN_DATA" --max-segment-generation=0 >/dev/null 2>&1; then
  echo "verify accepted a segment generation above configured limit" >&2
  exit 1
fi
bin/kouten verify --data="$KOUTEN_DATA" --segments |
  grep -q "ok   segments:"
if bin/kouten verify --data="$KOUTEN_DATA" --max-wal-bytes=1 >/dev/null 2>&1; then
  echo "verify accepted WAL bytes above configured limit" >&2
  exit 1
fi
if bin/kouten verify --data="$KOUTEN_DATA" --max-items=1 >/dev/null 2>&1; then
  echo "verify accepted items above configured limit" >&2
  exit 1
fi
if bin/kouten verify --data="$KOUTEN_DATA" --max-rings=1 >/dev/null 2>&1; then
  echo "verify accepted rings above configured limit" >&2
  exit 1
fi
if bin/kouten verify --data="$KOUTEN_DATA" --segments --max-segment-files=0 >/dev/null 2>&1; then
  echo "verify accepted segment files above configured limit" >&2
  exit 1
fi
if bin/kouten verify --data="$KOUTEN_DATA" --max-segment-bytes=1 >/dev/null 2>&1; then
  echo "verify accepted segment bytes above configured limit" >&2
  exit 1
fi
if bin/kouten verify --data="$KOUTEN_DATA" --max-dead-ratio=1.01 >/dev/null 2>&1; then
  echo "verify accepted an invalid dead-record ratio" >&2
  exit 1
fi
bin/kouten backup --data="$KOUTEN_DATA" --backup="$WORK/verify-backup" >/dev/null
bin/kouten verify --backup="$WORK/verify-backup" |
  grep -q "verify status: ok"
bin/kouten verify --backup="$WORK/verify-backup" --metrics |
  grep -q "verifyBackup 1"
bin/kouten verify --backup="$WORK/verify-backup" --json |
  grep -q '"kind": "backup"'
echo "[cli-crud] encrypted backup secret sources"
printf ' backup-secret with spaces \n' > "$WORK/backup-passphrase"
bin/kouten backup-encrypted --data="$KOUTEN_DATA" \
  --backup="$WORK/encrypted-backup" \
  --passphrase-file="$WORK/backup-passphrase" >/dev/null
grep -a -q '^KOUTENDB-BACKUP-ARGON2ID-V2$' \
  "$WORK/encrypted-backup/kouten.backup"
KOUTEN_BACKUP_PASSPHRASE=' backup-secret with spaces ' \
  bin/kouten verify --backup="$WORK/encrypted-backup" |
  grep -q "verify status: ok"
bin/kouten restore-encrypted --backup="$WORK/encrypted-backup" \
  --data="$WORK/encrypted-restored" \
  --passphrase-file="$WORK/backup-passphrase" >/dev/null
bin/kouten get --data="$WORK/encrypted-restored" --ring=docs/japan --limit=1 |
  grep -q '"status": "draft"'
bin/kouten doctor --data="$KOUTEN_DATA" |
  grep -q "verify status: ok"
printf 'right\n' > "$WORK/server-password"
printf 'secret\n' > "$WORK/server-secret"
cat >"$WORK/server-config.json" <<CONFIG
{
  "id": 0,
  "peers": ["127.0.0.1:${BASE_PORT}"],
  "dataDir": "$KOUTEN_DATA",
  "durability": "buffered",
  "user": "app",
  "passwordFile": "$WORK/server-password",
  "secretKeyFile": "$WORK/server-secret",
  "allowRing": ["docs", "cluster"],
  "roles": [
    {
      "user": "reader",
      "passwordFile": "$WORK/server-password",
      "role": "reader",
      "prefixes": ["docs"]
    }
  ]
}
CONFIG
bin/kouten verify --server-config="$WORK/server-config.json" |
  grep -q "server-config:"
bin/kouten verify --server-config="$WORK/server-config.json" --metrics |
  grep -q "verifyOk 1"
bin/kouten doctor --server-config="$WORK/server-config.json" --json |
  grep -q '"kind": "server-config"'
cat >"$WORK/bad-server-config.json" <<CONFIG
{
  "id": 4,
  "peers": ["127.0.0.1:${BASE_PORT}"],
  "secretKey": "secret",
  "tlsInsecureSkipVerify": true
}
CONFIG
if bin/kouten verify --server-config="$WORK/bad-server-config.json" >/dev/null 2>&1; then
  echo "verify accepted bad server config" >&2
  exit 1
fi
cat >"$WORK/bad-placement-config.json" <<CONFIG
{
  "id": 0,
  "peers": ["127.0.0.1:${BASE_PORT}"],
  "dataDir": "$KOUTEN_DATA",
  "placementEpoch": 0,
  "virtualArcsPerNode": 64
}
CONFIG
if bin/kouten verify --server-config="$WORK/bad-placement-config.json" >/dev/null 2>&1; then
  echo "verify accepted a non-positive placement epoch" >&2
  exit 1
fi

echo "[cli-crud] shell"
shell_out="$(bin/kouten shell --data="$WORK/shell" <<'SHELL'
put docs/japan {"title":"Shell","status":"ok"}
count docs/japan
list docs/japan
atlas
exit
SHELL
)"
grep -q "KoutenDB shell" <<<"$shell_out"
grep -q "put OK" <<<"$shell_out"
grep -q "count=1" <<<"$shell_out"
grep -q '"title":"Shell"' <<<"$shell_out"
grep -q '"schema": "koutendb.atlas.v1"' <<<"$shell_out"

echo "[cli-crud] auth error is user-facing"
src/koutend --id=0 --peers="127.0.0.1:${BASE_PORT}" \
  --data="$WORK/auth-server" --user=app --password=right \
  --secret-key=secret --slow-tick=0.05 >"$WORK/auth-server.log" 2>&1 &
PIDS+=("$!")
for _ in $(seq 1 50); do
  if bin/kouten health --peers="127.0.0.1:${BASE_PORT}" \
      --user=app --password=right --secret-key=secret >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

echo "[cli-crud] cluster connection config"
cat >"$WORK/cluster-config.json" <<CONFIG
{
  "peers": ["127.0.0.1:${BASE_PORT}"],
  "user": "app",
  "password": "right",
  "secret-key": "secret",
  "galaxy": "",
  "tls": false
}
CONFIG
bin/kouten health --config="$WORK/cluster-config.json" |
  grep -q "node=0"
KOUTEN_CONFIG="$WORK/cluster-config.json" bin/kouten health |
  grep -q "node=0"
config_put="$(bin/kouten put --config="$WORK/cluster-config.json" \
  --ring=cluster/config-demo --payload='{"kind":"config"}' --codec=json)"
config_raw_id="$(sed -n 's/.*rawId=\([^ ]*\).*/\1/p' <<<"$config_put")"
bin/kouten get --config="$WORK/cluster-config.json" \
  --ring=cluster/config-demo --filter="{\"id\":\"$config_raw_id\"}" |
  grep -q '"kind": "config"'
KOUTEN_CONFIG="$WORK/cluster-config.json" bin/kouten get \
  --ring=cluster/config-demo --filter="{\"id\":\"$config_raw_id\"}" |
  grep -q '"kind": "config"'

auth_out="$(bin/kouten health --peers="127.0.0.1:${BASE_PORT}" \
  --user=app --password=wrong --secret-key=secret 2>&1 >/dev/null || true)"
grep -q '^error: AUTHRESP failed: ERR auth-required$' <<<"$auth_out"
unknown_auth_out="$(bin/kouten health --peers="127.0.0.1:${BASE_PORT}" \
  --user=unknown --password=wrong --secret-key=secret 2>&1 >/dev/null || true)"
grep -q '^error: AUTHRESP failed: ERR auth-required$' <<<"$unknown_auth_out"

echo "[cli-crud] OK"
