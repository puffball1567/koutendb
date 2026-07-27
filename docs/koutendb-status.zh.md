# KoutenDB 状态 / 路线图

本文档是参考翻译。英文版 [koutendb-status.md](./koutendb-status.md) 是正本，
本翻译可能滞后。

Release checklist: [release-checklist.md](./release-checklist.md)

## Core DB

| Feature | Status | Notes |
|---|---|---|
| Embedded DB | Done | `open(dataDir=...)` and memory-only mode |
| put / get | Done | Ring-scoped writes and ID-based reads |
| ORM foundation API | Done | Foundation for `update`, JSON `patch`, `deleteById`, `listByRing`, `countByRing`; driver exposure is still pending |
| Warp belt | PoC | WAL-backed delayed patch queue with minimal retry / ack / dead-letter state |
| JSON document query | Done | GraphQL-style selection |
| Vector retrieve | Done | Dependency-free exact ranking runs after ring-scoped candidate reduction |
| Ring / hierarchy | Done | `ring = "a/b/c"` and child-ring expansion |
| Galaxy isolation | Done | Separate data dir / peer list / credential boundary |
| Atlas / ring map | Done | `atlas()` and `kouten atlas` |
| Retrieval tuning profile | Done | amount / scope / depth |
| WASM browser embedded | Post-v0.1 candidate | Browser state boundary / IndexedDB / OPFS |

## Persistence / Operations

| Feature | Status | Notes |
|---|---|---|
| Append-only WAL | Done | Batched flush by default; strong durability adds flush + fsync |
| Reopen recovery | Done | Items / vectors / ring metadata / descriptions |
| Transaction | Done | Embedded atomic transaction |
| Cluster transaction landing | PoC | node0 landing with failure retry smoke |
| Compact | Done | Rebuilds WAL from live records |
| Backup / restore | Done | Backup as compacted WAL and restore into another data dir |
| Dump / import-jsonl | Done | NoSQL JSONL import rules |
| Crash recovery tests | Partial | Torn WAL tail, compact interruption, partial commit |
| Core test suite | Done | `scripts/test_core.sh` |
| Full smoke suite | Done | `scripts/test_all_smoke.sh` |
| Kubernetes manifests | Planned | liveness/readiness, PVC, rolling restart |

## Cluster / Network

| Feature | Status | Notes |
|---|---|---|
| Static cluster | Done | `koutend --id --peers` |
| Deterministic locate | Done | `E(id,t) -> node` |
| Handoff / forwarder | PoC | Slow tick integration exists |
| Driver-friendly wire | Done | `PUTR/GETID/QRYID` |
| Authn + secret key | Done | username/password/secret-key |
| Authz / RBAC | PoC | Ring prefix authz and role matrix smoke |
| Wire fuzz smoke | Done | Malformed frame cases |
| Dynamic membership | Planned | Current peer list is static |
| TLS | Done | Standard TLS transport is implemented; see the English canonical document for details |

## Drivers / Bindings

| Target | Status | Notes |
|---|---|---|
| Nim API | Done | Native public API |
| C ABI | Done | ABI version / last error / put/get/retrieve/batch/atlas |
| Python | Done | Native wire minimal |
| Node.js / TypeScript / Bun | Partially published | npm `koutendb` v0.1.3. Bun remains experimental |
| Rust | Published | crates.io `koutendb` v0.1.3; see the English canonical document for links |
| Go | Done | C ABI wrapper minimal |
| PHP / Swift / Kotlin | Done | Docker smoke available |
| C# / C++ | Done | OSS generic wrappers; Unity / Unreal official assets are separate candidates |
| React Native / WASM | Post-v0.1 candidate | Browser / local state boundary |
| Driver discovery CLI | Done | `kouten driver list/info/install` prints official driver metadata and setup commands without executing remote scripts |
| Package publishing | Partial | `nimble install koutendb`, `cargo add koutendb`, `npm install koutendb`, `composer require koutendb/koutendb`, and `python3 -m pip install koutendb` are available. Other registries remain future work |

## Benchmarks / Demos

| Item | Status | Notes |
|---|---|---|
| Working-set bench | Done | scanned/query reduction |
| Memory-pressure bench | Done | candidate memory/query |
| RAG-style bench | Done | recall retained while tokens/query are reduced |
| AI/RAG JSONL case study | Done | deterministic multi-ring JSONL corpus |
| PostgreSQL / Redis comparison | Done | documented smoke/reference measurements |
| Cluster failure retry smoke | Partial | owner kill/restart retry |
| Multi-node cloud case study | Planned | VM/AZ, latency, failover |

## Security / Safety

| Item | Status | Notes |
|---|---|---|
| Username/password auth | Done | koutend and driver path |
| Secret key gate | Done | ID/password alone can be insufficient |
| nimsodium encryption primitive | Partial | auth transport; scope may expand |
| Galaxy isolation | Done | limits blast radius by galaxy |
| Backup encryption | Done | nimsodium secretbox |
| Threat model | Draft | [threat-model.md](./threat-model.md) |

## v0.1 后路线图候选

这些是 v0.2 及后续版本的候选项，并不表示全部都属于单一 v0.2.0 里程碑。

- WASM browser embedded
- IndexedDB / OPFS persistence
- React hooks / browser state boundary
- React Native / WASM local state module
- Unity official asset
- Unreal official plugin
- package publishing workflows for language drivers
