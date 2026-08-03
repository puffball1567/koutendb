#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TMP="${TMPDIR:-/tmp}/kouten-recovery-smoke-$$"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/src" "$TMP/plain-a" "$TMP/plain-b" "$TMP/plain-c" \
  "$TMP/plain-d" "$TMP/encrypted" "$TMP/readonly"

nim c -d:release --nimcache:/tmp/nimcache_koutencli_recovery -o:bin/koutencli src/koutencli.nim >/dev/null

cat > "$TMP/src/kouten.log" <<'LOG'
G 15
recovery-smoke
N 1 8
docs/ops
R 1 60.0 0.0
P 1 0 60.0 0.0 1.0 5 0
hello
P 1 1 60.0 0.0 2.0 7 0
deleted
L 1 1 60.0 0.0 2.0 3000000 0 1
LOG

cat > "$TMP/universe.json" <<JSON
{
  "version": 1,
  "requiredHealthy": 2,
  "authProfiles": {
    "shared-recovery": {
      "mode": "user-password-secret-key",
      "source": "secret-manager:kouten/shared-recovery"
    }
  },
  "universes": [
    {
      "universe": "tokyo-a",
      "location": "local",
      "failureDomain": "local-a",
      "authRef": "shared-recovery",
      "priority": 10,
      "snapshotSeq": 42,
      "galaxies": [
        {
          "galaxy": "recovery-smoke",
          "archive": "$TMP/plain-a"
        }
      ]
    },
    {
      "universe": "oregon-a",
      "location": "remote",
      "endpoint": "kouten://oregon-a.invalid:7301",
      "failureDomain": "local-b",
      "authRef": "shared-recovery",
      "priority": 5,
      "snapshotSeq": 41,
      "galaxies": [
        {
          "galaxy": "recovery-smoke",
          "archive": "$TMP/plain-b"
        }
      ]
    }
  ]
}
JSON

cat > "$TMP/universe-mismatch.json" <<JSON
{
  "version": 1,
  "universes": [
    {
      "universe": "tokyo-a",
      "location": "local",
      "galaxies": [
        {
          "galaxy": "recovery-smoke",
          "archive": "$TMP/plain-a"
        }
      ]
    },
    {
      "universe": "oregon-a",
      "location": "remote",
      "endpoint": "kouten://oregon-a.invalid:7301",
      "galaxies": [
        {
          "galaxy": "other-galaxy",
          "archive": "$TMP/plain-b"
        }
      ]
    }
  ]
}
JSON

cat > "$TMP/universe-bad-authref.json" <<JSON
{
  "version": 1,
  "authProfiles": {
    "shared-recovery": {
      "mode": "user-password-secret-key",
      "source": "secret-manager:kouten/shared-recovery"
    }
  },
  "universes": [
    {
      "universe": "tokyo-a",
      "location": "local",
      "authRef": "missing-profile",
      "galaxies": [
        {
          "galaxy": "recovery-smoke",
          "archive": "$TMP/plain-a"
        }
      ]
    }
  ]
}
JSON

cat > "$TMP/universe-weak-authmode.json" <<JSON
{
  "version": 1,
  "authProfiles": {
    "weak": {
      "mode": "user-password",
      "source": "secret-manager:kouten/weak"
    }
  },
  "universes": [
    {
      "universe": "tokyo-a",
      "location": "local",
      "authRef": "weak",
      "galaxies": [
        {
          "galaxy": "recovery-smoke",
          "archive": "$TMP/plain-a"
        }
      ]
    }
  ]
}
JSON

cat > "$TMP/universe-shared-endpoint.json" <<JSON
{
  "version": 1,
  "requiredHealthy": 4,
  "universes": [
    {
      "universe": "tokyo-a",
      "location": "remote",
      "endpoint": "kouten://shared.invalid:7301",
      "galaxies": [
        {
          "galaxy": "recovery-smoke",
          "archive": "$TMP/plain-a"
        },
        {
          "galaxy": "analytics-smoke",
          "archive": "$TMP/plain-c"
        }
      ]
    },
    {
      "universe": "oregon-a",
      "location": "remote",
      "endpoint": "kouten://shared.invalid:7301",
      "galaxies": [
        {
          "galaxy": "recovery-smoke",
          "archive": "$TMP/plain-b"
        },
        {
          "galaxy": "analytics-smoke",
          "archive": "$TMP/plain-d"
        }
      ]
    }
  ]
}
JSON

