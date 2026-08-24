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
| Store / WAL | `tests/tstore.nim`, `tests/tsegment_failpoints.nim` | Unit-covered: codec persistence, time-orbit profile persistence, placement topology persistence/epoch fencing, versioned WAL magic/checksum, checksum mismatch refusal, torn-tail repair, mid-file WAL corruption refusal, transaction replay, cross-process and canonical same-process data-dir locking, close/reopen lock release, compact, locality report, delete/backfill locality matrix, compact-before/after logical query invariants, disk-backed segment/index restart reuse, point and full-ring damaged-segment WAL fallback, checksum-detected mid-segment payload corruption, valid-looking wrong-record index offsets, malformed index/manifest recovery, bounded window limits/direction/delete/post-pack writes, exact recommendation thresholds, per-ring generation pack, inactive generation cleanup, disk-backed compact and backup/restore, encrypted backup verification temp isolation, universe sync applied-key retention replay; `-d:koutenTestFailpoints` covers byte/elapsed interruption before publication, interruption after the segment replacement, and interruption after both generation files are durable but before manifest activation |
| Public embedded API | `tests/tapi.nim` | Unit-covered: put/get, codec-aware projection, ring profiles, time-orbit put/read, readRing filtering, typed filter builders, pagination, sorting, disk-backed bounded and complete ring windows across pack/update/delete/reopen, shared maintenance plan/execution decisions, exact count/byte boundaries, durable completed/interrupted status, explicit recommended-pack count limits, exact capacity guardrail boundaries, stellar neighborhood reads from either side, stellar attach/detach persistence, chunked JSONL import stats, atomic batch rollback, cooperative ring/stellar locks with fencing values, idempotent release and stale-token lock safety, specialized validation/guardrail/conflict exceptions, warp, universe sync retry/dead-letter state |
| CLI embedded usage | `scripts/cli_crud_smoke.sh` | Smoke-covered: help, put/get/query/list/count, readRing options, `--near` placement, `--stellar`, stellar attach/detach, `--subring` neighborhood narrowing, codec display, ring profile auto codec, time-orbit put/get, dump/import JSONL round-trip, segment JSON/metrics output, maintenance plan/run/status and invalid budgets, operational capacity failures, data/backup/server-config verify, shell, auth error text |
| Bounded automatic packing | `tests/tmaintenance_window.nim`, `scripts/auto_pack_server_smoke.sh` | Unit/integration-covered: UTC same-day and midnight-crossing windows, invalid window rejection, opt-in server scheduling, actual stale-ring pack, maintenance metrics, durable status, offline reopen/verify, and rejection of unbounded automatic configuration |
| Operational metrics | `tests/tmetrics.nim`, `scripts/cluster_rbac_smoke.sh`, `scripts/checkpoint_smoke.sh`, `examples/cabi_contract.c` | Contract-covered: legacy key/value compatibility, Prometheus/OpenMetrics formatting and EOF, counter/gauge types, multi-node labels, bounded fallback/guardrail reason labels, no ring/checkpoint-ID labels, malformed source rejection, aggregate checkpoint health, cluster and checkpoint CLI paths, and additive C ABI output/validation. |
| C ABI | `examples/cabi_contract.c`, `examples/cabi_tls_contract.c`, `scripts/cabi_tls_smoke.sh`, `scripts/driver_compat.sh` | Contract-covered: ABI version, put/get/update/delete/exists, codec metadata, read ring page shape, strong disk-backed open and reopen, segment diagnostics, bounded maintenance plan/run/status/recovery, generation checkpoint create/status/list/cleanup/restore, Prometheus/OpenMetrics operational and checkpoint metrics, validation errors, NULL output pointers, oversized payload/vector/batch lengths, invalid codecs, handle close/reuse safety, atlas, CA-verified TLS-enabled connect path |
| Wire protocol | `tests/twire_driver.nim`, `scripts/cluster_wire_driver_smoke.sh`, `scripts/cluster_wire_fuzz_smoke.sh` | Smoke-covered: driver-facing PUTR/GETID/QRYID, codec metadata negotiation, malformed frame behavior, oversized/deep JSON rejection, `RETRIEVE` query-cost rejection, and broad-scan-denied server audit emission |
| TLS transport | `scripts/cluster_tls_smoke.sh` | Smoke-covered: TLS-enabled `koutend`/CLI build, three-node CA-verified authenticated TLS health, secret-key auth transport, JSON put/get, apply-time placement fencing, destination-side mutation/tombstone ordering on the stable physical owner, ID query, and plain-client rejection |
| Handoff mutation ordering | `tests/tstore.nim`, `tests/twire_driver.nim`, `tests/thandoff_ordering.nim`, `tests/thandoff_ordering_remote.nim`, `tests/thandoff_reclamation.nim` | Matrix-covered: stale and duplicate values, delete-before-delayed-transfer protection, newer recreation, WAL replay, compact, backup/restore, transaction delete, destination restart, TLS/authenticated transfer, canonical acknowledgement merging, single-node reclamation, all-node guard propagation, and bounded final reclamation |
| Placement epoch migration | `tests/tplacement_migration.nim`, `tests/twire_driver.nim`, `scripts/placement_migration_smoke.sh` | Integration-covered: short logical periods do not generate physical handoff, persistent drain before topology change, one-by-one mixed-epoch 2-to-3-node restart, wrong-epoch resume rejection, destination-down source retention/retry, admin-only maintenance transfer, preflight and apply-time topology fencing, unsupported in-place scale-in rejection, bounded convergence, activation preflight, post-resume writes, owner-routed reads, and settled-topology restart |
| Explicit scale-in migration | `tests/tscale_in_migration.nim`, `scripts/scale_in_migration_smoke.sh` | Integration-covered: persistent drain marker, 3-to-2-node migration, checkpoint/resume, target outage, mixed/wrong epoch, source fingerprint mismatch, versioned records and tombstones, metadata transfer and independent verification, pending operational queue rejection, malformed frame recovery, and idempotent rerun |
| Cluster transactions | `tests/tcluster_tx.nim`, `scripts/cluster_tx_smoke.sh` | Smoke-covered: landing intent, apply retry, basic owner failure path |
| Cluster auth / RBAC | `tests/tcluster_authz.nim`, `tests/tcluster_rbac.nim`, related scripts | Smoke-covered: username/password/secret key, unusable auth config fail-fast, server JSON config loading, role/ring-prefix authorization, admin-only metrics/drain/snapshot, minimal non-admin health, drain-mode write rejection with readable connection preservation, forged writer-level maintenance migration rejection, and auth/authz server audit emission |
| Cluster failure | `tests/tcluster_failure.nim`, `scripts/cluster_failure_smoke.sh` | Smoke-covered: owner restart and retry boundaries |
| Universe sync | `examples/universe_sync_demo.nim`, `scripts/universe_sync_*_smoke.sh` | Smoke-covered: local export/apply, remote apply, idempotency, retry/dead-letter handling, applied-key retention, malformed JSONL handling |
| Recovery | `scripts/recovery_smoke.sh` | Smoke-covered: backup/restore, recovery status, checksum/item/tombstone manifest mismatch rejection, and encrypted/readonly mirror paths |
| Generation checkpoints | `tests/tcheckpoints.nim`, `tests/tsegment_failpoints.nim`, `scripts/checkpoint_smoke.sh`, `examples/cabi_contract.c` | Matrix-covered: WAL plus segment/index generation sealing, manifest-last publication, strict content verification, selected-generation restore, immutable isolation from later source writes, retention, invalid-generation preservation, active/symlink/overlap target rejection, stable restore exclusion, post-publication restore rollback, CLI JSON lifecycle, and additive C ABI lifecycle. |
| Disk-backed ring reads | `tests/tstore.nim`, `tests/tapi.nim`, `scripts/auto_pack_server_smoke.sh` | Matrix-covered: seq-ordered ring metadata, bounded windows, monotonic duplicate-free pagination after old-sequence updates, deletion filtering, reopen stability, and embedded/remote disk-backed count/list behavior. |
| Compose examples | `scripts/compose_config_smoke.sh` | Smoke-covered: every `examples/compose/*.compose.yml` file parses with Docker Compose, including the optional tools profile |
| Container persistence and security | `scripts/container_security_matrix.sh` | Manual Docker matrix: TLS-enabled image build, strong disk-backed named-volume persistence, same-container restart, container replacement, network disconnect/reconnect, CA and hostname rejection, expired-certificate rejection, ID/password/secret-key failures, ring authorization denial, credential rotation, offline segment verification, and persisted audit evidence. Not part of normal CI. |
| Single-node self-host operations | `scripts/container_image_smoke.sh`, `scripts/self_host_bundle_smoke.sh` | CI-covered: TLS/authenticated strong-durability bootstrap, host and runtime secret/private-key permissions, generated certificate verification and SANs, network-disabled secret staging, non-root/read-only Compose runtime, persistent write recovery after an actual `koutend` process crash, invalid-version/non-empty/symlink bootstrap refusal, consecutive-health-failure restart threshold, healthy-state reset, starting-state restraint, and bounded restart-loop failure. |
| Soak testing | `examples/soak_72h.sh`, `examples/soak_runner.nim` | Optional local release gate: three strong-durability disk-backed nodes with writes, updates, deletes, backfills, point/projection/ring/stellar/retrieval reads, bounded auto-pack, latency percentiles, RSS/disk samples, queue convergence, snapshot, segment-aware offline verify, checkpoint restore, and exact dump equivalence. Not part of CI. |
| Disk-backed cluster wire reads | `tests/tcluster_disk_backed_reads.nim`, `scripts/cluster_disk_backed_reads_smoke.sh` | Regression-covered: GETID/QRYID, legacy GET, and BGET use the Store read boundary before and after a strong-durability server restart. |
| Accelerated churn | `examples/accelerated_churn.sh`, `examples/accelerated_churn.nim` | Manual high-density disk-backed validator: seeded writes, updates, deletes, backfills, bounded maintenance, checkpoint retention, reopen, backup/restore, independent full-state comparisons, bounded latency sampling, RSS/storage/fallback metrics, and final offline verification. A 120,000-operation local run completed with 1,202 exact logical-state comparisons, 60 reopens, 30 backup/restore comparisons, zero duplicate or missing records, and zero WAL fallbacks. It remains outside CI. |
| Disk-backed crash recovery | `scripts/disk_backed_recovery_smoke.sh`, `examples/disk_backed_recovery_matrix.nim` | Three process-level `SIGKILL` rounds during repeated strong-durability two-ring transactions, each followed by restart, atomic-pair verification, ring pack, compact, backup, restore, and result re-verification. The round count is configurable with `KOUTEN_RECOVERY_ROUNDS`. |
| Publication crash boundaries | `scripts/process_crash_matrix.sh`, `examples/process_crash_matrix.nim` | CI matrix using actual `SIGKILL` at nine exact boundaries: segment output, data and index publication, manifest activation, inactive-generation cleanup, and checkpoint/backup publication before and after replacement. Restart verification requires old-or-new generation visibility, unrelated-ring isolation, hidden unpublished checkpoints, restorable published state, retry safety, temporary-file cleanup, and zero post-recovery WAL fallback. Test hooks are compile-time-only and absent from release builds. This is process-crash coverage, not a power-loss durability claim. |
| Server concurrency / backpressure | `scripts/concurrency_backpressure_smoke.sh`, `examples/concurrency_backpressure_matrix.nim` | Multi-process CI matrix: concurrent same-ring writers and updates with applied acknowledgements, monotonic readers, metrics and snapshot barriers, bounded automatic packing, exact online/offline result equality, and segment verification. Pressure cases cover the active-connection cap and rejection metric, recovery after admission pressure, partial request-body timeout, oversized `LISTR` rejection, and a non-reading client bounded by the server send deadline. |
| Storage failures | `scripts/storage_failure_matrix.sh`, `tests/tstorage_failures.nim` | Strong-durability disk-backed matrix covering injected disk-full and short WAL writes, poisoned-handle rejection, metadata visibility after failed persistence, real directory permission loss, missing active segment recovery, damaged manifest recovery, and record-local WAL fallback for a valid-looking corrupt index offset. Every case reopens and compares exact logical state. Injection code is compile-time-only and absent from release builds. |
| Release upgrade fixtures | `tests/tupgrade_fixtures.nim`, `scripts/upgrade_fixture_matrix.sh`, `tests/fixtures/` | Authentic v0.10.1 and v0.11.0 disk-backed stores generated by their tagged release code. Matrix-covered: WAL replay, legacy generation-zero and manifest-selected generation-one reads, explicit current-format pack, exact logical dump comparison, JSONL migration with codec/vector preservation, generation checkpoint verification/restore, and offline operational verification. |
| Driver compatibility | `scripts/driver_compat.sh`, `scripts/external_driver_matrix.sh`, `scripts/driver_probes/python_security_probe.py` | The optional in-tree smoke covers C ABI and bundled driver paths. The manual external matrix runs the separately maintained Rust, JavaScript/TypeScript, PHP, C++, and Python suites, then applies one strong disk-backed TLS/auth/restart/error matrix to all five. The first v0.12 run found outstanding Rust test-expectation and Python wire-protocol blockers; it is not yet a passed release gate. |
| Data model demos | `scripts/demo_smoke.sh`, `examples/stellar_data_model_demo.sh`, `examples/locality_layout_demo.sh`, `examples/payload_codecs_demo.sh`, `examples/effect_validation_demo.sh` | Demo-covered: non-copy stellar visibility, narrowed stellar reads, original ring preservation after detach, payload codec persistence, compaction locality reporting, messy locality workloads, compact-before/after logical result invariants, lightweight effect validation, and read micro-samples. `examples/effect_validation_matrix.sh` and `examples/offline_effect_validation.sh` are manual validation tools, not default CI smoke steps. |

