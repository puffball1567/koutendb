---
layout: page
title: Data Migration
---

# Data Migration

KoutenDB's internal WAL and snapshot files are implementation details before
v1.0. They are hardened for recovery, but they are not the recommended
cross-version interchange format.

Use JSON Lines dump/import as the portable migration boundary:

```bash
kouten dump --data=./source-db --out=./koutendb-dump.jsonl
kouten import-jsonl --data=./target-db --in=./koutendb-dump.jsonl
```

For larger imports, use chunked commits:

```bash
kouten import-jsonl --data=./target-db --in=./koutendb-dump.jsonl --batch-size=10000
```

`--batch-size` controls how many successfully parsed records are committed per
WAL transaction. Larger batches reduce flush overhead during bulk load. Smaller
batches reduce the amount of work retried after a failed chunk.

This path is intended for:

- cross-version migration while the internal WAL format can still evolve;
- human-readable inspection and audit exports;
- moving data between local environments;
- importing MongoDB-like or document-store JSONL exports with ring routing.

## KoutenDB Dump Format

`kouten dump` writes `koutendb.dump.v1` JSONL. The file contains:

| Line type | Meaning |
|---|---|
| `meta` | Dump metadata such as format, galaxy, epoch, node count, document count, and ring count. |
| `ring` | Ring metadata such as key, name, period, and head angle. |
| `document` | A stored payload with ring, payload bytes as a JSON string, optional vector, and payload codec. |

Example document line:

```json
{"type":"document","ring":"docs/json","payload":"{\"title\":\"Hello\"}","codec":"json","vec":[1.0,0.0]}
```

`kouten import-jsonl` recognizes this dump shape. It skips `meta` and `ring`
lines, then imports `document` lines into their original ring with payload,
vector, and codec metadata preserved. KoutenDB IDs are reissued in the target
store; applications should not treat dump/import as an ID-preserving binary
clone.

The migration boundary is exercised by `scripts/upgrade_fixture_matrix.sh`.
It opens stores produced by the tagged v0.10.1 and v0.11.0 releases, exports
them with the current version, imports the JSONL into fresh stores, and compares
the portable logical records including ring, payload, codec, and vector data.
The same matrix separately verifies exact checkpoint restore behavior.

## External JSONL Imports

For external document stores, provide routing fields:

```bash
kouten import-jsonl \
  --data=./target-db \
  --in=./mongo-export.jsonl \
  --ring-field=tenant \
  --ring-prefix=tenant/ \
  --payload-field=body \
  --vec-field=embedding \
  --batch-size=10000
```

If `ring-field` is missing or empty for a row, KoutenDB uses `--default-ring`.
Blank rows are skipped. Malformed JSON rows are counted as errors without
stopping the whole import.

## Backup Is Different

Use backup/restore for operational recovery:

```bash
kouten backup --data=./source-db --backup=./backup
kouten restore --backup=./backup --data=./restored-db
```

Backup/restore preserves the internal store more directly and is meant for
same-version recovery. Dump/import is the safer public boundary when the goal is
portability, reviewability, or release-to-release migration.
