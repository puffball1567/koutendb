# Cloud Operations Metrics

KoutenDB v0.1.0 exposes lightweight node metrics through the existing wire
protocol and CLI:

```sh
kouten metrics --peers=127.0.0.1:7301,127.0.0.1:7302,127.0.0.1:7303
```

Disk-backed embedded deployments expose their local read-layout diagnostics
separately:

```sh
kouten segment-status --data=/var/lib/koutendb --metrics
kouten verify --data=/var/lib/koutendb \
  --max-wal-bytes=107374182400 \
  --max-segment-bytes=53687091200 \
  --max-dead-ratio=0.40 \
  --max-segment-generation=1000 \
  --metrics
```

`segment-status` is read-only. It reports active ring generations, physical
and stale segment records, pack recommendations, segment/index bytes, and
process-local segment hit/WAL fallback counters. `verify` exits non-zero when
an explicitly configured capacity bound is exceeded, making it suitable for a
scheduled health check.

An opt-in disk-backed server also reports bounded maintenance counters through
the existing `metrics` command: attempts, completed/partial/interrupted/failed
runs, no-work runs, packed rings, rewritten bytes, and the last elapsed time.
The durable per-ring reasons remain available locally:

```sh
kouten maintenance-status --data=/var/lib/koutendb --json
```

Automatic maintenance is disabled by default. Configure it only with positive
ring, byte, and elapsed limits; see
[Configuration Reference](config-reference.md).

## Generation Checkpoint Operations

Create and independently verify a selected storage generation before an
upgrade, migration, or external copy:

```sh
kouten checkpoint-create \
  --data=/var/lib/koutendb \
  --checkpoint-root=/backup/koutendb-generations \
  --checkpoint-id=before-upgrade-2026-08-05 \
  --durability=strong \
  --json

kouten checkpoint-verify \
  --checkpoint=/backup/koutendb-generations/before-upgrade-2026-08-05 \
  --json
```

For a cluster node, use the admin `drain` and `snapshot` barrier before creating
the local checkpoint, then `resume` after the artifact has been verified. The
checkpoint API itself is embedded/path-based and does not coordinate a cluster
quiet point.

Retention is explicit and fail-safe:

```sh
kouten checkpoint-clean \
  --checkpoint-root=/backup/koutendb-generations \
  --keep=3 \
  --json
```

Only older verified generations are removed. Invalid generations remain for
diagnosis, and `--keep=0` is rejected. Copy or upload the entire immutable
checkpoint directory; copying only the WAL discards the selected ring-local
read generation. Verify again after transport and before promotion.

See [Generation Checkpoints](generation-checkpoints.md) for the manifest,
restore, and trust-boundary contract.

Recovery mirrors can be verified as a separate operational check:

```sh
kouten recovery-verify --mirror=/backup/koutendb-a --metrics
```

For multi-universe recovery, keep the recovery topology in a JSON file and pass
secrets separately:

```json
{
  "version": 1,
  "requiredHealthy": 2,
  "authProfiles": {
    "shared-ai": {
      "mode": "user-password-secret-key",
      "source": "secret-manager:kouten/shared-ai"
    },
    "audit-readonly": {
      "mode": "user-password-secret-key",
      "source": "secret-manager:kouten/audit-readonly"
    }
  },
  "universes": [
    {
      "universe": "tokyo-a",
      "location": "local",
      "failureDomain": "aws-ap-northeast-1",
      "authRef": "shared-ai",
      "priority": 10,
      "snapshotSeq": 1001,
      "galaxies": [
        {
          "galaxy": "training-data",
          "archive": "/backup/koutendb/training-data/tokyo-a"
        },
        {
          "galaxy": "prompt-cache",
          "archive": "/backup/koutendb/prompt-cache/tokyo-a",
          "authRef": "audit-readonly",
          "readonly": false
        }
      ]
    },
    {
      "universe": "oregon-a",
      "location": "remote",
      "endpoint": "kouten://oregon-training.internal:7301",
      "failureDomain": "aws-us-west-2",
      "authRef": "shared-ai",
      "priority": 5,
      "snapshotSeq": 1000,
      "galaxies": [
        {
          "galaxy": "training-data",
          "archive": "/backup/koutendb/training-data/oregon-a"
        },
        {
          "galaxy": "prompt-cache",
          "archive": "/backup/koutendb/prompt-cache/oregon-a",
          "authRef": "audit-readonly",
          "readonly": true
        }
      ]
    }
  ]
}
```

```sh
kouten recovery-backup --data=/var/lib/koutendb \
  --universe-config=/etc/koutendb/recovery.json

kouten recovery-status --universe-config=/etc/koutendb/recovery.json \
  --metrics

kouten recovery-restore --universe-config=/etc/koutendb/recovery.json \
  --data=/var/lib/koutendb-restored
```

Do not store passphrases in the recovery topology file. Use
`--passphrase=TEXT`, a secret manager, or a wrapper script that injects the
secret at runtime.

