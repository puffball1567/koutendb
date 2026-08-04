---
layout: page
title: CLI Reference
---

# CLI Reference

Install the command:

```sh
nimble install koutendb
kouten --help
```

When working from a source checkout, install the local package onto your PATH:

```sh
nimble install -y
kouten --help
```

Nimble installs binaries into `~/.nimble/bin` by default. If `kouten` is not
found, add it to your shell PATH:

```sh
export PATH="$HOME/.nimble/bin:$PATH"
```

For persistent shell setup:

```sh
printf '\nexport PATH="$HOME/.nimble/bin:$PATH"\n' >> ~/.profile
```

For server-style installs, use `/usr/local/bin`:

```sh
nim c -d:release --nimcache:/tmp/nimcache_kouten -o:bin/kouten src/koutencli.nim
nim c -d:release --nimcache:/tmp/nimcache_koutend -o:bin/koutend src/koutend.nim
sudo install -m 0755 bin/kouten /usr/local/bin/kouten
sudo install -m 0755 bin/koutend /usr/local/bin/koutend
```

For repo-local development without installing, you can also build and run a
local binary:

```sh
nim c -d:release --nimcache:/tmp/nimcache_kouten -o:bin/kouten src/koutencli.nim
bin/kouten --help
```

## Common Cluster Flags

| Flag | Meaning |
|---|---|
| `--config=FILE` | Load cluster connection defaults from JSON. CLI flags override the file. `KOUTEN_CONFIG` can point to the same file. |
| `--peers=host:port,...` | Target cluster. |
| `--user=NAME` / `--password=TEXT` | Username/password auth. Prefer `--password-file` or `KOUTEN_PASSWORD` outside local smoke tests. |
| `--password-file=FILE` | Read password from a file. Trailing whitespace is stripped. |
| `--auth-token=TEXT` | Token-style auth. Prefer `--auth-token-file` or `KOUTEN_AUTH_TOKEN` outside local smoke tests. |
| `--auth-token-file=FILE` | Read token-style auth value from a file. |
| `--secret-key=TEXT` | Secret-key gate. Prefer `--secret-key-file` or `KOUTEN_SECRET_KEY` outside local smoke tests. |
| `--secret-key-file=FILE` | Read the secret-key gate value from a file. |
| `--galaxy=NAME` | Expected remote galaxy. |
| `--tls` | Use standard TLS for the TCP transport. Requires TLS-enabled binaries built with `-d:ssl`. |
| `--tls-ca=FILE` | CA/self-signed PEM file for server certificate verification. |
| `--tls-server-name=NAME` | Optional hostname override for TLS verification and SNI. |
| `--tls-insecure-skip-verify` | Skip certificate verification for local smoke tests only. |
| `--metrics` | Emit key/value metrics where supported. |
| `--json` | Emit JSON where supported. |

Example:

```json
{
  "peers": ["127.0.0.1:7301"],
  "user": "alice",
  "passwordFile": "/run/secrets/kouten_password",
  "secretKeyFile": "/run/secrets/kouten_secret_key",
  "tls": true,
  "tlsCaFile": "/etc/koutendb/ca.crt"
}
```

```sh
kouten health --config=/etc/koutendb/client.json
kouten get --config=/etc/koutendb/client.json --ring=docs/japan
```

## Cluster Commands

| Command | Purpose |
|---|---|
| `health` | Check cluster health. |
| `metrics` | Emit server metrics. |
| `rings` | Show ring summaries. |
| `atlas` | Emit the galaxy/ring map. Works with `--data` or `--peers`. |
| `drain` | Put cluster nodes into read-only maintenance mode. Requires admin auth. |
| `snapshot` | Flush cluster nodes and report a snapshot barrier. Requires admin auth. |
| `resume` | Leave drain mode only after every peer has the same topology and zero migration backlog. Requires admin auth. |
| `shutdown` | Stop a server. |
| `demo` | Run a small cluster demo. |

For maintenance or backup windows, use `drain`, then `snapshot`, then run the
backup or replacement operation, and finally `resume`:

```sh
kouten drain --peers=127.0.0.1:7301,127.0.0.1:7302 --user=admin --password-file=/run/secrets/kouten_admin
kouten snapshot --peers=127.0.0.1:7301,127.0.0.1:7302 --user=admin --password-file=/run/secrets/kouten_admin
kouten resume --peers=127.0.0.1:7301,127.0.0.1:7302 --user=admin --password-file=/run/secrets/kouten_admin
```

