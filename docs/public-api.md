---
layout: page
title: Public API
---

# Public API

This page summarizes the stable user-facing API surface for the current
technical preview. The canonical Nim definitions live in `src/koutendb.nim`.

## Core Types

| Type | Important fields | Meaning |
|---|---|---|
| `KoutenDb` | opaque handle | Embedded or cluster database handle. |
| `KoutenId` | opaque; printable as `parent:seq` | ID returned by `put`; pass it to `get`, `query`, `locate`, `nextVisit`, and `nextJoin`. |
| `KoutenTx` | opaque transaction handle | Transaction context returned by `beginTransaction`. |
| `GalaxyRouter` | opaque router handle | Holds named galaxy connections for applications that access multiple galaxies. |
| `KoutenRecord` | `id`, `payload` | Lightweight record returned by `listByRing`. |
| `KoutenListPage` | `items`, `nextCursor` | Cursor-paginated list result. Empty `nextCursor` means there is no next page. |
| `KoutenReadOptions` | `filter`, `selection`, `limit`, `cursor`, `pagination`, `page`, `pageLimit`, `sortField`, `sortDirection` | Ring read options shared with CLI semantics. |
| `KoutenReadPage` | `ring`, `count`, `items`, `nextCursor`, `pagination`, `page`, `pageLimit`, `sortField`, `sortDirection` | Ring read result. `count` is the number of returned items; use `countByRing` for the total ring size. |
| `KoutenStellarOptions` | `filter`, `selection`, `limitPerRing`, `subringLimits`, `subringSortFields`, `subringSortDirections`, `maxDepth`, `branchBudget`, `subrings`, `includeRoot`, `sortField`, `sortDirection` | Coordinate-near read options. A root ring behaves like a telescope target; nearby rings are visible unless narrowed by `subrings`. `limitPerRing`, `sortField`, and `sortDirection` are defaults; the `subring*` tables override them for named subrings. |
| `KoutenStellarPage` | `root`, `ringsVisited`, `count`, `rings` | Grouped result for a stellar neighborhood read. |
| `KoutenLockToken` | `scope`, `coordinate`, `token`, `fence`, `expiresAt`, `keys` | Cooperative opt-in lock token for high-integrity embedded workflows. `fence` is a monotonically increasing handle-local fencing value. |
| `KoutenHit` | `id`, `score`, `payload` | Retrieval hit. `score` is cosine similarity, higher is closer. |

`KoutenId` should normally be treated as opaque. `toRaw` and `fromRaw` exist for
C ABI / driver boundaries and CLI reproducibility, not as the preferred
application model.

## Error Types

KoutenDB still raises standard Nim exception families for compatibility.
Specialized exceptions inherit from those families so existing `ValueError`,
`IOError`, and `KeyError` handlers continue to work.

| Type | Inherits | Meaning |
|---|---|---|
| `KoutenValidationError` | `ValueError` | Invalid caller input that can be fixed before retrying. |
| `KoutenGuardrailError` | `ValueError` | An opt-in production guardrail rejected an operation. |
| `KoutenConflictError` | `IOError` | Retryable workflow conflict, such as a busy coordinate lock. |
| `KoutenOperationError` | `IOError` | Operational failure from remote cluster, durability, backup, or sync paths. |
| `KoutenNotFoundError` | `KeyError` | Requested record or maintenance job does not exist. |

The current release applies the taxonomy to the highest-value public API
boundaries first: guardrails, coordinate locks, and atomic batch validation.
Lower-level storage and network errors may still surface as their standard Nim
exception types.

## Retrieval Types

| Type | Important fields | Meaning |
|---|---|---|
| `RetrieveStats` | `totalVectors`, `scanned`, `skippedVectors`, `returned`, `ringsTouched`, `fanoutNodes`, `payloadBytes`, `estimatedTokens`, `candidateReduction` | Explains how much work retrieval avoided or performed. In cluster mode, a ring-scoped request contacts only each selected ring's physical owner; `totalVectors` is the vector population of the contacted owner nodes, counted once per node. |
| `RetrievalPlan` | `strategy`, `baseRing`, `amount`, `scope`, `depth`, `budget`, `focus`, `effectiveTopRings`, `selectedRings`, `prunedRings`, `reason` | Human-readable execution plan for retrieval tuning. |
| `RingMetric` | `ringKey`, `count`, `coherence` | Low-level ring population and coherence metric. |
| `KoutenRingSummary` | `ringKey`, `count`, `centroid`, `score`, `coherence`, `massG` | Ring summary used by atlas/planner-style workflows. |
| `RetrievalEnvelopeOptions` | `provider`, `galaxy`, `ring`, `requestId`, `sourceType`, `retentionClass`, `plan` | Metadata for RAG/MCP adapters. |

