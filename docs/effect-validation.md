# Effect Validation

This document tracks small, reproducible KoutenDB effect-validation demos.
These are generated local workloads, not universal performance claims.

The goal is to make KoutenDB's main claim testable:

- reduce the candidate set that must be scanned;
- reduce estimated downstream context tokens;
- produce a compact prompt before any LLM is called;
- keep the model choice optional and explicit.

For actual downstream model computation, see the optional
[Small Transformer Compute and Energy Experiment](transformer-energy-bench.md).
It runs a local causal Transformer on exported retrieval prompts, compares a
same-budget global control, and reports CPU package energy only when counters
are readable.

## Single Demo

```sh
examples/effect_validation_demo.sh
```

The demo generates a deterministic JSONL corpus, imports it into KoutenDB, and
compares:

- global retrieval across the whole generated corpus;
- ring-routed retrieval scoped to `docs/japan`.

Representative local output:

| docs | global scanned | routed scanned | global tokens | routed tokens |
| ---: | ---: | ---: | ---: | ---: |
| 168 | 168 | 24 | 692 | 260 |

This means the demo reduced scanned records by `85.7%` and estimated tokens by
`62.4%` before sending anything to an LLM.

## Matrix Demo

```sh
examples/effect_validation_matrix.sh
KOUTEN_EFFECT_LARGE=1 examples/effect_validation_matrix.sh
KOUTEN_EFFECT_QUICK=1 examples/effect_validation_matrix.sh
```

This matrix is a manual validation path. It is intentionally not part of the
default CI smoke suite because the default and large cases are meant to create
millions of generated records.

The matrix uses several generated workload shapes:

- `small-balanced`: small corpus with one useful ring and unrelated rings;
- `near-distractors`: adds near-topic distractors to avoid a trivial clean split;
- `medium-noisy`: adds a larger unrelated background corpus;
- `large-noisy`: optional larger generated case enabled by `KOUTEN_EFFECT_LARGE=1`.

By default, the matrix uses `KOUTEN_EFFECT_SCALE=1000`, which reaches
13,500,000 documents in the standard run. `KOUTEN_EFFECT_LARGE=1` adds a
98,000,000-document generated stress case. Use `KOUTEN_EFFECT_QUICK=1` for the
smaller fast matrix, or set `KOUTEN_EFFECT_SCALE=N` explicitly.

Bulk load uses chunked commits. The default matrix uses
`KOUTEN_EFFECT_BATCH_SIZE=10000`; set it explicitly when comparing import
behavior:

```sh
KOUTEN_EFFECT_SCALE=1000 KOUTEN_EFFECT_BATCH_SIZE=10000 examples/effect_validation_matrix.sh
```

The current matrix path uses disk-backed storage by default
(`KOUTEN_EFFECT_DISK_BACKED=1`). Set `KOUTEN_EFFECT_DISK_BACKED=0` only when
you intentionally want to compare the legacy in-memory validation path.

Quick local sanity result from this repository state:

| case | docs | global budget | routed budget | set latency us | set us/record | pack latency us | pack records/rings/bytes | scanned | tokens | retrieve latency us | scanned reduction | token reduction | prompt bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| small-balanced | 168 | 8 | 3 | 2250.065 | 13.393244 | 987.782 | 168 / 4 / 61352 | 168 -> 24 | 692 -> 260 | 321.089 -> 55.249 | 85.714% | 62.428% | 1356 |
| focused-pinpoint | 12045 | 30 | 3 | 166421.501 | 13.816646 | 56405.995 | 12040 / 4 / 4286760 | 12045 -> 5 | 2408 -> 260 | 19804.821 -> 60.418 | 99.958% | 89.203% | 1357 |
| focused-small-context | 12150 | 30 | 5 | 168488.497 | 13.867366 | 57476.127 | 12150 / 5 / 4330050 | 12150 -> 50 | 2595 -> 433 | 19583.824 -> 102.117 | 99.588% | 83.314% | 2064 |
| near-distractors | 1860 | 20 | 5 | 28328.164 | 15.230196 | 9541.160 | 1860 / 5 / 681730 | 1860 -> 120 | 1730 -> 433 | 3375.936 -> 221.486 | 93.548% | 74.971% | 2064 |
| medium-noisy | 13500 | 30 | 8 | 190560.775 | 14.115613 | 62926.742 | 13500 / 5 / 4855950 | 13500 -> 500 | 2595 -> 692 | 22898.644 -> 867.784 | 96.296% | 73.333% | 3124 |

Larger local validation with `KOUTEN_EFFECT_SCALE=100` and
`KOUTEN_EFFECT_BATCH_SIZE=10000`:

