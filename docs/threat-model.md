# KoutenDB Threat Model

This is the canonical English threat model for the current pre-release KoutenDB
core. It is intentionally scoped to the open-source core and first-party
drivers.

## Assets

- Stored payloads, vectors, ring names, galaxy names, and atlas descriptions.
- Authentication credentials: username, password, auth token, and secret key.
- Backup artifacts: `kouten.log`, JSONL dumps, and encrypted `kouten.backup`
  files.
- Cluster transaction landing intents before owner apply.
- Warp belt jobs, progress cursors, retry state, acknowledgements, and
  dead-letter records.
- Operational metadata: health, metrics, ring summaries, and atlas maps.

## Trust Boundaries

- Embedded mode: the application process is trusted. On POSIX systems,
  KoutenDB-created data directories are owner-only (`0700`) and known store,
  segment, backup, checkpoint, and audit files are owner-only (`0600`). Host
  privilege escalation, compromised application code, and storage-device access
  remain outside KoutenDB's process boundary.
- Cluster mode: each `koutend` process is trusted after authentication. The
  network between clients and nodes is not trusted unless TLS is enabled and
  certificate verification is configured for that deployment.
- Galaxy isolation: separate data directories, peer lists, credentials, and
  secret keys define isolation boundaries.
- Drivers: official drivers must not weaken authentication, ID parsing, or error
  handling compared with the wire protocol.

## In Scope Threats

- Accidental WAL truncation, torn tail records, compact interruption, and partial
  transaction records.
- Cluster owner crash before asynchronous transaction apply.
- Unauthorized access with only username/password or only secret key.
- Backup leakage when plain `backup` / `dump` artifacts are copied outside the
  trusted environment.
- Cross-galaxy confusion caused by connecting to the wrong peer list or data
  directory.
- Credential guessing, unauthenticated ring-prefix configurations, malformed
  wire frames, and oversized count/length fields intended to exhaust resources
  or desynchronize a connection.
- Ring-authorized users inferring inaccessible records through global retrieval
  work or unscoped item-count statistics.

## Current Controls

- Length-prefixed WAL records and replay repair for torn tails.
- Atomic embedded transactions: only transactions with a commit marker replay.
- Cluster landing intents: committed intents remain until applied and are retried
  after owner restart.
- Warp belt jobs are WAL-backed and restore progress / ack state after reopen.
  Acknowledged jobs can be pruned through a tombstone record.
- Read-your-writes fallback through landing intents for `get`, `query`, and
  `batchGet`.
- `durStrong` / `--durability=strong`: flush + fsync write boundaries for
  stronger crash durability.
- Username/password authentication plus secret-key challenge response.
- Constant-time password verification, including the unknown-user path, and a
  bounded per-peer authentication failure throttle. Secret-key challenge
  negotiation does not disclose whether the requested username exists in its
  first response.
- Non-loopback plaintext password authentication fails at startup unless TLS,
  secret-key transport, or the explicit development-only
  `--allow-insecure-auth` override is configured.
- Authenticated connections are bound to the configured galaxy before database
  commands are accepted. A wrong galaxy is rejected without disclosing the
  expected galaxy name.
- Ring prefix authorization for named-ring wire operations with
  `koutend --allow-ring=prefix[,prefix...]`.
- Minimal role authorization with `reader`, `writer`, `replicator`, and `admin` through
  `koutend --role=user:password:role[:prefix1,prefix2]`.
- Explicit `peerAuth` selection for multi-node role configurations. Application
  writers cannot invoke owner-routing, handoff, cluster apply, or Universe apply
  commands; replication credentials cannot invoke normal client CRUD or reads.
  Topology-fenced maintenance migration remains admin-only.
- Wire frame bounds for header, payload, vector, and encrypted transport frame
  lengths. Oversized, negative, or malformed frames return `ERR` and close only
  the offending connection.
- Client response bounds validate item counts, body lengths, vector dimensions,
  required fields, and aggregate framing before allocation or slicing.
