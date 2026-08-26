# Security Validation Matrix

This document records the executable confidentiality and protocol-hardening
checks for the v0.14 development line. It complements the canonical
[threat model](./threat-model.md); it is not a claim of independent security
certification.

## Validation Matrix

| Boundary | Expected result | Automated evidence |
|---|---|---|
| Remote password transport | A non-loopback listener refuses plaintext password authentication unless TLS, secret-key transport, or the explicit development override is configured. | `scripts/cluster_authz_smoke.sh` |
| Ring authorization startup | Ring-prefix authorization without authentication fails at startup. | `scripts/cluster_authz_smoke.sh` |
| Authentication guessing | Repeated failures from one peer are throttled; a valid login succeeds again after the bounded block interval. | `tests/tcluster_authz.nim` |
| Authentication identity disclosure | Secret-key challenge negotiation follows the same first-response path for configured and unknown usernames. | `scripts/cli_crud_smoke.sh` |
| Galaxy isolation | Missing and incorrect galaxy handshakes are rejected before data commands; the correct galaxy is accepted. | `tests/tcluster_authz.nim` |
| Ring read isolation | Restricted users cannot retrieve, count, list, query, update, or delete outside their authorized prefixes. | `scripts/cluster_authz_smoke.sh`, `scripts/cluster_rbac_smoke.sh` |
| Retrieval side channel | Global vector retrieval visits only authorized rings. Blocked-ring payloads, counts, and physical-visit work remain outside the result. | `tests/tcluster_rbac.nim` |
| Statistics side channel | `STATS` returns the visible item count for a scoped reader and the full count for an admin. | `tests/tcluster_rbac.nim` |
| Peer credential separation | Multi-node role configs require explicit `peerAuth`; unknown and writer-role peer identities fail startup. Writer credentials cannot invoke internal apply commands, while replicators cannot invoke public CRUD or reads. A normal writer transaction is also verified through replicator-only coordinator discovery, durable mirror, fenced owner apply, and completion acknowledgement paths. | `scripts/cluster_authz_smoke.sh`, `tests/tcluster_authz.nim`, `tests/tcluster_rbac.nim` |
| Role secret-key authentication | Role users, including the peer service account, use the challenge-response and encrypted-frame path when the server secret-key gate is enabled. | `scripts/cluster_rbac_smoke.sh` |
| Migration privilege | A replicator can perform steady-state peer work but cannot submit topology-fenced migration frames; admin remains required. | `tests/tcluster_rbac.nim` |
| Coordinator routing | Transaction coordinator commands sent to a non-coordinator return the current `COORD` assignment without terminating that node. | `tests/tcluster_wire_fuzz.nim` |
| Request framing | Negative, oversized, truncated, deep, and invalid request frames are rejected while the node remains responsive. | `scripts/cluster_wire_fuzz_smoke.sh` |
| Response framing | Client parsing bounds response body lengths, item counts, vector dimensions, required fields, and aggregate payload slices before use. | `src/kouten/wire.nim`, compile checks and cluster smoke suites |
| TLS | Trusted CA succeeds; plaintext and invalid certificate paths fail closed. | `scripts/cluster_tls_smoke.sh` |
| Backup confidentiality | New encrypted backups use Argon2id password derivation plus authenticated secretbox encryption and do not contain plaintext payloads. | `tests/tstore.nim`, `scripts/cli_crud_smoke.sh` |
| Backup migration | Legacy secretbox V1 encrypted backups remain verifiable and restorable. | `tests/tstore.nim` |
| Secret input | Backup passphrases can be read from an owner-managed file or environment variable instead of process arguments; trailing line endings are removed without discarding intentional spaces. | `scripts/cli_crud_smoke.sh` |
| Local artifact permissions | On POSIX, newly created managed data directories use `0700`; WAL, segment, dump, backup, checkpoint, and audit artifacts are opened as `0600` at creation time. Symbolic-link output targets are rejected. | `tests/tstore.nim` |
| Error disclosure | Remote failures use stable protocol categories rather than raw internal exception messages. | `src/koutend.nim`, cluster smoke suites |
| Public API failure containment | Invalid mode use and closed transactions raise catchable validation errors instead of process-ending assertions, including through C ABI call paths. | `tests/tapi.nim`, `tests/tstore.nim`, `tests/tcore.nim` |
| C ABI allocation bounds | Payload, vector, batch, and C-string inputs are bounded before allocation or unbounded conversion; boolean flags and orbital ranges are validated before use. Public limits are declared in `include/koutendb.h`. | `examples/cabi_contract.c`, `scripts/driver_compat.sh` |
| C ABI runtime boundary | Drivers initialize the Nim runtime once before starting concurrent foreign threads; repeated serialized initialization is idempotent. Handles fail closed after close and callers serialize operations that share one handle. | `include/koutendb.h`, `examples/cabi_contract.c` |

## Reproduction

Run the focused matrix from the repository root:

```sh
nim c --nimcache:/tmp/kouten-tstore-cache -r tests/tstore.nim
scripts/cluster_authz_smoke.sh
scripts/cluster_rbac_smoke.sh
scripts/cluster_wire_fuzz_smoke.sh
scripts/cluster_tls_smoke.sh
scripts/cli_crud_smoke.sh
```

The complete regression entry points remain:

```sh
scripts/test_core.sh
scripts/test_all_smoke.sh
```

## Local Result

On 2026-08-26, the focused matrix and the complete `scripts/test_all_smoke.sh`
regression suite passed on the local Ubuntu development host. The run covered
authenticated TLS, galaxy and ring isolation, the four-role authorization
model, replicator-only redundant coordinator traffic, authorization-aware
retrieval metrics, malformed request handling, encrypted backup migration,
owner-only POSIX artifact modes, crash recovery, storage failures, topology
migration, and remote Universe synchronization. External driver repositories
remain outside this core validation run; the core C ABI and C ABI TLS contracts
passed separately.

The remaining boundaries are explicit: KoutenDB does not provide transparent
WAL encryption, distributed login throttling, managed certificate/key rotation,
immutable remote audit retention, or an independent penetration-test report.
