# KoutenDB v0.13.0

KoutenDB v0.13.0 removes the cluster transaction landing node as a single
point of failure. Committed multi-owner transaction intent can now be mirrored
to a durable standby and recovered through an explicit, epoch-fenced
promotion, without adding consensus traffic to ordinary ring-local reads and
writes.

## Coordinator Recovery

- persisted coordinator epoch, primary, and standby assignment;
- epoch-encoded transaction IDs with a persistent local sequence;
- durable intent mirroring before commit acknowledgement;
- explicit majority-gated standby promotion through the Nim API and CLI;
- client discovery of the highest non-conflicting visible coordinator epoch;
- re-replication of pending intent before a promoted coordinator resumes;
- fenced mirror and owner-apply operations that reject a stale primary;
- coordinator role, replica-health, mirror, and pending-intent metrics.

The compatibility setting `coordinatorReplica: -1` retains the legacy
single-coordinator mode. To enable recoverable coordination, configure the same
positive `coordinatorEpoch`, `coordinatorNode`, and distinct
`coordinatorReplica` on every peer. Strong durability is recommended for the
coordinator pair.

## Failure Validation

The new three-node strong-durability matrix verifies:

- commit refusal while the standby is unavailable, under termination and
  SIGKILL;
- exact retry after standby recovery without duplicate visible data;
- mirror and completion replay idempotency;
- fail-closed transaction identity collision handling;
- pending-intent survival across primary and standby WAL restart;
- promotion refusal without drain, quorum, or the assigned standby;
- explicit standby promotion after primary loss;
- pending-intent re-replication and exact final convergence;
- stale-primary rejection after a newer epoch becomes active;
- fail-closed replay of orphan cluster-transaction WAL records.

The full local `scripts/test_all_smoke.sh` suite passed before release,
including storage corruption, process crash, concurrent pressure, TLS, RBAC,
wire fuzzing, placement migration, Universe sync, and demo coverage.
`nimble check` also passed. GitHub CI passed its Linux core/integration/TLS/C
ABI jobs and the macOS TLS-enabled C ABI job.

## Operational Boundary

Promotion is deliberately operator-driven. KoutenDB does not guess a winner
through a network partition, and this release does not add Raft or a quorum
round trip to every write. Peer discovery remains static, cross-Universe
convergence remains separate, and managed-service health policy and automatic
orchestration remain deployment-layer responsibilities.

Configuration and recovery commands are documented in
[Coordinator Failover](coordinator-failover.md). The complete invariants and
test matrix are recorded in the
[v0.13 implementation record](v0.13-roadmap.md).