For application-facing tuning, prefer `SearchProfile` over raw numeric knobs:

| Type | Values | Meaning |
|---|---|---|
| `ResultAmount` | `raFew`, `raNormal`, `raMany`, `raAllUseful` | How much useful context to keep. |
| `SearchScope` | `ssTight`, `ssNear`, `ssWide`, `ssAll` | How broadly to search related rings. |
| `SearchDepth` | `sdShallow`, `sdNormal`, `sdDeep`, `sdVeryDeep` | How far to descend ring hierarchy. |
| `SearchProfile` | `amount`, `scope`, `depth`, `note` | Named human-facing retrieval profile. |
| `RetrievalTuning` | `budget`, `focus`, `topRings`, `branchBudget`, `maxDepth`, `includeChildren` | Lower-level retrieval knobs. Use when you need explicit tuning. |
| `KoutenGuardrails` | `maxPayloadBytes`, `maxVectorDim`, `maxRingCount`, `maxRecordsPerRing` | Opt-in write-path limits for production trials. Zero means disabled. |

## Sync And Job Types

| Type | Important fields | Meaning |
|---|---|---|
| `UniverseSyncEvent` | `id`, `eventKey`, `sourceUniverse`, `sourceGalaxy`, `ring`, `logicalKey`, `payload`, `timestamp`, `acknowledged`, `error` | Durable eventual-convergence event in the source outbox. |
| `UniverseSyncStats` | `read`, `applied`, `skipped`, `acked`, `pruned`, `errors` | One-shot sync result. |
| `RingApplyPolicy` | `mode`, `historyKeep`, `delayMs` | Per-ring universe apply behavior. |
| `RingApplyMode` | `ramLatestOnly`, `ramAppendOnly`, `ramBoundedHistory`, `ramDelayedTimestamp` | How a ring treats replay, history, and delayed timestamp apply. |
| `WarpJob` | `id`, `rings`, `whereField`, `equals`, `patch`, `status`, `attempts`, `retryAt`, `acknowledged`, `error` | Delayed ring-scoped JSON patch job. |
| `WarpStepResult` | `job`, `scanned`, `matched`, `updated` | Result from one `warpStep`. |
| `WarpStatus` | `wsPending`, `wsRunning`, `wsDone`, `wsFailed`, `wsDeadLetter` | Warp job lifecycle. |

## Persistence Types

| Type | Important fields | Meaning |
|---|---|---|
| `CompactStats` | store-defined | Result of WAL compaction. |
| `BackupStats` | store-defined | Result of backup / verify / restore operations. |
| `KoutenOperationalVerifyReport` | object | Data-dir operational verification report. |
| `KoutenOperationalCheck` | object | One named operational verification check. |
| `DumpStats` | `bytes`, `records`, `rings`, `documents`, `destination` | JSONL dump summary. |
| `ImportStats` | `read`, `imported`, `skipped`, `errors`, `rings`, `batches`, `batchSize`, `source`, `defaultRing` | JSONL import summary, including chunked bulk-load commit information. |
| `KoutenDurability` | `durBuffered`, `durStrong` | WAL durability mode. |

## Handles

| API | Purpose |
|---|---|
| `open(dataDir = "", nodes = 8, durability = durBuffered)` | Open embedded KoutenDB. Omit `dataDir` for memory-only mode. |
| `connect(peers, username = "", password = "", authToken = "", secretKey = "", galaxy = "")` | Connect to a running `koutend` cluster. |
| `close(db)` | Close embedded or cluster resources. |
| `openGalaxyRouter()` | Create a local router for multiple named galaxies. |
| `addGalaxy(router, name, peers, ...)` | Register a remote galaxy connection. |
| `galaxy(router, name)` | Get a `KoutenDb` handle for one galaxy. |

## Documents

