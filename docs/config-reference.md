---
layout: page
title: Configuration Reference
---

# Configuration Reference

This page collects the main configuration surfaces. Topology JSON has its own
full reference in [Topology Configuration](topology-config.md).

## Embedded Open

| Property | Type | Default | Meaning |
|---|---:|---:|---|
| `nodes` | integer | `8` | Logical node count for embedded placement calculations. |
| `dataDir` | string | `""` | Empty means memory-only. Non-empty enables WAL persistence. |
| `durability` | enum | `durBuffered` | `durBuffered` batches flushes; `durStrong` adds flush/fsync boundaries. |
| `diskBacked` | bool | `false` | Keep payloads in the WAL and use ring-local segment files as the derived read layout. |

## Cluster Connect

| Property | Type | Default | Meaning |
|---|---:|---:|---|
| `peers` | string | required | Comma-separated `host:port` list. |
| `username` | string | `""` | Username for password auth. |
| `password` | string | `""` | Password for username auth. |
| `authToken` | string | `""` | Token-style auth convenience path. |
| `secretKey` | string | `""` | Additional secret-key gate and encrypted auth transport. |
| `galaxy` | string | `""` | Expected remote galaxy name. |
| `tls` | bool | `false` | Use standard TLS for the TCP transport. Requires binaries built with `-d:ssl`. |
| `tlsCaFile` | string | `""` | CA/self-signed PEM file for server certificate verification. |
| `tlsServerName` | string | `""` | Optional hostname override for TLS verification and SNI. |
| `tlsInsecureSkipVerify` | bool | `false` | Skip certificate verification for local smoke tests only. |

The CLI can load these connection defaults from JSON with `--config=FILE` or
`KOUTEN_CONFIG=FILE`. Command-line flags override the file.

```json
{
  "peers": ["127.0.0.1:7301", "127.0.0.1:7302"],
  "user": "alice",
  "password": "change-me",
  "secretKey": "change-me-too",
  "galaxy": "default",
  "tls": true,
  "tlsCaFile": "/etc/koutendb/ca.crt",
  "tlsServerName": "koutendb.internal",
  "tlsInsecureSkipVerify": false
}
```

`peers` may be either a comma-separated string or an array of `host:port`
strings. The CLI accepts the documented camelCase fields and their flag-style
aliases such as `secret-key`, `auth-token`, `tls-ca`, and `tls-server-name`.
Keep production config files outside the repository, lock down file
permissions, and prefer external secret injection when the deployment platform
provides it.

## `koutend` Server Flags

`koutend` can load these server defaults from JSON with `--config=FILE` or
`KOUTEN_SERVER_CONFIG=FILE`. Command-line flags override the file.

```json
{
  "id": 0,
  "peers": ["127.0.0.1:7301", "127.0.0.1:7302", "127.0.0.1:7303"],
  "dataDir": "/var/lib/koutendb/node0",
  "diskBacked": true,
  "autoPack": true,
  "autoPackInterval": 300,
  "autoPackWindow": "01:00-04:00",
  "autoPackStaleRatio": 0.25,
  "autoPackMinStaleRecords": 256,
  "autoPackMaxRings": 1,
  "autoPackMaxBytes": 67108864,
  "autoPackMaxElapsedMs": 1000,
  "slowTick": 0.05,
  "placementEpoch": 1,
  "virtualArcsPerNode": 64,
  "coordinatorEpoch": 1,
  "coordinatorNode": 0,
  "coordinatorReplica": 1,
  "startDrained": false,
  "durability": "strong",
  "galaxy": "app-main",
  "user": "app",
  "passwordFile": "/run/secrets/koutendb-password",
  "secretKeyFile": "/run/secrets/koutendb-secret-key",
  "allowRing": ["users", "orders"],
  "roles": [
    {
      "user": "reader",
      "passwordFile": "/run/secrets/koutendb-reader-password",
      "role": "reader",
      "prefixes": ["users"]
    }
  ],
  "tlsCertFile": "/etc/koutendb/server.crt",
  "tlsKeyFile": "/etc/koutendb/server.key",
  "tlsCaFile": "/etc/koutendb/ca.crt",
  "tlsServerName": "koutendb.internal"
}
```

