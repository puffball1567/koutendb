# KoutenDB v0.10.0

KoutenDB v0.10.0 is an operational-hardening release for the ring-local
document and retrieval path.

## Highlights

- Added operational configuration verification, capacity guardrails, audit
  events, backup verification, and a Docker Compose operational trial.
- Added explicit scale-in migration and rolling topology activation with
  controlled draining, handoff, and progress visibility.
- Added a local three-node soak runner that freezes its binary set, records
  JSONL progress, captures a final snapshot, and verifies all data directories
  offline after shutdown.
- Restricted cluster retrieval to its requested ring, preventing an accidental
  cluster-wide retrieval scan.
- Decoupled physical placement from the logical orbit schedule and moved
  handoff I/O off the request loop.
- Removed the optional FAISS backend. Exact retrieval is now dependency-free:
  KoutenDB narrows candidates by ring before cosine ranking rather than
  maintaining a second global vector index.

## 72-Hour Local Endurance Run

The release candidate completed a 72-hour local, three-node, persistent TCP
workload with 969,281 each of PUTs, returned-ID GETs, projection queries, and
bounded ring reads; 96,928 ring-scoped retrievals; and 48,464 metrics reads.
The runner recorded zero client errors. After shutdown, all three data
directories passed offline verification; handoff, migration, and universe-sync
error/queue counters were zero.

See [Soak Testing](soak-testing.md) for the exact configuration, counters, and
scope boundary.

## Verification

The v0.10.0 release branch is verified with:

```sh
scripts/test_all_smoke.sh
scripts/demo_smoke.sh
nimble check
git diff --check
```

The 72-hour endurance run is intentionally manual and is not part of CI.

## Scope

v0.10.0 strengthens operational guardrails and validates continuous local
cluster operation. It does not claim multi-machine or multi-region deployment
certification, a full TLS/authenticated endurance campaign, or strict latency
SLA certification.
