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

## Executable Failure Matrix

The coordinator suite uses three persistent nodes with strong durability. It
does not replace the separate TLS, authorization, wire-fuzz, storage-failure,
or process-crash suites; those remain part of `scripts/test_all_smoke.sh`.

| Boundary or failure | Injected condition | Required invariant |
|---|---|---|
| Promotion before drain | Send `COORDPROMOTE` to an active node | Reject; epoch and assignment remain unchanged. |
| Invalid assignment | Out-of-range node or identical primary/standby | Reject without changing durable coordinator state. |
| Same-epoch conflict | Reuse an epoch with another assignment | Reject; the existing epoch remains fenced. |
| Epoch rollback | Stage epoch N, then request N-1 | Reject before activation. |
| Partial staging | Stage one node only | Resume and new transactions remain rejected. |
| Quorum without standby | Stage a majority but not the assigned standby | Resume remains rejected. |
| Complete staging | Stage primary, standby, and quorum | Resume succeeds; role metrics match all nodes. |
| Promoted-primary restart | SIGKILL and reopen its own WAL | Epoch, assignment, active state, and tx sequence survive. |
| Standby unavailable before mirror | Termination and SIGKILL variants | Commit is not acknowledged; primary intent stays pending. |
| Exact retry after standby restart | Resend the same transaction ID and body | Commit converges once; final ring cardinality is one. |
| Duplicate mirror | Deliver the same intent twice | Both deliveries succeed without another logical intent. |
| Transaction-ID collision | Change op count, kind, parent, sequence, orbit, time, payload, codec, vector, or version | Every changed identity is rejected. |
| Duplicate completion | Deliver `TXMIRRORAPPLIED` twice | Completion is idempotent and writes one applied marker. |
| Orphan WAL operation/commit | Replay `CP` or `CC` without `CT` | Store open fails closed as WAL corruption. |
| Owner unavailable after mirror | Stop the selected owner before apply | Mirrored intent remains pending on primary and standby. |
| Standby unavailable at completion | Stop standby after owner recovery | Primary remains pending and re-seeds the standby later. |
| Standby WAL restart | Restart standby while intent is pending | Mirrored pending intent survives local WAL replay. |
| Primary loss | SIGKILL the primary with a mirrored pending intent | Standby can be explicitly promoted through quorum. |
| Stale primary return | Restart the old epoch after promotion | Stale reserve, commit, mirror, and apply paths are fenced. |
| Final convergence | Retry, restart, owner recovery, and promotion | Pending reaches zero and visible data has exact cardinality. |

This matrix intentionally distinguishes process termination from SIGKILL and
exact replay from conflicting replay. Recovery guarantees that depend on a
durable standby are tested with `durability=strong`; `coordinatorReplica: -1`
is documented as a non-recoverable compatibility mode rather than counted as a
successful failover cell.

The executable entry point is:
[`scripts/coordinator_failover_smoke.sh`](../scripts/coordinator_failover_smoke.sh).
