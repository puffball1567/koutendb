# Changelog

## Unreleased

## v0.14.1 - 2026-08-29

### Added

- Added a five-minute quickstart that demonstrates write-time locality,
  bounded neighborhood reads, subring narrowing, projections, and Atlas
  inspection without requiring a cluster.
- Added runnable Docker Compose web demos for the REKT stack (React, Express,
  KoutenDB, TypeScript) and the PRK stack (Prologue, React, KoutenDB).
- Added an adoption and ecosystem roadmap that separates first-use,
  integration, service-trial, and distribution work from the v1 compatibility
  plan.

### Changed

- Reorganized the README and documentation index around evaluation,
  integration, operation, and maturity paths.
- Clarified the installation boundary between the Nimble CLI/library, the
  official server image, published language drivers, and source development.
- Updated source-build examples to include TLS support.

### Fixed

- Made embedded `kouten atlas` honor `KOUTEN_DATA`, matching the other CLI
  commands and the documented quickstart.

## v0.14.0 - 2026-08-27

### Added

- Added an official TLS-enabled multi-architecture OCI image release path for
  `linux/amd64` and `linux/arm64` through GHCR.
- Added a single-node self-host bundle with non-root/read-only containers,
  persistent strong-durability storage, generated TLS/auth configuration,
  health checks, and bounded supervised restart integration.
- Added operator-controlled checkpoint export, independent restore
  verification, scheduled verified backups, and fail-safe retention.
- Added rollback-safe image upgrades and certificate rotation with preflight,
  recovery-generation verification, and post-change health checks.
- Added bounded capacity history, growth forecasts, content-derived plan IDs,
  explicit approval, and one-shot prepared-capacity verification.
- Added documented `reader`, `writer`, `replicator`, and `admin` roles plus
  explicit peer service credentials for node-to-node traffic.

### Changed

- Authenticated connections are bound to one galaxy, and ring-scoped reads,
  retrieval, statistics, migration, and replication paths enforce their
  declared authorization boundaries.
- New encrypted backups derive keys with Argon2id and authenticated secretbox
  encryption while retaining read compatibility with legacy V1 backups.
- Newly created POSIX data directories and managed artifacts use owner-only
  permissions, and managed output paths reject symbolic-link targets.
- Remote password authentication now refuses non-loopback plaintext deployment
  unless TLS, secret-key transport, or the explicit development override is
  configured.

### Fixed / Hardened

- Added authentication throttling and equivalent first-response behavior for
  configured and unknown identities.
- Added symmetric request/response framing limits, bounded C ABI allocation
  inputs, validated handles, and catchable public API failures.
- Prevented application writers from invoking replication, owner-apply,
  coordinator, Universe, and topology-maintenance operations.
- Replaced remotely exposed internal exception text with stable error
  categories and restricted non-admin health/statistics disclosure.
- Added focused confidentiality, RBAC, malformed-frame, backup-migration,
  artifact-permission, C ABI, TLS, and multi-node peer-role validation.

## v0.13.0 - 2026-08-21

### Added

- Added a configurable durable standby for the cluster transaction
  coordinator. A committed multi-owner transaction is acknowledged only after
  its complete intent reaches the configured primary and standby durability
  boundaries.
- Added persistent coordinator epochs, primary/standby assignments,
  epoch-encoded transaction IDs, mirror markers, and completion markers that
  survive WAL replay and compaction.
- Added explicit majority-gated coordinator promotion through the Nim API and
  `kouten coordinator-promote`, plus coordinator discovery and status commands.
- Added coordinator role, assignment, replica-health, mirror success/failure,
  and pending-intent metrics.
- Added a three-node strong-durability failure matrix covering process
  termination, SIGKILL, standby outages, primary loss, replay, promotion,
  transaction identity collisions, and stale-primary return.

### Changed

- Cluster transaction clients now discover the highest non-conflicting
  coordinator epoch from reachable peers instead of assuming node zero.
- Promoted coordinators re-replicate pending intent to the newly assigned
  standby before resuming owner application.
