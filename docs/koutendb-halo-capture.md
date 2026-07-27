# KoutenDB Halo Capture Design

This document describes the halo-capture mechanism at an implementation level.
It expands the design notes for data that arrives without a strong ring.

Status: partially implemented. The store supports vector payloads,
transactions, forwarding records, exact vector retrieval, and slow maintenance
hooks. The full capture policy is intentionally conservative and belongs on the
slow path.

## 1. Summary

Halo particles are records whose final ring is unknown or weakly justified at
write time. A single halo particle is too light to force a new ring or to be
adopted into an existing heavy ring. The slow layer can maintain semantic
clumps, then adopt a clump into a target ring only when evidence remains strong
for long enough.

The physical analogy is a loose rubble pile being captured by a larger body and
distributed into a ring. The database rule is simpler:

```text
halo particles
  -> budgeted micro-clustering
  -> clumps with centroid, mass, coherence, and age
  -> conservative capture decision
  -> adopt into a target ring with forwarding records
```

Version 1 treats an adopted clump as immediately distributed into the target
ring. A future version may preserve moonlet-like clumps as first-class objects.

## 2. Terms

| Term | Meaning |
|---|---|
| Halo | Reserved weak-placement area for records without a reliable ring |
| Clump | A group of halo particles with centroid, members, mass, and coherence |
| Adopt | Reinsert clump members into a target ring and create forwarding records |
| Forwarder | Mapping from old halo ID to new ring ID, usually with a TTL |
| Slow tick | Periodic maintenance loop that must not enter the hot read path |
| Heavy | A strong existing ring or ring summary that can capture a clump |

## 3. Invariants

1. The fast layer stays unchanged. `locate`, owner selection, and basic reads
   must not run capture logic.
2. Capture is one-way in v1. If a clump was adopted incorrectly, remediation is
   a future split or manual migration workflow.
3. Halo TTL still applies. A particle that never becomes useful can expire.
4. Capture requires persistence. Adopted records must survive restart, and old
   IDs should resolve through forwarders during the migration window.
5. The implementation must remain ARC-friendly: no cyclic object graphs and no
   unbounded references from clumps to live store internals.

## 4. Data Model

The slow layer needs these logical structures:

```nim
type
  HaloParticleRef* = object
    parent*: uint64
    seq*: uint32

  HaloClump* = object
    id*: uint64
    centroid*: seq[float32]
    members*: seq[HaloParticleRef]
    mass*: float64
    coherence*: float64
    nearestRing*: string
    distanceToNearest*: float64
    firstSeen*: int64
    lastSeen*: int64
    stableTicks*: int

  CapturePolicy* = object
    maxParticlesPerTick*: int
    maxClumps*: int
    minMass*: float64
    minCoherence*: float64
    maxDistance*: float64
    minStableTicks*: int
    forwardTtlSeconds*: int64
```

The concrete implementation may store these in `src/kouten/field.nim` and persist
only the durable state required for recovery.

## 5. Entry Points

Capture can be triggered by:

- inserting a vector without a useful ring;
- importing JSONL records whose route rule cannot assign a strong ring;
- periodic slow maintenance;
- an explicit CLI command for maintenance or testing.

The write path should only tag weak placement. It should not run clustering or
adoption synchronously.

## 6. Budgeted Micro-Clustering

The slow tick should process bounded work:

1. Select up to `maxParticlesPerTick` halo particles.
2. Compare each particle to existing clump centroids.
3. Add it to the nearest compatible clump, or create a new clump if under
   `maxClumps`.
4. Update centroid, mass, coherence, and timestamps.
5. Drop or merge weak clumps when policy limits are exceeded.

The dependency-free exact vector path is shared by production, tests, and
embedded deployments. Halo maintenance must keep its candidate set bounded
instead of relying on a broad external vector index.

## 7. Capture Decision

A clump can be adopted only when all conditions pass:

- `mass >= minMass`
- `coherence >= minCoherence`
- nearest target ring is known
- distance to target ring is below `maxDistance`
- the decision has remained stable for at least `minStableTicks`
- the target galaxy/ring policy permits adoption

The conservative bias is intentional. False negatives leave data in the halo;
false positives pollute a ring and can damage retrieval quality.

## 8. Adopt Operation

Adoption should be transactional at the single-store level:

1. Read clump members.
2. Insert each payload into the target ring.
3. Create forwarders from old IDs to new IDs.
4. Mark the old halo entries as forwarded or expired.
5. Persist all changes through the WAL transaction boundary.

Cluster-wide adoption should not require a cross-galaxy synchronous transaction.
If adoption spans nodes, the first production version should use an asynchronous
maintenance job with retry and audit state.

## 9. Wire Protocol

Forwarding requires read-side support:

- `GETID` for an old halo ID may return the new payload or a forward response.
- Clients should treat forwarding as transparent where possible.
- Debug or maintenance clients may expose the forward chain.

Forward loops are invalid and must be rejected or cut off with a small maximum
depth.

## 10. Parameters

Initial defaults should be conservative:

| Parameter | Suggested default | Reason |
|---|---:|---|
| `maxParticlesPerTick` | 1024 | bounded slow-path work |
| `maxClumps` | 4096 | prevents unbounded metadata growth |
| `minMass` | 8.0 | avoids adopting single stray records |
| `minCoherence` | 0.80 | requires semantic consistency |
| `maxDistance` | backend-specific | depends on embedding scale |
| `minStableTicks` | 3 | avoids one-tick noise |
| `forwardTtlSeconds` | 86400 | enough time for old IDs to resolve |

All production-facing values should be configurable.

## 11. Tests

Required tests:

- halo records do not affect ordinary ring-scoped retrieve until adopted;
- coherent clumps are adopted only after the stable-tick threshold;
- incoherent clumps are not adopted;
- forwarders resolve old IDs after adoption;
- adoption persists through reopen;
- compaction preserves live adopted records and valid forwarders;
- capture work is bounded per slow tick;
- restart during adoption does not create duplicate live state.

## 12. Future Work

Future versions may add:

- moonlet-like clump objects before full adoption;
- split and re-parent workflows;
- utility-based capture thresholds;
- adapter-driven scheduling with FlowBrigade;
- admin UI for inspecting halo candidates;
- quality-fixed retrieval tests that compare before and after adoption.
