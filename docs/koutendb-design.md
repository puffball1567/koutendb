# KoutenDB Detailed Design

Status: v0.1.0 technical-preview design, aligned with the current
implementation. This document is the English canonical design note. Historical
brainstorming and non-canonical translations should live in separate translated
or archival files.

Related documents:

- Concept: [koutendb-concept.md](./koutendb-concept.md)
- Benchmark notes: [koutendb-bench.md](./koutendb-bench.md)
- Feature status: [koutendb-status.md](./koutendb-status.md)
- Shelfer boundary: [koutendb-shelfer-integration.md](./koutendb-shelfer-integration.md)
- Halo capture: [koutendb-halo-capture.md](./koutendb-halo-capture.md)

## 1. Design Goal

KoutenDB is a placement-aware document/vector store. It is designed to reduce the
amount of data that must be read, transferred, reranked, embedded into prompts,
or held as candidates.

The target is not only lightweight NoSQL. Lightweight behavior is necessary, but
the main goal is to reduce waste in large AI and document systems:

- fewer scanned vectors;
- fewer candidate bytes;
- fewer returned chunks;
- fewer prompt tokens;
- less reranker work;
- less worker fanout;
- less memory pressure.

For ordinary web systems, the same structure provides tenant, category, region,
date, or state locality without forcing a relational schema.

## 2. Core Principle

KoutenDB separates logical locality from physical ownership:

```text
L(id, t) -> logical orbital coordinate
P(ringKey, topologyEpoch) -> physical owner node
```

`L` retains the time-dependent orbital model used by `locate`, future-arrival
planning, conjunctions, and retrieval locality. `P` uses a stable ring
coordinate and a shared virtual-arc topology. Records do not physically move
on every logical orbit.

Every node can calculate both values without a per-record directory or a leader
lookup. The separation is important: ephemeris-style predictability remains
available to planning, while normal physical ownership does not generate work
proportional to `live records / orbit period`.

Physical migration occurs only when the configured placement topology changes,
or when a misplaced durable record is recovered. The migration path is bounded,
version-checked, retried after destination failure, and fenced by a monotonic
placement epoch.

## 3. Public API Boundary

The public API must stay small:

- `open` for embedded stores;
- `connect` for cluster stores;
- `put`;
- `get`;
- `query`;
- `retrieve`;
- `locate`;
- `atlas`.

The internal model may be orbital and distributed, but the user should be able
to learn the database through normal database verbs.

External drivers should not reimplement ring-key hashing, orbit math, ID
encoding, or ownership rules. They should use high-level wire operations such as
`PUTR`, `GETID`, `QRYID`, `BGET`, and `RETRIEVE`.

## 4. Data Model

### 4.1 Galaxy

A galaxy is an isolation namespace. A production deployment may map galaxies to
separate clusters, credentials, secret keys, data directories, or operational
policy. The same KoutenDB mechanism can host unrelated datasets without making
them share a trust boundary.

Galaxy descriptions are stored as metadata and exposed through `atlas` so
agents and operators can understand where data likely belongs.

### 4.2 Ring

A ring is the primary placement coordinate. It can represent a tenant, topic,
region, date partition, state scope, or corpus domain.

Ring names may use `/` to express hierarchy:

```text
docs/japan
tenant/acme/orders/2026
papers/medicine
app/global/preferences
app/local/editor/session
```

Ring descriptions are stored as metadata and are part of the atlas.

### 4.3 Record

A record has:

- an orbital ID;
- ring placement;
- payload bytes or JSON;
- optional vector embedding;
- write timestamp;
- durability state through the WAL when persistent mode is enabled.

The core design prefers canonical storage in one galaxy/ring. Duplicate
logical copies across many rings should be avoided unless the application
explicitly accepts eventual maintenance through warp jobs.

## 5. Atlas

The atlas is the map that an agent, operator, or integration layer should read
before querying blindly. It contains galaxy and ring summaries, descriptions,
and retrieval metadata.

The goal is to reduce wasteful broad search:

1. inspect atlas;
2. choose likely galaxy/ring;
3. run scoped retrieval;
4. inspect stats;
5. widen only if needed.

This is the LLM-friendly equivalent of reading schema, table statistics, and
index hints before running a query.

## 6. Retrieval Planning

KoutenDB exposes a retrieval plan in the envelope. Human-facing knobs are:

| Field | Meaning |
|---|---|
| `amount` | how many useful chunks to return |
| `scope` | how widely KoutenDB may search across related rings |
| `depth` | how deeply KoutenDB may descend through hierarchy |

The implementation also exposes diagnostics such as:

- selected rings;
- pruned rings;
- effective top rings;
- branch budget;
- maximum depth;
- centroid similarity;
- ring count;
- candidate reduction;
- scanned records;
- skipped vectors.

Plan changes should be cheap and reversible. Physical merge, split, or
re-parent operations should remain explicit maintenance decisions.

## 7. Retrieval Envelope

The canonical envelope schema is:

```text
koutendb.retrieval.v1
```

The envelope contains:

- source provider, galaxy, ring, backend, and source type;
- query mode and budget;
- executed plan;
- chunks with IDs, scores, rings, payloads, token estimates, and source URIs;
- stats;
- policy hints.

