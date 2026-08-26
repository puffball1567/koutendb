---
layout: page
title: Roles And Service Accounts
---

# Roles And Service Accounts

KoutenDB separates application access, node-to-node replication, and operator
access. Role names are part of the server authorization model. Usernames are
deployment-defined; the names below are recommendations, not reserved names.

## Role Inventory

| Role | Recommended account | Purpose | Availability |
|---|---|---|---|
| `reader` | `kouten-reader` | Application and reporting reads within allowed ring prefixes. | Available |
| `writer` | `kouten-writer` | Normal application CRUD and client transaction operations within allowed ring prefixes. It includes normal reads. | Available |
| `replicator` | `kouten-replicator` | Node-to-node owner routing, handoff, cluster transaction apply, and Universe event apply. It is not a normal application account. | Available |
| `admin` | `kouten-admin` | Operational control, topology maintenance, metrics, recovery inspection, and every data or replication operation. | Available |

The `replicator` role is intentionally not placed between `writer` and
`admin` in a privilege hierarchy. It is a separate service role. It will not
receive ordinary application read or write access merely because it can apply
replication frames.

## Permission Matrix

| Operation class | `reader` | `writer` | `replicator` | `admin` |
|---|:---:|:---:|:---:|:---:|
| Point, ring, query, and authorized retrieval reads | Yes | Yes | No | Yes |
| Normal application put, update, delete, and transaction operations | No | Yes | No | Yes |
| Internal owner routing (`FPUT`, `FPUTR`), coordinator replication (`COORDINATOR`, `TXMIRROR`, `TXMIRRORAPPLIED`), and steady-state apply paths (`APPLYTX`, `APPLYTXF`, `TRF`, `TRFD`) | No | No | Yes | Yes |
| Cross-Universe `UAPPLY` | No | No | Yes | Yes |
| Metrics, Universe status, drain, snapshot, and resume | No | No | No | Yes |
| Topology-fenced maintenance migration | No | No | No | Yes |

Ring-prefix authorization remains an independent restriction. A role grants an
operation class; its `prefixes` decide which named rings that account may touch.
For example, a replicator scoped to `users` cannot apply an event to `billing`.

## Why Replication Has A Separate Role

Application writers and database peers do different jobs. A leaked web
application credential should not be usable to forge node handoffs or apply a
remote Universe event. Conversely, a replication credential should not become
a general-purpose application credential.

The server keeps these credentials separate:

- normal writers cannot invoke internal apply commands;
- peer credentials are selected explicitly through `peerAuth`;
- configuration order never chooses the peer identity;
- `admin` remains an emergency and maintenance override;
- topology-fenced maintenance migration remains admin-only even though it uses
  transfer frames internally.

## Server Configuration

```json
{
  "roles": [
    {
      "user": "kouten-reader",
      "passwordFile": "/run/secrets/kouten-reader-password",
      "role": "reader",
      "prefixes": ["users", "orders"]
    },
    {
      "user": "kouten-writer",
      "passwordFile": "/run/secrets/kouten-writer-password",
      "role": "writer",
      "prefixes": ["users", "orders"]
    },
    {
      "user": "kouten-replicator",
      "passwordFile": "/run/secrets/kouten-replicator-password",
      "role": "replicator",
      "prefixes": ["users", "orders"]
    },
    {
      "user": "kouten-admin",
      "passwordFile": "/run/secrets/kouten-admin-password",
      "role": "admin"
    }
  ],
  "secretKeyFile": "/run/secrets/kouten-peer-secret-key",
  "peerAuth": {
    "user": "kouten-replicator",
    "secretKeyFile": "/run/secrets/kouten-peer-secret-key"
  }
}
```

`peerAuth` identifies the credential used by this `koutend` process when it
connects to another KoutenDB node. It must refer to a configured `replicator` or
`admin` account. Its password is derived from the matching `roles` entry;
duplicating `password` or `passwordFile` inside `peerAuth` is rejected. A
multi-node role-based cluster fails startup when `peerAuth` is absent. It should
use a dedicated
replicator account instead of reusing an application writer or administrator.

`peerAuth.secretKeyFile` is the outbound peer secret. The server-level
`secretKeyFile` is the inbound secret-key gate. In a symmetric cluster they
normally point to the same externally mounted secret. An outbound secret must
match the target node's inbound secret.

Steady-state owner routing, coordinator discovery, durable transaction
mirroring, fenced owner apply, mirrored completion acknowledgement, and
replication use the `replicator` role.
Topology-fenced maintenance migration remains admin-only. During an explicit
topology migration, configure `peerAuth.user` as an admin service credential,
then restore the dedicated replicator credential after activation.

The peer secret key and TLS serve different boundaries. TLS authenticates and
encrypts the network channel. The secret-key challenge protects KoutenDB's
authentication exchange. Production peer connections should normally use both
verified TLS and externally injected credential files.

## Accounts To Create

A deployment does not have to create every optional application account. The
recommended minimum is:

| Deployment | Accounts |
|---|---|
| Read-only single node | `kouten-reader`, `kouten-admin` |
| Read/write single node | `kouten-writer`, `kouten-admin` |
| Authenticated multi-node cluster | `kouten-writer`, `kouten-replicator`, `kouten-admin` |
| Separate read and write application pools | All four recommended accounts |

Use separate credentials per environment and galaxy. Do not share production
credentials with development, and do not place plaintext passwords or secret
keys in the repository.