cat > "$TMP/universe-duplicate-galaxy.json" <<JSON
{
  "version": 1,
  "universes": [
    {
      "universe": "tokyo-a",
      "location": "local",
      "galaxies": [
        {
          "galaxy": "recovery-smoke",
          "archive": "$TMP/plain-a"
        },
        {
          "galaxy": "recovery-smoke",
          "archive": "$TMP/plain-c"
        }
      ]
    }
  ]
}
JSON

echo "[recovery-smoke] plain mirrors"
bin/koutencli recovery-backup \
  --data="$TMP/src" \
  --universe-config="$TMP/universe.json" >/dev/null

plain_metrics="$(bin/koutencli recovery-verify --mirror="$TMP/plain-a" --metrics)"
echo "$plain_metrics"
grep -q "recoveryMirrorHealthy 1" <<<"$plain_metrics"
grep -q "recoveryMirrorEncrypted 0" <<<"$plain_metrics"
grep -q "recoveryMirrorReadonly 0" <<<"$plain_metrics"
grep -q "recoveryMirrorItems 1" <<<"$plain_metrics"
grep -q "recoveryMirrorTombstones 1" <<<"$plain_metrics"
grep -q "recoveryMirrorRings 1" <<<"$plain_metrics"
grep -q "recoveryMirrorPriority 10" <<<"$plain_metrics"
grep -q "recoveryMirrorSnapshotSeq 42" <<<"$plain_metrics"
grep -q '"universe": "tokyo-a"' "$TMP/plain-a/kouten.recovery.json"
grep -q '"galaxy": "recovery-smoke"' "$TMP/plain-a/kouten.recovery.json"
grep -q '"location": "local"' "$TMP/plain-a/kouten.recovery.json"
grep -q '"authRef": "shared-recovery"' "$TMP/plain-a/kouten.recovery.json"
grep -q '"readonly": false' "$TMP/plain-a/kouten.recovery.json"
grep -q '"tombstones": 1' "$TMP/plain-a/kouten.recovery.json"
grep -q '"archive": "'"$TMP"'/plain-a"' "$TMP/plain-a/kouten.recovery.json"

bin/koutencli recovery-verify --mirror="$TMP/plain-b" >/dev/null

status_metrics="$(bin/koutencli recovery-status \
  --universe-config="$TMP/universe.json" \
  --metrics)"
echo "$status_metrics"
grep -q "recoveryUniverseHealthy 1" <<<"$status_metrics"
grep -q "recoveryHealthyUniverses 2" <<<"$status_metrics"
grep -q "recoveryRequiredHealthyUniverses 2" <<<"$status_metrics"
grep -q "recoveryBestPriority 10" <<<"$status_metrics"
grep -q "recoveryBestSnapshotSeq 42" <<<"$status_metrics"

echo "[recovery-smoke] restore selects eligible mirror"
mkdir -p "$TMP/restore"
bin/koutencli recovery-restore \
  --universe-config="$TMP/universe.json" \
  --data="$TMP/restore" >/dev/null
grep -q "hello" "$TMP/restore/kouten.log"

echo "[recovery-smoke] encrypted mirror"
bin/koutencli recovery-backup \
  --data="$TMP/src" \
  --mirror="$TMP/encrypted" \
  --passphrase=recovery-passphrase >/dev/null

encrypted_metrics="$(bin/koutencli recovery-verify \
  --mirror="$TMP/encrypted" \
  --passphrase=recovery-passphrase \
  --metrics)"
echo "$encrypted_metrics"
grep -q "recoveryMirrorHealthy 1" <<<"$encrypted_metrics"
grep -q "recoveryMirrorEncrypted 1" <<<"$encrypted_metrics"
grep -q "recoveryMirrorReadonly 0" <<<"$encrypted_metrics"

