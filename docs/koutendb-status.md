# KoutenDB Status / Roadmap

This is the canonical English status document. Translations are secondary
references and may lag behind this file.

Release checklist: [release-checklist.md](./release-checklist.md)

Current release evidence: [v0.12.1 release notes](./github-release-v0.12.1.md)

Current persistence-cycle record: [v0.12 implementation and validation](./v0.12-roadmap.md)

Current development record: [v0.13 coordinator redundancy](./v0.13-roadmap.md)

Historical planning reference: [v0.10 roadmap](./v0.10-roadmap.md)

Translations:

- Japanese: [koutendb-status.ja.md](./koutendb-status.ja.md)
- German: [koutendb-status.de.md](./koutendb-status.de.md)
- French: [koutendb-status.fr.md](./koutendb-status.fr.md)
- Chinese: [koutendb-status.zh.md](./koutendb-status.zh.md)
- Korean: [koutendb-status.ko.md](./koutendb-status.ko.md)

## Core DB

| Feature | Status | Notes |
|---|---|---|
| Embedded DB | Done | `open(dataDir=...)` and memory-only mode |
| put / get | Done | Ring-scoped writes and ID-based reads |
| ORM foundation API | Done | Embedded APIs plus cluster PoC for `update`, JSON `patch`, `deleteById`, `listByRing`, `countByRing`; canonical data is expected to live in one galaxy/ring, with alternate views handled by ring hierarchy, naming, import rules, and retrieval profiles; driver exposure is still pending |
| Warp belt | PoC | WAL-backed delayed patch queue: `enqueueWarp`, `warpStep`, `warpDrain`; scans specified rings in registration order and drops merge patches onto matching JSON documents; includes minimal attempts / retryAt / maxAttempts / ack / dead-letter state plus acked-job cleanup; FlowBrigade and FlowLogbook adapters are planned instead of core dependencies; server scheduling is still pending |
| JSON document query | Done | GraphQL-style selection |
| Payload codecs | PoC | Per-record `raw` / `json` / `nif` / `bif` metadata survives WAL, cluster transport, handoff, transactions, Universe sync, and retrieval. NIF/BIF encoding/decoding remains outside the core; optional adapter: [`koutendb-nif`](https://github.com/puffball1567/koutendb-nif) backed by [`nifkit`](https://github.com/puffball1567/nifkit) |
| Prepared selection | Done | Reusable validated projection tree in embedded mode plus a bounded server-side parse cache for cluster queries |
| Vector retrieve | Done | Dependency-free exact ranking runs after ring-scoped candidate reduction |
| Ring / hierarchy | Done | `ring = "a/b/c"` and child-ring expansion |
| Galaxy isolation | Done | Separate data dir / peer list / credential boundary |
| Atlas / ring map | Done | `atlas()` and `kouten atlas` |
| Galaxy/ring description | Done | Atlas map annotations, not payload text |
| Time orbit | PoC | Embedded ring-local 60-bit millisecond orbit for log/event/time-series placement. Includes persisted profiles, `putTime` / `readTime`, and `kouten time-orbit/time-put/time-get`; cluster profile administration is still pending. Design note: [time-orbit.md](./time-orbit.md) |
| Retrieval tuning profile | Done | amount / scope / depth |
| Retrieval planner | PoC | Deterministic heuristic planner. Stronger planner claims require larger real-corpus benchmarks and further tuning |
| WASM browser embedded | Post-v0.1 candidate | Browser state boundary / IndexedDB / OPFS |

## Persistence / Operations

| Feature | Status | Notes |
|---|---|---|
| Append-only WAL | Done | Batched flush by default; `durStrong` / `--durability=strong` adds flush + fsync write boundaries. New WAL files use a magic/version header and per-record length + CRC32 wrappers; legacy pre-v1.0 WAL remains readable for migration |
| Reopen recovery | Done | Items / vectors / ring metadata / descriptions |
| Operational verify | Foundation | `operationalVerify(dataDir)` and `kouten verify --data=DIR` open/replay a persistent store and report WAL, metadata, segment, and locality health. `--max-wal-bytes`, `--max-segment-files`, `--max-items`, and `--max-rings` add operator-defined capacity thresholds. `kouten verify --backup=DIR` verifies backup readability. `kouten doctor --data=DIR` / `--backup=DIR` use the same operational paths |
| Transaction | Done | Embedded atomic transaction plus all-or-nothing `batchPutAtomic`, `batchUpdateAtomic`, and `batchDeleteAtomic` helpers |
| Cooperative coordinate locks | Done | Embedded opt-in `ring` and `stellar` locks for high-integrity workflows; normal NoSQL read/write paths do not check locks |
| Cluster transaction landing | Foundation | A configured primary synchronously mirrors durable intent to a standby before acknowledgement. Epoch-fenced explicit promotion recovers pending intents without adding consensus to ordinary ring-local writes. `scripts/coordinator_failover_smoke.sh` covers owner failure, primary crash, quorum refusal, promotion, convergence, and stale-primary rejection. |
| Cluster CRUD/list/count | PoC | `update`, `deleteById`, JSON `patch`, `listByRing`, `countByRing` use landing intents or node fan-out; `scripts/cluster_tx_smoke.sh` covers smoke |
| Compact | Done | Rebuilds WAL from live records |
| Backup / restore | Done | Backup as compacted WAL and restore into another data dir |
| Drain / snapshot barrier | Foundation | `DRAIN`, `SNAPSHOT`, and `RESUME` provide an admin-only maintenance boundary for cluster nodes. Drain is persisted across restart, rejects new writes while preserving read access and wire framing, and is required by explicit scale-in and coordinator promotion. Snapshot flushes and reports item/ring/pending-tx/WAL state. Managed backup orchestration remains planned. |
| Dump / import-jsonl | Done | NoSQL JSONL import rules. This is the stable human-readable migration boundary while the pre-v1.0 internal WAL format can still evolve |
| Universe sync outbox | PoC | WAL-backed eventual sync event queue with idempotent apply, ack/prune, transaction-backed `putSynced`, prune-safe monotonic source ids, latest-only pending coalescing, delayed timestamp apply windows, retryAt / maxAttempts / dead-letter state, `kouten universe-export` / `universe-apply` JSONL handoff, one-shot `kouten universe-sync` between local data dirs, remote `--peers` delivery via `UAPPLY`, and `universe-status` operational counters. It is a durable scheduler boundary, not immediate global consistency |
| Crash and storage-failure tests | Foundation | Torn WAL tail repair, checksum/mid-file corruption refusal, compact interruption, partial commit cases, nine real `SIGKILL` publication boundaries, injected disk-full/short writes, permission loss, missing generations, damaged manifests, and index-only corruption. Power-loss/device-controller fault coverage remains external validation work |
| Strong durability / fsync knob | Done | `open(dataDir=..., durability=durStrong)` and `koutend --durability=strong`; store/API tests cover reopen, transaction, compact |
| Core test suite | Done | `scripts/test_core.sh` runs orbital core, selection, field, store, and public API tests |
| Full smoke suite | Done | `scripts/test_all_smoke.sh` runs core tests plus cluster tx, failure retry, authz, wire fuzz, recovery, and remote universe sync smoke; driver compatibility is opt-in |
| Generation snapshot / checkpoint | Foundation | Immutable `koutendb-checkpoint-v1` generations bind a compact WAL to complete ring segment/index generations through a checksummed manifest and completion marker. Creation, strict verification, listing, fail-safe retention, and atomic-directory restore are exposed through Nim, CLI, and additive C ABI v2 JSON functions. Continuous PITR and managed scheduling remain planned |
| Kubernetes manifests | Planned | liveness/readiness, PVC, rolling restart |

## Cluster / Network

| Feature | Status | Notes |
|---|---|---|
| Static cluster | Done | `koutend --id --peers` |
| Deterministic locate | Done | Logical `L(id,t)` remains available for orbital planning; physical `P(ringKey, topologyEpoch)` provides stable server ownership |
| Handoff / forwarder | Foundation | Physical migration is explicit, version-checked, destination-topology-fenced, bounded per tick, retried after failure, and independent of logical orbit frequency. Fully automated membership orchestration is not done |
| Driver-friendly wire | Done | `PUTR/GETID/QRYID`; `WIREVER` exposes the current protocol version and `CODECS` exposes payload formats. Compatibility policy is documented in `docs/protocol-compatibility.md` |
| Health / metrics / rings | Done | CLI and wire protocol; legacy key/value plus Prometheus/OpenMetrics text. Metrics include uptime, request/error/auth counters, connection counts, WAL bytes, warp backlog, universe apply counters, cluster tx backlog, storage/ring counts, physical/scored retrieval work, segment/WAL fallback reasons, maintenance state, and aggregate checkpoint health. Default labels exclude ring names and checkpoint IDs. |
| Authn + secret key | Done | username/password/secret-key; unusable credential combinations fail at startup |
| TLS | Done | Standard TLS transport for `koutend` and CLI/client connections when built with `-d:ssl`; `scripts/cluster_tls_smoke.sh` covers authenticated TLS, secret-key transport, JSON put/get, and plain-client rejection |
| Authz / RBAC | PoC | `koutend --allow-ring=prefix[,prefix...]` and `--role=user:password:reader|writer|admin[:prefixes]`; `scripts/cluster_authz_smoke.sh` and `scripts/cluster_rbac_smoke.sh` cover prefix and role matrix behavior |
| Wire fuzz smoke | Done | `scripts/cluster_wire_fuzz_smoke.sh` runs deterministic malformed-frame cases, including oversized headers and deep JSON, and verifies the cluster stays healthy |
| Server resource guardrails | Foundation | Accepted sockets have receive/send deadlines and a fixed active-connection cap; rejected admission has a dedicated counter and plain connections receive `ERR overloaded`. Ring-list pages and retrieval work are bounded. `scripts/concurrency_backpressure_smoke.sh` covers slow input/output, admission recovery, concurrent readers/writers, automatic maintenance, metrics/snapshot barriers, and offline reopen. Per-tenant quotas remain planned |
| Embedded write guardrails | Foundation | Opt-in `KoutenGuardrails` can cap payload bytes, vector dimension, ring count, and records per ring for production trials; default zero values preserve existing behavior |
| Bounded server retrieve | Done | `koutend` keeps only the current top candidates up to request budget. Ring-scoped retrieval routes to the calculated owner and walks the ring index; only global retrieval scans every node |
| Dynamic membership / epoch migration | Foundation | Scale-out supports a write-quiesced, one-node-at-a-time restart into a higher persisted placement epoch. Persistent drain, topology-fenced admin migration, cluster-wide activation preflight, bounded handoff, and source retention prevent mixed-epoch write acknowledgement. Explicit stop-the-world scale-in adds durable checkpoints, version/tombstone and metadata preservation, and independent verification. Live-write topology changes, in-place/live scale-in, and discovery orchestration remain unsupported and fail closed |
| Cluster transaction coordinator redundancy | Foundation | Configurable primary/standby, durable intent mirroring, epoch-fenced apply, majority-gated explicit promotion, client discovery, metrics, and a crash/recovery matrix. Automatic failover and dynamic service discovery are intentionally not included. |
| Read-your-writes for cluster tx | Foundation | `get/query/batchGet` discover the active coordinator and fall back to its landing intent before owner apply; cluster smoke covers update/delete and coordinator promotion. |
| Fault-tolerance improvements | Planned | Post-v0.1 work; universe sync outbox is now the first durable eventual-convergence primitive |
| Multi-VM / multi-AZ benchmark | Planned | Real-world latency and failure behavior |

## Drivers / Bindings

| Target | Status | Notes |
|---|---|---|
| Nim API | Done | Native public API |
| C ABI | Done | ABI version / last error / put/get/retrieve/batch/atlas plus additive codec-aware put/get calls; C ABI vectors are host-native float arrays, while TCP wire vectors are canonical little-endian float32 |
| JavaScript / TypeScript | Published | npm [`koutendb` v0.1.5](https://www.npmjs.com/package/koutendb); repository [`puffball1567/koutendb-js`](https://github.com/puffball1567/koutendb-js); Node-API C ABI wrapper with TypeScript API |
| Bun | Partial | The npm package uses Node-API and includes Bun compatibility verification, but Bun support remains experimental |
| Rust | Published | crates.io [`koutendb` v0.1.6](https://crates.io/crates/koutendb); repository [`puffball1567/koutendb-rust`](https://github.com/puffball1567/koutendb-rust); C ABI wrapper |
| Python | Published | PyPI [`koutendb` v0.2.1](https://pypi.org/project/koutendb/); repository [`puffball1567/koutendb-python`](https://github.com/puffball1567/koutendb-python); native TCP wire driver |
| Go | In-tree only | Minimal C ABI wrapper; no Go module or external driver repository has been published |
| PHP | Published | Packagist [`koutendb/koutendb` v0.1.3](https://packagist.org/packages/koutendb/koutendb); repository [`puffball1567/koutendb-php`](https://github.com/puffball1567/koutendb-php); FFI / C ABI wrapper with Docker smoke |
| Swift | In-tree only | SwiftPM-compatible C ABI wrapper with Linux Docker smoke; no SwiftPM package has been published |
| C# minimal | In-tree only | Generic C# wrapper; no NuGet package has been published. Unity official asset is separate |
| C++ | Released | Repository [`puffball1567/koutendb-cpp` v0.1.3](https://github.com/puffball1567/koutendb-cpp); C++17 C ABI wrapper with CMake smoke; Unreal official plugin is separate |
| Kotlin-first JVM | In-tree only | JNI / C ABI wrapper with Docker smoke; no Maven package has been published |
| React Native / WASM local state | Post-v0.1 candidate | Browser / React Native state boundary; handled with the WASM line, not before Kotlin |
| Driver discovery CLI | Done | `kouten driver list/info/install` prints official driver metadata and setup commands without executing remote scripts |
| Driver compatibility test suite | Partial | `scripts/driver_compat.sh`; Docker-backed PHP / Swift / Kotlin are opt-in and verified |
| Package publishing | Partial | `nimble install koutendb`, `cargo add koutendb`, `npm install koutendb`, `composer require koutendb/koutendb`, and `python3 -m pip install koutendb` are available. NuGet, Maven, Go, SwiftPM, and other registry packages remain future work |

## Benchmarks / Demos

| Item | Status | Notes |
|---|---|---|
| Working-set bench | Done | scanned/query reduction |
| Memory-pressure bench | Done | estimated candidate memory/query |
| RAG-style bench | Done | recall retained while tokens/query are reduced |
| AI/RAG JSONL case study | Done | `examples/ai_rag_case_study.sh` generates a deterministic multi-ring JSONL corpus, imports it, and compares global / routed / wrong-ring retrieval |
| PostgreSQL comparison | Done | Limited reference comparison |
| Redis comparison | Done | Smoke test with conditions and limits documented |
| C ABI bench | Done | `examples/cbench.c` |
| Docker case study | Partial | memory pressure / PHP / Swift smoke plus `examples/compose/operational-trial.compose.yml` for server JSON config loading, authenticated persistent startup, live health, offline verify, backup verification, and audit JSONL inspection |
| Unique data model demo | Done | `examples/stellar_data_model_demo.sh` demonstrates separate rings, stellar attach/detach, narrowed reads, and non-copy visibility changes |
| Cluster transaction smoke | Foundation | `scripts/cluster_tx_smoke.sh` verifies normal apply/retrieve; `scripts/coordinator_failover_smoke.sh` verifies durable standby failover and fencing. |
| Cluster failure retry smoke | Foundation | `scripts/cluster_failure_smoke.sh` covers owner restart; the coordinator matrix additionally covers primary crash, promotion, pending-intent replay, and stale-primary rejection. |
| Universe sync demo | Done | `examples/universe_sync_demo.sh` builds a small source/target pair, demonstrates API-level sync, then demonstrates the CLI export/sync/prune boundary. `scripts/universe_sync_failure_smoke.sh` verifies malformed JSONL handling, replay idempotency, and explicit ack/prune. `scripts/universe_sync_remote_smoke.sh` verifies remote `--peers` delivery and target-down retry behavior |
| Payload codec demos | Done | `examples/payload_codecs_demo.sh` covers embedded persistence and prepared selection; `examples/payload_codecs_cluster_demo.sh` covers codec negotiation and legacy wire-header compatibility |
| Crash / failure case study | Partial | Store-level WAL tail repair, mid-file WAL corruption refusal, compact interruption, partial commit, and cluster owner crash/restart retry are covered |
| Multi-node cloud case study | Planned | VM/AZ, latency, failover behavior |
| Prometheus / OpenMetrics output | Done | Nim, CLI, and additive C ABI surfaces share one bounded-label formatter. HTTP serving and vendor-specific collectors remain deployment concerns outside the database process. |
| State boundary demo | Post-v0.1 candidate | browser/RN local-global state demo |

## Security / Safety

| Item | Status | Notes |
|---|---|---|
| Username/password auth | Done | koutend and driver path; user without password fails closed |
| Secret key gate | Done | ID/password alone can be insufficient; secret-key without user/password fails closed |
| nimsodium encryption primitive | Partial | Used for auth transport; scope may expand |
| Galaxy isolation | Done | Limits blast radius by galaxy |
| TLS | Done | Standard TCP transport TLS is implemented for `-d:ssl` builds; certificate rotation and managed CA workflows remain operational work |
| Ring/galaxy authz | PoC | Ring prefix authorization is implemented for named-ring wire operations; richer role policy is pending |
| Backup encryption | Done | `backupEncrypted` / `restoreEncryptedBackup` and `kouten backup-encrypted` / `restore-encrypted` use nimsodium secretbox |
| General audit log | Foundation | Persistent embedded stores append `kouten.audit.jsonl` for direct write/update/delete, backup, restore, compact, and guardrail denial events. Persistent `koutend` nodes also append auth success/failure, authz denial, and retrieve/broad-scan denial events. Full enterprise audit policy remains planned |
| Threat model document | Draft | `docs/threat-model.md` covers assets, trust boundaries, current controls, and known gaps |

## Post-v0.1 Roadmap Candidates

These are candidates for v0.2 and later releases. They are not all scoped to a
single v0.2.0 milestone.

- WASM browser embedded
- IndexedDB / OPFS persistence
- React hooks / browser state boundary
- React Native / WASM local state module
- Unity official asset
- Unreal official plugin
- package publishing workflows for remaining language drivers
- API reference documentation
- Datadog/CloudWatch deployment collectors and managed dashboards
- Fault-tolerance improvements

## Managed Service Readiness Gaps

KoutenDB should be able to become a managed service in the same operational
category as hosted cache, document, search, or AI-context databases. Some
managed-service requirements are already expressible through KoutenDB concepts:
replication-style redundancy maps to universes, logical isolation maps to
galaxies, read scope maps to rings, and backup verification maps to recovery
universes.

The following items are the remaining implementation candidates that are not
fully covered by the current concepts or code:

| Candidate | Why it is needed |
|---|---|
| Durable eventual universe sync | Universes currently cover recovery topology. A managed service also needs live delayed convergence between same-name galaxies across universes without global commit waits. |
| Ring apply policy | Managed deployments need per-ring behavior such as latest-only, append-only, bounded-history, and delayed timestamp apply. This keeps consistency rules explicit without making the whole DB strongly serializable. |
| Read-your-writes across local pending state | Local users should not feel universe-sync delay. The cluster landing-intent fallback is a start; universe-level pending overlays are still missing. |
| Dynamic node replacement | Managed services must replace failed or upgraded nodes without manual peer-list surgery. Current clusters use static peers. |
| Automated coordinator orchestration | Fenced primary/standby promotion is implemented. A managed service still needs health policy, operator approval, config rollout, and service discovery around that explicit boundary. |
| TLS and certificate rotation | Username/password/secret-key auth exists, but managed public or VPC deployments need transport TLS and rotation workflows. |
| Secret rotation | `authProfiles` reference external secrets, but the server and drivers need an explicit rotation story for username/password/secret-key credentials. |
| Point-in-time recovery / generation checkpoints | Backup/restore exists. Managed services normally require recoverable generations, restore-point selection, and verification before promotion. |
| Managed drain / quiesce orchestration | The server has admin-only `DRAIN` / `SNAPSHOT` / `RESUME` primitives. Managed services still need rolling orchestration, promotion policy, and backup scheduling around those primitives. |
| CloudWatch / Datadog managed integrations | KoutenDB emits Prometheus/OpenMetrics text, but provider-managed collection, dashboards, and alert policy remain deployment work. |
| Quotas and capacity guardrails | Galaxy isolation exists, but managed multi-tenant operation needs limits for WAL bytes, item count, ring count, payload size, and connection pressure. |
| Protocol / storage compatibility policy | Managed upgrades need clear compatibility rules for wire protocol, WAL records, snapshots, and drivers. |

These gaps define the boundary between a promising server database and a
provider-ready managed database. KoutenDB should not copy every Redis, RDS, or
ElastiCache mechanism one-to-one; it should provide equivalent operational
outcomes where KoutenDB's universe / galaxy / ring model already gives a simpler
or more natural shape.
