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

Point reads are served only by the calculated current owner. A previous owner
may retain a short handoff copy, but it is not exposed as a read fallback
because it is not the authoritative serving location. Clients follow at most
two explicit owner redirects and never perform all-node fan-out.

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

Tombstones survive WAL replay, compaction, backup, and restore. Each node keeps
a local guard copy instead of deleting the marker when ownership moves. The
current orbital owner advances an acknowledgement set in `TRFD`; non-owners do
not independently fan out the marker. Once every configured peer ID has
durably applied the same delete version, the owner assigns a reclamation
deadline. The deadline covers both the bounded handoff queue and enough time
for the completed acknowledgement set to make another full orbit through the
guard copies. Final reclamation writes `LG`, so a restart cannot restore the
marker after it was safely collected.

This is deliberately not a time-only tombstone TTL. Reclamation remains
fail-closed while any configured peer is missing. The peer set must remain
stable during an acknowledgement epoch; a tombstone that names a node outside
the configured peer set is rejected rather than guessed through. Restoring an
arbitrarily old node image after reclamation is also outside the direct-restart
contract: operators must restore from a current recovery snapshot and complete
catch-up before the node may serve or hand off data. Explicit topology
generations and stale-snapshot fencing remain part of the physical placement
work.

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