Drain mode rejects new write commands, including body-carrying frames, after
consuming their remaining payload bytes. That keeps the TCP protocol boundary
intact so the same connection can continue to serve reads and admin commands.
`snapshot` is a flush/report barrier; use it after `drain` when a quiet point is
required. `resume` first checks every configured peer. Unreachable peers, mixed
placement epochs, and pending migration all fail closed without clearing the
local drain marker.

## Scale-In Commands

Scale-in copies persistently drained old node directories into a fresh smaller
cluster with a higher placement epoch. Run each source directory separately
and keep the target outside application routing until all sources verify.

| Command | Purpose |
|---|---|
| `scale-in-plan` | Validate the source/target boundary and report record, tombstone, metadata, and per-target counts without writing. |
| `scale-in-migrate` | Transfer versioned records, tombstones, and database metadata with a durable resumable checkpoint. |
| `scale-in-verify` | Independently compare target mutation state and metadata before activation. |
| `scale-in-status` | Read a checkpoint without connecting to either cluster. |

```sh
kouten scale-in-plan --data=/var/lib/koutendb/old/node0 \
  --peers=127.0.0.1:7401,127.0.0.1:7402 --json
kouten scale-in-migrate --data=/var/lib/koutendb/old/node0 \
  --peers=127.0.0.1:7401,127.0.0.1:7402 \
  --checkpoint-every=1000
kouten scale-in-verify --data=/var/lib/koutendb/old/node0 \
  --peers=127.0.0.1:7401,127.0.0.1:7402 --json
kouten scale-in-status \
  --checkpoint=/var/lib/koutendb/old/node0/kouten.scale-in.2.json
```

Authentication and TLS flags are the same as other cluster commands. See
[Physical Placement and Topology Remapping](topology-remapping.md) for the
complete maintenance order, safety boundaries, and recovery behavior.

## Driver Commands

KoutenDB keeps language drivers small and publishable as language-native
packages. External drivers can live outside the core repository while the
`kouten` CLI keeps the discovery path consistent.

```sh
kouten driver list
kouten driver info rust
kouten driver install rust
kouten driver install rust --manifest-path=/path/to/Cargo.toml
```

`driver install` currently prints the official repository/package path and
package-manager command. It does not execute remote scripts or download code.
For Rust it resolves the target `Cargo.toml` in this order:

1. `--manifest-path=FILE`
2. `KOUTEN_DRIVER_MANIFEST`
3. `--project-dir=DIR`
4. `KOUTEN_DRIVER_PROJECT`
5. `Cargo.toml` in the current directory

Pass `--execute` to run the package-manager command when the selected driver is
published and the target project can be resolved. KoutenDB refuses to execute
package-manager commands for unpublished drivers and prints the command
instead.

| Command | Purpose |
|---|---|
| `driver list` | Show known official driver targets and their publication status. |
| `driver info LANG` | Show repository, package name, mode, and notes for one driver. |
| `driver install LANG` | Print the recommended setup command and target project path. |

## Document Commands

These commands work with `--data=DIR` for embedded mode and `--peers=...` for a
running cluster. When `--data=DIR` is omitted, embedded commands use
`KOUTEN_DATA` if set, otherwise `./data`.

```sh
kouten put --ring=docs/japan --payload='{"title":"Hello"}' --codec=json
kouten get --ring=docs/japan
kouten put --ring=orders --near=users/123 --payload='{"orderNo":"A-001"}' --codec=json
kouten get --ring=users/123 --subring=orders
kouten get --stellar=users/123 --filter='{"kind":"order"}' --subring=orders
kouten get --ring=users/123 --subring=profile,orders,billing --subring-limit=orders:10,billing:1 --subring-rsort=orders:time
kouten stellar attach --stellar=commerce/order/A-001 --ring=users/123
kouten stellar detach --stellar=commerce/order/A-001 --ring=users/123
kouten get --ring=docs/japan --limit=1 --rsort=time
kouten get --ring=docs/japan --pagination=on --page=2 --pagelimit=20 --sort=id
kouten get --ring=docs/japan --filter='{"id":"RAW_ID"}' --selection='{ title }'
kouten get --ring=docs/japan --filter='{"status":"draft"}' --selection='{ title }'
kouten count-ring --ring=docs/japan
```

Codec is explicit at write time. If you do not pass a codec, KoutenDB stores the
payload as `raw` bytes unless `--codec=auto` resolves to a ring profile.

