# KoutenDB v0.14.0

KoutenDB v0.14.0 adds a reproducible self-host operations path and hardens the
database's confidentiality and trust boundaries. The release combines
versioned multi-architecture images, verified recovery workflows, safe
lifecycle automation, explicit service roles, stricter authorization, and
bounded protocol and C ABI inputs.

## Self-Hosted Operations

- official TLS-enabled `linux/amd64` and `linux/arm64` OCI image publishing
  through `ghcr.io/puffball1567/koutendb`;
- a non-root, read-only single-node Compose deployment with persistent
  strong-durability storage, generated TLS/auth configuration, and health
  checks;
- bounded watchdog restart behavior that distinguishes an unhealthy process
  from a persistent operational fault;
- checkpoint creation, staged export, independent restore verification,
  scheduled backups, and verified-generation retention;
- rollback-safe versioned image upgrades and certificate rotation;
- bounded capacity history and forecasts plus content-derived, explicitly
  approved execution plans.

The operator executes only typed KoutenDB actions. It does not provision cloud
instances, resize physical storage, or execute arbitrary infrastructure hooks.

## Confidentiality And Access Control

- separate `reader`, `writer`, `replicator`, and `admin` roles;
- explicit `peerAuth` credentials for node-to-node replication and coordinator
  traffic;
- galaxy-bound authenticated sessions and authorization-aware ring retrieval,
  listing, counting, querying, updates, deletes, and statistics;
- admin-only topology migration and maintenance boundaries;
- fail-closed non-loopback password deployment unless TLS, secret-key
  transport, or an explicit development override is configured;
- bounded authentication guessing and identity-neutral challenge negotiation;
- stable remote error categories that do not expose internal exception text.

## Storage And API Hardening

- new encrypted backups use Argon2id password derivation plus authenticated
  secretbox encryption while legacy V1 backups remain readable;
- passphrases can come from owner-managed files or environment variables;
- newly created POSIX data directories use mode `0700`, managed artifacts use
  mode `0600`, and symbolic-link output targets are rejected;
- request and response framing limits are enforced before allocation;
- C ABI payload, vector, batch, string, boolean, and orbital inputs are bounded
  and validated;
- C ABI handles fail closed after close, and public API misuse raises catchable
  errors instead of process-ending assertions.

## Validation

The release branch passed the complete core and smoke suites. The validation
includes Linux and macOS C ABI builds, CA-verified TLS, role and peer-service
authorization, galaxy and ring isolation, malformed protocol frames, encrypted
backup migration, POSIX artifact permissions, crash and storage-failure
recovery, topology migration, coordinator failover, Universe synchronization,
and OCI image construction.

The security guarantees and their executable evidence are listed in the
[Security Validation Matrix](security-validation.md). Self-host lifecycle
invariants and operational boundaries are documented in
[v0.14 Self-Hosted Operations](v0.14-self-hosted-operations.md).

External driver repository releases remain independent from this core release.
KoutenDB does not claim transparent WAL encryption, distributed login
throttling, managed fleet PKI, automatic cloud provisioning, or independent
penetration-test certification.