- Coordinator changes require an explicit maintenance drain, a reachable
  majority, and reachable assigned primary and standby. Ordinary ring-local
  reads and writes do not gain a quorum round trip.

### Fixed / Hardened

- Fenced mirror and apply operations reject stale coordinator epochs and
  conflicting assignments after failover.
- Duplicate intent, mirror, completion, and retry operations are idempotent,
  while transaction-ID reuse with changed content fails closed.
- Orphan cluster-transaction WAL operation and commit records now fail closed
  during replay instead of producing an incomplete intent.
- A failed standby mirror or completion acknowledgement leaves the primary
  intent pending and recoverable instead of reporting an unsafe success.

## v0.12.1 - 2026-08-15

### Changed

- Updated the documented Rust, JavaScript/TypeScript, Python, PHP, and C++
  driver versions to match their current public package or GitHub releases.
- Distinguished published external drivers from the Go, Swift, C#, Kotlin,
  Node TCP, and Bun foundations that currently exist only in the core
  repository.
- Replaced the misleading Go package installation hint with the supported
  local `go.mod replace` workflow.
- Synchronized driver release status across the README, installation guide,
  roadmap, CLI discovery output, canonical status page, and translations.

## v0.12.0 - 2026-08-13

### Added

- Added opt-in bounded automatic ring packing with ring, byte, elapsed-time,
  maintenance-window, and stale-data limits plus shared plan/run/status APIs.
- Added immutable generation checkpoints that seal a compact WAL and complete
  ring-local segment/index generations behind a checksummed manifest and
  completion marker.
- Added checkpoint create, inspect, strict verify, list, fail-safe cleanup, and
  atomic-directory restore APIs through Nim, CLI, and additive C ABI v2 JSON
  functions.
- Added corruption, symlink, overlap, retention, empty-store, CLI, and C ABI
  checkpoint coverage.
- Added Prometheus and OpenMetrics output for requests, persistence, segment
  layout, maintenance, capacity guardrails, checkpoints, and fallback reasons.
- Added stable maintenance and fallback reason codes without unbounded
  ring-name or error-text metric labels.
- Added accelerated churn, process-crash, concurrency/backpressure,
  storage-failure, upgrade-fixture, container-security, and external-driver
  validation matrices.
- Added a final 72-hour three-node, disk-backed, strong-durability gate that
  completed 4,213,187 mixed operations with zero client errors and exact
  source-to-restored checkpoint equality.

### Fixed / Hardened

- Checkpoint restore now verifies a complete staged generation before
  publication and rolls back to an existing target if post-publication
  validation fails.
- Linux checkpoint overwrite now exchanges the staged and existing data
  directories with `renameat2(RENAME_EXCHANGE)`, with rollback tests at both
  the immediate post-exchange and post-publication boundaries. Platforms
  without an equivalent primitive fail closed for existing-directory overwrite.
- Checkpoint retention preserves invalid generations for diagnosis and refuses
  to remove the final verified generation.
- Persistent data-directory exclusion now combines canonical in-process
  reservations with cross-process file locks. Checkpoint restore holds a
  stable sibling guard across verification, directory publication, and
  rollback, so an active or concurrently opened target cannot be replaced.
- WAL write and flush failures poison the affected Store handle, reject later
  mutations, and cannot publish a failed record into in-memory state.
- Torn final WAL records recover to the last checksummed boundary, while
  derived segment, index, and manifest damage rebuilds from authoritative WAL.
- Accepted sockets use bounded receive/send deadlines, connection admission is
  observable, and oversized ring-list pages fail within a fixed limit.
- Cluster Nim API writes persist ring names correctly across reopen.
- Upgrade validation covers immutable v0.10.1 and v0.11.0 stores, legacy
  segment layouts, current packing, checkpoints, restore, and JSONL migration.

## v0.11.0 - 2026-08-04

### Added

- Added persistent ring-local segment and sidecar-index generations for
  disk-backed reads, with bounded point, ring, and stellar read paths.
- Added explicit `pack-ring`, `segment-status`, and `pack-recommended`
  maintenance commands plus machine-readable segment metrics.
