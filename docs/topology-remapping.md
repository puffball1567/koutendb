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
virtual arcs per node. `--start-drained` / `startDrained` persists a read-only
maintenance marker before topology activation.

The server persists this tuple in its WAL. It rejects:

- an epoch rollback;
- a node-count change without an epoch increase;
- a virtual-arc change without an epoch increase;
- an existing data directory changing topology without persistent drain;
- an in-place node-count decrease without the explicit scale-in workflow;
- a handoff destination reporting a different epoch or topology.

Changing the peer list or virtual-arc density therefore requires an explicit
epoch increase on every node. Nodes may restart one by one, but application
writes remain quiesced until every configured peer reports the same topology
and no migration work remains. This is write-quiesced rolling activation, not
zero-downtime live membership change.

## Write-Quiesced Rolling Activation

The safe scale-out or virtual-arc-change workflow is:

1. run `kouten drain` and `kouten snapshot` against the old cluster;
   resolve pending cluster transactions, warp jobs, and Universe sync events
   before changing the topology;
2. restart each existing node, one at a time, with the complete new peer list
   and a higher placement epoch;
3. start added empty nodes with `--start-drained` as an explicit operator
   signal; empty multi-node stores starting above epoch `1` also drain
   automatically;
4. keep application traffic away while mixed epochs are present;
5. wait for `activationMigrationPending` to reach `0` on every node;
6. run `kouten resume` against the complete new peer list.

During the mixed-epoch interval, ordinary writes remain rejected. A migration
transfer can cross the drain boundary only when it carries the exact topology
fence, has the explicit `MIGRATION` marker, and authenticates as admin. A normal
writer cannot forge this path. Wrong-epoch destinations reject the transfer,
and the source copy remains durable for retry.

Ring coordinates, names, descriptions, payload profiles, and time-orbit
profiles travel with the first successful ring migration to a new owner.
Activation therefore does not rely on payload counts alone: the metadata needed
for named reads, authorization, codec interpretation, and time-local lookup is
present before the source copy is evicted.

`kouten resume` performs a cluster-wide preflight before changing any node:

- every configured peer must be reachable;
- epoch, node count, and virtual-arc density must match;
- each node must be either drained-and-ready or already active;
- migration work must be zero on every node.

Each server repeats the peer preflight before clearing its own persistent drain
marker. If the command is interrupted after some nodes resume, rerunning it is
idempotent. The brief partial-resume window may reject a write routed to a node
that is still drained, but it cannot acknowledge the write on an old topology.

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

## Explicit Scale-In

Node removal is intentionally not an in-place startup operation. KoutenDB uses
a stop-the-world workflow that copies persistently drained old node directories
into a fresh, smaller target topology. This avoids making an old survivor serve
two placement epochs or silently dropping records owned by a removed node.

The safety boundary is:

1. stop application writes to the old cluster;
2. run `kouten drain` against every old node;
3. run `kouten snapshot` and stop the old server processes;
4. start a fresh smaller target cluster with a higher placement epoch, but do
   not expose it to application traffic; fresh targets above epoch `1` start
   drained automatically;
5. plan, migrate, and verify every old node data directory;
6. activate the target with `kouten resume` only after every source reports
   successful verification;
7. retain the old directories and checkpoint files until the target has passed
   the operator's acceptance and backup window.

Example: migrate three old nodes into a fresh two-node epoch:

```sh
OLD_PEERS=127.0.0.1:7301,127.0.0.1:7302,127.0.0.1:7303
NEW_PEERS=127.0.0.1:7401,127.0.0.1:7402

kouten drain --peers="$OLD_PEERS" --user=admin \
  --password-file=/run/secrets/kouten_admin
kouten snapshot --peers="$OLD_PEERS" --user=admin \
  --password-file=/run/secrets/kouten_admin

# After stopping the old processes, repeat these commands for node0, node1,
# and node2. The new servers use placementEpoch=2 and fresh data directories.
kouten scale-in-plan --data=/var/lib/koutendb/old/node0 \
  --peers="$NEW_PEERS" --user=admin \
  --password-file=/run/secrets/kouten_admin
kouten scale-in-migrate --data=/var/lib/koutendb/old/node0 \
  --peers="$NEW_PEERS" --user=admin \
  --password-file=/run/secrets/kouten_admin
kouten scale-in-verify --data=/var/lib/koutendb/old/node0 \
  --peers="$NEW_PEERS" --user=admin \
  --password-file=/run/secrets/kouten_admin
```

`scale-in-migrate` writes a durable checkpoint named
`kouten.scale-in.<targetEpoch>.json` in the old node directory by default.
`--checkpoint=FILE` places it elsewhere. The source WAL is never deleted or
rewritten. A stopped target or interrupted command can therefore resume from
the last acknowledged record:

```sh
kouten scale-in-status \
  --checkpoint=/var/lib/koutendb/old/node0/kouten.scale-in.2.json
kouten scale-in-migrate --data=/var/lib/koutendb/old/node0 \
  --peers="$NEW_PEERS" --checkpoint-every=1000 --max-transfers=100000
```

The checkpoint is bound to the source WAL fingerprint, source topology, target
peer list, and target topology. A changed source or target is rejected instead
of resuming against a different migration.

### What Is Preserved

Scale-in transfers more than live payload bytes:

- live records, vectors, codecs, and mutation versions;
- durable tombstones, so delayed stale writes cannot resurrect deleted data;
- ring coordinates, names, and descriptions;
- ring payload/charset/format profiles;
- ring time-orbit profiles;
- stellar maps;
- forwarders;
- galaxy identity and non-empty galaxy descriptions.

Without this metadata, raw record counts could match while named ring reads,
codec interpretation, time-orbit lookup, stellar visibility, or moved-ID
routing silently changed. `scale-in-verify` independently checks records,
tombstones, and these metadata objects on their calculated target owners before
marking the checkpoint as verified.

Committed-but-unapplied cluster transactions, warp jobs, and pending Universe
sync events are not guessed or silently copied. Resolve those queues before
scale-in; their ordering and acknowledgement state have separate semantics.

### Deliberate Limits

- This workflow has a maintenance window. It does not claim live scale-in.
- Target data directories must be fresh for this workflow.
- The target must remain outside application routing until all old node
  directories are migrated and verified.
- `--reset-checkpoint` discards progress tracking, not source data. Re-sending
  records is version-idempotent, but resetting should remain an operator
  decision.
- Live writes during topology change and membership discovery remain separate
  work.

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
- persistent write drain across one-by-one mixed-epoch restarts;
- resume rejection while a peer has the wrong epoch or migration is pending;
- admin-only, topology-fenced migration transfer through drain;
- convergence after the correct destination starts;
- cluster-wide activation preflight and post-resume write acceptance;
- direct owner-routed reads after migration;
- restart on the settled topology with an empty migration plan.

`scripts/scale_in_migration_smoke.sh` covers:

- persistent drain enforcement;
- three-to-two-node migration into fresh target directories;
- bounded checkpoint progress and resume;
- target outage without source WAL modification or false progress;
- wrong/mixed target epoch rejection;
- topology-fenced record, tombstone, and metadata transfer;
- independent record/tombstone/metadata verification;
- stale, missing, wrong-kind, and metadata-mismatch rejection;
- pending transaction/warp/Universe queue rejection;
- idempotent re-execution and source/checkpoint fingerprint checks.

The peer list remains static for one server process. Automated membership
discovery, live-write topology changes, live peer removal, and managed-service
orchestration remain separate operational work; they are not hidden inside the
logical orbit model. This release supports write-quiesced rolling scale-out and
stop-the-world scale-in migration. Live scale-in remains unsupported and fails
closed.
