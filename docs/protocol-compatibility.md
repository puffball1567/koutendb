# KoutenDB Protocol / Compatibility Policy

This is the canonical compatibility note for KoutenDB's current technical
preview.

## Scope

KoutenDB currently exposes two external contracts:

- C ABI: `KOUTEN_ABI_VERSION`
- TCP wire protocol: `WIREVER`

Both are intentionally small. They are stable enough for local drivers and
smoke tests, but KoutenDB does not yet claim long-term production compatibility
across arbitrary mixed-version clusters.

Additive C ABI functions may retain the current ABI version when existing
struct layouts, calling conventions, and symbol behavior do not change. The
v0.12 disk-backed open, CRUD completion, bounded-maintenance, and generation-
checkpoint JSON functions follow this rule, preserving ABI v2 for already-
published wrappers.

## Wire Protocol

The wire protocol is a KoutenDB-specific text-header protocol with length-prefixed
payloads. It is easy to inspect and fuzz, but compatibility must be managed
explicitly as commands grow.

Rules:

- Clients should check `WIREVER` before assuming command compatibility.
- Minor command additions may preserve the same version only when old clients
  can safely ignore them.
- Any incompatible frame, payload, numeric, or response change must bump
  `WireProtocolVersion`.
- Drivers should prefer high-level named-ring commands such as `PUTR`, `GETID`,
  `QRYID`, `BGET`, `UAPPLY`, and `USTATUS` instead of constructing internal
  placement metadata themselves.
- `CODECS` reports the payload format identifiers accepted by the node.
- Oversized `RETRIEVE` work is rejected with the existing stable error path
  (`ERR bad-request`). The response shape of successful `RHIT` frames is not
  changed by the query-cost guard.

Ownership redirects may append the calculated owner node to `FWD` responses.
The field is additive: older clients may ignore it, while current clients use
it to redirect directly instead of probing every node.

`TOPOLOGY` reports the physical placement epoch, node count, and virtual arcs
per node. Current clients use this response to reconstruct the same deterministic
virtual-arc table as the server. Cluster connections fail closed if this
metadata is unavailable or disagrees with the configured peer count; silently
falling back to legacy equal arcs would risk misrouting writes. Point reads are served only by the stable
physical ring owner. During topology migration, a source retains its copy until
the destination has applied the versioned transfer. Internal transfer frames
also carry an optional placement fence (`epoch`, node count, and virtual-arc
density), which the destination validates immediately before applying the
mutation. Clients follow at most two explicit owner redirects and never perform
all-node fan-out.

Ring-scoped `RETRIEVE` follows the same stable placement table and is sent only
to the selected ring's physical owner. On the server, it walks the durable
ring index rather than filtering a whole-node record scan after the fact.
Global retrieval intentionally remains an all-node operation. The additive
`METRICS` counters `retrievePhysicalVisited` and `retrieveCandidatesScored`
make the difference observable without changing the successful `RHIT` frame.
Draining nodes reject retrieval after consuming the declared vector body, so
topology migration cannot turn an incomplete owner copy into a silent empty
result or corrupt the next frame on a persistent connection.

`ACTIVATION` is an admin-only local readiness report:

```text
ACTIVATION READY|ACTIVE|BLOCKED <epoch> <nodes> <virtualArcs> <migrationPending>
```

`resume` clients compare this response across every configured peer before
requesting activation. Each server repeats peer topology/readiness checks before
clearing its persistent drain marker.

Topology-fenced `TRF` / `TRFD` frames may append `MIGRATION`. A drained server
accepts that path only for an admin-authenticated request with an exact topology
fence. Ordinary transfer frames and writer-role attempts remain rejected while
drained.

Scale-in uses admin-only operator commands rather than exposing migration
primitives as normal driver CRUD:

- `MIGMETA` applies topology-fenced ring/galaxy/stellar/forwarder metadata;
- `MIGVERIFY` compares a record or tombstone mutation version without changing
  target state;
- `MIGMETAVERIFY` compares topology-fenced metadata without changing target
  state.

Body-carrying migration commands drain their declared body before returning a
topology error, preserving the next frame boundary on a persistent connection.
These commands are used by `kouten scale-in-*`; application drivers should not
use them directly.

## Mutation Ordering

Particle and logical-delete transfer frames carry an optional hybrid logical
mutation version:

```text
<physicalMicros> <logical> <origin>
```

The tuple is compared lexicographically at the destination. A destination
rejects duplicate or older values, and a durable tombstone rejects a delayed
value that predates the delete. `TRF` appends the version after the codec;
`TRFD` transfers a logical-delete tombstone without a payload. Existing `TRF`
frames without these fields remain readable and derive a compatibility version
from `tWrite`.