```sh
# JSON document: projection and JSON filters can be used later.
kouten put --ring=docs/japan --payload='{"title":"Hello","status":"draft"}' --codec=json
kouten get --ring=docs/japan --filter='{"status":"draft"}' --selection='{ title }'

# NIF text: stored as NIF-tagged bytes. KoutenDB does not parse it as JSON.
kouten put --ring=docs/nif --in=sample.nif --codec=nif
kouten get --ring=docs/nif --limit=1

# BIF binary: stored as BIF-tagged bytes. `auto` view decodes through an
# optional adapter when available; otherwise it returns base64.
kouten put --ring=docs/bif --in=sample.bif --codec=bif
kouten get --ring=docs/bif --limit=1
kouten get --ring=docs/bif --limit=1 --view=base64
kouten get --ring=docs/bif --limit=1 --view=hex

# Plain raw bytes or text.
kouten put --ring=logs/raw --payload='plain text payload' --codec=raw
kouten get --ring=logs/raw --limit=1
```

| Command | Required flags | Purpose |
|---|---|---|
| `put` | `--ring=RING` plus `--payload=TEXT` or `--in=FILE`; optional `--near=BASE_RING`, `--codec=auto|raw|json|nif|bif` | Store a document and print `id`, `rawId`, resolved ring, and codec. `--near=users/123 --ring=orders` stores into the nearby coordinate `users/123/orders`. `auto` uses the ring profile. |
| `get` | `--ring=RING` or `--stellar=RING`; optional `--subring=a,b`, `--subring-limit=a:10,b:1`, `--subring-sort=a:id`, `--subring-rsort=b:time`, `--filter=JSON`, `--selection=SEL`, `--limit=N`, `--cursor=CURSOR`, `--sort=id|time`, `--rsort=id|time`, `--pagination=on|off`, `--page=N`, `--pagelimit=N`, `--view=raw|auto|base64|hex` | Read the ring or stellar coordinate's neighborhood. It always returns an `items` array and includes per-ring groups in `rings`. Use `--subring` to narrow the field of view. `--limit` is the default per-ring limit for stellar reads; `--subring-limit` overrides it for named subrings. `--subring-sort` and `--subring-rsort` override sort order for named subrings. A `--filter='{"id":"RAW_ID"}'` read stays on the exact ring path for script compatibility. Sorting is applied to the fetched page/filter window, not as a global full-ring sort. The default view is `auto`: payload codec is inferred from stored metadata. |
| `stellar attach` | `--stellar=RING --ring=RING` | Add an existing ring coordinate to a stellar coordinate's visible lens. Payloads are not copied. |
| `stellar detach` | `--stellar=RING --ring=RING` | Remove a ring coordinate from a stellar coordinate's visible lens. Payloads are not deleted. |
| `stellar list` | `--stellar=RING` | List rings attached to a stellar coordinate. |
| `time-orbit` | `--data=DIR --ring=RING`; optional `--bucket-ms=N`, `--bits=N`, `--phase=N`, `--salt=TEXT` | Read or update the embedded ring-local time-orbit profile used by `time-put` and `time-get`. Remote profile administration is not available yet. |
| `time-put` | `--data=DIR --ring=RING --time-ms=N` plus `--payload=TEXT` or `--in=FILE` | Store a log/event payload into the ring's calculated time bucket. JSON object payloads receive `eventTimeMs` and `ingestTimeMs` metadata when missing. |
| `time-get` | `--data=DIR --ring=RING --from-ms=N --to-ms=N`; optional `--filter=JSON`, `--selection=SEL`, `--limit=N`, `--sort=id|time`, `--rsort=id|time` | Calculate the affected time-bucket rings and read only those buckets. The response includes `bucketsVisited`, `rings`, and `items`. |
| `query` | `--ring=RING --filter='{"id":"ID"}' --selection=SEL`; optional `--id=ID` | Compatibility command for JSON projection by ID. Prefer `get --selection=...` for new CLI use. |
| `list-ring` | `--ring=RING` | Compatibility command for listing records in one ring. Prefer `get --ring=...` for new CLI use. |
| `count-ring` | `--ring=RING` | Count records in one ring. |
| `ring-profile` | `--ring=RING` | Read or update the persisted `defaultCodec`, `charset`, and `formatVersion` declaration. |

For example:

```sh
kouten ring-profile --ring=docs/nif --codec=nif --charset=UTF-8 --format-version=1
kouten put --ring=docs/nif --payload='(example)' # codec=nif via the profile
```

The profile is advisory. Every record keeps its explicit codec, so a later
profile change does not reinterpret existing bytes. Remote profile
administration is not available in this release.

Time orbit is an embedded PoC for log/event/time-series placement:

