# Audit Remediation Tracker

This document tracks KoutenDB's response to the 2026-07-16 external audit notes.
It is an engineering tracker, not a production-readiness claim. The source audit
document lives outside this repository; this file records what the current code
base has implemented, what remains open, and which items need an explicit
product decision.

## Status Legend

| Status | Meaning |
|---|---|
| Done | Implemented, documented where relevant, and covered by tests or smoke checks. |
| Partial | Some risk is reduced, but the audit item is not fully closed. |
| Decision | A direct patch would change KoutenDB's model; decide the intended behavior first. |
| Planned | Accepted as future work, not implemented in this branch. |
| Not aligned | Intentionally not adopted because it conflicts with KoutenDB's concept or current scope. |

## Primary Findings

| ID | Audit concern | Current status | Evidence / next action |
|---|---|---|---|
| R1 | `compact()` could replace the only good WAL with an unsynced snapshot under default durability. | Done | Snapshot writes now fsync before atomic replace; compact uses temp files, atomic rename, and directory sync. Covered by `tests/tstore.nim` compact interruption and strong compact tests. |
| R2 | Mid-file WAL corruption was repaired by truncating the file silently. | Done | Replay now refuses invalid records before EOF and only repairs torn tail records. Covered by `WAL 中間破損は tail repair せず起動を拒否する`. |
| R3 | `restoreBackup` / encrypted restore were not durable and had non-atomic overwrite windows. | Done | Restore writes through temp files, fsyncs, atomically replaces, syncs the directory, and accepts durability. Covered by backup/restore and encrypted restore tests. |
| R4 | Escaping `Defect` could return `KOUTEN_OK` through the C ABI. | Done | `config.nims` enables `--panics:on`; C ABI validates node count and oversized lengths; C handle safety tests were expanded. Covered by `examples/cabi_contract.c`. |
| R5 | WAL lacked checksum/versioning and unknown records could desynchronize replay into payload bytes. | Done | New WAL files use `!KOUTENDB-WAL 2` plus per-record length and CRC32 wrappers. Versioned checksum mismatch refuses open; versioned torn tails repair to the last checked record. Legacy pre-v1.0 WAL remains readable. Covered by new `tests/tstore.nim` WAL v2 cases. |
| R6 | `backup()` could report success for a backup not durable on disk. | Done | Backup and encrypted backup write compact snapshots through durable temp files and atomic replacement. Covered by backup verification and corrupted backup tests. |
| R7 | Unusable auth configs such as `--secret-key` without `--user` failed open. | Done | `koutend` rejects unusable user/password/secret-key combinations at startup. Covered by `scripts/cluster_authz_smoke.sh`. |
| R8 | One stalled body read could block the single-threaded server indefinitely. | Done | Accepted sockets now get a receive timeout, a fixed active connection cap, and server-side `RETRIEVE` budget/scan guards. Oversized scans return `ERR bad-request` after the frame body is consumed, preserving protocol boundaries. Covered by wire fuzz smoke with small test limits. |
| R9 | `logicalKey` converged only while events were pending; target apply did not overwrite by logical key. | Decision | Source-side pending coalescing exists; target-side logical-key convergence is still not implemented. This should be decided before patching because it changes whether universe sync is append-only, latest-value, or bounded-history at the target. |
| R10 | Remote universe sync acked/pruned events regardless of the target status. | Done | Source now acks only `APPLIED` or verified `SKIPPED`. `DELAYED` is accepted as a non-error retry state but is not acked. Covered by universe sync failure/remote smoke tests. |
| R11 | Rings created inside a transaction were not persisted by name after reopen. | Done | Transactions can persist ring names through `XN` records; tests verify commit/rollback ring-name behavior across reopen. |
| R12 | No data-directory lock allowed two processes to corrupt or merge WAL transactions. | Done | `openStore` takes an exclusive data-directory lock on POSIX and fails cleanly if another process owns it. Covered by child-process lock test. |
| R13 | Bare `D` replay bypassed `applyOp` and left `itemsByRing` inconsistent. | Done | Bare delete replay now routes through `applyOp`. Covered by delete replay consistency test. |
| R14 | `seqs` and `maxTWrite` regressed across compaction. | Done | Snapshot records now persist `S <ringKey> <nextSeq>` and `M <maxTWrite>`. Covered by compact replay tests. |
| R15 | Server `RETRIEVE` copied all candidates before applying budget. | Done | Server retrieve keeps only the current top candidates up to budget. Ring-scoped cluster retrieval now routes to the physical owner and walks `itemsByRing`; physical visits and scored candidates are separately observable. Scan caps/query deadlines remain separate guardrail work. |
| R16 | Selection and JSON parsing had unbounded recursion risk. | Done | Selection parsing has `MaxSelectionDepth`; `UAPPLY` validates JSON depth before parsing. Covered by selection depth and wire fuzz tests. |