The config accepts camelCase names and flag-style aliases such as
`placement-epoch`, `virtual-arcs-per-node`, `password-file`,
`secret-key-file`, `tls-cert`, and `allow-ring`. Changing the peer count or
virtual-arc density requires increasing `placementEpoch` on every node.
Existing data directories must be persistently drained before that change.
Pending cluster transactions, warp jobs, and Universe sync events must also be
resolved before startup accepts the new topology.
Write-quiesced rolling scale-out migration is supported. In-place node removal fails
closed; use the explicit stop-the-world workflow documented in
[Physical Placement and Topology Remapping](topology-remapping.md). `peers`
may be a comma-separated string or an array. `allowRing` / `allow-ring` may be
a comma-separated string or an array. `roles` may contain either
`"user:password:role[:prefix1,prefix2]"` strings or objects with `user`,
`password`, `role`, and optional `prefixes`.

Validate a server config before startup:

```sh
kouten verify --server-config=/etc/koutendb/server.json
kouten doctor --server-config=/etc/koutendb/server.json --json
```

| Flag | Meaning |
|---|---|
| `--config=FILE` | Load server defaults from JSON. `KOUTEN_SERVER_CONFIG` can point to the same file. |
| `--id=N` | Node index in the peer list. |
| `--peers=host:port,...` | Static cluster peer list. |
| `--data=DIR` | Persistent data directory. |
| `--disk-backed` | Enable the ring-local segment read layout. Required by automatic packing. |
| `--slow-tick=SECONDS` | Background handoff / maintenance tick interval. |
| `--auto-pack` | Opt in to bounded automatic ring packing. Default is off. Requires `--data` and `--disk-backed`. |
| `--auto-pack-interval=SECONDS` | Minimum interval between automatic maintenance attempts. Default `300`. |
| `--auto-pack-window=HH:MM-HH:MM` | Optional UTC maintenance window. A range may cross midnight. Omit it for all day. |
| `--auto-pack-stale-ratio=F` | Per-ring stale-ratio threshold. Default `0.25`. |
| `--auto-pack-min-stale-records=N` | Per-ring stale-record threshold. Default `256`. |
| `--auto-pack-max-rings=N` | Hard ring-count limit per run. Default `1`. Must be positive for automatic packing. |
| `--auto-pack-max-bytes=N` | Hard segment/index rewrite budget per run. Default `67108864`. Must be positive for automatic packing. |
| `--auto-pack-max-elapsed-ms=N` | Elapsed-time budget per run. Default `1000`. Must be positive for automatic packing. |
| `--placement-epoch=N` | Monotonic physical placement generation. Increase it when peer count or virtual-arc settings change. |
| `--virtual-arcs-per-node=N` | Deterministic virtual arcs assigned to each node. Default `64`; changing it requires a placement epoch increase. |
| `--coordinator-epoch=N` | Monotonic cluster transaction coordinator generation. Default `1`. Increase only during explicit coordinator promotion. |
| `--coordinator-node=N` | Primary cluster transaction coordinator node index. Default `0`. |
| `--coordinator-replica=N` | Durable coordinator standby node index. Default `-1` disables redundancy. Production coordinator redundancy requires a distinct node. |
| `--start-drained` | Persist read-only maintenance drain before serving. Use it for a newly added node during rolling topology activation. |
| `--durability=buffered|strong` | WAL durability policy. Applies to server writes and local management commands such as `compact`, `backup`, and `restore`. |
| `--user=NAME` / `--password=TEXT` | Basic username/password gate. Prefer `--password-file` or `KOUTEN_PASSWORD` outside local smoke tests. |
| `--password-file=FILE` | Read the server password from a file. Trailing whitespace is stripped. |
| `--secret-key=TEXT` | Secret-key gate and secure auth transport. Prefer `--secret-key-file` or `KOUTEN_SECRET_KEY` outside local smoke tests. |
| `--secret-key-file=FILE` | Read the secret-key gate value from a file. |
| `--auth-token=TEXT` | Token-style auth convenience path. Prefer `--auth-token-file` or `KOUTEN_AUTH_TOKEN` outside local smoke tests. |
| `--auth-token-file=FILE` | Read token-style auth value from a file. |
| `--tls-cert=FILE` / `--tls-key=FILE` | Enable standard TLS for the TCP listener. Requires `-d:ssl`. |
| `--tls-ca=FILE` | CA/self-signed PEM file used by the server's peer client. |
| `--tls-server-name=NAME` | Optional hostname override for peer TLS verification and SNI. |
| `--tls-insecure-skip-verify` | Skip peer certificate verification for local smoke tests only. |
| `--galaxy=NAME` | Galaxy identity expected by clients. |
| `--allow-ring=PREFIX[,PREFIX...]` | Ring-prefix authorization boundary. |
| `--role=user:password:reader|writer|admin[:prefixes]` | Role and optional ring-prefix policy. |