| API | Purpose |
|---|---|
| `put(payload, ring = "default", vec = @[])` | Store a string payload in a ring. |
| `put(doc: JsonNode, ring = "default", vec = @[])` | Store a JSON document. |
| `put(encodedPayload(bytes, codec), ring, vec)` | Store `raw`, `json`, `nif`, or `bif` bytes with format metadata. |
| `putNear(baseRing, payload/doc/encoded, ring, vec = @[])` | Store under a nearby coordinate derived from `baseRing/ring`, for example `users/123` + `orders` -> `users/123/orders`. The near hint is not stored separately. |
| `get(id)` | Fetch by KoutenDB ID. |
| `getEncoded(id)` | Fetch payload bytes together with their `PayloadCodec`. |
| `query(id, selection)` | Fetch a JSON projection using GraphQL-style selection syntax. |
| `prepareSelection(selection)` / `query(id, prepared)` | Validate and compile a reusable projection before execution. |
| `koutenFilter().eq(key, value)` / `koutenFilter().id(id)` | Build JSON read filters without string-concatenated query text. |
| `exists(id)` / `contains(id)` | Check whether an ID exists. |
| `update(id, payload)` / `update(id, doc)` | Replace an existing document. |
| `patch(id, patchDoc)` | Apply a JSON merge patch. |
| `deleteById(id)` / `remove(id)` | Delete by ID. |
| `batchPut(payloads, ring, vecs)` | Insert multiple records. |
| `batchPutAtomic(payloads/docs, ring, vecs)` | Embedded all-or-nothing bulk insert. Rolls back every staged write if any step fails. |
| `batchGet(ids)` | Fetch multiple IDs. |
| `batchDelete(ids)` | Delete multiple IDs. |
| `batchUpdateAtomic(ids, payloads/docs, vecs)` | Embedded all-or-nothing bulk replace. Every ID must exist before commit. |
| `batchDeleteAtomic(ids)` | Embedded all-or-nothing bulk delete. |

The C ABI exposes matching additive functions: `kouten_put_codec`,
`kouten_put_vec_codec`, and `kouten_get_codec`. See [Payload Codecs](payload-codecs.md).

## Ring Reads

| API | Purpose |
|---|---|
| `listByRing(ring, limit = 100, cursor = "")` | List records in one ring with cursor pagination. |
| `readRing(ring, options = defaultReadOptions())` | Read one ring with filter, selection, cursor/page limit, and page-local sort. |
| `readStellar(root, options = defaultStellarOptions())` | Read the root ring and nearby coordinate rings. Parent, child, and sibling rings can be in the same field of view; distant rings are not forced into the read path. |
| `configureTimeOrbitProfile(ring, profile)` | Configure an embedded ring-local time orbit for log/event placement. The profile is persisted as ring metadata. |
| `timeOrbitProfile(ring)` | Read the effective time-orbit profile for a ring. |
| `putTime(payload/doc, ring, timestampMs)` | Store a log/event payload into the calculated time-bucket ring. JSON object payloads receive `eventTimeMs` and `ingestTimeMs` when missing. |
| `readTime(ring, fromMs, toMs, options)` | Calculate the affected time-bucket rings and read only those buckets, using normal read filters/projection inside each bucket. |
| `defaultReadOptions().withFilter(koutenFilter().eq(...))` | Apply a typed filter builder to ring reads. |
| `defaultStellarOptions().withFilter(koutenFilter().eq(...))` | Apply a typed filter builder to stellar reads. |
| `nearRing(baseRing, ring)` | Resolve a write-time nearby coordinate, for example `nearRing("users/123", "orders") == "users/123/orders"`. |
| `countByRing(ring)` | Count records in one ring. |
| `retrieve(queryVec, ring = "", budget = 8, ...)` | Vector/RAG-style retrieval with ring-aware planning. |
| `retrievalPlan(...)` | Build a readable retrieval plan without executing it. |
| `tunedRetrievalPlan(db, profile = "default", ...)` | Build a plan from a stored profile. |
| `searchPlan(...)` | Build a plan from human-facing amount/scope/depth terms. |
| `ringMetrics()` | Return low-level ring metrics. |
| `localityReport()` | Return physical WAL locality metrics for embedded stores. |
| `ringSummaries(queryVec = @[])` | Return ring centroids, coherence, mass, and optional similarity scores. |
| `retrievalEnvelope(...)` | Return retrieval results with source metadata for RAG/MCP adapters. |

## Placement And Observability

| API | Purpose |
|---|---|
| `locate(id, at = -1.0)` | Compute the owning node for an ID at the current or specified time. |
| `nextVisit(id, node)` | Compute when an ID next visits a node. |
| `nextJoin(a, b)` | Compute the next co-location time for two KoutenDB IDs. |
| `stats()` | Return per-node item counts. |

## Transactions

| API | Purpose |
|---|---|
| `beginTransaction()` | Start a transaction. |
| `tx.put(...)` | Stage a write. |
| `tx.update(...)` | Stage an update. |
| `tx.remove(id)` | Stage a delete. |
| `tx.commit()` | Commit. |
| `tx.rollback()` | Roll back. |
| `transaction(db, proc(tx))` | Helper that rolls back on exception. |

Cluster transactions are a PoC. They use a landing intent and retry apply, but
coordinator redundancy is still planned.

## Cooperative Locks