The envelope is intentionally adapter-neutral. Shelfer, HTTP gateways, CLI
tools, and future drivers can consume the same structure.

Compatibility rules:

- v1 may add optional fields;
- required v1 fields must not be removed or renamed without a new schema;
- consumers must ignore unknown fields;
- consumers should reject envelopes that fail validation;
- policy hints are advisory and do not replace authorization.

## 8. Vector Backend

KoutenDB has an exact backend for correctness, tests, and small deployments. The
intended production vector path uses a FAISS bridge.

The core goal is still to reduce the candidate set before the vector backend
does heavy work. KoutenDB should not require GPU FAISS as the default path. The
database should make the working set small enough that CPU-side search remains
useful for many workloads.

## 9. Insert Path

Insert should be simple:

1. choose a ring from application logic, user policy, or import rule;
2. write payload and optional vector;
3. update ring summaries;
4. append WAL records if persistent mode is enabled.

KoutenDB is not a mandatory write-time classifier. Expensive inference should
not be required to place each document.

Import rules can assign rings from JSONL fields:

```text
--ring-field=tenant
--ring-prefix=tenant/
--payload-field=body
--vec-field=embedding
```

This makes large corpus ingestion practical without hand-classifying every
document.

## 10. Read Path

A scoped read should avoid touching unrelated rings. For vector retrieval this
means skipped vectors must be counted before search, not merely filtered after
results are found.

Important stats:

- `totalVectors`
- `scanned`
- `skippedVectors`
- `ringsTouched`
- `returned`
- `payloadBytes`
- `estimatedTokens`
- `candidateReduction`

The benchmark document includes API tests and case studies that confirm
ring-scoped retrieval lowers `scanned` and `skippedVectors` before downstream
processing.

## 11. Projection

`query(id, "{ title author { name } }")` supports GraphQL-like field projection.
This is not a GraphQL server. The benefit is narrower:

- fewer bytes returned;
- less application-side filtering;
- a driver-friendly way to ask for only the needed fields;
- useful behavior even when documents have flexible NoSQL shapes.

If a requested field does not exist, the projection omits it rather than
inventing a value.

## 12. Persistence

Persistent embedded stores use an append-only WAL. The WAL records:

- puts;
- deletes;
- vector payloads;
- metadata;
- transaction boundaries;
- forwarders;
- warp jobs;
- warp job deletion tombstones.

Compaction writes a compact representation of live state. Backup and restore use
compact WAL snapshots. Human-readable dump is available for inspection and
migration, not for crash recovery.

Additional fault-tolerance work is a v0.2+ direction. Public documentation
intentionally keeps this area high-level.

Durability modes:

- normal durability batches flushes for throughput;
- strong durability flushes and fsyncs at write boundaries.

## 13. Transactions

Single-store transactions group multiple changes into an atomic WAL boundary.
They protect local consistency across records, vectors, forwarders, and warp job
state.

Cluster transaction landing is intentionally conservative. KoutenDB does not
pretend to have mature global serializable distributed transactions. Cross-node
or cross-galaxy maintenance should use landing, retry, acknowledgement, and
repair patterns rather than blocking the whole system on a wide lock.

## 14. Warp Queue

Warp jobs are asynchronous maintenance operations. A job contains:

- target rings;
- match field;
- expected value;
- JSON patch;
- status;
- cursor/ring index;
- scanned/matched/updated counters;
- attempts;
- retry time;
- acknowledgement state;
- error text.

The lifecycle is:

```text
pending -> running -> done -> acknowledged -> pruned
                 \-> failed -> retry
                 \-> dead-letter
```

This is the safe minimal mechanism for "apply this change wherever matching
documents are found" without creating synchronous multi-ring object identity.

## 15. Ring-Local History and Ordering

Most KoutenDB data should not require a global application order. If related
facts are placed in the same ring, the ring itself carries the relationship:
comments, knowledge chunks, embeddings, snapshots, and AI/RAG context can be
stored with their write time and displayed, retrieved, or synchronized later in
the order the reader needs.

The default policy should therefore be order-relaxed:

- store the data in the target ring;
- keep write time / origin metadata with the record;
- synchronize or export records by ring;
- let readers sort by timestamp, score, source, or another domain attribute.

This avoids turning KoutenDB into a heavyweight global-order database. Strict
ordering should be opt-in at the ring level.

For rings where order changes the final state, KoutenDB should use delayed
apply:

- receive the change;
- hold it in a pending window;
- sort by timestamp, source, or explicit sequence;
- apply after the delay window closes.

Undo/redo and recent-history use cases do not need a full global log either.
A ring can keep a bounded history window, such as the latest N versions or the
latest N undo/redo pairs. For many UI and document workflows, retaining around
20 recent entries is enough; append-like data such as comments can simply be
kept with timestamps and sorted at read time. If history is not needed, older
versions can be pruned and only the latest value retained.

Future universe synchronization should build on this model:

- default: ring-local, order-relaxed transfer;
- ordered rings: delayed apply;
- strict rings: explicit opt-in policy;
- append-only rings: timestamped accumulation and read-time sorting.