| case | docs | global budget | routed budget | set latency us | set us/record | pack latency us | pack records/rings/bytes | scanned | tokens | retrieve latency us | scanned reduction | token reduction | prompt bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| small-balanced | 16800 | 8 | 3 | 235716.932 | 14.030770 | 82063.821 | 16800 / 4 / 6168360 | 16800 -> 2400 | 692 -> 260 | 27384.316 -> 4239.180 | 85.714% | 62.428% | 1360 |
| focused-pinpoint | 1204500 | 30 | 3 | 16409354.387 | 13.623374 | 6158327.700 | 1204500 / 5 / 432620950 | 1204500 -> 500 | 2595 -> 260 | 2730205.122 -> 901.451 | 99.958% | 89.981% | 1361 |
| focused-small-context | 1215000 | 30 | 5 | 16650765.840 | 13.704334 | 5555622.287 | 1215000 / 5 / 436784450 | 1215000 -> 5000 | 2595 -> 433 | 2353292.649 -> 8855.607 | 99.588% | 83.314% | 2068 |
| near-distractors | 186000 | 20 | 5 | 2529182.669 | 13.597756 | 835860.620 | 186000 / 5 / 68640450 | 186000 -> 12000 | 1730 -> 433 | 325546.670 -> 20660.522 | 93.548% | 74.971% | 2068 |
| medium-noisy | 1350000 | 30 | 8 | 17598824.700 | 13.036166 | 5875386.987 | 1350000 / 5 / 489914450 | 1350000 -> 50000 | 2595 -> 692 | 2530113.316 -> 86388.774 | 96.296% | 73.333% | 3128 |

The disk-backed path now separates two costs:

- `set latency`: normal JSONL import into the WAL-backed store;
- `pack latency`: an explicit physical-layout step that builds ring-local
  segment files for faster reads.

The WAL remains the source of truth. Ring segment files are rebuildable read
layout, similar in operational role to a compaction or optimize step. They are
not required for correctness.

The current segment-pack implementation uses buffered ring-local writes and
skips very small rings. Large rings benefit from contiguous segment files, while
tiny rings such as `users/<id>` can stay on WAL-offset reads without paying the
cost of one segment file per ring. Explicit post-import packing is now fast
enough for the scale-100 validation path, but it is still a visible cost at the
largest multi-million stress scale. The `effectPackRecords`,
`effectPackRings`, and `effectPackBytes` metrics expose that cost so future pack
optimization can be measured directly.
`KOUTEN_EFFECT_PACK_DURING_IMPORT=1` can be used to test import-time segment
construction, but it is not the default because it currently increases normal
import latency too much.

Scale-1000 validation also completed on this machine with the current
disk-backed segment path:

| case | docs | global budget | routed budget | set latency us | set us/record | pack latency us | pack records/rings/bytes | scanned | tokens | retrieve latency us | scanned reduction | token reduction | prompt bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| small-balanced | 168000 | 8 | 3 | 2268312.838 | 13.501862 | 808368.180 | 168000 / 4 / 61929560 | 168000 -> 24000 | 692 -> 260 | 289622.808 -> 42232.274 | 85.714% | 62.428% | 1362 |
| near-distractors | 1860000 | 20 | 5 | 24940651.107 | 13.408952 | 9361622.001 | 1860000 / 5 / 689944450 | 1860000 -> 120000 | 1730 -> 433 | 3481719.378 -> 227453.701 | 93.548% | 74.971% | 2070 |
| medium-noisy | 13500000 | 30 | 8 | 203851078.694 | 15.100080 | 72425799.771 | 13500000 / 5 / 4955874450 | 13500000 -> 500000 | 2595 -> 692 | 30082232.678 -> 1101752.063 | 96.296% | 73.333% | 3130 |

The scale-1000 stress path shows that the generated 13.5M-record case completes
without the previous OOM kill. It also shows the next performance target:
post-import segment packing is much faster than the earlier unbuffered path, but
the largest pack step is still large enough to deserve more optimization before
calling the v0.9 line final.

The important part is not that these generated numbers are universal. They show
how to test the effect: compare broad retrieval with placement-aware retrieval,
then report import latency, scanned records, estimated tokens, retrieval
latency, and prompt bytes.

## Pinpoint User Read

`examples/pinpoint_user_read_bench.sh` measures a common application pattern:
many users exist, but a request already knows the target user. It compares two
layouts with the same logical records:

- broad layout: every profile is stored in one `users` ring and read with an
  `id` filter;
- local layout: each profile is stored in `users/<id>` and read by ring.

Run:

```sh
KOUTEN_PINPOINT_USERS=100000 examples/pinpoint_user_read_bench.sh
```

Local disk-backed result with 100,000 users:

| layout | set latency us | set us/record | pack latency us | read mode | read latency us |
| --- | ---: | ---: | ---: | --- | ---: |
| broad users ring | 783773.641 | 7.837736 | 360499.095 | filter id in users | 1906854.458 |
| local users/<id> ring | 10297185.434 | 102.971854 | 11704.754 | read users/<id> limit=1 | 70.755 |
| local users/<id> ring | 10297185.434 | 102.971854 | 11704.754 | read users/<id> limit=20 | 77.601 |