- Added segment capacity guardrails for bytes, stale records and ratios,
  generation counts, and file counts.
- Added a three-round process-level `SIGKILL` recovery matrix covering strong
  durability, paired transactions, restart, pack, compact, backup, and restore.
- Added deterministic pack failpoints and tests around segment replacement and
  manifest activation boundaries.

### Changed

- Made physical locality a persistent read-layout property: WAL remains the
  source of truth while validated ring-local segments serve eligible reads.
- Wrapped new segment records in length-and-CRC32 envelopes while retaining
  read compatibility with legacy unframed generation-zero segments.
- Optimized CRC32 with slicing-by-eight tables and a compile-time standard
  vector check.
- Made pack selection explicit and operator-controlled instead of starting
  unpredictable background maintenance.

### Fixed / Hardened

- Detects same-length segment payload corruption and falls back to the complete
  authoritative WAL ring without returning partial or duplicated output.
- Rejects valid-looking index offsets that resolve to the wrong record identity.
- Preserves the previous complete generation when packing is interrupted before
  manifest activation, and cleans inactive generations after successful pack.
- Distinguishes an omitted `--max-rings` option from an explicitly invalid
  negative value.
- Prevents TLS smoke tests from accidentally connecting to an occupied plain
  listener by selecting a verified free three-port block and reporting node
  startup logs on failure.

## v0.10.1 - 2026-08-04

### Changed

- Repositioned the README around KoutenDB's locality-first retrieval model,
  verified RAG working-set/token reductions, bounded related-data reads, and
  completed 72-hour persistent cluster evidence.
- Moved the operational scope boundary behind the primary product explanation,
  benchmarks, and installation path.
- Bumped package metadata to `0.10.1`.

## v0.10.0 - 2026-08-03

### Added

- Added operational server configuration loading and verification, including
  opt-in write guardrails, audit events, capacity thresholds, backup
  verification, and a Docker Compose operational trial.
- Added explicit scale-in migration and rolling topology activation with
  migration progress, handoff, and drain controls.
- Added a local three-node soak runner that isolates the exact binaries and
  data directories used for a run, records JSONL progress, takes a final
  snapshot, and performs offline verification after shutdown.
- Added ring-scoped cluster retrieval coverage and a retrieval-locality
  benchmark helper.

### Changed

### Changed

- Removed the optional FAISS bridge, fetch/build scripts, vendored-source
  metadata, and runtime backend selection API.
- Standardized vector retrieval on the dependency-free exact path: KoutenDB
  narrows candidates by ring before cosine ranking instead of maintaining a
  second global vector index.
- Reworked the vector benchmark to compare broad and ring-scoped exact
  retrieval directly.

### Fixed / Hardened

- Decoupled physical placement from the logical orbit schedule so a logical
  orbit boundary cannot stall local request processing.
- Kept handoff I/O off the request loop and prevented stale handoff replay
  from resurrecting an older mutation.
- Corrected disk-backed locality verification so its score describes physical
  WAL run locality rather than a misleading in-memory measure.
- Restricted cluster `RETRIEVE` to its requested ring instead of falling back
  to a cluster-wide scan.
- Extended C ABI validation, coordinate-lock edge coverage, wire-fuzz smoke
  coverage, topology migration tests, and recovery/handoff smoke coverage.

## v0.9.0 - 2026-07-21

### Added

- Added `examples/effect_validation_demo.sh` and
  `examples/effect_validation_demo.nim`.
- Added `examples/effect_validation_matrix.sh` for multi-case generated corpus
  validation, including noisy and near-distractor workloads. The default manual
  matrix can scale to 13,500,000 generated records; the large opt-in case can
  scale to 98,000,000.
- Added `examples/offline_effect_validation.sh` for pre-production validation
  against copied/exported JSONL data without production traffic.
- Added optional Apache JMeter TCP health-load smoke plan and wrapper:
  `examples/jmeter/koutendb-health-load.jmx` and
  `examples/jmeter_load_smoke.sh`.
