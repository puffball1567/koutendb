# Soak Testing

KoutenDB includes an optional local soak runner for long-running stability
checks. It is designed for pre-release and pre-production validation, not for
normal CI.

The runner starts a three-node local cluster with strong durability,
disk-backed ring segments, and bounded automatic packing. It repeatedly
exercises:

- TCP cluster writes
- updates, deletes, and historical backfill writes
- point reads by returned ID
- JSON projection queries
- ring reads with sort and limit
- stellar neighborhood reads
- vector retrieval
- metrics collection
- bounded maintenance and queue convergence
- final snapshot, offline verify, generation checkpoint restore, and exact
  logical dump comparison after shutdown

The workload writes progress as JSON Lines so failures can be inspected even if
the run stops before the target duration.

During a run, inspect the `lastMetrics` entries in `soak-progress.jsonl`.
`handoffPending` and `handoffQueueDepth` should remain bounded instead of
growing continuously. `handoffFailed`, `handoffStaleAck`, and
`handoffQueueFull` are cumulative counters and must be investigated when they
increase persistently.

## Quick Smoke

Use a short duration when checking the script itself:

```sh
KOUTEN_SOAK_SECONDS=30 examples/soak_72h.sh
```

The script prints the work directory and writes:

- `soak-progress.jsonl`
- `system-progress.jsonl` with per-node RSS and data-directory bytes
- `node0.log`, `node1.log`, `node2.log`
- `health-start.txt`
- `health-final.txt`
- `snapshot-final.txt`
- `metrics-final.txt`
- `metrics-quiesced.txt` and `quiesce.txt`
- `verify-node0.json`, `verify-node1.json`, `verify-node2.json`
- `segment-status-node0.json`, `segment-status-node1.json`, and
  `segment-status-node2.json`
- `checkpoint-node*.json`, `checkpoint-verify-node*.json`, and
  `checkpoint-restore-node*.json`
- `verify-restored-node*.json`
- source and restored `dump-*.jsonl` files used for exact sorted comparison
- `run-config.txt` with the tested commit and workload settings
- `bin/` with the exact server, CLI, and runner binaries used by the run
- `completed.ok` after the final snapshot and every offline verify succeed

The run uses only the binaries stored under its work directory. Rebuilding the
repository during a long soak therefore cannot change the binaries used for
the final snapshot or offline verification.

## 72-Hour Run

For an endurance run:

```sh
KOUTEN_SOAK_SECONDS=259200 \
KOUTEN_SOAK_WORKDIR=/tmp/koutendb-soak-72h \
examples/soak_72h.sh
```

Useful optional controls:

```sh
KOUTEN_SOAK_RINGS=64
KOUTEN_SOAK_INTERVAL_MS=100
KOUTEN_SOAK_REPORT_EVERY_SECONDS=60
KOUTEN_SOAK_RECENT=4096
KOUTEN_SOAK_RING_READ_LIMIT=32
KOUTEN_SOAK_RETRIEVE_EVERY=10
KOUTEN_SOAK_METRICS_EVERY=20
KOUTEN_SOAK_BASE_PORT=18411
KOUTEN_SOAK_SYSTEM_EVERY_SECONDS=60
KOUTEN_SOAK_UPDATE_EVERY=7
KOUTEN_SOAK_DELETE_EVERY=29
KOUTEN_SOAK_BACKFILL_EVERY=37
KOUTEN_SOAK_STELLAR_EVERY=5
KOUTEN_SOAK_AUTO_PACK_INTERVAL_SECONDS=60
KOUTEN_SOAK_AUTO_PACK_STALE_RATIO=0.20
KOUTEN_SOAK_AUTO_PACK_MIN_STALE_RECORDS=32
KOUTEN_SOAK_QUIESCE_TIMEOUT_SECONDS=120
```

The latency object in each progress row includes cumulative average and
maximum latency plus p50/p95/p99 over a bounded rolling window of the latest
4,096 samples per operation. This keeps the runner memory-bounded while still
making start, 24-hour, 48-hour, and 72-hour behavior comparable. The system
progress file supplies the corresponding RSS and physical data-size samples.

The work directory must be empty. This prevents an earlier run from changing
the storage state or final verification result.

## v0.12 Final Gate Preflight

The release-candidate harness completed a 45-second local preflight on
2026-08-09. It used three strong-durability disk-backed nodes and an accelerated
two-second automatic-pack interval. It completed 1,980 writes, 1,980 point
reads, 1,980 projections, 1,980 ring reads, 396 stellar reads, 282 updates, and
68 deletes with zero workload errors. Automatic packing rewrote 46 rings in
total, and every node reported zero segment-to-WAL fallback.

All three source stores passed segment-aware offline verification. Their final
checkpoints passed checksum verification, restored into fresh directories,
passed offline verification again, and produced exact sorted JSONL dumps equal
to the source stores. This is a harness preflight, not the final 72-hour result.

## v0.10.0 Endurance Result

The v0.10.0 release candidate completed one local three-node, disk-backed
endurance run on 2026-07-31 through 2026-08-03. The exact executable set was
built from commit `87c755c9130ec0bbf70a3903c75fd2bdae8b084b` and then isolated
under the run work directory for the whole run.

Configuration:

- duration: 259,200 seconds (72 hours)
- three local TCP nodes: ports 18411, 18412, and 18413
- persistent storage enabled; buffered durability mode
- 250 ms workload interval and 60 second progress reports
- mixed TCP workload: writes, returned-ID point reads, projected queries,
  bounded ring reads, ring-scoped vector retrieval, and metrics reads

Final client counters:

| Operation | Completed |
|---|---:|
| PUT | 969,281 |
| returned-ID GET | 969,281 |
| projection query | 969,281 |
| bounded ring read | 969,281 |
| ring-scoped retrieve | 96,928 |
| metrics read | 48,464 |
| client errors | 0 |

The final snapshot completed, all three persistent data directories passed
offline `kouten verify`, and the tracked handoff, migration, and universe-sync
error/queue counters remained zero. Retrieval stayed ring-scoped; the final
metrics reported zero global retrieval requests.

This is a local endurance result, not a multi-machine, TLS/authenticated, or
strong-durability certification. It is retained here so the release claim is
auditable and the same runner can be reused with a different deployment mode.

## Scope

This validates that core cluster operations can run continuously under a mixed
workload and that the resulting persistent data directories pass offline
verification and checkpoint restore equivalence after shutdown.

It does not replace:

- multi-machine or multi-region testing
- real TLS and auth deployment tests
- production traffic replay
- strict SLA or latency certification
- long-running memory profiling with external tools

Keep the 72-hour run outside CI. CI should remain fast and deterministic.
