---
layout: home
title: KoutenDB Documentation
---

# KoutenDB Documentation

KoutenDB is a pre-v1 ring-oriented NoSQL database. It stores data with a
coordinate-like `ring` and uses that placement at read time to reduce the amount
of data that must be searched, transferred, held in memory, and passed to
downstream AI/RAG or application logic.

## Start Here

- [Concept](koutendb-concept.md)
- [Installation](installation.md)
- [Hands-on Evaluation](hands-on-evaluation.md)
- [Service Trial](service-trial.md)
- [v1.0 Stabilization Plan](v1-stabilization.md)
- [v0.14 Self-Hosted Operations](v0.14-self-hosted-operations.md)
- [Single-Node Self-Host Bundle](https://github.com/puffball1567/koutendb/tree/main/deploy/self-hosted)
- [Public API](public-api.md)
- [Configuration Reference](config-reference.md)
- [CLI Reference](cli-reference.md)
- [How KoutenDB Differs From Typical NoSQL](nosql-positioning.md)
- [Unique Data Model And Operating Patterns](unique-data-model.md)
- [Use Case Recipes](use-case-recipes.md)
- [Technical FAQ](technical-faq.md)
- [Feature Status / Roadmap](koutendb-status.md)
- [v0.12 Implementation And Validation Record](v0.12-roadmap.md)
- [v0.13 Coordinator Redundancy Record](v0.13-roadmap.md)
- [Coordinator Failover](coordinator-failover.md)
- [Operational Trials](operational-trials.md)
- [72-Hour Strong-Durability Soak Result](soak-testing.md)
- [Accelerated Churn Testing](accelerated-churn-testing.md)
- [Benchmark Notes](koutendb-bench.md)
- [Benchmark Comparison Tables](benchmark-comparison.md)
- [Effect Validation](effect-validation.md)

## Core Guides

- [Detailed Design](koutendb-design.md)
- [Topology Configuration](topology-config.md)
- [Topology Pattern Catalog](topology-examples.md)
- [Topology Remapping](topology-remapping.md)
- [Universe Sync](universe-sync.md)
- [Data Locality](data-locality.md)
- [Generation Checkpoints](generation-checkpoints.md)
- [Time Orbit Design](time-orbit.md)
- [Data Migration](data-migration.md)
- [Container Persistence and Security Validation](container-security-validation.md)
- [External Driver Validation](external-driver-validation.md)
- [Cloud Operations Metrics](cloud-operations.md)
- [Roles And Service Accounts](access-control.md)
- [Threat Model](threat-model.md)
- [Security Validation Matrix](security-validation.md)
- [Test Coverage](test-coverage.md)
- [Audit Remediation Tracker](audit-remediation.md)
- [Development Workflow](development-workflow.md)

## Drivers And Protocol

- [Driver Installation](driver-installation.md)
- [Driver / FFI Roadmap](koutendb-driver-roadmap.md)
- [Protocol Compatibility](protocol-compatibility.md)
- [TLS Transport](tls-transport.md)
- [Query Safety](query-safety.md)
- [Payload Codecs](payload-codecs.md)
- [Exact Vector Retrieval](vector-backends.md)

## Release

- [Release Checklist](release-checklist.md)
- [v0.14.0 Release Notes](github-release-v0.14.0.md)
- [v0.13.0 Release Notes](github-release-v0.13.0.md)
- [v0.12.1 Release Notes](github-release-v0.12.1.md)
- [v0.12.0 Release Notes](github-release-v0.12.0.md)
- [v0.11.0 Release Notes](github-release-v0.11.0.md)
- [Historical v0.10 Roadmap](v0.10-roadmap.md)