## Release Gate

For a normal core release, run:

```sh
scripts/test_core.sh
scripts/process_crash_matrix.sh
scripts/concurrency_backpressure_smoke.sh
scripts/storage_failure_matrix.sh
scripts/upgrade_fixture_matrix.sh
scripts/checkpoint_smoke.sh
scripts/cli_crud_smoke.sh
scripts/auto_pack_server_smoke.sh
scripts/cluster_tx_smoke.sh
scripts/cluster_failure_smoke.sh
scripts/cluster_authz_smoke.sh
scripts/cluster_rbac_smoke.sh
scripts/cluster_wire_driver_smoke.sh
scripts/cluster_wire_fuzz_smoke.sh
scripts/cluster_retrieve_routing_smoke.sh
scripts/handoff_reclamation_smoke.sh
scripts/placement_migration_smoke.sh
scripts/scale_in_migration_smoke.sh
scripts/cluster_tls_smoke.sh
scripts/recovery_smoke.sh
scripts/universe_sync_failure_smoke.sh
scripts/universe_sync_remote_smoke.sh
scripts/compose_config_smoke.sh
scripts/container_image_smoke.sh
```

`scripts/test_all_smoke.sh` runs the same sequence and skips driver
compatibility by default. Set `KOUTEN_TEST_DRIVERS=1` when the local driver
toolchains are available.

`cluster_retrieve_routing_smoke.sh` checks both logical results and physical
work. Its persistent two-node matrix verifies owner-only routing, ring-indexed
record visits, both local-owner and remote-owner transaction apply, rollback,
update, delete, empty-ring behavior, global fan-out, drain/resume, restart, and
fail-closed behavior when the calculated owner is unavailable. The disk-backed
API suite separately covers writes and updates made after segment packing and
after reopen.

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
