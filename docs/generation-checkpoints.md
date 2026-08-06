---
layout: page
title: Generation Checkpoints
---

# Generation Checkpoints

KoutenDB generation checkpoints preserve one immutable, self-contained storage
generation. A checkpoint binds a compact WAL to the complete ring-local segment
and index files derived from that WAL. It is intended for selected-generation
recovery, backup orchestration, upgrade rehearsal, and reproducible operational
verification.

This is distinct from the other storage and cluster mechanisms:

- `backup` creates a compact WAL recovery copy;
- the cluster `SNAPSHOT` command flushes a drained node and reports a quiet
  high-water state;
- a generation checkpoint seals the WAL and its ring-local read layout together
  and verifies the complete set before publication.

## Create And Verify

```sh
kouten checkpoint-create --data=/var/lib/kouten --json
```

The default checkpoint root is the source data-directory sibling
`/var/lib/kouten.checkpoints`. Use an explicit root or identity when an
orchestrator needs deterministic paths:

```sh
kouten checkpoint-create \
  --data=/var/lib/kouten \
  --checkpoint-root=/backup/kouten-generations \
  --checkpoint-id=before-upgrade-2026-08-05 \
  --durability=strong \
  --json

kouten checkpoint-status \
  --checkpoint=/backup/kouten-generations/before-upgrade-2026-08-05 \
  --json

kouten checkpoint-verify \
  --checkpoint=/backup/kouten-generations/before-upgrade-2026-08-05 \
  --json
```

`checkpoint-status` reports `verified=false` and a reason for an invalid
artifact. `checkpoint-verify` is the fail-fast form for scripts and exits
non-zero on verification failure.

The checkpoint root must not overlap the live data directory. Checkpoint IDs
accept ASCII letters, digits, `.`, `_`, and `-`, are limited to 128 bytes, and
must not start with `.tmp-`.

## Publication And Integrity

Creation performs these steps:

1. Flush the live persistent store and record its WAL high-water mark.
2. Write a fresh compact WAL into a staging directory.
3. Build complete ring-local segment/index generations from that WAL.
4. Inventory every restore file with byte size and a memory-bounded BLAKE2b
   chain checksum.
5. Write `checkpoint.json`, then write `checkpoint.complete` containing the
   manifest checksum.
6. Verify the staged checkpoint and atomically rename its directory into the
   checkpoint root.

Verification rejects incomplete markers, manifest changes, missing or extra
segment files, size/checksum changes, unsafe paths, symlinks, strict WAL replay
failures, logical-count drift, and segment/index records that do not match the
WAL generation.

The checksum inventory detects accidental corruption and incomplete copies. It
is not a keyed MAC, digital signature, or source-authentication mechanism; an
attacker who can replace the files can also replace the manifest. Encrypt and
authenticate checkpoint transport or storage when artifacts cross a trust
boundary. KoutenDB's encrypted backup remains available when a single encrypted
WAL artifact is the better operational boundary.

## List And Retain

```sh
kouten checkpoint-list \
  --checkpoint-root=/backup/kouten-generations \
  --json

kouten checkpoint-clean \
  --checkpoint-root=/backup/kouten-generations \
  --keep=3 \
  --json
```

Listings are newest first and include both verified and invalid checkpoint
directories. In-progress `.tmp-*` directories are ignored. Cleanup removes only
older verified generations, requires `--keep` of at least one, and preserves
invalid generations for diagnosis. It therefore never deletes the final
verified generation automatically.

## Restore

```sh
kouten checkpoint-restore \
  --checkpoint=/backup/kouten-generations/before-upgrade-2026-08-05 \
  --data=/var/lib/kouten-restored \
  --json
```

Use `--overwrite` only when replacing an existing inactive data directory.
Restore first verifies the source, copies every referenced file into a sibling
staging directory, verifies the staged copy, and then atomically replaces the
whole target directory. If publication or published-copy verification fails,
KoutenDB restores the previous target directory. Live processes must be
stopped before an overwrite. The data-directory lock rejects an active target
in the same process or another process. A stable sibling guard remains held
across staged verification, atomic publication, and rollback, so replacing
the directory cannot create an unlocked window.

On Linux, replacement of an existing directory uses
`renameat2(RENAME_EXCHANGE)`, so the target path changes from the previous
generation to the restored generation in one namespace operation. Tests force
failures both immediately after that exchange and after publication validation,
and verify that the previous generation is restored. Platforms without an
equivalent atomic directory exchange fail closed for existing-directory
overwrite; restore to a new path remains supported.

Persistent stores also use the sibling guard file
`DATA_DIR.kouten-dir.lock`. Its contents are not data and it is not part of a
checkpoint, but the file path must not be removed or replaced while a process
has the data directory open.

Restore publishes storage files; it does not persist a runtime open mode.
Choose buffered or strong durability and in-memory or disk-backed reads when
the restored directory is opened by the application or server.

The restored data directory does not keep `checkpoint.json` or
`checkpoint.complete`. Those files describe the immutable source artifact, not
the active mutable store.

## Nim API

```nim
import koutendb

var db = koutendb.open(dataDir = "/var/lib/kouten", diskBacked = true)
let created = db.createCheckpoint(
  root = "/backup/kouten-generations",
  id = "before-upgrade-2026-08-05")
db.close()

discard verifyCheckpoint(created.path)
let available = listCheckpoints("/backup/kouten-generations")
discard cleanupCheckpoints("/backup/kouten-generations", keep = 3)
discard restoreCheckpoint(created.path, "/var/lib/kouten-restored",
                          overwrite = false)
```

Creation requires an embedded persistent handle. Status, verification, listing,
cleanup, and restore are path-based APIs.

## C ABI

The additive ABI v2 functions return length-delimited JSON:

```c
void *kouten_checkpoint_create_json(void *db, const char *root,
                                    const char *checkpoint_id,
                                    size_t *out_len);
void *kouten_checkpoint_status_json(const char *checkpoint_dir,
                                    size_t *out_len);
void *kouten_checkpoint_list_json(const char *root, size_t *out_len);
void *kouten_checkpoint_cleanup_json(const char *root, int keep,
                                     size_t *out_len);
void *kouten_checkpoint_restore_json(const char *checkpoint_dir,
                                     const char *data_dir, int overwrite,
                                     size_t *out_len);
```

Release every non-null JSON buffer with `kouten_free`. Read
`kouten_last_error()` after a null result.

## Scope

Generation checkpoints do not provide continuous point-in-time recovery,
cross-node consensus, remote object-store upload, retention scheduling, or key
management. They provide the complete, verifiable generation primitive that an
operator or managed-service control plane can schedule, copy, retain, and
promote.