- Added chunked JSONL bulk-load commits through `importJsonl(..., batchSize=N)`
  and `kouten import-jsonl --batch-size=N`.
- Added `examples/subring_bundle_bench.nim` for heterogeneous related-data
  bundle reads with per-subring limits and per-subring sort directions.
- Added `examples/subring_bundle_postgres_bench.sh` to compare the same
  logical user-detail workload against PostgreSQL indexed queries and a JSON
  aggregate query.
- Added benchmark documentation for bounded stellar/subring reads where one
  request reads profile, addresses, career, preferences, orders, and
  notifications with different limits.
- The effect-validation demo imports a deterministic JSONL corpus, compares
  global vs ring-routed retrieval, reports import latency, scanned-record and
  estimated-token reduction, retrieval latency, writes a compact prompt, and
  can optionally pass that prompt to a trusted tiny local LLM command.
- Documented Gemma 4 E2B through Ollama as the recommended trusted small-model
  demo target.
- Added effect-validation prompt generation to the demo smoke matrix without
  requiring a model download in CI.

### Changed

- Reused prepared projection state inside `readStellar` so a multi-subring read
  does not reparse the same selection for every subring.
- Added a bounded ring-window read path for simple embedded reads with empty
  filters, positive limits, and `id` or `time` sorting.
- Added cached disk segment read streams so bounded disk-backed reads do not
  repeatedly open and close the same segment files.
- Updated effect-validation and benchmark comparison docs with the latest
  13.5M-record stress result, pinpoint user read result, user bundle
  PostgreSQL comparison, and heterogeneous subring bundle comparison.

### Fixed / Hardened

- Expanded public API tests for `readStellar` subring limits and per-subring
  descending time sorts.
- Kept the broad-scan and RAG effect-validation numbers separate from the
  PostgreSQL/Redis latency comparisons so the documented claims remain scoped
  to the measured workloads.
- Bumped package metadata to `0.9.0`.

## v0.8.0 - 2026-07-20

### Changed

- Renamed the project to KoutenDB.
- Renamed the public Nim package to `koutendb`.
- Renamed the command-line entry point to `kouten` and the daemon to `koutend`.
- Renamed the C ABI surface to `libkoutendb.so`, `include/koutendb.h`, and
  `kouten_*` / `KOUTEN_*` symbols.
- Renamed source modules, documentation, examples, scripts, driver stubs, and
  environment variables to the KoutenDB naming scheme.
- Updated package, driver, installation, benchmark, topology, codec, and
  release documentation to use the new repository and package names.

### Naming

- `Kouten` comes from the Japanese word "kouten" (公転), meaning orbital
  revolution: one body moving around another. The name is intended to match
  KoutenDB's model: rings, orbit-inspired placement, locality-aware retrieval,
  and smaller working sets.
- The technical direction is unchanged. KoutenDB remains the same
  ring-oriented NoSQL document/vector store, now under a clearer name.

### Migration Notes

- New users should use `nimble install koutendb` and the `kouten` CLI.
- Driver projects should target the new KoutenDB package names and C ABI names.
- Older names may remain visible in historical posts, package registries, or
  archived release notes, but the active project name is KoutenDB.

## v0.7.0 - 2026-07-19

### Added

- Added C ABI release-build hardening with `scripts/build_capi.sh`, using
  `--app:lib -d:ssl -d:release` as the canonical shared-library build path.
- Added C ABI TLS smoke coverage and C ABI contract coverage for TLS-capable
  driver builds.
- Added `tests/tauth.nim` for authentication helper coverage.
- Added data migration documentation for JSONL dump/import as the primary
  pre-v1 compatibility boundary.
- Added time-orbit design documentation for calculated time-bucket placement.
- Added full-demo smoke coverage through `scripts/demo_smoke.sh`, including
  stellar modeling, codec workflows, and locality workloads.
- Added cluster wire driver smoke coverage so the public driver protocol path
  is exercised as part of the all-smoke suite.

### Changed

- Centralized driver C ABI build instructions around `scripts/build_capi.sh`
  across README, driver docs, and compatibility scripts.