```sh
kouten time-orbit --ring=logs/api --bucket-ms=1000 --bits=60 --phase=100 --salt=api
kouten time-put --ring=logs/api --time-ms=1784376000000 \
  --payload='{"level":"error","message":"timeout"}'
kouten time-get --ring=logs/api --from-ms=1784376000000 --to-ms=1784376300000 \
  --filter='{"level":"error"}' --selection='{ level message eventTimeMs }'
```

`--filter` is a JSON object. `{"id":"RAW_ID"}` performs an exact read, while
other top-level fields filter JSON records in the selected ring. `--where` is
accepted as a compatibility alias for `--filter`.

`--near` is a write-time placement hint, not a persistent relationship field.
For example, `kouten put --near=users/123 --ring=orders ...` writes the record to
`users/123/orders`. Later reads use the coordinate itself:

```sh
kouten get --ring=users/123
kouten get --stellar=users/123 --filter='{"kind":"order"}' --subring=orders
kouten get --ring=users/123/orders
kouten get --ring=users/123 --subring=orders
```

This is similar to pointing a telescope at a ring. Nearby satellites are in the
same field of view; distant rings are not pulled in just to emulate a global
join.

`stellar attach` and `stellar detach` adjust a stellar coordinate's lens after
data already exists:

```sh
kouten put --ring=users/123 --payload='{"kind":"user"}' --codec=json
kouten put --ring=shops/1123 --payload='{"kind":"shop"}' --codec=json
kouten put --ring=orders/A-001 --payload='{"kind":"order"}' --codec=json

kouten stellar attach --stellar=commerce/order/A-001 --ring=users/123
kouten stellar attach --stellar=commerce/order/A-001 --ring=shops/1123
kouten stellar attach --stellar=commerce/order/A-001 --ring=orders/A-001

kouten get --stellar=commerce/order/A-001 --filter='{"kind":"shop"}'
kouten stellar detach --stellar=commerce/order/A-001 --ring=shops/1123
```

This is a lens relationship, not a copy operation. Compaction can later use the
same metadata to place related coordinates more favorably on disk.

`--sort=FIELD` sorts ascending and `--rsort=FIELD` sorts descending. Supported
fields are `id` and `time` (`write` is accepted as a compatibility alias for
`time`). The default is `--rsort=time`. `--pagination=on --page=N
--pagelimit=N` is a human-friendly page interface. For high-volume scans,
prefer cursor-based reads with `--cursor` because deep pages must skip earlier
filtered matches.

For BIF payloads, the default `auto` view looks for an optional adapter in this
order: `KOUTENDB_NIF_TOOL`, `koutendb-nif`, then `nif_file_tool`. The adapter
command must support:

```sh
ADAPTER decode --in=input.bif --out=output.nif
```

ID formats accepted by `get` and `query`:

- `parent:seq`
- `parent:epoch:seq:tWrite`

Use the `rawId` printed by `put` for scripts and reproducible examples.

## Interactive Shell

`kouten shell` provides a small MySQL-like interactive command surface for manual
exploration:

```sh
kouten shell
```

Minimal shell commands:

```text
put RING PAYLOAD
get ID [RING]
query ID SELECTION
query ID RING SELECTION  # cluster mode
list RING [LIMIT]
count RING
atlas
help
exit
```

The shell intentionally uses KoutenDB terms directly. It is not an SQL parser.
For scripts and reproducible examples, prefer the single-shot commands above.

## Local Data Commands

| Command | Required flags | Purpose |
|---|---|---|
| `compact` | `--data=DIR` | Compact WAL. |
| `pack-ring` | `--data=DIR --ring=RING` | Merge one disk-backed ring into a new local segment generation. |
| `segment-status` | `--data=DIR`; optional `--stale-ratio=F`, `--min-stale-records=N`, `--metrics`, `--json` | Inspect ring-local generations, stale ratios, bytes, and pack recommendations without rewriting data. |
| `pack-recommended` | `--data=DIR`; optional `--stale-ratio=F`, `--min-stale-records=N`, `--max-rings=N` | Explicitly pack only rings selected by the current diagnostic. |
| `locality` | `--data=DIR`; optional `--metrics` | Inspect physical WAL locality by ring. |
| `backup` | `--data=DIR --backup=DIR` | Create backup. |
| `restore` | `--backup=DIR --data=DIR` | Restore backup. |
| `backup-encrypted` | `--data=DIR --backup=DIR --passphrase=TEXT` | Create encrypted backup. |
| `restore-encrypted` | `--backup=DIR --data=DIR --passphrase=TEXT` | Restore encrypted backup. |
| `verify` | `--data=DIR` or `--backup=DIR`; optional `--segments`, `--max-wal-bytes=N`, `--max-segment-bytes=N`, `--max-dead-records=N`, `--max-dead-ratio=F`, `--max-segment-generation=N`, `--max-segment-files=N`, `--max-items=N`, `--max-rings=N`, `--metrics`, `--json` | Open and inspect a persistent data directory or backup. Data-dir verification checks WAL replay, lock, metadata, locality, capacity thresholds, and rebuildable segment layout. Backup verification checks restore readability without writing into the live data directory. |
| `dump` | `--data=DIR` | Export JSONL. |
| `import-jsonl` | `--data=DIR --in=FILE`; optional `--batch-size=N` | Import JSONL with chunked commits. |
| `describe-galaxy` | `--data=DIR --description=TEXT` | Set galaxy map description. |
| `describe-ring` | `--data=DIR --ring=RING --description=TEXT` | Set ring map description. |

