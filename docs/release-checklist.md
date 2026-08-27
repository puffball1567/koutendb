# KoutenDB Release Checklist

This is the canonical release checklist for the public KoutenDB repository.
The current automated test coverage matrix is tracked in
[Test Coverage](test-coverage.md).

## Required Before v1.0 RC

The detailed gates and evidence rules are defined in
[v1.0 Stabilization](v1-stabilization.md).

| Area | Required Item | Status |
|---|---|---|
| Human evaluation | Complete the public install, CRUD, reopen, migration, backup, and restore path from a clean environment | Documentation ready; independent run pending |
| Maintainer dogfooding | Use KoutenDB through a maintained application and keep an operation/incident journal | Pending |
| Service trial | Run a useful persistent service with real application traffic, monitoring, verified backups, and recovery drills | Pending |
| Stable surface | Name the v1.x API, CLI, configuration, storage, migration, wire, and C ABI contracts | Pending final freeze |
| Experimental surface | Label features outside the v1.x compatibility promise consistently | Pending review |
| Upgrade matrix | Exercise maintained historical fixtures, JSONL migration, supported drivers, wire negotiation, and fail-closed boundaries | Partial; historical storage fixtures exist |
| Recovery matrix | Re-run crash, corruption, storage-failure, checkpoint, coordinator, TLS/auth, and restore tests on the RC commit | Existing coverage; final RC run pending |
| Operations | Publish redacted service evidence with metrics, incidents, restore results, and exclusions | Pending |
| Documentation | A new operator can install, evaluate, operate, troubleshoot, and recover without implementation knowledge | In progress |
| Release blockers | No open issue violates the declared stable v1.0 contract | Pending RC review |

## v0.2.0 Positioning

Release v0.2.0 as a technical preview / research OSS release with stronger
operational demos and Universe sync coverage.

Recommended wording:

```text
KoutenDB v0.2.0 Technical Preview
A ring/galaxy-oriented document and vector database prototype focused on
smaller working sets, durable recovery boundaries, and eventual universe sync.
```

Avoid claiming that KoutenDB is generally faster than Redis, PostgreSQL, or
Apache Arrow. The current defensible claim is narrower:

```text
Local reads are being moved toward existing database speed bands, while
RAG-style synthetic benchmarks show reduced scanned candidates and token input
under the documented conditions. v0.2 adds stronger operational and sync
validation for evaluation.
```

## v0.1.0 Positioning

Release v0.1.0 as a technical preview / research OSS release.

Recommended wording:

```text
KoutenDB v0.1.0 Technical Preview
A ring/galaxy-oriented document and vector database prototype focused on
reducing working-set size for retrieval-heavy systems.
```

Avoid claiming that KoutenDB is generally faster than Redis, PostgreSQL, or
Apache Arrow. The current defensible claim is narrower:

```text
Local reads are being moved toward existing database speed bands, while
RAG-style synthetic benchmarks show reduced scanned candidates and token input
under the documented conditions.
```

## Required Before v0.1.0

| Area | Required Item | Status |
|---|---|---|
| Core tests | `scripts/test_core.sh` passes | Done |
| WAL recovery | Versioned WAL magic/checksum, checksum mismatch refusal, torn-tail, invalid length, invalid vector dim, mid-file corruption refusal, partial transaction tests pass | Done |
| Migration boundary | `kouten dump` / `kouten import-jsonl` round-trip KoutenDB JSONL across data directories and preserve ring, payload, vector, and codec metadata | Done |
| C ABI library | `scripts/build_capi.sh` is the canonical build and includes `-d:ssl`; CA-verified C ABI TLS smoke passes | Done |
| Warp belt | WAL persistence, reopen recovery, ack cleanup, idempotent patch behavior | Done |
| Cluster smoke | tx / failure retry / authz fail-fast / RBAC / wire fuzz smoke scripts pass locally | Done |
| Exact retrieval | Ring-scoped exact retrieval and candidate-reduction metrics are documented and reproducible | Done |
| Drivers | Driver status table is accurate and does not overclaim package publication | Done |
| Bench docs | Benchmark conditions, limitations, Redis/PostgreSQL wording, and environment are consistent | Done |
| AI/RAG case study | Generated JSONL corpus is imported and measured with global / routed / wrong-ring retrieval | Done |
| Security docs | Threat model and third-party notices are present | Done |
| License docs | Core license and third-party dependency licenses are clear | Done |
| Generated files | Test binaries and temporary outputs are not included in release artifacts | Done; build/test binaries are ignored or removed |

## Recommended Before v0.1.0