The local layout has a higher write/setup cost because it creates many ring
metadata entries. The read path is the important result: once the application
places data at `users/<id>`, the request does not need to scan the broad `users`
ring and can read the target ring directly.

## User Bundle Read Compared With PostgreSQL

`examples/user_bundle_postgres_bench.sh` measures a user-detail page shape
rather than a single primary-key lookup. Each user has 20 logical records:
profile, addresses, career entries, preferences, and orders. KoutenDB stores
them under coordinate-local rings such as `users/<id>/profile` and
`users/<id>/orders`, then reads the bundle with a narrowed stellar read:

```sh
N=100000 READS=500 examples/user_bundle_postgres_bench.sh
```

PostgreSQL stores the same logical data in normalized indexed tables and is
measured in two shapes:

- five prepared indexed `SELECT` statements in one transaction;
- one prepared JSON aggregate query over the same indexed tables.

Local disk-backed results:

| users | logical records | KoutenDB bundle read us | PostgreSQL 5 SELECT us | PostgreSQL JSON aggregate us |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 20,000 | 213.248 | 424 | 246 |
| 10,000 | 200,000 | 202.668 | 442 | 257 |
| 100,000 | 2,000,000 | 205.799 | 407 | 240 |

The KoutenDB read path stayed roughly flat in this benchmark because the query
starts from `users/<id>` and only visits the requested subrings:
`profile`, `addresses`, `career`, `preferences`, and `orders`. This is the
intended locality model: related records can be retrieved together without
turning every request into a broad collection scan or a multi-table join.

The write/setup side is still a performance target. At 100,000 users,
KoutenDB inserted 2,000,000 logical records at `33.442073 us/record` in this
helper. That is good enough for the read-locality validation, but bulk load and
many-ring metadata creation should be optimized before treating this shape as a
final ingestion design.

## Per-Subring Limit And Sort Case Study

The heterogeneous subring bundle benchmark checks a shape that is awkward to
express as a plain relational join: one root user plus several related
collections where each collection has a different limit and sort order.

Example read shape:

```sh
kouten get --ring=users/<id> \
  --subring=profile,addresses,career,preferences,orders,notifications \
  --subring-limit=profile:1,addresses:3,career:2,preferences:1,orders:10,notifications:5 \
  --subring-rsort=orders:time,notifications:time
```

Local disk-backed result, measured with
`N=10000 READS=1000 examples/subring_bundle_postgres_bench.sh` on
2026-07-21:

| users | logical records | KoutenDB subring bundle read us | PostgreSQL 6 SELECT us | PostgreSQL JSON aggregate us |
| ---: | ---: | ---: | ---: | ---: |
| 10,000 | 1,050,000 | 196.859 | 515 | 236 |

The important distinction is the model. KoutenDB treats the related collections
as nearby subrings and applies the bounds at the read boundary. PostgreSQL can
still express the shape with indexed limited subqueries and JSON aggregation,
but it is no longer a simple join and it pushes more response-shaping work into
SQL.

## Offline Real-Data Copy

Generated workloads are useful for repeatability, but the next pre-production
step is to run the same measurement against copied or exported real data:

```sh
KOUTEN_REAL_JSONL=/path/to/corpus.jsonl \
QUERY_RING=docs/japan \
GLOBAL_BUDGET=40 \
ROUTED_BUDGET=10 \
examples/offline_effect_validation.sh
```

Expected JSONL shape:

```json
{"ring":"docs/japan","body":{"id":"doc-1","title":"...","text":"..."},"embedding":[1.0,0.0,0.0,0.0]}
```

This keeps the validation offline. It does not require production traffic and it
does not call an LLM unless the user separately chooses to run the generated
prompt through a model.

## Optional Trusted LLM Step

The effect validation does not require a model download. It always writes a
prompt first. A trusted local model can be added explicitly:

```sh
ollama pull gemma4:e2b
KOUTEN_TRUSTED_LLM_CMD='ollama run gemma4:e2b' examples/effect_validation_demo.sh
```

Gemma 4 E2B is used as the documented example because it is an official Google
Gemma 4 edge-size model available through Ollama.

References:

- https://deepmind.google/models/gemma/
- https://ai.google.dev/gemma/docs
- https://registry.ollama.com/library/gemma4

## JMeter Load Smoke

```sh
examples/jmeter_load_smoke.sh
KOUTEN_JMETER_THREADS=64 KOUTEN_JMETER_LOOPS=1000 examples/jmeter_load_smoke.sh
```

This is an optional Apache JMeter load smoke for the `koutend` TCP listener. It
sends concurrent `HEALTH` requests and writes a JTL result file.

It is deliberately separate from retrieval-locality benchmarks:

- JMeter health load checks listener stability and request/response behavior;
- effect-validation scripts check retrieval working-set and token reduction.

When JMeter is not installed, the wrapper exits successfully with a clear skip
message so the repository remains easy to test in minimal environments.