- Expanded GitHub Actions to build and check the C ABI path on Linux and macOS.
- Clarified benchmark wording so PostgreSQL, Redis, durability, persistence,
  and BGET comparisons do not imply stronger claims than the measured setup.
- Updated protocol, TLS, threat-model, query-safety, public API, status, and
  release-checklist documentation for the v0.7 hardening track.

### Fixed / Hardened

- Enabled `--panics:on` through `config.nims` so internal Defects do not become
  false success values across C ABI boundaries.
- Added persistent data-directory locking to fail closed when multiple
  processes try to open the same store.
- Hardened universe sync ack handling so source events are only pruned after
  accepted target statuses.
- Added universe sync retry/dead-letter behavior and remote sync recovery
  smoke coverage.
- Added bounded applied-event dedup replay for universe sync idempotency.
- Added server-side retrieve budget / scan guards so broad scans can be
  bounded and diagnosed instead of silently growing without limits.
- Added lock fencing-token persistence for opt-in ring and stellar locks.
- Expanded WAL, backup/restore, compact, transaction, atomic batch, locality,
  wire fuzz, authz, RBAC, TLS, recovery, and universe sync coverage.
- Bumped package metadata to `0.7.0`.

## v0.6.0 - 2026-07-16

### Added

- Added typed `KoutenFilterBuilder` helpers for safer read filters without
  string-concatenated JSON.
- Added locality validation workloads for interleaved, random, delete-heavy,
  backfill-heavy, and hot/cold write patterns, including compact-before/after
  read micro-samples.
- Added locality invariant checks so the same logical ring query must return
  the same ID/payload set before and after compaction while disk-span metrics
  are reported.
- Added topology remapping primitives: explicit arc tables, weighted arcs,
  deterministic virtual arcs, topology validation, and `remapFraction`.
- Added `docs/topology-remapping.md` to explain the boundary between remapping
  primitives and future online rebalance.
- Added `docs/use-case-recipes.md` with application recipes for list/detail,
  membership, inventory locks, webhook idempotency, SaaS tenant isolation,
  stellar neighborhoods, and RAG corpus layout.
- Added CLI connection config loading with `--config=FILE` and `KOUTEN_CONFIG`.
  Config can provide peers, auth, galaxy, and TLS defaults while command-line
  flags remain the override.

### Changed

- Updated technical FAQ and status documents to reflect that arc-table based
  remapping has a foundation, while live dynamic membership remains future
  work.
- Expanded CLI and configuration documentation for cluster/TLS connection
  defaults.

### Fixed / Hardened

- Expanded CLI smoke coverage to verify config-driven cluster health, put, and
  get workflows.
- Expanded core tests for explicit arc ownership, weighted arcs, virtual arc
  remap reduction, and malformed topology rejection.
- Expanded store locality tests to assert logical result preservation across
  delete/backfill/compact workloads.
- Bumped package metadata to `0.6.0`.

## v0.5.1

### Added

- Added `docs/technical-faq.md` for first-time database reviewers.
- Linked the Technical FAQ from the README and documentation index.

### Changed

- Documented KoutenDB's boundaries around partitioning, joins, secondary access
  paths, consistent-hashing-like owner mapping, physical locality, production
  readiness, and current best-fit workloads.
- Bumped package metadata to `0.5.1`.

## v0.5.0

### Added

- Added stellar locality lens workflows. Existing rings can be attached to or
  detached from a stellar coordinate, allowing related records to be read
  together without copying payloads.
- Added `readStellar` / `kouten get --stellar=...` workflows with `--subring`,
  filter, selection, and grouped ring output.
- Added embedded all-or-nothing bulk helpers:
  `batchPutAtomic`, `batchUpdateAtomic`, and `batchDeleteAtomic`.
- Added opt-in embedded cooperative coordinate locks:
  `acquireRingLock`, `acquireStellarLock`, `withRingLock`,
  `withStellarLock`, `releaseLock`, and `lockActive`.
