---
layout: home
title: KoutenDB Documentation
---

# KoutenDB Documentation

KoutenDB is a ring-oriented NoSQL database prototype. It stores data with a
coordinate-like `ring` and uses that placement at read time to reduce the amount
of data that must be searched, transferred, held in memory, and passed to
downstream AI/RAG or application logic.

## Start Here

- [Concept](koutendb-concept.md)
- [Installation](installation.md)
- [Public API](public-api.md)
- [Configuration Reference](config-reference.md)
- [CLI Reference](cli-reference.md)
- [How KoutenDB Differs From Typical NoSQL](nosql-positioning.md)
- [Unique Data Model And Operating Patterns](unique-data-model.md)
- [Use Case Recipes](use-case-recipes.md)
- [Technical FAQ](technical-faq.md)
- [Feature Status / Roadmap](koutendb-status.md)
- [v0.10 Roadmap](v0.10-roadmap.md)
- [Operational Trials](operational-trials.md)
- [Soak Testing](soak-testing.md)
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
- [Time Orbit Design](time-orbit.md)
- [Data Migration](data-migration.md)
- [Cloud Operations Metrics](cloud-operations.md)
- [Threat Model](threat-model.md)
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
- [GitHub Release Draft](github-release-v0.9.0.md)