- Global retrieval enumerates only authorized rings, and `STATS` reports only
  records visible to a ring-scoped user.
- Deterministic malformed-frame smoke coverage in
  `scripts/cluster_wire_fuzz_smoke.sh`.
- Core and cluster smoke entry points are available through
  `scripts/test_core.sh` and `scripts/test_all_smoke.sh`.
- Standard TLS for TCP transport when `koutend` and clients are built with
  `-d:ssl`.
- nimsodium secretbox for secret-key auth transport and encrypted backups.
- Encrypted backups use Argon2id password derivation, random salt, and
  authenticated nimsodium secretbox encryption. Legacy V1 backups remain
  readable for migration.
- Galaxy binding in persistent data directories and an explicit per-connection
  galaxy handshake.
- Owner-only POSIX modes for KoutenDB-managed persistent artifacts.
- Stable protocol error categories avoid returning internal exception text.
- Public mode and transaction-state checks raise catchable validation errors;
  they do not rely on process-ending assertions at the embedded or C ABI
  boundary.

## Known Gaps

- TLS is implemented for `koutend` TCP transport. The single-node self-host
  operator validates and rolls back server certificate rotation; production
  deployments still need approved issuance, expiry monitoring, external client
  trust distribution, and certificate policy management.
- Rich role policies are intentionally not implemented. KoutenDB's primary
  isolation model is galaxy separation plus ring-prefix scope; roles remain a
  small operation-class boundary. See
  [Roles And Service Accounts](./access-control.md).
- Cluster transaction intent can be synchronously mirrored to a configured
  standby and promoted through an explicit, epoch-fenced majority operation.
  Automatic failure detection and promotion are not implemented; operators
  must confirm the old primary is unavailable before promotion.
- Write-quiesced rolling scale-out is implemented with persistent drain,
  topology fencing, bounded migration, and activation preflight. Online
  membership discovery, live writes during topology change, and live scale-in
  are not implemented.
- Audit JSONL covers embedded mutations and maintenance events plus server auth,
  authorization, galaxy, broad-scan, drain, and resume events. It is not yet an
  immutable, remotely shipped, policy-complete enterprise audit facility.
- Server-side warp scheduling is not implemented; applications must call
  `warpStep` / `warpDrain` explicitly in the current core.
- Encrypted backup uses Argon2id passphrase derivation and authenticated
  secretbox encryption. External key management and rotation are not
  implemented.
- Plain `dump` and plain `backup` remain intentionally available and must be
  treated as sensitive artifacts.
- WAL, segments, and plain backups are not encrypted at rest. Owner-only POSIX
  modes reduce accidental cross-user disclosure but do not replace encrypted
  volumes or host key management.
- Authentication throttling is per peer and in-memory. It is not a distributed
  rate limiter and does not replace an edge firewall or service-level quota.
  The bounded peer table evicts its oldest window when full, so rotating source
  addresses still require controls at the network edge.
- Deterministic malformed-frame and boundary matrices are not a substitute for
  an independent penetration test or continuous coverage-guided fuzzing.

## Deployment Guidance

- Use TLS for untrusted networks. Private networks or tunnels are still useful
  defense-in-depth and are recommended when certificate management is not yet
  operationally mature.
- Use separate galaxies, credentials, and secret keys for separate trust domains.
- Use `--durability=strong` for data where losing the last flush batch is
  unacceptable.
- Prefer `backup-encrypted` for artifacts that leave the host or trusted storage
  boundary.
- Prefer `--passphrase-file` or `KOUTEN_BACKUP_PASSPHRASE`; inline passphrases
  can be exposed through process argument inspection.
- Keep ring and atlas descriptions free of secrets; they are routing metadata,
  not protected payload fields.
- Export `kouten metrics` output to CloudWatch, Cloud Monitoring, or a similar
  system and alert on transaction backlog, error growth, auth failures, WAL
  growth, connection pressure, and unexpected restarts.

The executable security matrix and current result are documented in
[security-validation.md](./security-validation.md).
