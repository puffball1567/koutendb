# KoutenDB v0.14.1

KoutenDB v0.14.1 makes the locality model easier to evaluate from a clean
environment and adds two complete web application examples. It retains the
v0.14 storage, wire, C ABI, security, and self-host compatibility boundaries.

## Faster Evaluation Path

- a five-minute embedded CLI quickstart that writes one entity and nearby
  records, reads the bounded neighborhood, narrows it by subring, and inspects
  the resulting coordinates with Atlas;
- a task-oriented documentation index for evaluation, application integration,
  service operation, and maturity review;
- explicit installation choices for Nimble, the official GHCR server image,
  published language drivers, and source development;
- an adoption roadmap that keeps ecosystem work separate from the v1.0
  compatibility and quality gates.

## Runnable Web Application Demos

- **REKT:** React, Express, KoutenDB, and TypeScript;
- **PRK:** Prologue, React, and KoutenDB through the public Nim API.

Both Docker Compose demos expose the same responsive CRUD interface and run
against an authenticated, persistent KoutenDB node. They demonstrate category
rings, tag-related reads scoped to one ring, point reads, updates, deletion,
and moving a record when its category changes. The interface reports the ring
and candidate count so the locality boundary remains visible.

The demos are application examples, not separate supported frameworks or
benchmarks. Their source and run instructions are under `examples/web/`.

## Fixes And Documentation

- embedded `kouten atlas` now honors `KOUTEN_DATA` consistently with the other
  CLI commands;
- source-build instructions now enable TLS explicitly;
- current self-host examples and defaults use the v0.14.1 image.

## Validation

The release candidate passed the complete Linux CI suite, including core,
runtime-contract, C ABI, TLS transport, CLI, cluster, recovery, Universe, and
OCI-image checks, plus the macOS TLS-enabled C ABI build. Both web Compose
stacks were also built and exercised through the shared CRUD/locality smoke
test from clean persistent volumes.

No storage-format, wire-protocol, or C ABI version change is introduced by this
patch release. External driver releases remain versioned independently.
