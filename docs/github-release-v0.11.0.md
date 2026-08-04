# KoutenDB v0.11.0

KoutenDB v0.11.0 makes ring locality a persistent disk-read property and
strengthens the recovery boundary around that layout.

## Highlights

- Added persistent ring-local segment and sidecar-index generations for
  disk-backed point, ring, and stellar reads.
- Added atomic per-ring generation activation. An interrupted pack keeps the
  previous complete generation active, while WAL remains authoritative.
- Added length-and-CRC32 envelopes to new segment records. Same-length payload
  corruption, malformed indexes, and wrong-record offsets are detected instead
  of being returned as valid data.
- Added automatic whole-ring WAL fallback when a segment or index cannot be
  trusted. Partial segment results are discarded before fallback.
- Added `pack-ring`, `segment-status`, and `pack-recommended` for explicit,
  operator-controlled maintenance.
- Added machine-readable segment metrics and capacity guardrails for segment
  bytes, stale records and ratios, generations, and file counts.
- Added a configurable process-level recovery matrix. The default three rounds
  kill a strong-durability writer with `SIGKILL`, then verify paired records,
  restart, pack, compact, backup, restore, and verify again.

## Compatibility

The WAL is still the source of truth. Existing pre-v0.11 stores without a
segment manifest or sidecar index are rebuilt from the WAL. Legacy unframed
generation-zero segments remain readable and are upgraded by an explicit pack
or rebuild.

## Local Segment Benchmark

The included `examples/segment_layout_bench.nim` compares the same interleaved
update workload before and after per-ring packing and asserts identical result
sets. In the documented local run with 1,000 live records in each of three
rings and 10,000 interleaved updates:

| Read path | Before pack | After pack |
|---|---:|---:|
| Point get | 12.51 us | 11.34 us |
| Direct ring segment scan | 34.07 ms | 3.50 ms |
| Public `readRing` | 33.87 ms | 3.21 ms |
| Public `readStellar` | 40.17 ms | 10.68 ms |

These are local measurements, not universal latency claims. The benchmark and
full conditions are documented in [Data Locality](data-locality.md).

## Verification

The release branch was verified with:

```sh
scripts/test_core.sh
scripts/disk_backed_recovery_smoke.sh
scripts/cli_crud_smoke.sh
scripts/cluster_tls_smoke.sh
scripts/test_all_smoke.sh
nim check src/koutencli.nim
nimble check
git diff --check
```

The full smoke suite covers cluster transactions and failure recovery,
authentication and authorization, malformed wire input, placement migration,
TLS, backup and restore, Universe synchronization, demos, and Compose config in
addition to the embedded unit matrix. Published external-driver compatibility
remains a separate release track.