Each universe is a logical parallel recovery universe. Its `galaxies` array
names the KoutenDB galaxies protected by that universe and the archive location
for each galaxy. Every universe must contain the same galaxy names; only the
archive paths, endpoint, location, and failure domain should differ. `location`
describes whether that universe is local or remote from the current process.
`authProfiles` declares reusable galaxy authentication profile names, and
`authRef` tells a galaxy placement which profile to use. The supported profile
mode is `user-password-secret-key`: KoutenDB expects the resolved profile to
provide both username/password authentication and the additional secret-key
gate. The profile may point at a secret manager entry, environment convention,
or operator policy, but the topology file must not contain the actual username,
password, or secret key. A galaxy-level `authRef` overrides the universe-level
default, so multiple galaxies can deliberately use the same galaxy
authentication profile when that is operationally acceptable.
`readonly` marks a galaxy placement as readable but not writable by
`recovery-backup`; it remains eligible for verification and restore when an
archive already exists. This leaves room for remote mirrors, analysis-only
copies, restore-only copies, and future replication policies without changing
the topology format. Secrets remain outside this file.

The topology is intentionally expressed as universes that each contain galaxies,
instead of a flat list of local and remote paths. This lets KoutenDB represent a
layout that most databases do not model directly: one logical database topology
can contain both local and remote galaxy placements. That matters for AI and
large document infrastructure because the corpus can be distributed by server,
region, or trust boundary while still being managed as one coordinated KoutenDB
deployment. The current v0.2 recovery path uses that model for verification and
restore selection; future replication work should preserve the same rule that
every universe carries the same galaxy names.

Endpoints are physical placement hints, not galaxy identity. Different
universes may point at the same endpoint, and one endpoint may host different
galaxies, as long as each configured universe still contains the required galaxy
names. KoutenDB rejects duplicate galaxy names inside a single universe because
that would make the archive and policy target ambiguous.

This is intentionally not a Prometheus, OpenMetrics, Datadog, or CloudWatch
exporter yet. The output is a stable key/value line that can be scraped by a
sidecar, init script, cron job, or managed-agent integration on AWS, GCP, and
similar platforms.

## Metrics

| Metric | Meaning | Operational use |
|---|---|---|
| `node` | Node index in the static peer list | Identify the reporting node |
| `uptimeSec` | Process uptime in seconds | Restart detection |
| `requests` | Frames processed by the node | Traffic baseline and load |
| `errors` | Error responses emitted by the node | Alert on protocol, auth, or internal failures |
| `authFailures` | Failed authentication attempts | Credential abuse or misconfiguration signal |
| `authzDenied` | Authorization denials | Role/ring-prefix policy mismatch or probing |
| `connectionsAccepted` | Total accepted TCP connections | Connection churn baseline |
| `activeConnections` | Current open TCP connections | Client pressure and leak detection |
| `items` | Stored live particles/documents on the node | Capacity and skew monitoring |
| `tombstones` | Durable logical-delete guard markers retained by the node | Mutation-ordering safety and acknowledgement/reclamation pressure |
| `tombstonesReclaimed` | Guard markers safely reclaimed after all-node acknowledgement and drain grace | Confirm that delete metadata is converging instead of growing without bound |
| `rings` | Known ring metadata count | Routing/domain growth |
| `forwarders` | Active handoff forwarders | Orbital handoff pressure |
| `handoffPending` | Records currently awaiting a transfer result | In-flight orbital handoff pressure |
| `handoffQueueDepth` | Transfers waiting for the background worker | Sustained worker backlog |
| `handoffQueued` / `handoffApplied` | Cumulative accepted and acknowledged transfers | Handoff throughput and completion |
| `handoffFailed` | Transfer attempts that failed or timed out | Peer reachability or TLS/auth failures |
| `handoffStaleAck` | Acknowledgements rejected because the record or target changed | Concurrent mutation or ownership churn |
| `handoffQueueFull` | Queue submissions rejected by backpressure | Worker saturation; source copies remain retained |
| `walBytes` | Current WAL file size in bytes | Disk capacity and compaction trigger |
| `warpJobs` | Persisted warp jobs | Delayed update backlog |
| `universeSyncEvents` | Persisted universe sync outbox events | Eventual-convergence backlog / remote delivery pressure |
| `universeSyncApplied` | Durable applied universe event keys on this node | Idempotency state / replay baseline |
| `universeApplyApplied` | Process-local remote universe apply successes | Remote convergence throughput |
| `universeApplySkipped` | Process-local idempotent duplicate remote applies | Replay / retry pressure |
| `universeApplyErrors` | Process-local remote universe apply failures | Alert on malformed events, authz mismatch, or routing failure |
| `universeApplyForwarded` | Process-local UAPPLY forwards to owner nodes | Target cluster routing pressure |
| `universeApplyLastOk` | Unix timestamp of last successful remote apply on this process | Staleness detection |
| `universeApplyLastError` | Unix timestamp of last failed remote apply on this process | Recent failure detection |
| `persistent` | `1` when running with a data directory | Deployment sanity check |
| `durabilityStrong` | `1` when fsync durability is enabled | Durability policy sanity check |
| `clusterTxCommitted` | Committed cluster transaction intents | Transaction landing throughput |
| `clusterTxApplied` | Applied cluster transaction intents | Apply progress |
| `clusterTxPending` | Committed but unapplied cluster transaction intents | Retry backlog / owner failure signal |
| `clumps` | Field-state clump count | Query/index state growth |