echo "[recovery-smoke] readonly mirror is not written"
readonly_out="$(bin/koutencli recovery-backup \
  --data="$TMP/src" \
  --mirror="$TMP/readonly" \
  --readonly)"
echo "$readonly_out"
grep -q "recovery-backup SKIP" <<<"$readonly_out"
if [ -f "$TMP/readonly/kouten.recovery.json" ]; then
  echo "recovery-backup unexpectedly wrote readonly mirror" >&2
  exit 1
fi

echo "[recovery-smoke] shared endpoint with multiple galaxies is allowed"
bin/koutencli recovery-backup \
  --data="$TMP/src" \
  --universe-config="$TMP/universe-shared-endpoint.json" >/dev/null
shared_endpoint_metrics="$(bin/koutencli recovery-status \
  --universe-config="$TMP/universe-shared-endpoint.json" \
  --metrics)"
echo "$shared_endpoint_metrics"
grep -q "recoveryUniverseHealthy 1" <<<"$shared_endpoint_metrics"
grep -q "recoveryHealthyUniverses 4" <<<"$shared_endpoint_metrics"

echo "[recovery-smoke] manifest mismatch fails closed"
perl -0pi -e 's/"items": 1/"items": 2/' "$TMP/plain-a/kouten.recovery.json"
if bin/koutencli recovery-verify --mirror="$TMP/plain-a" >/dev/null 2>&1; then
  echo "recovery-verify unexpectedly accepted mismatched manifest" >&2
  exit 1
fi
if bin/koutencli recovery-status \
  --universe-config="$TMP/universe.json" >/dev/null 2>&1; then
  echo "recovery-status unexpectedly accepted too few healthy mirrors" >&2
  exit 1
fi
bin/koutencli recovery-status \
  --universe-config="$TMP/universe.json" \
  --required-healthy=1 >/dev/null

echo "[recovery-smoke] tombstone manifest mismatch fails closed"
perl -0pi -e 's/"items": 2/"items": 1/; s/"tombstones": 1/"tombstones": 2/' \
  "$TMP/plain-a/kouten.recovery.json"
if bin/koutencli recovery-verify --mirror="$TMP/plain-a" >/dev/null 2>&1; then
  echo "recovery-verify unexpectedly accepted mismatched tombstone count" >&2
  exit 1
fi
perl -0pi -e 's/"tombstones": 2/"tombstones": 1/' \
  "$TMP/plain-a/kouten.recovery.json"

echo "[recovery-smoke] universe galaxy mismatch fails closed"
if bin/koutencli recovery-status \
  --universe-config="$TMP/universe-mismatch.json" >/dev/null 2>&1; then
  echo "recovery-status unexpectedly accepted mismatched universe galaxies" >&2
  exit 1
fi

echo "[recovery-smoke] universe authRef mismatch fails closed"
if bin/koutencli recovery-status \
  --universe-config="$TMP/universe-bad-authref.json" >/dev/null 2>&1; then
  echo "recovery-status unexpectedly accepted undeclared authRef" >&2
  exit 1
fi

echo "[recovery-smoke] weak auth profile mode fails closed"
if bin/koutencli recovery-status \
  --universe-config="$TMP/universe-weak-authmode.json" >/dev/null 2>&1; then
  echo "recovery-status unexpectedly accepted weak auth profile mode" >&2
  exit 1
fi

echo "[recovery-smoke] duplicate galaxy in one universe fails closed"
if bin/koutencli recovery-status \
  --universe-config="$TMP/universe-duplicate-galaxy.json" >/dev/null 2>&1; then
  echo "recovery-status unexpectedly accepted duplicate galaxy in one universe" >&2
  exit 1
fi

echo "[recovery-smoke] checksum mismatch fails closed"
printf 'x' >> "$TMP/plain-b/kouten.log"
if bin/koutencli recovery-verify --mirror="$TMP/plain-b" >/dev/null 2>&1; then
  echo "recovery-verify unexpectedly accepted mismatched checksum" >&2
  exit 1
fi

echo "[recovery-smoke] OK"
