# Operational Trials

KoutenDB v0.10 adds an operational evaluation path for users who want to try a
persistent deployment shape before putting important data behind it.

The goal is not to pretend that a Compose file is a managed service. The goal is
to make a small trial repeatable:

- start an authenticated persistent node;
- write through the live TCP server;
- stop the server before direct data-dir maintenance;
- verify WAL replay, metadata, segment layout, and locality;
- create and verify a backup;
- inspect the append-only audit JSONL file.

## Compose Trial

Use `examples/compose/operational-trial.compose.yml`. The server reads static
node settings from `examples/compose/operational-server.json`; the Compose file
still passes password and secret-key values as overrides so the checked-in JSON
does not need to contain deployment secrets.

Start the node:

```sh
docker compose -f examples/compose/operational-trial.compose.yml up -d --build
docker compose -f examples/compose/operational-trial.compose.yml ps
```

Check live health:

```sh
docker compose -f examples/compose/operational-trial.compose.yml exec -T kouten-app \
  koutencli health --peers=127.0.0.1:7301 \
  --user=app --password=change-me --secret-key=change-me-too
```

Write one live record:

```sh
docker compose -f examples/compose/operational-trial.compose.yml exec -T kouten-app \
  koutencli put --peers=127.0.0.1:7301 \
  --user=app --password=change-me --secret-key=change-me-too \
  --ring=users/123/profile --payload='{"name":"Alice"}' --codec=json
```

Stop the server before direct data-dir verification. This is intentional:
embedded maintenance opens the data directory and should not bypass the
single-writer lock held by the server.

```sh
docker compose -f examples/compose/operational-trial.compose.yml stop kouten-app
```

Verify the persistent data directory:

```sh
docker compose -f examples/compose/operational-trial.compose.yml --profile tools run --rm kouten-tools \
  'koutencli verify --data=/data/app-main --segments --json'
```

Create and verify a backup:

```sh
docker compose -f examples/compose/operational-trial.compose.yml --profile tools run --rm kouten-tools \
  'koutencli backup --data=/data/app-main --backup=/backup/app-main'
docker compose -f examples/compose/operational-trial.compose.yml --profile tools run --rm kouten-tools \
  'koutencli verify --backup=/backup/app-main --json'
```

Inspect the audit log:

```sh
docker compose -f examples/compose/operational-trial.compose.yml --profile tools run --rm kouten-tools \
  'tail -n 20 /data/app-main/kouten.audit.jsonl'
```

Clean up:

```sh
docker compose -f examples/compose/operational-trial.compose.yml down
```

Add `-v` to `down` only when you intentionally want to delete the named data
and backup volumes.

## What This Proves

This trial proves the local operational loop:

- the server can run with authentication and persistent storage;
- the health path is available over TCP;
- direct data-dir verification exercises WAL replay and the data-dir lock;
- segment layout can be rebuilt from the WAL source of truth;
- backups can be created and verified before restore;
- audit events are written to append-only JSONL for operational inspection,
  including server-side auth, authz, and broad retrieve guard events on
  persistent `koutend` nodes.

It does not prove:

- cloud managed-service behavior;
- online backup while a server holds the embedded data-dir lock;
- multi-region disaster recovery;
- enterprise audit policy completeness.

Those are larger deployment topics. The v0.10 trial is deliberately smaller:
it should be easy to run, inspect, and challenge.
