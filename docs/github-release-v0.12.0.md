# KoutenDB v0.12.0

KoutenDB v0.12.0 strengthens persistent operation with bounded automatic
maintenance, verified generation checkpoints, production-facing metrics, and a
completed 72-hour strong-durability cluster run.

## 72-Hour Release Gate Passed

The v0.12 release candidate completed a local three-node, disk-backed,
strong-durability run with:

- **72 hours of continuous mixed operation**
- **4,213,187 completed operations**
- **zero client errors**
- **164,053 committed and applied cluster transactions**
- **zero pending transactions and zero queued handoff work at shutdown**
- **zero global retrieval requests and zero segment-to-WAL fallbacks**
- **successful offline verification of every source and restored store**
- **exact source-to-restored JSONL equality on all three nodes**

The workload covered writes, updates, deletes, historical backfills, point
reads, projections, bounded ring reads, stellar reads, ring-scoped vector
retrieval, metrics, automatic packing, checkpoint creation, restore, and queue
convergence. See [Soak Testing](soak-testing.md) for the complete workload,
counters, latency telemetry, and recovery evidence.

## Bounded Automatic Maintenance

v0.12 adds opt-in automatic ring packing with explicit limits for selected
rings, rewritten bytes, elapsed time, maintenance windows, and stale-data
thresholds. Operators can inspect the same decision model through plan, run,
status, dry-run, CLI, Nim API, and C ABI paths.

Maintenance remains bounded and observable. Stable reason codes explain why a
ring was selected, skipped, interrupted, or served through WAL fallback.

## Verified Generation Checkpoints

Generation checkpoints now seal a compact WAL and complete ring-local
segment/index generations behind checksums and a completion marker. KoutenDB
can create, inspect, verify, retain, clean up, and restore selected generations
through Nim, CLI, and additive C ABI v2 functions.

Restore verifies a staged generation before publication and protects an
existing target with atomic replacement and rollback behavior. Invalid
generations are preserved for diagnosis, and retention never removes the final
verified generation.

## Operational Metrics

Prometheus and OpenMetrics output now covers request/error counters, WAL and
segment layout, automatic maintenance, capacity guardrails, checkpoint health,
and bounded fallback reasons. Metric labels avoid ring names, checkpoint IDs,
and arbitrary error text to prevent unbounded cardinality.

## Reliability Validation

The v0.12 cycle added or completed:

- a 120,000-operation accelerated churn matrix;
- nine process-level `SIGKILL` publication failpoints;
- concurrent readers, writers, metrics, maintenance, and backpressure tests;
- deterministic WAL, disk-full, permission, segment, manifest, and index
  failure injection;
- immutable v0.10.1 and v0.11.0 upgrade fixtures plus JSONL migration checks;
- Docker persistence, network interruption, TLS, authentication,
  authorization, credential rotation, and audit validation;
- a clean Rust, JavaScript/TypeScript, PHP, C++, and Python driver matrix;
- the final 72-hour strong-durability endurance and exact restore gate.

## Compatibility

The WAL remains authoritative. Existing stores continue through the tested
upgrade path, including legacy generation-zero segments. JSONL dump/import
remains the stable pre-v1 logical migration boundary when a portable rebuild is
preferred.

## Verification

The release is backed by the core and smoke suites plus the manual validation
matrices documented in the [v0.12 roadmap](v0.12-roadmap.md). The 72-hour run is
kept outside CI so normal pull-request checks remain deterministic.

## Scope Note

The endurance result covers the documented local Ubuntu environment. It does
not claim multi-machine, multi-region, or workload-independent SLA
certification.
