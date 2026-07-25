# Test Coverage

This document tracks KoutenDB's test coverage by product surface. It is not a
claim of exhaustive production certification; it is the current engineering
matrix used before releases.

## Coverage Matrix

| Area | Primary checks | Current status |
| --- | --- | --- |
| Orbital / physical placement core | `tests/tcore.nim` | Unit-covered: angle wrapping, logical ownership, stable physical ring coordinates, weighted arcs, virtual arc remap reduction, future arrival, conjunctions |
| Field / halo movement | `tests/tfield.nim` | Unit-covered: field state and ring movement behavior |
| Selection parser | `tests/tselect.nim` | Unit-covered: GraphQL-like selection parsing, bounded selection depth, and projection basics |
| Store / WAL | `tests/tstore.nim` | Unit-covered: codec persistence, time-orbit profile persistence, placement topology persistence/epoch fencing, versioned WAL magic/checksum, checksum mismatch refusal, torn-tail repair, mid-file WAL corruption refusal, transaction replay, data-dir locking, compact, locality report, delete/backfill locality matrix, compact-before/after logical query invariants, backup/restore, encrypted backup verification temp isolation, universe sync applied-key retention replay; `-d:koutenTestFailpoints` covers poisoned write-path rejection after simulated durability failure |
| Public embedded API | `tests/tapi.nim` | Unit-covered: put/get, codec-aware projection, ring profiles, time-orbit put/read, readRing filtering, typed filter builders, pagination, sorting, stellar neighborhood reads from either side, stellar attach/detach persistence, chunked JSONL import stats, atomic batch rollback, cooperative ring/stellar locks with fencing values, idempotent release and stale-token lock safety, specialized validation/guardrail/conflict exceptions, warp, universe sync retry/dead-letter state |
| CLI embedded usage | `scripts/cli_crud_smoke.sh` | Smoke-covered: help, put/get/query/list/count, readRing options, `--near` placement, `--stellar`, stellar attach/detach, `--subring` neighborhood narrowing, codec display, ring profile auto codec, time-orbit put/get, dump/import JSONL round-trip, operational data/backup/server-config verify, shell, auth error text |
| C ABI | `examples/cabi_contract.c`, `examples/cabi_tls_contract.c`, `scripts/cabi_tls_smoke.sh`, `scripts/driver_compat.sh` | Contract-covered: ABI version, put/get, codec metadata, read ring page shape, validation errors, NULL output pointers, oversized payload/vector/batch lengths, invalid codecs, handle close/reuse safety, atlas, CA-verified TLS-enabled connect path |
| Wire protocol | `tests/twire_driver.nim`, `scripts/cluster_wire_driver_smoke.sh`, `scripts/cluster_wire_fuzz_smoke.sh` | Smoke-covered: driver-facing PUTR/GETID/QRYID, codec metadata negotiation, malformed frame behavior, oversized/deep JSON rejection, `RETRIEVE` query-cost rejection, and broad-scan-denied server audit emission |
| TLS transport | `scripts/cluster_tls_smoke.sh` | Smoke-covered: TLS-enabled `koutend`/CLI build, three-node CA-verified authenticated TLS health, secret-key auth transport, JSON put/get, apply-time placement fencing, destination-side mutation/tombstone ordering on the stable physical owner, ID query, and plain-client rejection |
| Handoff mutation ordering | `tests/tstore.nim`, `tests/twire_driver.nim`, `tests/thandoff_ordering.nim`, `tests/thandoff_ordering_remote.nim`, `tests/thandoff_reclamation.nim` | Matrix-covered: stale and duplicate values, delete-before-delayed-transfer protection, newer recreation, WAL replay, compact, backup/restore, transaction delete, destination restart, TLS/authenticated transfer, canonical acknowledgement merging, single-node reclamation, all-node guard propagation, and bounded final reclamation |
| Placement epoch migration | `tests/tplacement_migration.nim`, `tests/twire_driver.nim`, `scripts/placement_migration_smoke.sh` | Integration-covered: short logical periods do not generate physical handoff, 2-to-3-node persistent migration, destination-down source retention/retry, preflight and apply-time topology fencing, unsupported scale-in rejection, bounded convergence, owner-routed reads, and settled-topology restart |
| Cluster transactions | `tests/tcluster_tx.nim`, `scripts/cluster_tx_smoke.sh` | Smoke-covered: landing intent, apply retry, basic owner failure path |
| Cluster auth / RBAC | `tests/tcluster_authz.nim`, `tests/tcluster_rbac.nim`, related scripts | Smoke-covered: username/password/secret key, unusable auth config fail-fast, server JSON config loading, role/ring-prefix authorization, admin-only metrics/drain/snapshot, minimal non-admin health, drain-mode write rejection with readable connection preservation, and auth/authz server audit emission |
| Cluster failure | `tests/tcluster_failure.nim`, `scripts/cluster_failure_smoke.sh` | Smoke-covered: owner restart and retry boundaries |
| Universe sync | `examples/universe_sync_demo.nim`, `scripts/universe_sync_*_smoke.sh` | Smoke-covered: local export/apply, remote apply, idempotency, retry/dead-letter handling, applied-key retention, malformed JSONL handling |
| Recovery | `scripts/recovery_smoke.sh` | Smoke-covered: backup/restore, recovery status, checksum/item/tombstone manifest mismatch rejection, and encrypted/readonly mirror paths |
| Compose examples | `scripts/compose_config_smoke.sh` | Smoke-covered: every `examples/compose/*.compose.yml` file parses with Docker Compose, including the optional tools profile |
| Soak testing | `examples/soak_72h.sh`, `examples/soak_runner.nim` | Optional local runner: long-running three-node cluster validation with mixed writes, point reads, query projection, ring reads, retrieval, metrics, snapshot, and offline verify. Not part of CI. |
| Driver compatibility | `scripts/driver_compat.sh` | Optional smoke: C, C++, and published driver-facing C ABI paths when enabled |
| Data model demos | `scripts/demo_smoke.sh`, `examples/stellar_data_model_demo.sh`, `examples/locality_layout_demo.sh`, `examples/payload_codecs_demo.sh`, `examples/effect_validation_demo.sh` | Demo-covered: non-copy stellar visibility, narrowed stellar reads, original ring preservation after detach, payload codec persistence, compaction locality reporting, messy locality workloads, compact-before/after logical result invariants, lightweight effect validation, and read micro-samples. `examples/effect_validation_matrix.sh` and `examples/offline_effect_validation.sh` are manual validation tools, not default CI smoke steps. |

