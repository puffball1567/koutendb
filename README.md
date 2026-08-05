# KoutenDB: A Locality-First Database for RAG, AI Retrieval, and Related Data

**KoutenDB is a locality-first document and vector database.** It lets an
application place related data into explicit `ring` coordinates, then retrieves
the bounded nearby working set before vector ranking, filtering, reranking, or
LLM context construction.

The result is a database designed to reduce the records, bytes, candidate
memory, and tokens a request must process. KoutenDB is useful for RAG and AI
retrieval, but it is equally suited to tenant-scoped web systems, user detail
pages, product data, application state, and any service where related data is
known before a read begins.

## Reduce RAG Search Space, Candidate Memory, and Token Use

KoutenDB's core claim is direct: **do not rank, transfer, or send unrelated data
downstream when the application already knows the relevant locality.** A `ring`
is a first-stage retrieval boundary, not merely a collection name or a filter
applied after a broad search.

Included, reproducible benchmarks show the effect of selecting the correct ring
before exact retrieval:

| Workload | Result |
|---|---|
| 100-ring working-set benchmark | scanned records/query `10,000 -> 100` (99% reduction) |
| 100-ring memory-pressure benchmark | candidate memory/query `93.079 MiB -> 0.931 MiB` (99% reduction) |
| synthetic RAG benchmark | recall `1.000`, scanned/query `8,000 -> 1,000`, estimated tokens/query `3,955 -> 657` |
| generated AI/RAG JSONL case study | recall `1.000`, scanned/query `400 -> 40`, estimated tokens/query `615.2 -> 231.6` |

KoutenDB does not try to scan an entire corpus faster. It is built to make total
corpus size matter less when the request can name a meaningful scope such as a
tenant, repository, product, language, version, region, user, or document
family.

## Retrieve Related Data Without Join Shaping

Related records can be stored as nearby subrings and read as one bounded bundle.
This lets an endpoint state the shape it needs directly: one profile, a few
addresses, recent orders, and recent notifications, each with its own limit and
sort direction.

```sh
kouten get --ring=users/<id> \
  --subring=profile,addresses,career,preferences,orders,notifications \
  --subring-limit=profile:1,addresses:3,career:2,preferences:1,orders:10,notifications:5 \
  --subring-rsort=orders:time,notifications:time
```

In the included 1,050,000-record related-data benchmark, this KoutenDB subring
bundle read measured `196.859 us`. The same logical result measured `515 us`
through six indexed PostgreSQL queries and `236 us` through a PostgreSQL JSON
aggregate query. The detailed workload, data shape, and reproduction helper are
documented in [Benchmark Comparison](docs/benchmark-comparison.md).

## Verified Persistent Cluster Operation

KoutenDB v0.10.0 completed a **72-hour local three-node persistent cluster
run** with **4,022,516 mixed client operations**, **zero client errors**, and
successful offline verification of all three data directories after shutdown.

The run completed 969,281 each of PUTs, returned-ID GETs, projection queries,
and bounded ring reads, plus 96,928 ring-scoped retrievals. Handoff, migration,
and universe-sync error/queue counters remained zero, and retrieval did not fall
back to a global cluster scan. See [72-Hour Soak Testing](docs/soak-testing.md)
for the exact configuration and final counters.

## How Locality-First Retrieval Works

An application, import rule, or operator assigns a record to a meaningful
`ring`. That placement becomes part of the read plan. A retrieval can therefore
start from the known local scope, then apply exact vector ranking, structured
filters, projections, limits, and sorting only to eligible nearby data.

This differs from treating placement as an internal storage detail. In KoutenDB,
locality can also align authorization boundaries, dump units, migration units,
and application routing. The name comes from the Japanese word "kouten" (公転),
meaning orbital revolution: placement, rings, and orbit-inspired coordinates are
part of the data model rather than an afterthought.

Writes are intentionally light. A human, application, or import rule places data
into a ring. Reads use ring hierarchy, nearby subrings, retrieval profiles, and
projections to keep the candidate set small. See [How KoutenDB Differs From
Typical NoSQL](docs/nosql-positioning.md) for the full model.

## Documents