- Added `docs/unique-data-model.md` and
  `examples/stellar_data_model_demo.sh` to demonstrate KoutenDB-specific
  ring/stellar data modeling.

### Changed

- Updated Redis, PostgreSQL, Docker-Docker, working-set, memory-pressure, and
  RAG benchmark documentation with the latest local verification numbers.
- Documented that benchmark helpers use fresh temporary KoutenDB/PostgreSQL
  data directories, fresh Docker containers where applicable, or unique Redis
  key prefixes that are deleted before exit.
- Expanded public API and test coverage documentation for high-integrity
  application workflows.
- Bumped package metadata to `0.5.0`.

### Fixed / Hardened

- Added matrix coverage for atomic batch commit/rollback, update/delete
  failure rollback, persistence replay, ring lock conflicts, stellar/member
  lock conflicts, disjoint lock coexistence, TTL expiry, and release on
  exception.
- Kept cooperative locks opt-in so ordinary `put`, `get`, `list`, and
  `retrieve` paths remain outside the lock-check path.

## v0.3.0

### Added

- Added the C ABI v2 `kouten_read_ring_json` entry point so external drivers can
  read ring-shaped pages with JSON filters, optional projection, sorting,
  cursor/page options, codec metadata, and a stable JSON response shape.
- Added explicit CLI examples for JSON, NIF, BIF, raw, and ring-profile
  `--codec=auto` payload workflows.
- Added `docs/test-coverage.md` to track the current unit, smoke, contract,
  recovery, cluster, universe sync, and driver compatibility test matrix.

### Changed

- Unified recent ring-oriented CLI read behavior around one page-shaped result
  for single and multiple records.
- Bumped package metadata to `0.3.0`.

### Fixed / Hardened

- Expanded public API coverage for `readRing` filtering, ID lookup, pagination,
  sorting defaults, sort aliases, empty-result behavior, and invalid sort
  rejection.
- Expanded codec coverage for JSON-compatible projection and NIF/BIF projection
  rejection.
- Expanded CLI smoke coverage for codec display, BIF base64/hex/adapter views,
  invalid filters, invalid sort fields, and invalid projection requests.
- Expanded the C ABI contract smoke with JSON projection, NIF/BIF metadata,
  invalid filter, invalid sort, and null-ring error checks.

## v0.2.5

### Fixed

- Restored the cluster read path after transaction landing-zone reads had added
  an avoidable request before ordinary `GET` / `BGET` operations.
- Kept read-your-writes behavior for accepted-but-not-yet-applied cluster
  writes by tracking only the pending IDs written through the current client.
- Fixed the benchmark stable-ring guard so full-period orbits are not
  misclassified as stable during cluster latency tests.

### Changed

- Updated PostgreSQL and Redis benchmark documentation with the 2026-07-08
  local retest results.
- Added comparison-friendly benchmark tables.
- Bumped package metadata to `0.2.5`.

## v0.2.4

### Added

- Added driver discovery and installation guidance through `kouten driver
  list`, `kouten driver info`, and `kouten driver install`.
- Added Rust driver install targeting for manifest path, project directory, and
  environment-variable based setup.

### Changed

- Removed the Rust driver implementation from the core repository so language
  drivers can be released from separate repositories.

## v0.2.3

### Fixed

- Removed the `koutend` selector `getData` path that triggered Nim's
  `ProveInit` warning during server builds.
- Bumped package metadata to `0.2.3`.

## v0.2.2

### Changed

- Updated installation documentation now that KoutenDB is available through
  Nimble.
- Clarified that non-Nim language packages remain repository-local foundations
  while `nimble install koutendb` is the normal Nim install path.
- Bumped package metadata to `0.2.2`.

## v0.2.1

### Changed

- Clarified CLI installation paths and documented `~/.nimble/bin` PATH setup.
- Added system install guidance for `/usr/local/bin/kouten` and
  `/usr/local/bin/koutend`.
- Added a dedicated installation page and linked it from README and the docs
  index.

## v0.2.0

### Added

- Added GitHub Pages documentation structure, public API/config/CLI references,
  and topology / universe sync guides.
