# Physical Placement and Topology Remapping

KoutenDB uses two related but independent coordinate systems:

| Layer | Function | Changes with wall time |
| --- | --- | --- |
| Logical orbit | retrieval locality, `locate`, arrival and conjunction planning | Yes |
| Physical placement | authoritative server ownership and durable storage | No, within one topology epoch |

The physical coordinate is a stable hash-derived angle for the ring key. All
records in that ring therefore share one physical owner, preserving ring-local
reads. The owner is selected from a deterministic virtual-arc table:

```nim
let table = virtualArcTable(
  epoch = 3,
  nNodes = 8,
  virtualArcsPerNode = 64)
let node = table.placementOwner(ringKey)
```

Long logical orbit periods do not concentrate new writes on one node, and short
periods do not cause repeated physical transfers.

## Topology Epoch

`koutend` accepts:

```text
--placement-epoch=N
--virtual-arcs-per-node=N
```

The same values are available as `placementEpoch` and
`virtualArcsPerNode` in server JSON. The default is epoch `1` with `64`
virtual arcs per node.

The server persists this tuple in its WAL. It rejects:

- an epoch rollback;
- a node-count change without an epoch increase;
- a virtual-arc change without an epoch increase;
- a node-count decrease without a separate drain/export workflow;
- a handoff destination reporting a different epoch or topology.

Changing the peer list or virtual-arc density therefore requires an explicit
epoch increase on every node. Stop-the-world topology activation is the
supported workflow in this release; mixed-epoch rolling activation is rejected
by the migration path.

## Bounded Migration

On startup, a node builds a ring-level migration cursor from its recovered
store. The normal 100 ms maintenance tick does not scan every live record.
Instead, it submits at most `256` explicit migration or retry tasks per tick.

For each task:

1. calculate the stable physical owner;
2. verify the destination topology;
3. include the expected topology in the transfer frame so the destination
   validates it again immediately before apply;
4. transfer the original mutation version;
5. wait for destination apply/skip acknowledgement;
6. re-check that the source version is unchanged;
7. physically evict the source copy.

A failed or unavailable destination leaves the source intact and schedules
bounded exponential retry. Destination-side mutation versions and durable
tombstones reject stale values and resurrection.

Operational metrics include:

- `placementEpoch`;
- `placementVirtualArcs`;
- `migrationRemaining`;
- `migrationLagSec`;
- `handoffWorkDepth`;
- `handoffPending`;
- `handoffQueued`, `handoffApplied`, `handoffFailed`;
- `handoffQueueFull`, `handoffStaleAck`.

## Remap Measurement

`remapFraction` estimates how much angle space changes owner:

```nim
let before = virtualArcTable(3, 8, 64)
let after = virtualArcTable(4, 9, 64)
let moved = remapFraction(before, after, samples = 8192)
```

Virtual arcs preserve existing node/slot positions when a node is added, so
movement is substantially lower than rebuilding a naive equal-division
`mod nNodes` table.

## Tested Lifecycle

`scripts/placement_migration_smoke.sh` covers:

- stable physical ownership across multiple short logical orbits;
- persistent two-node writes;
- two-to-three-node epoch migration;
- destination-down retry without source deletion;
- rejection of a reachable destination on the wrong epoch;
- convergence after the correct destination starts;
- direct owner-routed reads after migration;
- restart on the settled topology with an empty migration plan.

The peer list remains static for one server process. Automated membership
discovery, live peer removal, and managed-service orchestration remain separate
operational work; they are not hidden inside the logical orbit model. This
release supports explicit scale-out migration. It fails closed on scale-in
rather than implying that removing a unique owner is data-safe.