## Recovery Mirror Metrics

`kouten recovery-verify --metrics` emits one key/value line when the recovery
mirror is valid. It exits non-zero when the mirror is missing, corrupt,
undecryptable, or inconsistent with its manifest.

| Metric | Meaning | Operational use |
|---|---|---|
| `recoveryMirrorHealthy` | `1` when verification succeeds | Alert when the command exits non-zero or this value is missing |
| `recoveryMirrorEncrypted` | `1` when verified with encrypted backup mode | Confirm the expected backup policy |
| `recoveryMirrorBytes` | Backup artifact size | Detect missing, truncated, or unexpectedly large mirrors |
| `recoveryMirrorItems` | Live item count in the recovery snapshot | Compare against source-side item trends |
| `recoveryMirrorTombstones` | Durable logical-delete marker count | Detect missing ordering state and track future reclamation pressure |
| `recoveryMirrorRings` | Ring metadata count in the recovery snapshot | Detect incomplete domain metadata |
| `recoveryMirrorNames` | Ring name count in the recovery snapshot | Detect incomplete ring map metadata |
| `recoveryMirrorClusterTx` | Cluster transaction intents in the mirror | Recovery backlog / landing-state visibility |
| `recoveryMirrorWarpJobs` | Warp jobs in the mirror | Delayed update recovery visibility |
| `recoveryMirrorUniverseSyncEvents` | Universe sync outbox events in the mirror | Eventual-sync backlog recovery visibility |

`kouten recovery-status --metrics` verifies every configured universe
independently, counts healthy universes, and exits non-zero when the configured
`requiredHealthy` threshold is not met.

| Metric | Meaning | Operational use |
|---|---|---|
| `recoveryUniverseHealthy` | `1` when enough universes are independently valid | Page when this is `0` or the command exits non-zero |
| `recoveryHealthyUniverses` | Number of universes that passed manifest and artifact verification | Track available recovery redundancy |
| `recoveryRequiredHealthyUniverses` | Minimum healthy universe count required by policy | Confirm the expected durability policy |
| `recoveryFailedUniverses` | Number of universes that failed verification | Triage damaged, stale, or unreachable archives |
| `recoveryBestPriority` | Priority of the currently preferred restore candidate | Confirm restore ordering |
| `recoveryBestSnapshotSeq` | Snapshot sequence of the preferred restore candidate | Detect stale preferred mirrors |
| `recoveryBestBytes` | Artifact size of the preferred restore candidate | Capacity and truncation sanity check |
| `recoveryBestItems` | Item count of the preferred restore candidate | Compare with source-side item trends |

## Suggested Alerts

Start with conservative alerts:

- `clusterTxPending` remains above `0` for longer than the expected owner
  restart/retry window.
- `errors` increases quickly compared with `requests`.
- `authFailures` or `authzDenied` increase unexpectedly.
- `walBytes` approaches the disk budget or grows much faster than `items`.
- `segmentRecommendedRings` remains above the maintenance budget, or a ring's
  `segmentRingStaleRatio` remains above its configured threshold.
- `segmentWalFallbacks` increases after the initial startup baseline; inspect
  segment/index health and run `verify --segments` if needed.
- `verify --max-segment-bytes`, `--max-dead-ratio`, or
  `--max-segment-generation` exits non-zero.
- `recovery-verify --metrics` exits non-zero for any required mirror.
- `recovery-status --metrics` exits non-zero or reports
  `recoveryUniverseHealthy 0`.
- `recoveryMirrorItems`, `recoveryMirrorTombstones`, `recoveryMirrorRings`, or
  `recoveryMirrorBytes` changes unexpectedly compared with the source and
  previous mirrors.
- `activeConnections` rises without returning to the normal range.
- `uptimeSec` resets outside planned maintenance.

## Cloud Mapping

On AWS, these values can be pushed as CloudWatch custom metrics by a small
sidecar or scheduled task. On GCP, use an Ops Agent custom script or a small
collector that converts the key/value response into Cloud Monitoring metrics.
Datadog can ingest the same values through a custom check or by converting them
to OpenMetrics in a sidecar.

KoutenDB does not require cloud-specific APIs in the core. The core exposes the
operational facts; deployment tooling decides how to ship them.

## Post-v0.1 Exporters

Prometheus / OpenMetrics output and a Datadog-friendly collector are v0.2+
candidates. They should live outside the core server loop so KoutenDB does not
take a dependency on any single cloud or observability vendor.
