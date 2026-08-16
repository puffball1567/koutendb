# Cluster Transaction Coordinator Failover

KoutenDB can keep the cluster transaction landing path available after a
coordinator process or host failure. The normal ring-local data path remains
unchanged; only committed multi-owner transaction intent is synchronously
mirrored.

## Initial Configuration

Configure the same assignment on every node. Node indexes are positions in the
static peer list.

```json
{
  "id": 0,
  "peers": [
    "10.0.0.10:17301",
    "10.0.0.11:17301",
    "10.0.0.12:17301"
  ],
  "dataDir": "/var/lib/koutendb/node0",
  "durability": "strong",
  "coordinatorEpoch": 1,
  "coordinatorNode": 0,
  "coordinatorReplica": 1
}
```

Use separate data directories for every node. Strong durability is recommended
for a coordinator pair because commit acknowledgement depends on both intent
copies reaching their configured durability boundary.

`coordinatorReplica: -1` preserves the legacy single-coordinator mode. It does
not provide coordinator failure recovery.

## Inspect The Assignment

```sh
kouten coordinator-status \
  --peers=10.0.0.10:17301,10.0.0.11:17301,10.0.0.12:17301
```

The command queries all reachable peers, selects the highest visible epoch, and
fails if peers report conflicting assignments for that epoch.

## Promote The Standby

After confirming that the old coordinator is unavailable, promote its durable
standby with a higher epoch:

```sh
kouten coordinator-promote \
  --peers=10.0.0.10:17301,10.0.0.11:17301,10.0.0.12:17301 \
  --coordinator-epoch=2 \
  --coordinator-node=1 \
  --coordinator-replica=2
```

The command:

1. discovers the current non-conflicting assignment;
2. requires the new primary to be the current primary or standby;
3. requires the new primary, new standby, and a cluster majority to be
   reachable;
4. drains reachable nodes;
5. durably stages the new epoch and assignment;
6. resumes non-primary nodes, then resumes the new primary last.

If staging or activation fails, nodes remain drained. Correct the cause and
repeat the same epoch and assignment. Do not invent another epoch merely to
retry an incomplete operation.

Update the server configuration files to the promoted epoch before restarting
the promoted nodes. Persistent stores reject coordinator epoch rollback and
same-epoch assignment changes.

## Why Promotion Is Explicit

Automatic promotion during a network partition can activate two coordinators.
KoutenDB instead makes the rare ownership change explicit and majority-gated.
Ordinary reads and writes do not pay a quorum round trip for this protection.

## Monitor

The key/value, Prometheus, and OpenMetrics surfaces include:

| Metric | Meaning |
|---|---|
| `coordinatorEpoch` | Active coordinator fencing generation. |
| `coordinatorNode` | Primary coordinator node index. |
| `coordinatorReplica` | Durable standby node index, or `-1`. |
| `coordinatorRole` | Local role: `0` follower, `1` primary, `2` standby. |
| `coordinatorReplicaReachable` | Standby state observed locally: `-1` not configured/not observed by this node, `0` unknown/unreachable/mismatched, `1` reachable with matching coordinator metadata. The primary is the active observer. |
| `coordinatorReplicaLastCheck` | Unix time of the last standby observation. |
| `coordinatorReplicaLastOk` | Unix time of the last successful standby observation. |
| `coordinatorReplicaLastError` | Unix time of the last failed or mismatched standby observation. |
| `coordinatorMirrorSucceeded` | Intent mirrors accepted by the standby. |
| `coordinatorMirrorFailed` | Intent mirror or mirrored apply-ack failures. |
| `clusterTxPending` | Committed intents not yet fully applied. |

Alert when `coordinatorReplicaReachable` remains `0`, or on any sustained
increase in `coordinatorMirrorFailed` or `clusterTxPending`. Replica health is
sampled outside ordinary ring-local request paths and therefore does not add a
round trip to normal reads or writes. A commit whose standby mirror fails is
not acknowledged as successful.

## Recovery Properties

- Pending intents survive WAL replay and compaction on both coordinator copies.
- Client reservation and commit requests must carry the active epoch in their
  transaction ID. A durable pending intent keeps its original transaction ID
  while a newer coordinator mirrors and finishes it, so promotion does not
  strand an operation acknowledged before the failure.
- A new epoch forces pending intents to be copied to the new standby before
  owner application resumes.
- A lost standby completion acknowledgement leaves the primary intent pending;
  the primary re-seeds the standby and retries after connectivity returns.
- Owner application is idempotent through transaction identity and mutation
  version checks.
- A stale primary may restart, but current-epoch nodes reject its fenced mirror
  and apply requests.

The executable failure matrix covers mirror loss, coordinator loss, owner
loss, quorum rejection, standby WAL restart, duplicate delivery, transaction-ID
collision, stale-primary fencing, and exact final cardinality:
[`scripts/coordinator_failover_smoke.sh`](../scripts/coordinator_failover_smoke.sh).