## Release Gate

For a normal core release, run:

```sh
scripts/test_core.sh
scripts/cli_crud_smoke.sh
scripts/cluster_tx_smoke.sh
scripts/cluster_failure_smoke.sh
scripts/cluster_authz_smoke.sh
scripts/cluster_rbac_smoke.sh
scripts/cluster_wire_driver_smoke.sh
scripts/cluster_wire_fuzz_smoke.sh
scripts/handoff_reclamation_smoke.sh
scripts/placement_migration_smoke.sh
scripts/cluster_tls_smoke.sh
scripts/recovery_smoke.sh
scripts/universe_sync_failure_smoke.sh
scripts/universe_sync_remote_smoke.sh
scripts/compose_config_smoke.sh
```

`scripts/test_all_smoke.sh` runs the same sequence and skips driver
compatibility by default. Set `KOUTEN_TEST_DRIVERS=1` when the local driver
toolchains are available.

## Remaining Depth Targets

The following areas are intentionally tracked as deeper follow-up work rather
than hidden assumptions:

- long-running node-restart soak tests during active traffic;
- mixed-version wire protocol compatibility tests;
- TLS certificate lifecycle, rotation, expiry, and deployment policy tests beyond the local CA smoke;
- larger universe sync replay and backlog-pressure tests;
- driver matrix CI across all published language repositories.

## High-Integrity Workflow Matrix

`tests/tapi.nim` includes focused coverage for the opt-in integrity path:

| Area | Cases covered |
|---|---|
| Atomic put | multi-record commit, staged write rollback on exception, persistence replay |
| Atomic update | length mismatch rejection, missing ID rollback, previous payload preservation |
| Atomic delete | successful multi-delete, missing ID rollback, previous payload preservation |
| Ring lock | same-ring conflict, disjoint-ring coexistence, release, TTL expiry, token/fence change on reacquire |
| Stellar lock | member-ring conflict, ring-to-stellar conflict, unrelated stellar coexistence |
| Lock helper | `withRingLock` transaction body, `withStellarLock` release on exception |

These tests intentionally keep locks opt-in. Ordinary `put`, `get`, `list`, and
`retrieve` remain outside the lock check path.
