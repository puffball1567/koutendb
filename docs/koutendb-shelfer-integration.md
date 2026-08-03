# KoutenDB x Shelfer Integration

KoutenDB and Shelfer address the same cost problem at different layers. KoutenDB
alone is not positioned as a complete answer to AI infrastructure consumption.
The strategy is a toolchain in which each component removes a different kind of
waste, reducing search scope, transfer volume, prompt tokens, worker fanout,
retries, and unsafe context inclusion in aggregate.

KoutenDB reduces the candidate set before data reaches an LLM or reranker through
placement, rings, halos, galaxies, exact vector ranking, and retrieval statistics.
Shelfer handles MCP execution boundaries, Delivery, worker routing,
token/cost budgets, RAG utility, and audit.

Therefore KoutenDB should not become Shelfer's internal database. The default
integration shape is that Shelfer sees KoutenDB as a RAG source, document source,
or retrieval source.

```text
corpus / events / documents
  -> KoutenDB galaxy / ring / exact vector retrieval
  -> KoutenDB retrieval envelope
  -> Shelfer RAG source adapter
  -> Shelfer Delivery / policy / metrics / audit
  -> LLM or allowlisted MCP workers
  -> Shelfer utility feedback
  -> KoutenDB routing and ring policy tuning
```

## Responsibility Split

| Layer | Responsibility |
| --- | --- |
| KoutenDB | document / vector storage, ring scoped retrieval, galaxy isolation, candidate reduction, payload projection, auth boundary |
| Shelfer | MCP tools/resources/prompts, Delivery queues, worker allowlists, token/cost budgets, RAG/resource utility, review and audit ledgers |
| prompt/content guard | untrusted RAG/tool/worker text inspection before LLM context inclusion |
| flow-control layer | retry, backoff, circuit breaking, bulkheads, deadlines, token/cost budgets |
| Adapter | stable JSON envelope, policy hints, metric mapping, retry/backoff integration |

KoutenDB should not expose Shelfer-specific runtime internals in its public core.
Shelfer should not depend on KoutenDB's orbital internals. The shared contract is
a small retrieval envelope plus metrics.

## Retrieval Envelope Contract

Shelfer is expected to release after KoutenDB, so KoutenDB should stabilize an
adapter-neutral retrieval envelope first. Shelfer can later implement a
consumer adapter or plugin against this contract.

Canonical constants:

| Name | Value |
| --- | --- |
| `RetrievalEnvelopeSchema` | `koutendb.retrieval.v1` |
| `RetrievalEnvelopeVersion` | `1` |

A KoutenDB-backed source returns an envelope shaped like this:

```json
{
  "schema": "koutendb.retrieval.v1",
  "version": 1,
  "source": {
    "provider": "koutendb",
    "galaxy": "tenant-a",
    "ring": "docs/security",
    "backend": "exact",
    "sourceType": "document"
  },
  "query": {
    "mode": "vector",
    "budget": 8,
    "ringScoped": true
  },
  "plan": {
    "strategy": "ring-scoped",
    "baseRing": "docs/security",
    "amount": "raNormal",
    "scope": "ssTight",
    "depth": "sdNormal",
    "ringScoped": true,
    "budget": 8,
    "focus": 0,
    "topRings": 0,
    "effectiveTopRings": 0,
    "branchBudget": 0,
    "maxDepth": 0,
    "includeChildren": false,
    "reason": "explicit ring scope",
    "selectedRings": ["docs/security"],
    "prunedRings": []
  },
  "chunks": [
    {
      "id": "0000000000000001:00000002",
      "payload": "...",
      "score": 0.93,
      "estimatedTokens": 120,
      "ring": "docs/security",
      "sourceUri": "koutendb://tenant-a/docs/security/0000000000000001:00000002"
    }
  ],
  "stats": {
    "totalVectors": 1000000,
    "scanned": 12000,
    "skippedVectors": 988000,
    "returned": 8,
    "ringsTouched": 1,
    "fanoutNodes": 2,
    "payloadBytes": 3900,
    "estimatedTokens": 975,
    "candidateReduction": 0.988
  },
  "policyHints": {
    "resourceKind": "rag",
    "resourceScope": "topic",
    "retentionClass": "normal",
    "contextReusable": true,
    "dataLabel": "internal"
  }
}
```

This keeps the contract useful for Shelfer, HTTP clients, and future drivers
without making Shelfer a hard dependency of KoutenDB.

KoutenDB exposes:

- `retrievalEnvelope(...)`: produce the canonical JSON envelope.
- `RetrievalEnvelopeSchema`: schema identifier.
- `RetrievalEnvelopeVersion`: integer schema version.
- `retrievalEnvelopeValidationErrors(env)`: return compatibility errors.
- `isValidRetrievalEnvelope(env)`: convenience boolean.