The v0.2 implementation starts this as a durable outbox: KoutenDB can persist
universe sync events in the WAL, restore them after restart, apply them
idempotently in another embedded store, acknowledge delivered events, and prune
acknowledged events. `putSynced` can write locally and enqueue a universe sync
event in the same API path when the application wants that behavior.

Ring apply policies are intentionally small:

- `latest-only` coalesces pending events with the same logical key before they
  leave the source outbox;
- `append-only` preserves event inserts and relies on read-time ordering;
- `bounded-history` keeps only a bounded number of pending versions per logical
  key;
- `delayed-timestamp` keeps events unacknowledged until the target-side delay
  window has passed.

The CLI can export and apply these events as JSONL for smoke testing and
external schedulers. It also has a one-shot local `universe-sync` command that
moves pending events between two data directories. Long-running scheduling and
remote transport can live outside the hot server loop.

Write acknowledgement is a separate policy knob. Many rings can return once the
change is durably accepted into the landing / pending log. Rings that need
read-visible confirmation can wait until the change is applied inside the
currently addressed galaxy / cluster. This is not a wait-for-every-universe
operation.

Workloads that need immediate global finality are outside the default universe
sync model. KoutenDB should keep those workloads separate instead of forcing all
galaxies and universes into the slowest consistency mode.

```nim
db.configureWriteAckMode(wamAccepted)
db.configureRingWriteAckMode("users/123/profile", wamApplied)
```

## 16. Cluster Design

Cluster mode runs multiple `koutend` nodes with a shared peer list. The client can
connect to the peer set and use the same high-level API.

Key properties:

- deterministic owner calculation;
- persistent TCP connections;
- wake/fallback handling during movement;
- primary revisit to close the TOCTOU gap during forward movement;
- ring-prefix authorization;
- simple RBAC;
- authenticated wire sessions;
- fuzz tests for protocol boundary robustness.

The cluster implementation is technical-preview grade. It is suitable for smoke
testing and design validation, not yet for production claims.

The wire protocol has an explicit `WIREVER` command and canonical little-endian
float32 vector bytes. Compatibility policy is documented in
[protocol-compatibility.md](./protocol-compatibility.md).

## 17. Authentication and Authorization

KoutenDB supports username/password style authentication with an additional
secret key concept. This is intended to feel familiar to database driver users:
an application connects with credentials rather than only relying on process or
cloud IAM boundaries.

Current authorization includes:

- ring-prefix allow rules;
- minimal role categories;
- galaxy isolation by deployment boundary;
- server-side checks before mutating operations;
- protocol behavior that drains or rejects frames safely when auth fails.

Fine-grained enterprise policy can be built later without making the core
database unusable.

## 18. Security Boundary

KoutenDB data retrieved for RAG or tools is untrusted content until a host policy
accepts it. The database should enforce storage and access boundaries, but it
should not claim to solve prompt injection, tool misuse, or application
authorization by itself.

See [threat-model.md](./threat-model.md).

## 19. Web-System Value

KoutenDB can reduce application complexity when routes and state scopes map to
rings:

- tenant data can be separated naturally;
- global state and local state can be different rings;
- user or document routes can become data coordinates;
- projection can avoid overfetching;
- import/export can operate by ring;
- future authorization can follow ring prefixes;
- flexible documents can coexist with structured retrieval.

This does not remove the need for validation. It can reduce the amount of custom
query plumbing and index planning needed for locality-heavy applications.

## 20. AI-System Value

For AI systems, KoutenDB should be used before expensive reasoning:

1. map corpus into galaxies and rings;
2. publish descriptions through atlas;
3. retrieve scoped candidates;
4. project only needed payload;
5. pass fewer chunks to rerankers or LLMs;
6. measure recall, token volume, and candidate reduction.

The database should not include model optimization in the core. Agents,
operators, or external tools can inspect atlas, explain output, stats, and
benchmarks to recommend better ring layout or profiles.

## 21. Performance Gates

Current gates for the technical preview:

- location evaluation below 100 ns/call;
- embedded and TCP local read paths in a competitive range;
- working-set reduction measured through `scanned`;
- memory-pressure reduction measured through candidate bytes;
- RAG-style token reduction with fixed recall in synthetic cases;
- Redis and PostgreSQL comparisons documented with constraints;
- reproducible scripts;
- no benchmark claim without environment and interpretation.

See [koutendb-bench.md](./koutendb-bench.md).

## 22. Operational Roadmap

Core gaps before stronger production positioning:

- broader crash and corruption tests;
- longer cluster soak tests;
- TLS and stronger wire security;
- richer RBAC / audit policy for enterprise environments;
- coordinator redundancy for cluster transactions;
- mature FAISS bridge packaging;
- observability and admin tooling;
- larger corpus benchmarks;
- multi-driver compatibility tests in CI;
- backup/restore hardening;
- migration guide from common NoSQL exports;
- clear release artifacts.

Commercial or enterprise plugins should stay outside the Apache-2.0 core and
focus on operational value: advanced audit, policy, scheduler integrations,
management UI, observability, support tooling, and ecosystem integrations.
