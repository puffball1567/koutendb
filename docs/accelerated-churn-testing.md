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