## Additional Audit Items

| Area | Item | Current status | Notes |
|---|---|---|---|
| Durability | Fresh store directory entry is not fsynced under strong durability. | Partial | `openStore` now syncs the data directory in strong mode after opening the log. A stronger crash-injection test is still future work. |
| Durability | `syncDir` silently ignored directory open failure. | Done | POSIX directory-open failure now raises instead of silently returning. |
| Durability | Store comment overstated default process-crash safety. | Done | Store comments now describe `durBuffered` as batched flush and `durStrong` as fsync write boundaries. |
| Durability | fsync failure can leave memory ahead of disk. | Done | Store now marks the persistent write path as poisoned after flush/fsync failure and rejects later mutations on that handle. `-d:koutenTestFailpoints tests/tstore.nim` covers the fail-closed contract. |
| Storage | `SM` accepts arbitrary blobs that may not replay. | Done | Store validates stellar-map JSON shape before write and during replay: `stellar` must match the key and `members` must be a string array. `tests/tstore.nim` covers write rejection and bad replay rejection. |
| Storage | Legacy `E` record reader exists but current writers inline vectors in `P` / `XP`. | Planned | Decide whether to keep the legacy reader for compatibility or remove it before v1.0. |
| Storage | Encrypted backup verification writes a temp file into the verified directory. | Done | Encrypted backup verification now decrypts into an OS temporary directory and removes it after validation, so the backup directory is not polluted with plaintext verification files. Covered by encrypted backup tests. |
| Concurrency | Cooperative locks are embedded-only and not enforced by normal write paths. | Decision | This is intentional so far: locks are opt-in high-integrity guards. Making them server-visible or mandatory would change the NoSQL write path. |
| Concurrency | Lock token generation and fencing are weak for future distributed locks. | Partial | Embedded lock tokens now include a monotonically increasing handle-local `fence`, and tests cover token/fence change after TTL reacquire. Server/distributed lock persistence remains out of scope for this branch. |
| C ABI | `last_error` pointer lifetime was unclear. | Done | `include/koutendb.h` documents that the pointer is valid only until the next KoutenDB C ABI call on the same thread. |
| C ABI | Raw pointer handles lacked validation. | Done | C ABI now uses an internal handle registry and treats closed/unknown handles as errors. Covered by C ABI contract tests. |
| C ABI | OOM can still terminate the host process. | Planned | Nim runtime OOM behavior is not solved in this branch. Document and avoid huge allocations at API boundaries where possible. |
| C ABI | `kouten_init` was not idempotent. | Done | `kouten_init()` is guarded; contract test calls it twice. |
| C ABI | Thread-safety contract was not documented. | Done | `include/koutendb.h` and `docs/driver-installation.md` document `kouten_init` idempotency, `last_error` lifetime, handle sharing, and `kouten_close` synchronization requirements. |
| Server | Prepared selection cache is entry-bounded, not byte-bounded. | Done | Server prepared-selection cache now has a total source-byte budget, LRU eviction, and a per-selection source-size limit. |
| Server | Internal exception messages are returned to clients. | Done | Remote catch paths now return stable `ERR bad-request`, `ERR io-error`, or `ERR internal` categories instead of raw exception text. Wire fuzz covers stable bad-request behavior. |
| Server | Password compare uses normal string equality. | Done | Auth paths now use `secureEqual` for password-like comparisons and secret-response plaintext checks. |
| Server | Credentials are passed as CLI arguments in examples. | Done | Server and CLI now accept `--password-file`, `--auth-token-file`, `--secret-key-file`, and `KOUTEN_*` env fallbacks. Docs prefer file/env paths outside local smoke tests; `cluster_authz_smoke` covers file/env auth. |
| Server | `authedUsers` cleanup on disconnect was missing. | Done | Disconnect cleanup now removes `authedUsers` alongside auth, codec metadata, and auth challenges. |
| Server | Metrics/health exposure and global vector counts may leak information. | Done | `METRICS` remains admin-only. When RBAC users are configured, non-admin `HEALTH` now returns only minimal liveness (`node=...`) while admin users retain item and pending transaction counters. Covered by RBAC tests. |
| Docs | Threat model had stale TLS language. | Done | Threat model now treats TLS as implemented and recommends TLS for untrusted networks plus private networks/tunnels as defense-in-depth. |
| Universe sync | Remote delayed-apply windows were not enforced. | Done | Source events can carry `applyAfter`; remote `UAPPLY` returns `DELAYED` without applying or acking until the window is ready. `scripts/universe_sync_remote_smoke.sh` covers the pending behavior. |
| Universe sync | Role checks can fail open when no roles are configured. | Decision | Default unauthenticated/local deployments are intentional; partial auth/role combinations need a clearer fail-fast policy. |
| Universe sync | `putSynced` local write and outbox enqueue are not one transaction. | Done | `putSynced` now stages the local particle write and source outbox event in one Store transaction (`XP` + `XUJ` under one commit marker). Latest-only coalescing deletes are staged as `XUD` in the same boundary. |
| Universe sync | Applied event dedup state is grow-only. | Done | Target-side applied event keys now keep insertion order and support bounded retention. Prunes are persisted through `UX` WAL records, so restart/compact preserve the idempotency window. Covered by store replay tests. |
| Universe sync | Retry accounting is mostly inert. | Done | Source outbox events now persist `attempts`, `maxAttempts`, `retryAt`, `deadLetter`, and `error`. Failed delivery attempts back off and eventually dead-letter without being acked/pruned. `tests/tapi.nim` covers dispatch gating, persistence, and dead-letter behavior. |
| Universe sync | Outbox ID can reset after full prune. | Done | Store now persists `UQ <nextEventId>` independently of live outbox rows. Tests cover prune + reopen + compact without event-id reuse. |
| Cluster | Static peers and unfenced topology remain. | Planned | Dynamic membership / epoch migration is foundation-only today; coordinator redundancy remains planned. |

