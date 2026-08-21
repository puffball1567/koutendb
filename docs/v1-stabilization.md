---
layout: page
title: KoutenDB v1.0 Stabilization
---

# KoutenDB v1.0 Stabilization

KoutenDB has reached the point where adding more features is not the shortest
path to v1.0. The remaining work is to make the existing database predictable
for a person who did not implement it, use it continuously in a maintained
application, operate it as a small service, and freeze the contracts that v1.x
must preserve.

This document is the canonical v1.0 stabilization plan. It does not assign an
RC date. KoutenDB enters RC only after the evidence gates below are complete.

## Release Sequence

1. **Human evaluation:** a new user can install KoutenDB, perform normal reads
   and writes, restart it, inspect it, back it up, and restore it by following
   one guide.
2. **Author dogfooding:** the maintainer uses KoutenDB through an application,
   not only through test scripts, and records friction and incidents.
3. **Service trial:** at least one useful, non-critical service runs against a
   persistent KoutenDB deployment with monitoring and verified recovery.
4. **Compatibility freeze:** stable storage, migration, wire, C ABI, CLI, and
   configuration contracts are named and exercised across supported releases.
5. **v1.0 RC:** only bug fixes, compatibility corrections, documentation fixes,
   and release-blocking operational work enter the RC line.

The RC is not blocked on broad market adoption. It is blocked on evidence that
the documented product can be used and recovered without private knowledge.

## Candidate Stable Surface

The following areas are candidates for the v1.x compatibility promise:

| Area | Candidate contract |
|---|---|
| Data model | galaxy, ring hierarchy, in-store record identity, JSON/raw payloads, stellar visibility |
| Embedded API | open, CRUD, ring reads, projections, transactions, locks, backup, restore |
| Persistence | acknowledged strong-durability writes survive supported restart and recovery paths |
| Portable migration | versioned JSONL dump/import remains readable across supported releases |
| Server | authenticated/TLS TCP operation, bounded requests, health, metrics, drain and snapshot |
| Cluster | static topology, deterministic placement epochs, explicit migration and coordinator promotion |
| C ABI | ABI version discovery, documented ownership, length, error, and byte-order rules |
| Operations | verify, doctor, checkpoint, backup, restore, maintenance status, and audit output |

The exact list must be frozen before RC. A feature is not automatically stable
because it exists in v0.x.

## Experimental Surface

Features may remain available in v1.0 without joining the full compatibility
promise. Current candidates include the heuristic retrieval planner, time
orbit administration, Universe convergence policy, browser/WASM work, and
automatic deployment orchestration.

Experimental features must:

- be identified in the status and API documentation;
- fail clearly when a required capability is unavailable;
- not weaken the stable persistence or recovery path;
- have an explicit migration or removal policy.

Dynamic membership, automatic coordinator failover, global serializable
transactions, and managed-service orchestration are not required for v1.0 if
their unsupported boundaries remain explicit and fail closed.

## Gate 1: Human Evaluation

The [Hands-on Evaluation Guide](hands-on-evaluation.md) must be completed from
a clean environment by following the public documentation only.

Evidence must record:

- operating system, KoutenDB version, compiler/runtime version, and install
  method;
- every command that differed from the guide;
- unclear output, missing prerequisites, and manual recovery steps;
- successful persistent reopen, dump/import, backup verification, and restore;
- the final `verify` or `doctor` result.

Documentation defects found here are release defects. They should not be
worked around only in a private script.

## Gate 2: Maintainer Dogfooding

At least one maintained application must use KoutenDB for useful state. A
benchmark generator or a process that only calls `health` does not count.

The application should exercise representative operations such as:

- repeated writes, updates, deletes, ring reads, and restart;
- the locality shape that motivated choosing KoutenDB;
- one published driver or the public Nim API;
- real error handling rather than unconditional retries;
- backup and restore from the same data shape used by the application.

Use the journal in the hands-on guide. Record normal operation as well as
failures; an empty incident log is useful only when the observation period and
operation counts are also present.

## Gate 3: Service Operation

The [Service Trial Guide](service-trial.md) defines the deployment and evidence
requirements. The recommended minimum observation window is 30 consecutive
calendar days. Duration alone is not a pass: the service must receive real
application traffic and complete the recovery drills.

Required outcomes:

- no unexplained loss of an acknowledged write;
- no silent corruption or silent authorization bypass;
- health and bounded-cardinality metrics collected continuously;
- backups or checkpoints created on schedule and verified;
- at least two restores performed into independent directories or instances;
- one controlled process termination and restart;
- one upgrade rehearsal and one rollback or restore rehearsal;
- every incident assigned a result: fixed, documented limitation, or explicit
  v1.0 blocker.

The first service should use non-critical or reconstructible data. That reduces
adoption risk without turning the trial into a synthetic demo.

## Gate 4: Compatibility And Recovery

Before RC, automated validation must cover:

1. open and migrate the maintained historical release fixtures;
2. export old stores and import them into the RC using the portable JSONL
   boundary;
3. verify same-version checkpoint and backup restore;
4. exercise supported driver versions against the RC server;
5. verify wire-version negotiation and fail-closed mixed-version boundaries;
6. test configuration parsing, deprecated fields, unknown fields, and invalid
   combinations;
7. document whether direct WAL opening from each supported v0.x release is
   supported, migrated, or rejected with recovery instructions;
8. run the crash, corruption, coordinator, TLS/auth, and storage-failure
   matrices on the RC commit.

KoutenDB must not imply that JSONL migration preserves internal record IDs when
the documented dump format reissues them. Stable claims must match executable
tests exactly.

## Gate 5: RC Review

The RC branch is ready when:

- every stable API and operational command is documented;
- stable and experimental features are labeled consistently in README, status,
  API, CLI, and configuration documents;
- all release checks pass from a clean checkout;
- service-trial evidence is linked from the repository;
- known limitations describe observable behavior and recovery, not only future
  plans;
- no open release-blocking issue remains.

After RC begins, new product features move to the post-v1 branch. The RC line
accepts only work needed to make the declared v1.0 contract true.

## Evidence Location

Commit compact, reviewable evidence under `docs/validation-evidence/`. Do not
commit live databases, secrets, raw customer content, huge logs, or generated
build trees. Prefer:

- environment and configuration summaries with secrets removed;
- compressed progress summaries;
- final health, metrics, verify, and checkpoint reports;
- hashes for deliberately deleted large artifacts;
- incident and recovery timelines;
- exact reproduction commands.

Operational evidence supports a release claim only when another person can
understand what ran, what passed, and what was not tested.
