# Changelog

## Unreleased

### Changed

- Removed the optional FAISS bridge, fetch/build scripts, vendored-source
  metadata, and runtime backend selection API.
- Standardized vector retrieval on the dependency-free exact path: KoutenDB
  narrows candidates by ring before cosine ranking instead of maintaining a
  second global vector index.
- Reworked the vector benchmark to compare broad and ring-scoped exact
  retrieval directly.

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