`dump` / `import-jsonl` are the portable migration boundary while KoutenDB's
pre-v1.0 internal WAL format can still evolve. `import-jsonl` recognizes
`koutendb.dump.v1` files produced by `dump`, and can also route external JSONL
exports through `--ring-field`, `--payload-field`, and `--vec-field`.
`--batch-size=N` controls how many successfully parsed records are committed per
WAL transaction during bulk load. See
[Data Migration](data-migration.md).

## Recovery Commands

| Command | Purpose |
|---|---|
| `recovery-backup` | Write recovery archives from a data directory. |
| `recovery-verify` | Verify one recovery archive. |
| `recovery-status` | Check archive health against `requiredHealthy`. |
| `recovery-restore` | Restore from the best healthy archive. |

Recovery commands accept `--mirror`, `--universe-config`, `--universe`,
`--galaxy`, `--location`, `--failure-domain`, `--priority`, `--snapshot-seq`,
`--auth-ref`, `--readonly`, and `--passphrase` where applicable.

## Universe Sync Commands

| Command | Purpose |
|---|---|
| `universe-export --data=DIR [--out=FILE]` | Export source outbox events. |
| `universe-apply --data=DIR --in=FILE` | Apply exported events to a local data directory. |
| `universe-sync --data=SOURCE --target-data=TARGET` | One-shot local sync. |
| `universe-sync --data=SOURCE --peers=host:port,...` | Deliver source outbox events to a running cluster. |
| `universe-status --data=DIR` | Inspect source outbox status. |
| `universe-status --peers=host:port,... --metrics` | Inspect remote apply counters. |

## Benchmark / Demo Commands

| Command | Purpose |
|---|---|
| `bench` | Basic cluster operation benchmark. |
| `retrieve-bench` | Retrieval benchmark. |
| `redis-bench` | Redis comparison smoke. |
| `rag-bench` | Synthetic RAG-style working-set/token benchmark. |
| `working-set-bench` | Working-set reduction benchmark. |
| `memory-pressure-bench` | Candidate memory pressure benchmark. |
| `doctor` | Without `--data` / `--backup` / `--server-config`, report the dependency-free embedded setup. With `--data=DIR`, `--backup=DIR`, or `--server-config=FILE`, run operational verification. |

## Operational Verification

| Command | Purpose |
|---|---|
| `verify --data=DIR [--segments] [--max-wal-bytes=N] [--max-segment-files=N] [--max-items=N] [--max-rings=N]` | Open/replay a persistent data directory and check WAL, metadata, locality, optional capacity thresholds, and optional segment rebuild health. |
| `pack-ring --data=DIR --ring=RING [--durability=buffered|strong]` | Build a new complete disk-backed segment generation for one ring and atomically activate it through the segment manifest. |
| `segment-status --data=DIR [--metrics|--json]` | Report active generation, live/covered/stale records, bytes, runtime segment hits/WAL fallbacks, and the current pack recommendation for every ring. |
| `pack-recommended --data=DIR [--max-rings=N]` | Apply the same recommendation thresholds explicitly; no background pack is started automatically. |
| `verify --backup=DIR` | Verify backup readability before restore. |
| `verify --server-config=FILE` | Validate a `koutend` server JSON config before startup. |
| `doctor --server-config=FILE --json` | Emit the same server config checks as JSON. |

Server config verification checks `id` / `peers`, persistence, auth
combinations, secret file readability, role entries, ring-prefix authorization
shape, TLS cert/key pairing, TLS file existence, and whether certificate
verification has been explicitly disabled.
