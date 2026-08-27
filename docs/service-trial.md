---
layout: page
title: Service Trial
---

# Service Trial

The v1.0 service trial moves KoutenDB beyond scripted validation. It runs a
useful application against a persistent deployment and records whether normal
operation, maintenance, recovery, and upgrade work as documented.

Start with non-critical or reconstructible data. Good first workloads include
documentation retrieval, a searchable content catalog, application activity
context, generated metadata, or a secondary read model populated from another
source of truth. The service must still be useful; a health-check-only process
does not count.

Real application traffic does not require public adoption or high request
volume. Maintainer usage counts when requests come from a real workflow and the
application would notice missing, stale, or incorrect data. Synthetic load can
supplement that evidence, but cannot replace it.

## Choose The Data Contract

Before deployment, write down:

1. why related records belong in the selected rings;
2. which reads should remain ring-local;
3. which system is authoritative for each data class;
4. whether records can be reconstructed;
5. the maximum acceptable data loss and recovery time;
6. which operations require a transaction or cooperative lock;
7. which features are stable and which are experimental.

This prevents the trial from changing its success criteria after an incident.

## Minimum Deployment

The first service trial may use one persistent node. Use a three-node cluster
only when the application needs to exercise placement, handoff, or coordinator
recovery. A small honest topology is more useful than a large topology that no
one monitors.

For server operation, require:

- strong durability;
- disk-backed ring-local reads;
- TLS with certificate verification;
- username/password plus secret-key authentication;
- least-privilege role and ring-prefix authorization;
- secrets supplied by files or the deployment secret manager;
- persistent data and checkpoint volumes;
- a bounded automatic-maintenance policy or an explicit maintenance schedule;
- health, metrics, audit, and disk-capacity collection.

The existing Compose operational trial is a local rehearsal. A service trial
must also document the actual host, container, VM, or orchestration boundary.

## Observe The Right Signals

Collect at least:

- process uptime and restart count;
- requests, errors, auth failures, and authorization denials;
- active and rejected connections;
- item, ring, WAL, segment, and stale-record growth;
- ring-local segment hits and WAL fallback reasons;
- maintenance attempts, failures, rewritten bytes, and elapsed time;
- transaction, handoff, migration, and Universe queues when enabled;
- checkpoint verification status and age;
- application latency and error rate at the call site.

Use bounded labels. Do not put ring names, record IDs, or user-controlled values
into Prometheus labels.

## Required Operating Loop

Run this loop throughout the trial.

### Daily

- inspect health, application errors, queue depth, storage growth, and the last
  successful checkpoint;
- verify that backup/checkpoint creation completed;
- review auth failures and unexpected broad-scan diagnostics.

### Weekly

- run offline `verify` during a documented maintenance window or verify an
  immutable checkpoint independently;
- restore a selected backup or checkpoint into an isolated target;
- run representative application reads against the restored target;
- review maintenance recommendations and execute only bounded work.

### Once Per Release Candidate

- terminate the process during representative write traffic and verify reopen;
- rehearse the documented upgrade path;
- rehearse rollback or restore to the previous known-good state;
- rotate a test credential and certificate;
- confirm an unauthorized role cannot read or write outside its prefixes;
- exercise overload and malformed-request handling without losing health.

Never run a destructive drill against the only copy of the data.

## Incident Handling

For each incident, record:

- first observable symptom and detection source;
- affected version, topology, configuration, and workload;
- whether an acknowledged write was at risk;
- exact recovery commands and elapsed recovery time;
- final verification result;
- root cause and regression-test location;
- whether the outcome is a defect, documented boundary, or operator error.

Open a focused issue for reproducible defects. Close it after the fix is merged
and the regression test passes; the trial journal should link both the issue
and the validating release.

## Acceptance Criteria

The recommended v1.0 gate is at least 30 consecutive calendar days with real
application traffic. It passes only when all of the following are true:

- no acknowledged write is missing without a documented external failure
  outside the declared durability boundary;
- no corruption, authorization bypass, or incompatible state is accepted
  silently;
- monitoring covers the process, application, storage, and recovery artifacts;
- scheduled backups/checkpoints are verified;
- at least two independent restores return the expected logical data;
- controlled termination and restart preserve the documented guarantees;
- upgrade and rollback/recovery rehearsals complete from public instructions;
- unresolved incidents are classified and none violates the proposed stable
  v1.0 contract;
- the operator can explain the remaining experimental boundaries.

Do not invent an availability SLA from a lightly used trial. Publish the actual
duration, operation counts, workload, failures, and recovery results.

## Evidence To Publish

Commit a redacted summary under `docs/validation-evidence/` containing:

- release and environment information;
- topology and non-secret configuration;
- start/end timestamps and operation counts;
- final metrics and storage diagnostics;
- checkpoint/backup verification and restore results;
- incident timeline and linked fixes;
- commands required to reproduce the drills;
- explicit exclusions.

Do not commit live databases, credentials, private payloads, or huge raw logs.
The evidence should let a reviewer distinguish a continuously used service
from a process that was merely left running.