### Required Fields

| Path | Meaning |
| --- | --- |
| `schema` / `version` | Contract identity and compatibility version |
| `source.provider` | Usually `koutendb`; adapters may namespace derived providers |
| `source.galaxy` | Isolation / tenant boundary when available |
| `source.ring` | Routed ring / topic namespace when available |
| `source.backend` | `exact` for embedded retrieval or `cluster` for remote retrieval |
| `source.sourceType` | `document`, `event`, `code`, `metric`, etc. |
| `query.mode` | Retrieval mode such as `vector` |
| `query.budget` | Requested result budget |
| `query.ringScoped` | Whether the query was explicitly scoped to a ring |
| `plan` | Executed retrieval plan. Human-facing fields are `amount`, `scope`, and `depth`; numeric fields are internal diagnostics |
| `plan.ringFeatures` | Query-aware ring candidates used by the planner, including centroid similarity, ring count, and base/sibling/descendant flags |
| `chunks[]` | Ordered retrieval candidates |
| `stats` | Candidate reduction and payload/token estimates |
| `policyHints` | Advisory metadata for runtime policy |

### Compatibility Rules

- KoutenDB core may add optional fields to v1 envelopes.
- KoutenDB must not remove or rename required v1 fields without a new schema.
- Consumers must ignore unknown fields.
- Consumers should reject envelopes that fail `retrievalEnvelopeValidationErrors`.
- Policy hints are advisory. They do not change auth, galaxy isolation, or runtime policy by themselves.
- `estimatedTokens` is an approximation for routing and measurement, not a billing source of truth.

## Retrieval Plan Tuning

KoutenDB should expose query execution as a plan, similar in spirit to SQL
`EXPLAIN` and optimizer hints. The first version is deliberately non-destructive:
it changes the retrieval plan, not physical data placement.

The plan is the right place to represent ring collision / satellite / bridge
behavior before allowing any physical merge or re-parenting.

Examples:

| Situation | Plan-level expression |
| --- | --- |
| Explicit ring search | `strategy = "ring-scoped"`, `selectedRings = [baseRing]` |
| Broad search with bounded fanout | `strategy = "top-rings"`, `effectiveTopRings > 0` |
| Future parent/child traversal | `strategy = "hierarchical-ring"`, `includeChildren = true`, `maxDepth > 0` |
| Collision-like co-selection | selected sibling rings in the same plan |
| Bridge behavior | include both branches for a query family without moving data |
| Satellite behavior | prefer a child ring when entering a parent ring |

Current implementation:

- Ring names separated by `/` are registered as a hierarchy when written.
- `depth = sdDeep` / `sdVeryDeep` expands a base ring into child rings in the retrieval plan.
- `scope = ssNear` / `ssWide` / `ssAll` expands a ring to siblings under the same parent.
- The exact vector backend can search multiple selected rings in one pass.
- Ring names are persisted in the WAL and hierarchy is restored after reopen.
- Persistent embedded stores can compact the WAL with `compact` /
  `kouten compact --data=DIR`, keeping only live records and metadata.
- Persistent embedded stores can create and restore compact WAL backups with
  `backup` / `restoreBackup` or `kouten backup --data=DIR --backup=DIR` and
  `kouten restore --backup=DIR --data=DIR`. Restore can use
  `--durability=strong` when the recovered store should be validated with
  strong WAL durability immediately.
- Persistent embedded stores can export readable JSON Lines dumps with `dump`
  or `kouten dump --data=DIR --out=FILE`; this is for inspection and
  migration, not crash recovery.
- External NoSQL JSON Lines exports can be imported with routing rules:
  `importJsonl(..., ringField = "tenant", ringPrefix = "tenant/",
  payloadField = "body", vecField = "embedding")` or
  `kouten import-jsonl --data=DIR --in=FILE --ring-field=tenant`.
  The selected ring is created automatically, so imports can distribute
  existing documents into KoutenDB's ring hierarchy during ingestion.
- The builtin planner ranks expanded candidates with deterministic DB-local
  features: base ring priority, centroid similarity to the query, optional
  utility, and ring count.
- Planner selection is deterministic heuristic ranking inside KoutenDB. Model
  optimizers stay outside the read path; agents should use atlas, stats, and
  explain output to recommend profiles or ring changes.
- Physical merge, split, re-parent, bridge creation, and collision automation are still advisory/future work.

The human-facing tuning words are:

| Field | Choices | Meaning |
| --- | --- | --- |
| `amount` | `raFew`, `raNormal`, `raMany`, `raAllUseful` | How many useful chunks to return |
| `scope` | `ssTight`, `ssNear`, `ssWide`, `ssAll` | How widely KoutenDB may search across related rings |
| `depth` | `sdShallow`, `sdNormal`, `sdDeep`, `sdVeryDeep` | How deeply KoutenDB may descend through ring hierarchy |

The numeric fields (`budget`, `focus`, `effectiveTopRings`, `branchBudget`,
`maxDepth`) are diagnostics and low-level override points. Application code
should normally use the words above.

This gives each deployment room to tune for its own workload:

- low-latency systems can use `amount = raFew`, `scope = ssTight`, `depth = sdShallow`;
- recall-sensitive systems can use `amount = raMany`, `scope = ssWide`, `depth = sdDeep`;
- deep research systems can use `amount = raAllUseful`, `scope = ssAll`, `depth = sdVeryDeep`;
- tenant-sensitive systems can forbid cross-galaxy or cross-label plan expansion;
- Shelfer can compare plan variants through utility and context-investment metrics.

Physical rewrite operations such as merge, split, or re-parent should remain
explicit policy decisions. Plan changes are safe to A/B test and easy to roll back.

KoutenDB exposes named tuning profiles for this purpose:

```nim
db.configureSearchProfile("short",
  SearchProfile(amount: raFew, scope: ssTight, depth: sdShallow,
                note: "short answer"))

db.configureSearchProfile("wide",
  SearchProfile(amount: raMany, scope: ssWide, depth: sdDeep,
                note: "wider answer"))

let fast = db.retrievalEnvelopeTuned(queryVec, ring = "docs/security",
                                     profile = "short")
let broad = db.retrievalEnvelopeTuned(queryVec, ring = "docs/security",
                                      profile = "wide")
```

The analogy to RDB tuning is:

| RDB concept | KoutenDB equivalent |
| --- | --- |
| SQL text | retrieval request + base ring |
| optimizer plan | `RetrievalPlan` |
| index choice | ring / hierarchy traversal choice |
| optimizer hint | `SearchProfile` / internal `RetrievalTuning` profile |
| workload advisor | external agent using atlas and stats, not KoutenDB read path |
| `EXPLAIN` | envelope `plan` + `stats` |
| table statistics | ring summaries, ring metrics, candidate reduction |
| query plan regression test | quality-fixed `rag-bench` / Shelfer utility comparison |

## Shelfer Metric Mapping

KoutenDB already exposes `RetrieveStats` fields that map naturally to Shelfer's
RAG/resource utility and context investment metrics.

| KoutenDB field | Shelfer usage |
| --- | --- |
| `chunks[].id` | `selectedResources`, `usedItemIds`, `ignoredItemIds` |
| `source.galaxy` | `resourceProvider = "koutendb:<galaxy>"` or tenant label |
| `source.ring` | `ragNamespace` / `resourceNamespace` |
| `source.backend` | `ragProfile` / `resourceProfile` |
| `stats.estimatedTokens` | `contextLoadTokens` |
| baseline tokens - routed tokens | `qualityAdjustedSavedTokens`, when quality is unchanged |
| `candidateReduction` | retrieval efficiency signal |
| `fanoutNodes` / `ringsTouched` | routing pressure and source-selection signal |

Shelfer records whether the returned context actually changed the answer,
which chunks were used, and which chunks were ignored. KoutenDB should use that
feedback to tune ring policies and default budgets, not to silently change
authorization or runtime policy.

## Safety Boundary

KoutenDB retrieval results are data cargo. Shelfer should treat them as
untrusted RAG content until runtime policy accepts them.

- Auth, secret keys, and galaxy isolation remain KoutenDB-side access controls.
- Shelfer applies worker allowlists, labels, Delivery policy, and audit.
- Prompt/content inspection can run before KoutenDB chunks enter an LLM context.
- Plugin or adapter metadata is advisory until a Shelfer host explicitly adopts it.
- Utility feedback must not bypass tenant, galaxy, or credential boundaries.

## Implementation Order

1. Keep KoutenDB core independent and emit the stable retrieval envelope.
2. Add a small KoutenDB RAG adapter for Shelfer as a separate module or plugin.
3. Map KoutenDB `RetrieveStats` into Shelfer RAG/resource utility records.
4. Add a feedback loop that recommends ring budgets and source routing.
5. Measure quality-fixed reductions with `kouten rag-bench` and Shelfer
   context investment reports.

The important KPI is not only latency. For AI workloads the target is:

```text
same recall / answer quality
with fewer scanned vectors, fewer returned chunks, fewer prompt tokens,
less reranker work, and less worker fanout.
```