Mixed-version rolling upgrades preserve old value transfers, but logical delete
convergence requires every receiving node to understand `TRFD`. An older node
rejects that unknown command; the upgraded source retains the tombstone and
retries instead of acknowledging or pruning it. Upgrade all cluster nodes
before relying on cross-node delete convergence.

Physical source eviction is deliberately separate from logical deletion.
Moving an acknowledged source copy writes a physical `D` record; application
deletion writes a versioned logical `L` tombstone. This prevents a normal
handoff departure from deleting the accepted destination value.

Tombstones survive WAL replay, compaction, backup, and restore. Delete
propagation is explicit and bounded by the configured peer count; it no longer
depends on a logical orbit carrying the marker through every node. Once every
configured peer ID has durably applied the same delete version, the completed
acknowledgement set is sent to every guard copy. Reclamation waits for that
fanout and the bounded stale-transfer drain window. Final reclamation writes
`LG`, so a restart cannot restore the marker after it was safely collected.

This is deliberately not a time-only tombstone TTL. Reclamation remains
fail-closed while any configured peer is missing. Handoff workers also verify
the destination's placement epoch and topology before transferring a record.
A tombstone that names a node outside the configured peer set is rejected
rather than guessed through. Restoring an
arbitrarily old node image after reclamation is also outside the direct-restart
contract: operators must restore from a current recovery snapshot and complete
catch-up before the node may serve or hand off data.

## Payload Codec Metadata

`PUT`, `PUTR`, transaction apply, and handoff frames may append one codec name:
`raw`, `json`, `nif`, or `bif`. Clients that need response metadata first send
`CODECMETA ON`; negotiated `VAL`, `ITEM`, and `HIT` response headers then append
the stored codec where applicable. Clients that do not negotiate retain the
original response shape. Missing metadata is interpreted as `raw` for
compatibility with existing WAL records and drivers.

NIF/BIF bytes are opaque to KoutenDB core. The core preserves them across WAL
replay, cluster transfer, and retrieval but does not bundle a NIF/BIF encoder
or decoder. Use the optional
[`koutendb-nif`](https://github.com/puffball1567/koutendb-nif) adapter when an
application needs NIF text / BIF byte conversion. See
[Payload Codecs](payload-codecs.md).

## Vector Byte Order

TCP wire vector bytes are canonical little-endian IEEE-754 `float32` values.
This is now encoded and decoded explicitly in `src/kouten/wire.nim`; native wire
drivers must follow the same byte order.

The C ABI is different: C ABI calls accept normal host-native `float` arrays
inside the same process. The ABI boundary does not serialize those floats onto
the network directly.

## WAL / Snapshot Compatibility

The internal WAL is not the long-term external migration format before v1.0.
New WAL files start with `!KOUTENDB-WAL 2` and store each logical record behind
a length + CRC32 wrapper. This lets KoutenDB reject corrupted versioned records
instead of silently treating shifted payload bytes as later headers.

Legacy pre-v1.0 WAL records remain readable for migration and tests, but new
writes and compacted snapshots use the versioned format. For portable,
human-readable migration across releases, use `kouten dump` and
`kouten import-jsonl` rather than copying or editing WAL internals directly.
See [Data Migration](data-migration.md) for the supported JSONL boundary.

Generation checkpoints are versioned separately as
`koutendb-checkpoint-v1`. They are immutable restore artifacts that bind one
compact WAL to its ring segment/index files through a checksum inventory and a
manifest completion marker. They are not the pre-v1 portable migration format:
restore them with the same compatible KoutenDB release line, and use JSONL dump
and import when crossing an unsupported storage-format boundary.

## Production Readiness Boundaries

KoutenDB has username/password/secret-key auth, ring-prefix authorization, simple
RBAC, and deterministic wire fuzz smoke tests. For enterprise production claims,
the remaining gaps are still material:

- certificate issuance, rotation, and expiry monitoring for TLS deployments;
- richer role policy and audit logs;
- cluster transaction coordinator redundancy;
- explicit mixed-version upgrade tests for wire, WAL, snapshots, and drivers.

Until those land, expose `koutend` only on trusted networks or behind a tunnel /
proxy that provides transport security.

## Planner Boundary

The default retrieval planner is deterministic heuristic ranking. This is
deliberate: it keeps the DB predictable and avoids embedding a model optimizer
in the core. KoutenDB's strongest current evidence is measured working-set and
token reduction under documented synthetic workloads. Broader production claims
must come from larger real-corpus benchmarks and planner improvements.