- Documentation site entry point: [docs/index.md](docs/index.md)
- Installation: [docs/installation.md](docs/installation.md)
- Public API reference: [docs/public-api.md](docs/public-api.md)
- Configuration reference: [docs/config-reference.md](docs/config-reference.md)
- CLI reference: [docs/cli-reference.md](docs/cli-reference.md)
- How KoutenDB differs from typical NoSQL: [docs/nosql-positioning.md](docs/nosql-positioning.md)
- Unique data model and operating patterns: [docs/unique-data-model.md](docs/unique-data-model.md)
- Technical FAQ for database reviewers: [docs/technical-faq.md](docs/technical-faq.md)
- Concept: [docs/koutendb-concept.md](docs/koutendb-concept.md)
- Detailed design: [docs/koutendb-design.md](docs/koutendb-design.md)
- Feature status / roadmap: [docs/koutendb-status.md](docs/koutendb-status.md)
- v0.12 implementation and validation roadmap: [docs/v0.12-roadmap.md](docs/v0.12-roadmap.md)
- Release checklist: [docs/release-checklist.md](docs/release-checklist.md)
- GitHub release notes: [docs/github-release-v0.11.0.md](docs/github-release-v0.11.0.md)
- Driver / FFI roadmap: [docs/koutendb-driver-roadmap.md](docs/koutendb-driver-roadmap.md)
- Driver installation guide: [docs/driver-installation.md](docs/driver-installation.md)
- Exact vector retrieval: [docs/vector-backends.md](docs/vector-backends.md)
- Protocol compatibility: [docs/protocol-compatibility.md](docs/protocol-compatibility.md)
- TLS transport: [docs/tls-transport.md](docs/tls-transport.md)
- Query safety: [docs/query-safety.md](docs/query-safety.md)
- Payload codecs and prepared selections: [docs/payload-codecs.md](docs/payload-codecs.md)
- Use case recipes: [docs/use-case-recipes.md](docs/use-case-recipes.md)
- Universe sync: [docs/universe-sync.md](docs/universe-sync.md)
- Threat model: [docs/threat-model.md](docs/threat-model.md)
- Benchmark notes: [docs/koutendb-bench.md](docs/koutendb-bench.md)
- Effect validation: [docs/effect-validation.md](docs/effect-validation.md)
- Cloud operations metrics: [docs/cloud-operations.md](docs/cloud-operations.md)
- Topology configuration reference: [docs/topology-config.md](docs/topology-config.md)
- Topology pattern catalog: [docs/topology-examples.md](docs/topology-examples.md)
- Topology remapping: [docs/topology-remapping.md](docs/topology-remapping.md)
- Shelfer integration boundary: [docs/koutendb-shelfer-integration.md](docs/koutendb-shelfer-integration.md)
- Halo capture design: [docs/koutendb-halo-capture.md](docs/koutendb-halo-capture.md)
- Changelog: [CHANGELOG.md](CHANGELOG.md)
- Third-party notices: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
- Contribution policy: [CONTRIBUTING.md](CONTRIBUTING.md)

## Installation

KoutenDB is available through Nimble. Rust, JavaScript / TypeScript, PHP, and
Python drivers are published as language packages, while the remaining non-Nim
language drivers are still repository-local foundations.

Prerequisites:

- Nim `2.0.0` or newer
- `git`
- `gcc` or another C compiler supported by Nim

Install the CLI and Nim library:

```sh
nimble install koutendb
kouten --help
```

Clone the repository when you want to run the full source test suite, examples,
or driver smoke tests:

```sh
git clone https://github.com/puffball1567/koutendb.git
cd koutendb
scripts/test_core.sh
nimble install -y
```

Nimble installs binaries into `~/.nimble/bin` by default. If `kouten` is not
found, add it to your shell PATH:

```sh
export PATH="$HOME/.nimble/bin:$PATH"
```

For server-style installs, build locally and install the binaries into
`/usr/local/bin`, the usual source-install location for database tools:

```sh
nim c -d:release --nimcache:/tmp/nimcache_kouten -o:bin/kouten src/koutencli.nim
nim c -d:release --nimcache:/tmp/nimcache_koutend -o:bin/koutend src/koutend.nim
sudo install -m 0755 bin/kouten /usr/local/bin/kouten
sudo install -m 0755 bin/koutend /usr/local/bin/koutend
```