Coordinate locks are opt-in guards for high-integrity embedded workflows. Normal
`put`, `get`, `list`, and `retrieve` do not check these locks, so the lightweight
NoSQL path remains unchanged. Use locks around workflows that need explicit
coordination, idempotency, or rollback behavior.

| API | Purpose |
|---|---|
| `acquireRingLock(ring, ttlSeconds = 30.0, waitMs = 0)` | Acquire a cooperative lock for one ring coordinate. |
| `acquireStellarLock(stellar, ttlSeconds = 30.0, waitMs = 0)` | Acquire a cooperative lock for a stellar lens and its current member rings. |
| `releaseLock(token)` | Release a lock if the owner token still matches. |
| `withRingLock(ring, proc())` | Acquire/release a ring lock around a body. |
| `withStellarLock(stellar, proc())` | Acquire/release a stellar lock around a body. |

Each acquired lock gets a distinct token and an increasing `fence` value. A
later reacquire after TTL expiry cannot be accidentally released by an older
token.

These locks are not presented as a payment-ledger or financial-core mechanism.
They are intended for application workflows such as order state updates,
webhook processing, retry-safe maintenance, and coordinated edits around a ring
or stellar lens.

## Atlas And Descriptions

| API | Purpose |
|---|---|
| `setGalaxyDescription(description)` | Set a galaxy-level map description. |
| `getGalaxyDescription()` | Read the galaxy description. |
| `setRingDescription(ring, description)` | Set a ring map description. |
| `getRingDescription(ring)` | Read a ring description. |
| `atlas()` | Return a galaxy/ring map for agents and tools. |

## Persistence And Data Movement

| API | Purpose |
|---|---|
| `compact()` | Rebuild the WAL from live records. |
| `backup(dstDir)` | Create a compact backup. |
| `backupEncrypted(dstDir, passphrase)` | Create an encrypted backup. |
| `verifyBackup(backupDir)` | Verify a backup. |
| `operationalVerify(dataDir, diskBacked = true, verifySegments = false, maxWalBytes = -1, maxSegmentFiles = -1, maxItems = -1, maxRings = -1)` | Open and inspect a persistent embedded data directory, optionally failing when WAL bytes, segment-file count, item count, or ring count exceed configured trial thresholds. |
| `auditLogPath(dataDir)` / `auditLogPath(db)` | Return the append-only audit JSONL path for persistent embedded stores. |
| `restoreBackup(backupDir, dataDir, overwrite = false, durability = durBuffered)` | Restore into a data directory. |
| `restoreEncryptedBackup(backupDir, dataDir, passphrase, overwrite = false, durability = durBuffered)` | Restore an encrypted backup into a data directory. |
| `dump(path = "", includeVectors = true)` | Export `koutendb.dump.v1` JSONL with ring, payload, vector, and codec metadata. |
| `importJsonl(path, defaultRing = "imported", ...)` | Import KoutenDB dump JSONL or external JSONL with ring routing. |

## Universe Sync And Warp

| API | Purpose |
|---|---|
| `putSynced(...)` | Store locally and append a universe sync event. |
| `universeSyncEvents(includeAcknowledged = false)` | Inspect source outbox events. |
| `applyUniverseSyncEvent(event)` | Apply one sync event idempotently. |
| `ackUniverseSyncEvent(eventId)` | Mark a source event acknowledged. |
| `pruneAckedUniverseSyncEvents()` | Remove acknowledged source events. |
| `syncUniverseOnce(source, target, pruneAcked = false)` | One-shot local data-dir sync. |
| `enqueueWarp(...)` | Queue a delayed ring-scoped JSON patch. |
| `warpStep(jobId, maxRecords = 100)` | Advance one warp job. |
| `warpDrain(jobId)` | Run a warp job until done or bounded. |
| `ackWarp(jobId)` / `pruneAckedWarpJobs()` | Acknowledge and clean completed jobs. |

## Configuration APIs

| API | Purpose |
|---|---|
| `configurePlannerBackend(kind)` | Select deterministic planner backend. |
| `configureRetrievalTuning(profile, ...)` | Define numeric retrieval knobs. |
| `configureSearchProfile(name, amount, scope, depth)` | Define human-facing retrieval profile. |
| `configureRing(ring, period)` | Configure ring orbit period. |
| `configureWriteAckMode(mode)` | Set default write acknowledgement mode. |
| `configureRingWriteAckMode(ring, mode)` | Override write acknowledgement per ring. |
| `configureRingApplyPolicy(ring, policy)` | Configure universe apply behavior for one ring. |
| `configureGuardrails(guardrails)` / `guardrails()` | Configure or inspect opt-in write-path limits. |

See [Configuration Reference](config-reference.md) for property names and
recommended defaults.