## Evidence Gaps

| Gap | Current status | Next action |
|---|---|---|
| `tests/twire_driver.nim` is not in the default smoke path. | Done | Added `scripts/cluster_wire_driver_smoke.sh`, included it in `scripts/test_all_smoke.sh`, and added it to GitHub Actions smoke tests. |
| Cross-version migration needs a stable boundary while WAL can evolve before v1.0. | Done | `koutendb.dump.v1` JSONL is documented as the migration boundary; `importJsonl` recognizes KoutenDB dump files and preserves ring, payload, vector, and codec metadata. Covered by API and CLI round-trip tests. |
| Release gate omitted TLS despite TLS being implemented. | Done | `scripts/test_all_smoke.sh` now includes `scripts/cluster_tls_smoke.sh`, and the release checklist explicitly gates CA-verified TLS transport. |
| TLS deployment note in test coverage was stale. | Done | Test coverage now distinguishes local CA-verified TLS smoke from future certificate lifecycle / deployment policy tests. |
| Demo scripts are not all executed by CI. | Done | Added `scripts/demo_smoke.sh` for stellar data model, payload codec, and locality workload matrix demos, and added it to `scripts/test_all_smoke.sh` and GitHub Actions. |
| Summary benchmark tables dropped some qualifiers. | Done | README and benchmark comparison wording now explicitly separate PostgreSQL persistence-enabled reference, strong-durability non-measurement, Redis persistence-disabled latency smoke, and working-set/token reduction claims. |
| `docs/public-api.md` parameter order drifted from implementation. | Done | Public API docs were adjusted in this hardening branch. |

## Items Intentionally Not Adopted As Direct Fixes

| Item | Reason |
|---|---|
| Make Raft/consensus the default cluster write path. | This conflicts with KoutenDB's current direction: reduce global coordination and use ring/galaxy/universe boundaries instead. Coordinator redundancy and recovery are still valid goals, but not by defaulting every write to consensus. |
| Make MVCC the immediate answer. | Current embedded/server execution is not yet a multi-reader concurrent engine. For the current scope, data-dir locking and explicit transaction boundaries solve the concrete issues first. |
| Make secondary indexes the primary model. | KoutenDB's primary access model is ring/stellar locality. Secondary mechanisms should remain hints, projections, or lookup maps that point back into ring-local reads. |
| Make cooperative locks mandatory for normal writes. | That would make the normal NoSQL path heavier and less KoutenDB-like. Locks should remain opt-in unless a high-integrity workflow asks for them. |

## Verification Snapshot

The current hardening branch has been checked with:

- `nim check src/kouten/store.nim`
- `nim c -r --nimcache:/tmp/nimcache_kouten_tstore tests/tstore.nim`
- `nim c -r --nimcache:/tmp/nimcache_kouten_tapi tests/tapi.nim`
- `scripts/test_core.sh`
- `scripts/cli_crud_smoke.sh`
- `scripts/test_all_smoke.sh`
- `nimble check`
- C ABI shared library build plus `bin/cabi_contract`

Driver repository compatibility remains a separate release task.