See [docs/installation.md](docs/installation.md) for PATH and system install
details.

Use KoutenDB from a Nim program in this repository by importing the public module:

```nim
import koutendb
```

For command-line tools and demos that need repo-local binaries, build them under
`bin/`:

```sh
nim c -d:release --nimcache:/tmp/nimcache_kouten -o:bin/kouten src/koutencli.nim
nim c -d:release --nimcache:/tmp/nimcache_koutend -o:bin/koutend src/koutend.nim
```

Basic CLI document workflow:

```sh
kouten put --ring=docs/japan --payload='{"title":"Hello"}'
kouten get --ring=docs/japan
kouten get --ring=docs/japan --filter='{"id":"RAW_ID"}' --selection='{ title }'
```

When `--data=DIR` is omitted, the CLI uses `KOUTEN_DATA` if set, otherwise
`./data`. Use `--peers=host:port,...` instead when talking to a running
`koutend` cluster.

Vector retrieval is dependency-free. KoutenDB first narrows the working set by
ring and then performs exact cosine ranking over that bounded candidate set.

## Quickstart: Embedded Mode

```nim
import koutendb

var db = koutendb.open(dataDir = "data")   # persistent; omit dataDir for memory-only
db.setGalaxyDescription("Product and support knowledge")
db.setRingDescription("docs/japan", "Japanese product documentation and support articles")

let id = db.put("hello", ring = "docs/japan")
echo db.get(id)
echo db.atlas()                           # galaxy/ring map for agents and tools

echo db.locate(id)                        # current owner, computed locally
echo db.locate(id, at = 120.0)            # future owner, also computed locally
```

`get(id)` is the fastest path when the application already has a KoutenDB ID. If
the ID is not known, start from a ring.

```nim
import koutendb

var db = koutendb.open(dataDir = "data")

discard db.put("""{"slug":"hello","title":"Hello"}""", ring = "docs/japan")
discard db.put("""{"slug":"refund","title":"Refund guide"}""", ring = "docs/japan")

for item in db.listByRing("docs/japan"):
  echo item.payload
```

For vector/RAG-style lookup, search the ring directly:

```nim
let hits = db.retrieve(@[1.0'f32, 0.0'f32], ring = "docs/japan", budget = 3)

for hit in hits:
  echo hit.payload
```

If the right ring is not obvious, use `atlas()` and ring descriptions to choose
the search scope first. KoutenDB is designed to avoid ID-less global scans when a
ring coordinate is available.

## Why It Helps Web Systems

KoutenDB is useful outside AI workflows when the application naturally has
locality boundaries.

- Tenant locality: `ring = "tenant/acme/orders"` keeps query scope, dump scope,
  backup scope, and future authorization scope aligned.
- Smaller responses: `query(id, "{ title status }")` returns only requested
  fields, so large JSON documents do not need to cross the process or network
  boundary on every read.
- Import routing: JSONL exports from MongoDB-like stores can be imported and
  routed by fields such as `tenant`, `category`, `region`, or `date`.
- Migration boundary: `kouten dump` / `kouten import-jsonl` provide a
  human-readable data path while the pre-v1.0 internal WAL format continues to
  harden. `kouten import-jsonl --batch-size=N` uses chunked commits for larger
  imports.
- Galaxy isolation: separate services can use separate galaxies, data
  directories, credentials, and clusters while using the same implementation.
- Explainable location: `locate(id)` and `locate(id, at=...)` make placement
  observable without a directory service.
- Incremental adoption: start with embedded `open(dataDir=...)`, then move to
  cluster `connect(...)` when the service needs separate nodes.

## Drivers

The public driver surface is intentionally small. External drivers can use
high-level wire frames such as `PUTR`, `GETID`, `QRYID`, `BGET`, and
`RETRIEVE`; they do not need to reimplement KoutenDB's ring-key, orbit, or ID
rules.

Published external drivers:

| Language / runtime | Package | Version | Repository | Mode |
|---|---|---:|---|---|
| Rust | [`koutendb`](https://crates.io/crates/koutendb) | `0.1.3` | [`puffball1567/koutendb-rust`](https://github.com/puffball1567/koutendb-rust) | C ABI wrapper |
| JavaScript / TypeScript | [`koutendb`](https://www.npmjs.com/package/koutendb) | `0.1.3` | [`puffball1567/koutendb-js`](https://github.com/puffball1567/koutendb-js) | Node-API C ABI wrapper |
| PHP | [`koutendb/koutendb`](https://packagist.org/packages/koutendb/koutendb) | `0.1.2` | [`puffball1567/koutendb-php`](https://github.com/puffball1567/koutendb-php) | FFI / C ABI wrapper |
| C++ | GitHub / CMake source package | `0.1.1` | [`puffball1567/koutendb-cpp`](https://github.com/puffball1567/koutendb-cpp) | C++17 C ABI wrapper |
| Python | [`koutendb`](https://pypi.org/project/koutendb/) | `0.1.3` | [`puffball1567/koutendb-python`](https://github.com/puffball1567/koutendb-python) | Native TCP wire driver |

The table below lists current core-repository driver foundations. Publication
priority for remaining language packages is tracked in
[docs/koutendb-driver-roadmap.md](docs/koutendb-driver-roadmap.md).

| Language / runtime | Driver path | Current mode | Smoke status |
|---|---|---|---|
| Nim | `src/koutendb.nim` | Native embedded and cluster API | core tests |
| C ABI | `include/koutendb.h` | Embedded / cluster foundation for bindings | contract smoke |
| Node.js / TypeScript | `drivers/node` | Native TCP wire driver, ESM | `node --test` |
| Bun | `drivers/node` | Node-compatible TCP wire driver | `bun test` |
| Go | `drivers/go` | C ABI wrapper | `go test` |
| Swift | `drivers/swift` | SwiftPM C ABI wrapper | Linux Docker smoke |
| C# | `drivers/csharp` | Generic .NET C ABI wrapper | contract smoke |
| Kotlin/JVM | `drivers/kotlin` | JNI / C ABI wrapper | Docker smoke |

Detailed setup notes are in
[docs/driver-installation.md](docs/driver-installation.md). Nimble package
registration is complete. Rust, JavaScript / TypeScript, PHP, Python, and C++
source releases are published; NuGet, Maven, Go, SwiftPM, and other registry
packages remain roadmap items.

## Cluster Mode

Run `koutend` nodes with the same peer list:

```sh
koutend --id=0 --peers=h1:7301,h2:7301,h3:7301 --data=/var/lib/kouten
```

Then connect with the same API shape:

```nim
var db = connect("h1:7301,h2:7301,h3:7301")
let id = db.put(%*{"title": "KoutenDB", "author": {"name": "Ada"}}, ring = "docs")
echo db.query(id, "{ title author { name } }")
echo db.locate(id, at = epochTime() + 60)
```

The core placement rule is deterministic:

> data location = deterministic function `E(id, t) -> node`

Every node can compute where a record is now, and where it will be later,
without a directory lookup. Handoffs are scheduled from ephemeris state rather
than from a central rebalance service.

Canonical data should normally live in one galaxy/ring. Multiple views should be
modeled with hierarchy, naming conventions, import rules, retrieval profiles, or
projection. KoutenDB core does not try to keep duplicate logical records in
multiple galaxies perfectly synchronized.

For asynchronous maintenance across rings, KoutenDB has a minimal `warp` queue.
A warp job scans specified rings over time and drops a patch into matching
documents. It is closer to a maintenance asteroid belt than a relational join:
jobs have attempts, retry timing, acknowledgements, and dead-letter state, and
their state is persisted in the WAL. Rich scheduling, backoff policy, audit
history, and flow orchestration are intended to live in adapters such as the
future `koutendb-flow` integration.

## Detailed Retrieval, Memory, Token, and Latency Benchmarks

KoutenDB's strongest benchmark story is working-set reduction. Local reads are
also in the same broad latency class as existing databases, but the larger claim
is that KoutenDB can reduce how much data is touched before ANN, rerank, LLM, or
application processing.

| Benchmark | Setup | Result |
|---|---|---|
| Working-set | 100 rings / 10k docs | scanned/query `10000 -> 100` (99% reduction) |
| Memory-pressure | 100 rings / 100k docs / 512B payload | candidate memory/query `93.079 MiB -> 0.931 MiB` (99% reduction) |
| Synthetic RAG | fixed recall | recall `1.000`, scanned/query `8000 -> 1000`, tokens/query `3955 -> 657` |
| AI/RAG case study | generated JSONL, 400 docs / 6 rings | recall `1.000`, scanned/query `400 -> 40`, tokens/query `615.2 -> 231.6` |
| API minimum test | 2 rings / 4 vectors | `skippedVectors` and `candidateReduction` confirm pre-filtered search scope |

Reference latency results are tracked in
[docs/koutendb-bench.md](docs/koutendb-bench.md), with compact comparison tables
in [docs/benchmark-comparison.md](docs/benchmark-comparison.md). The short
version is:

- KoutenDB 3-node TCP with persistence enabled measured `53.5 us` per
  single-key read and `61.1 us` per single-key write in the PostgreSQL
  comparison helper run. KoutenDB strong durability was not part of that
  PostgreSQL reference comparison.
- PostgreSQL 14.23 on the same machine measured `86 us` for primary-key read
  and `104 us` for `synchronous_commit=off` single-row write over local TCP.
- The PostgreSQL comparison also has a Docker-Docker reproduction helper; in
  the included run KoutenDB measured `61.3 us` read / `103.6 us` write, while
  PostgreSQL measured `103 us` primary-key read / `149 us`
  `synchronous_commit=off` write.
- Local Redis 6.0.16 measured `44.93 us/op` for single GET and `3.55 us/op`
  for pipeline GET. KoutenDB TCP GET measured `52.88 us/op`; KoutenDB TCP BGET
  measured `1.81 us/op` in the same local single-client benchmark shape.
  This Redis comparison uses KoutenDB buffered durability with a fresh temporary
  data directory and measures simple GET/BGET latency, not the working-set
  reduction benchmarks.
- In the Docker-Docker Redis comparison, Redis 7 measured `48.74 us/op` for
  single GET and `2.06 us/op` for pipeline GET. KoutenDB TCP GET measured
  `55.78 us/op`; KoutenDB TCP BGET measured `1.71 us/op`.

These are not universal performance claims. They show that the local read path
is already competitive enough for the working-set reduction story to matter.

## C ABI

`include/koutendb.h` plus `lib/libkoutendb.so` is the foundation for non-Nim
bindings.

```c
kouten_init();
if (kouten_abi_version() != KOUTEN_ABI_VERSION) return 1;

void *db = kouten_connect("h1:7301,h2:7301,h3:7301");
kouten_id id;

kouten_set_galaxy_description(db, "Product and support knowledge");
kouten_set_ring_description(db, "docs", "Documentation ring");
kouten_put(db, "docs", "hello", 5, &id);

float v[2] = {1.0f, 0.0f};
kouten_put_vec(db, "docs", "hello", 5, v, 2, &id);

kouten_batch_result *b = kouten_batch_get(db, &id, 1);
kouten_batch_get_free(b);

kouten_retrieve_result *r = kouten_retrieve(db, v, 2, "docs", 8, 0, 0);
kouten_retrieve_free(r);

size_t n;
char *j = kouten_query(db, id, "{ title }", &n);
kouten_free(j);

char *a = kouten_atlas(db, v, 2, 8, &n);
kouten_free(a);

int node = kouten_locate(db, id, -1.0);
```

## Build and Verification

### Core Test Suite

```sh
scripts/test_core.sh
scripts/test_all_smoke.sh
```

Include driver compatibility checks when local toolchains are available:

```sh
KOUTEN_TEST_DRIVERS=1 scripts/test_all_smoke.sh
```

### Simulation And Mechanism Benchmarks

```sh
nim c -d:danger -o:bin/koutensim src/koutensim.nim
bin/koutensim all

nim c -d:danger -o:bin/koutenbench src/koutenbench.nim
bin/koutenbench
```

### Working-Set, Memory, And RAG Benchmarks

```sh
nim c -d:release -o:bin/kouten src/koutencli.nim
kouten working-set-bench --n=100000 --rings=100 --queries=50 --budget=20
kouten memory-pressure-bench --n=100000 --rings=100 --queries=50 --budget=20 --payload-bytes=512
RUN_REDIS=0 examples/memory_pressure_case_study.sh
examples/ai_rag_case_study.sh
examples/effect_validation_demo.sh
examples/effect_validation_matrix.sh
KOUTEN_EFFECT_LARGE=1 examples/effect_validation_matrix.sh
```

The effect-validation demo generates a deterministic JSONL corpus, imports it
into KoutenDB, and compares global retrieval against ring-routed retrieval. It
prints scanned-record reduction, estimated token reduction, and the compact
prompt size before any LLM is involved. It also reports import and retrieval
latency so the working-set effect is visible alongside the cost of loading and
reading the generated corpus.

The matrix script runs several generated workload shapes, including near-topic
distractors and medium noisy corpora. The default manual matrix can scale to
13,500,000 generated documents; `KOUTEN_EFFECT_LARGE=1` adds a
98,000,000-document stress case. `KOUTEN_EFFECT_BATCH_SIZE=N` controls JSONL
bulk-load chunk commits. It
prints a Markdown table so results can be pasted into issues, release notes, or
benchmark discussions. This is a manual validation path and is not part of the
default CI smoke suite:

```sh
KOUTEN_EFFECT_SCALE=1000 KOUTEN_EFFECT_BATCH_SIZE=10000 examples/effect_validation_matrix.sh
KOUTEN_EFFECT_LARGE=1 examples/effect_validation_matrix.sh
```

To validate a copied or exported real dataset without production traffic:

```sh
KOUTEN_REAL_JSONL=/path/to/corpus.jsonl QUERY_RING=docs/japan examples/offline_effect_validation.sh
```

LLM execution is optional so CI and first-time users do not need to download a
model. To run the generated prompt through a trusted small local model, use an
official Gemma edge-size model through Ollama:

```sh
ollama pull gemma4:e2b
KOUTEN_TRUSTED_LLM_CMD='ollama run gemma4:e2b' examples/effect_validation_demo.sh
```

Gemma 4 E2B is the recommended demo target because it is an official Google
Gemma 4 edge-size model available through Ollama. Other commands can be used
through `KOUTEN_TRUSTED_LLM_CMD`, but the demo documentation intentionally avoids
recommending unknown or untrusted model sources.

References: [Google Gemma](https://deepmind.google/models/gemma/),
[Gemma docs](https://ai.google.dev/gemma/docs),
[Ollama Gemma 4](https://registry.ollama.com/library/gemma4).

### Load Smoke With JMeter

KoutenDB also includes an optional Apache JMeter plan for basic TCP server load
smoke:

```sh
examples/jmeter_load_smoke.sh
KOUTEN_JMETER_THREADS=64 KOUTEN_JMETER_LOOPS=1000 examples/jmeter_load_smoke.sh
```

This plan sends concurrent `HEALTH` requests to `koutend`. It validates the TCP
listener and request/response path under load; it is separate from the
retrieval-locality benchmarks above.

### Redis Comparison

Use an existing local Redis server:

```sh
N=1000 examples/redis_local_bench.sh
```

Or compare Redis and KoutenDB inside the same Docker network:

```sh
N=1000 examples/redis_docker_bench.sh
```

### Server Options

```sh
nim c -d:release -o:bin/koutend src/koutend.nim
nim c -d:release -o:bin/kouten src/koutencli.nim
```

Strong durability mode:

```sh
bin/koutend --id=0 --peers=127.0.0.1:7301 --data=/var/lib/kouten --durability=strong
```

Ring-prefix authorization:

```sh
bin/koutend --id=0 --peers=127.0.0.1:7301 \
  --user=alice \
  --password-file=/run/secrets/kouten_password \
  --allow-ring=allowed
```

Minimal RBAC plus ring-prefix authorization:

```sh
bin/koutend --id=0 --peers=127.0.0.1:7301 \
  --role=reader:read:reader:allowed \
  --role=writer:write:writer:allowed \
  --role=admin:admin:admin:allowed
```

Encrypted backup / restore:

```sh
kouten backup-encrypted --data=data --backup=backup.enc --passphrase=change-me
kouten restore-encrypted --backup=backup.enc --data=restored --passphrase=change-me --durability=strong
```

`backup`, `backup-encrypted`, `restore`, and `restore-encrypted` use
temporary files plus atomic replacement. Snapshot files are fsynced before they
are made visible.

### Driver Checks

```sh
node --test drivers/node/test/*.test.js
```

The Python driver is managed outside the core repository:
[`puffball1567/koutendb-python`](https://github.com/puffball1567/koutendb-python).

Cluster demo:

```sh
./examples/cluster_demo.sh
```

Universe sync demo:

```sh
./examples/universe_sync_demo.sh
./scripts/universe_sync_remote_smoke.sh
```

This shows a WAL-backed eventual sync outbox, idempotent apply, ack/prune, and
the CLI handoff boundary between two local data directories or a remote KoutenDB
server. See [docs/topology-examples.md](docs/topology-examples.md) for topology
patterns.

Payload codec and prepared selection demos:

```sh
examples/payload_codecs_demo.sh
examples/payload_codecs_cluster_demo.sh
```

KoutenDB core stores and transports `raw`, `json`, `nif`, and `bif` payloads as
codec-tagged bytes. NIF/BIF conversion stays outside the core; use the optional
[`koutendb-nif`](https://github.com/puffball1567/koutendb-nif) adapter backed by
[`nifkit`](https://github.com/puffball1567/nifkit) when applications need NIF
text / BIF byte roundtrips. CLI `get` uses codec metadata automatically: when
`KOUTENDB_NIF_TOOL`, `koutendb-nif`, or `nif_file_tool` is available, BIF is
decoded to NIF text; otherwise BIF falls back to base64 display. Use
`--view=raw`, `--view=base64`, or `--view=hex` only when you want to override
that default.

### C ABI

```sh
scripts/build_capi.sh
gcc examples/demo.c -Iinclude -Llib -lkoutendb -Wl,-rpath,'$ORIGIN/../lib' -o bin/demo
bin/demo
```

`scripts/build_capi.sh` is the canonical C ABI build and includes `-d:ssl`.
Drivers that call `kouten_connect_auth_tls` should use this library.

### Exact Vector Retrieval

```sh
examples/vector_backend_bench.sh
```

The benchmark reports broad and ring-scoped exact retrieval separately.
KoutenDB does not maintain a second global vector index: ring routing is the
primary mechanism for reducing vector work. See
[docs/vector-backends.md](docs/vector-backends.md) for the execution model and
local benchmark procedure.

KoutenDB forces Nim ARC through `config.nims`. Avoiding reference cycles is a
structural constraint of the codebase, not just a style preference.

## Project Layout

```text
src/koutendb.nim        public API for embedded and cluster modes
src/koutend.nim         node server: scale-out, persistence, handoff
src/koutencli.nim       CLI, demos, benchmarks, maintenance commands
src/koutendb_capi.nim   C ABI
src/kouten/core.nim     ephemeris fast layer: Orbit, ArcTable, encounters
src/kouten/select.nim   GraphQL-like projection
src/kouten/store.nim    particle store plus append-only WAL
src/kouten/wire.nim     wire protocol and persistent client
src/koutensim.nim       PoC verification CLI
drivers/               language drivers and wrappers
include/koutendb.h      C header
examples/              C demo, cluster demo, benchmark scripts
examples/compose/      Docker Compose topology demos
tests/                 unit and smoke tests
```

## Operational Scope

KoutenDB v0.11.0 is a public pre-v1 release with persistent storage, recovery,
transactions, topology controls, TLS-capable transport, a C ABI, published
drivers, ring-local physical segments, operational verification, and documented
local endurance and forced-crash recovery evidence.

It is designed for teams that can express a meaningful locality boundary and
want to evaluate a smaller-working-set retrieval architecture. Multi-machine
and multi-region endurance testing, strong-durability endurance testing, and
broader external production reports remain active validation tracks. See
[Operational Trials](docs/operational-trials.md),
[Soak Testing](docs/soak-testing.md), and
[Feature Status](docs/koutendb-status.md) for the current evidence and roadmap.

## License

KoutenDB core and the OSS drivers are released under Apache-2.0; see
[LICENSE](LICENSE).

Third-party dependency and tooling notices are tracked in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Security assumptions and known
gaps are tracked in [docs/threat-model.md](docs/threat-model.md).
