# Soak Testing

KoutenDB includes an optional local soak runner for long-running stability
checks. It is designed for pre-release and pre-production validation, not for
normal CI.

The runner starts a three-node local cluster and repeatedly exercises:

- TCP cluster writes
- point reads by returned ID
- JSON projection queries
- ring reads with sort and limit
- vector retrieval
- metrics collection
- final snapshot and offline verify after shutdown

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
- `node0.log`, `node1.log`, `node2.log`
- `health-start.txt`
- `snapshot-final.txt`
- `metrics-final.txt`
- `verify-node0.json`, `verify-node1.json`, `verify-node2.json`
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
```

## Scope

This validates that core cluster operations can run continuously under a mixed
workload and that the resulting persistent data directories pass offline
verification after shutdown.

It does not replace:

- multi-machine or multi-region testing
- real TLS and auth deployment tests
- production traffic replay
- strict SLA or latency certification
- long-running memory profiling with external tools

Keep the 72-hour run outside CI. CI should remain fast and deterministic.