| Area | Item |
|---|---|
| Release notes | Done: `CHANGELOG.md` and `docs/github-release-v0.1.0.md` |
| Docker | Done: Docker-backed PHP / Swift / Kotlin smoke passed locally |
| Cluster | Done: local 3-node smoke scripts passed locally |
| Docs | Done: README links to status, benchmark, threat model, driver roadmap, and release draft |
| Examples | Done: cluster demo passed locally; core tests cover embedded usage |
| AI/RAG demo | Done: `examples/ai_rag_case_study.sh` passed locally |
| Package metadata | Done: `koutendb.nimble` version / description / license checked |
| CLI CRUD | `kouten --help`, `put/get/query/list-ring/count-ring`, and minimal `kouten shell` are available for embedded smoke usage | Done |

## Required Before v0.2.0

| Area | Required Item | Status |
|---|---|---|
| Universe sync | Local data-dir sync and remote `--peers` delivery pass smoke tests | Done |
| Universe sync failure | Target-down retry keeps source outbox pending and later applies / acks / prunes | Done |
| Universe sync JSONL failure | Malformed JSONL rows are counted, valid rows still apply, replay is idempotent, and source ack/prune remains explicit | Done |
| Universe sync observability | Remote apply status and process-local apply/error counters are exposed through `universe-status --peers --metrics` | Done |
| Universe sync authz/fuzz | `UAPPLY` authz, idempotency, malformed frame, oversized body, and invalid JSON cases pass | Done |
| Universe sync restart | Remote target restart preserves applied keys, and duplicate delivery is skipped after restart | Done |
| TLS transport | `scripts/cluster_tls_smoke.sh` passes for CA-verified TLS health, authenticated put/get, and plain-client rejection | Done |
| Protocol compatibility | `WIREVER` exists and protocol compatibility notes document versioning and wire vector byte order | Done |
| Driver byte order | C ABI versus TCP wire vector endian contract is documented | Done |
| Documentation site | GitHub Pages workflow plus API / config / CLI entry pages exist under `docs/` | Done |
| Docker Compose demos | Single galaxy, three-node galaxy, and local/remote universe demos build, start, pass health checks, and cleanly stop | Done |
| CLI usability | CRUD, shell, help, and user-facing auth error smoke checks pass | Done |
| Package metadata | `koutendb.nimble` is valid and versioned for v0.2.0 | Done |
| Nimble CLI entrypoint | `src/kouten.nim` builds the user-facing `kouten` command for Nimble installs | Done |
| Production boundary | README/status/design distinguish implemented TLS, audit foundation, and coordinator redundancy from remaining certificate lifecycle and mixed-version work | Done |
| Planner boundary | Heuristic planner status and benchmark dependency are documented | Done |

## Explicitly Not Required For v0.1.0

These are important, but should not block the first technical preview:

- certificate lifecycle automation for public-network deployments
- dynamic cluster membership
- automatic coordinator failover orchestration
- multi-VM / multi-AZ benchmark
- WASM browser build
- FlowBrigade / FlowLogbook adapter
- enterprise plugin features
- remaining package publication to PyPI / Composer / NuGet / Maven / Go / SwiftPM
- fault-tolerance improvements
- cluster repair and integrity verification

## Post-v0.1 Direction

The post-v0.1 roadmap should focus on integration and operational maturity.
The items below are candidates for v0.2 and later releases, not a promise that
all of them fit into v0.2.0:

- `koutendb-flow` adapter
- FlowBrigade-backed retry / backoff / lock / rate limit for warp belt
- FlowLogbook-compatible warp attempt and ack history
- server-side warp scheduler
- browser / WASM local-state boundary
- stronger cluster operational stories
- package publication workflows
- API reference documentation
- Prometheus / OpenMetrics and Datadog metrics adapters

## Final Release Gate

Before tagging:

1. Run core tests.
2. Run `scripts/test_all_smoke.sh`.
3. Confirm `scripts/disk_backed_recovery_smoke.sh` completes all configured
   `SIGKILL` rounds with paired records after forced process termination, pack,
   compact, and backup/restore.
4. Run Docker Compose demo checks from `examples/compose/README.md`.
5. Run selected Docker-backed driver smoke tests when Docker capacity allows.
6. Run `nimble check`.
7. Run `scripts/cluster_wire_driver_smoke.sh`.
8. Run `scripts/demo_smoke.sh`.
9. Review benchmark wording.
10. Review license and third-party notices.
11. Remove generated binaries and temporary artifacts.
12. Confirm README and status docs describe the current release accurately.
13. Prepare the `nim-lang/packages` PR after the release tag exists.
