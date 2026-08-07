# Accelerated Churn Testing

KoutenDB includes a manual high-density validator for the v0.12 disk-backed
storage and maintenance path. It does not replace the final 72-hour endurance
gate. It finds state-transition bugs before spending three days on that gate.

The runner repeatedly combines:

- seeded multi-ring writes, updates, deletes, and backfills;
- point reads checked against an independent expected-state model;
- bounded segment maintenance;
- generation checkpoint creation, verification, and cleanup;
- close/reopen cycles;
- backup/restore equivalence checks;
- complete logical-result comparisons with compact reporting digests;
- final offline operational verification.

Each maintenance invocation remains bounded. At shutdown, the runner performs
a finite sequence of bounded passes and fails if the maintenance backlog cannot
be drained or if a pass makes no progress.

Every logical comparison checks the complete sorted
`ring + parent + sequence + payload` tuple set against a separately maintained
model. The digest in the report is a compact run identifier, not the equality
test. Maintenance, checkpoint, reopen, and restore operations cannot silently
change the expected result set.

## One-Hour Run

```sh
KOUTEN_CHURN_SECONDS=3600 examples/accelerated_churn.sh
```

Use a fixed work directory when the report must survive shell interruption:

```sh
KOUTEN_CHURN_SECONDS=10800 \
KOUTEN_CHURN_WORKDIR=/tmp/koutendb-churn-3h \
examples/accelerated_churn.sh
```

## Operation-Bounded Development Run

Set the duration to zero and choose a fixed operation count:

```sh
KOUTEN_CHURN_SECONDS=0 \
KOUTEN_CHURN_OPERATIONS=1000 \
KOUTEN_CHURN_WORKDIR=/tmp/koutendb-churn-smoke \
examples/accelerated_churn.sh
```

This short form validates the runner itself. It is not the v0.12 endurance
evidence and is intentionally not part of normal CI.

## Recorded v0.12 Operation-Bounded Run

The following local run completed on 2026-08-07 after the disk-backed cursor
pagination fix:

```sh
KOUTEN_CHURN_SECONDS=0 \
KOUTEN_CHURN_OPERATIONS=120000 \
KOUTEN_CHURN_WORKDIR=/tmp/koutendb-churn-v012-120k \
examples/accelerated_churn.sh
```

Environment:

- Ubuntu Linux 6.8.0, x86-64;
- AMD Ryzen 5 5600H, 6 cores / 12 threads;
- Nim 2.2.10;
- ARC memory management and release optimization;
- local disk-backed mode, without Docker or network transport.

Results:

| Measurement | Result |
|---|---:|
| Elapsed time | 830 seconds |
| Churn operations | 120,000 |
| Writes recorded by the workload | 32,045 puts / 66,012 updates / 23,991 deletes |
| Checked point reads | 120,000 |
| Exact logical-state comparisons | 1,202 |
| Bounded maintenance runs | 482 |
| Verified checkpoints | 120 |
| Close/reopen cycles | 60 |
| Backup/restore comparisons | 30 |
| Final live records | 8,054 across 17 rings |
| Duplicate or missing logical records | 0 |
| Segment-to-WAL fallbacks | 0 |
| Final recommended rings | 0 |
| Final operational verification | Passed |

The final checkpoint was complete and verified. The final logical set matched
the independent model after the maintenance backlog was drained. Sampled point
read latency was 31.431 us p50, 46.237 us p95, and 56.854 us p99. These latency
values describe this local generated workload and machine; they are validation
telemetry, not universal performance claims.

This run provides dense state-transition evidence. It does not replace the
separate process-crash, concurrency, storage-failure, container, or final
72-hour matrices.

## Output

The work directory contains:

- `report.jsonl`: start, progress, final, or failure records;
- `data/`: the final persistent database;
- `checkpoints/`: the retained verified generations;
- `completed.ok`: written only after final hash and offline verification pass.

Progress and final records include:

- operation counts;
- live-record count and logical hash;
- bounded p50/p95/p99 latency samples;
- process RSS;
- WAL, segment, and index bytes;
- maximum segment generation and recommended-ring count;
- segment-to-WAL fallback counters.

The latency reservoir stores at most 65,536 samples per operation class, so a
long run does not grow measurement memory without bound. A healthy run fails if
it observes a segment corruption fallback, logical divergence, checkpoint
verification failure, restore mismatch, or final operational verification
failure.