Physical ownership is stable inside one placement epoch and is independent of
logical ring orbit periods. The placement tuple is persisted in the WAL.
Startup rejects epoch rollback, same-epoch topology changes, and undrained
changes to an existing topology. Empty multi-node stores above epoch `1` start
drained automatically. See
[Physical Placement and Topology Remapping](topology-remapping.md).

Coordinator assignment is independent of placement ownership. Configure the
same coordinator tuple on every node. Persistent stores reject epoch rollback
and same-epoch assignment changes. See
[Cluster Transaction Coordinator Failover](coordinator-failover.md).

Automatic packing runs on the server's existing single-owner maintenance path;
it never accesses the same `Store` concurrently from another thread. The byte
and elapsed limits are enforced while writing temporary generation files. If a
limit or process termination interrupts a pack, the manifest is not switched
and the previous complete generation remains active. Final atomic publication
and directory synchronization may finish just beyond the elapsed deadline once
publication has started. The latest run is stored atomically as
`segment-maintenance.json` in the data directory.

## Retrieval Tuning

Prefer `SearchProfile` for application-facing settings:

| Property | Values | Meaning |
|---|---|---|
| `amount` | `raFew`, `raNormal`, `raMany`, `raAllUseful` | How many useful results to retain. |
| `scope` | `ssTight`, `ssNear`, `ssWide`, `ssAll` | How broadly to search related rings. |
| `depth` | `sdShallow`, `sdNormal`, `sdDeep`, `sdVeryDeep` | How far to descend ring hierarchy. |

Lower-level knobs are still available:

| Property | Range / Default | Meaning |
|---|---:|---|
| `budget` | default `8` | Max returned retrieval hits. |
| `focus` | `0..100` | Human-facing breadth control. It maps to effective top-ring selection. |
| `topRings` | clamped internally | Direct top-ring candidate count for advanced tuning. |
| `branchBudget` | `0` means default | Per-branch hierarchy breadth. |
| `maxDepth` | `0` means no descent | Child-ring depth. |
| `includeChildren` | `false` | Include descendant rings. |

## Write Acknowledgement

| Value | Meaning |
|---|---|
| `wamAccepted` | Return after durable landing/intake. |
| `wamApplied` | Return after owner apply. |

Use `configureWriteAckMode` for the default and
`configureRingWriteAckMode` for ring-specific overrides.

## Ring Apply Policy

| Property | Type | Meaning |
|---|---:|---|
| `mode` | enum | Universe sync apply behavior. |
| `historyKeep` | integer | Bounded history size for modes that keep history. |
| `delayMs` | integer | Delay window before timestamp-ordered apply. |

Modes:

| Mode | Meaning |
|---|---|
| `ramLatestOnly` | Keep the newest logical value. |
| `ramAppendOnly` | Append timestamped data while deduplicating event IDs. |
| `ramBoundedHistory` | Keep bounded history for future undo/redo-style use. |
| `ramDelayedTimestamp` | Delay application to preserve timestamp order. |

## Topology JSON

Use [Topology Configuration](topology-config.md) for universe / galaxy recovery
layouts. The important top-level fields are:

| Field | Meaning |
|---|---|
| `version` | Schema marker. Use `1`. |
| `requiredHealthy` | Minimum healthy recovery archives. |
| `authProfiles` | Named references to external secret locations. |
| `universes` | Parallel placements. Each universe contains the same galaxy names. |

Do not store raw `username`, `password`, or `secretKey` values in topology JSON.
