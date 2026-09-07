#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEADER="${KOUTENDB_CAPI_HEADER:-$ROOT/include/koutendb.h}"
LIBRARY="${KOUTENDB_CAPI_LIBRARY:-$ROOT/lib/libkoutendb.so}"

if [[ ! -f "$HEADER" ]]; then
  echo "C ABI header not found: $HEADER" >&2
  exit 1
fi
if [[ ! -f "$LIBRARY" ]]; then
  echo "C ABI library not found: $LIBRARY" >&2
  exit 1
fi

declared="$(mktemp)"
exported="$(mktemp)"
trap 'rm -f "$declared" "$exported"' EXIT

perl -0777 -ne '
  while (/\b(kouten_[a-z0-9_]+)\s*\([^;{}]*\)\s*;/sg) {
    print "$1\n";
  }
' "$HEADER" | sort -u > "$declared"

case "$(uname -s)" in
  Darwin)
    nm -gU "$LIBRARY" | awk '{print $NF}' | sed 's/^_//' |
      grep '^kouten_' | sort -u > "$exported"
    ;;
  Linux)
    nm -D --defined-only "$LIBRARY" | awk '{print $NF}' |
      grep '^kouten_' | sort -u > "$exported"
    ;;
  *)
    echo "unsupported platform for C ABI symbol inspection: $(uname -s)" >&2
    exit 1
    ;;
esac

missing="$(comm -23 "$declared" "$exported")"
undeclared="$(comm -13 "$declared" "$exported")"
if [[ -n "$missing" || -n "$undeclared" ]]; then
  if [[ -n "$missing" ]]; then
    echo "declared C ABI functions missing from the shared library:" >&2
    echo "$missing" >&2
  fi
  if [[ -n "$undeclared" ]]; then
    echo "exported C ABI functions missing from the header:" >&2
    echo "$undeclared" >&2
  fi
  exit 1
fi

echo "C ABI symbol contract OK ($(wc -l < "$declared") functions)"