- Added `bin/kouten` CLI workflows for CRUD, ring listing/counting, atlas, and a
  minimal interactive shell.
- Added Docker Compose demos for a single galaxy, a three-node galaxy, and a
  local/remote universe-shaped topology.
- Added remote universe sync smoke coverage for target downtime, restart
  recovery, applied-key persistence, and duplicate delivery idempotency.
- Added user-facing CLI error handling for wire/auth failures.

### Changed

- Tightened Docker demo builds with a small build context and explicit
  nimsodium/libsodium setup.
- Reworked recovery topology terminology around universes and galaxies.

## v0.1.5

### Changed

- Added README installation steps before the embedded-mode quickstart so new
  users can set up the repository before writing code.

## v0.1.4

### Changed

- Reduced public fault-tolerance roadmap details and kept detailed recovery
  strategy outside the public repository.

## v0.1.3

### Added

- Added `CONTRIBUTING.md` with a pre-1.0 contribution policy focused on
  real-world verification reports, operational evidence, benchmark results,
  recovery reports, and small documentation fixes.

## v0.1.2

### Changed

- Kept the ID-less lookup guidance inside the embedded quickstart instead of a
  separate README section.
- Added API reference documentation to the v0.2+ roadmap.

## v0.1.1

### Changed

- Documented how to look up records when the application does not already have a
  KoutenDB ID: start from a ring with `listByRing`, use ring-scoped `retrieve`
  for vector/RAG lookup, and use `atlas()` / ring descriptions to choose scope.

## v0.1.0 Technical Preview

Initial public technical preview target.

### Added

- Embedded KoutenDB API with memory-only and WAL-backed `open(dataDir=...)`
  modes.
- Ring / galaxy data model, ring hierarchy, galaxy and ring descriptions, and
  atlas output for LLM / agent navigation.
- `put`, `get`, `query`, `locate`, `retrieve`, `batchGet`, `listByRing`,
  `countByRing`, `update`, `patch`, and `deleteById` foundations.
- Append-only WAL with replay repair for torn tails and invalid record tails.
- Embedded atomic transactions and strong durability mode.
- Compact, backup / restore, encrypted backup / restore, dump, and JSONL import.
- Cluster PoC with static peer lists, deterministic locate, landing-intent
  transactions, owner crash/restart retry smoke, and read-your-writes fallback.
- Username/password authentication, secret-key gate, ring-prefix authorization,
  and minimal reader / writer / admin RBAC.
- Wire protocol hardening for malformed and oversized frames.
- Warp belt PoC: WAL-backed delayed patch queue with progress, retry state,
  ack, dead-letter state, cleanup, and idempotent patch behavior.
- Vector retrieval with exact backend and optional FAISS dynamic bridge.
- C ABI plus minimal Python, Node.js / TypeScript / Bun, Rust, Go, PHP, Swift,
  C#, C++, and Kotlin/JVM driver or wrapper foundations.
- Benchmark records for mechanism cost, cluster TCP, PostgreSQL reference,
  Redis smoke, working-set reduction, memory-pressure reduction, and RAG-style
  synthetic retrieval.
- Threat model, third-party notices, driver roadmap, release checklist, and
  Flow-series integration policy.

### Known Gaps

- TLS is not implemented; do not expose `koutend` directly on untrusted networks.
- Cluster membership is static, and node0 remains the landing coordinator.
- Cluster coordinator redundancy and epoch migration are not implemented.
- Server-side warp scheduling is not implemented.
- FAISS GPU backend is not planned for core.
- WASM / browser local-state support is planned for a later release.
- FlowBrigade / FlowLogbook adapters are post-v0.1 roadmap items rather than
  core v0.1.0 scope.
- Package publishing workflows are not complete.

### Positioning

KoutenDB v0.1.0 should be described as a technical preview / research OSS
release. Do not claim general replacement status for Redis, PostgreSQL,
MongoDB, or Apache Arrow. The current defensible claim is that KoutenDB can
reduce working-set size under documented synthetic conditions while local and
TCP read paths are being moved toward existing database speed bands.
