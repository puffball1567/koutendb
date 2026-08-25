# KoutenDB Single-Node Self-Host Bundle

This bundle starts one persistent KoutenDB node with TLS, username/password and
secret-key authentication, strong durability, ring-local disk reads, bounded
automatic packing, a read-only container root, and a non-root runtime user.

It is the baseline OSS operational path. Fleet control, cloud provisioning,
cross-account policy, and a hosted management UI are intentionally outside this
bundle.

## Generate A Deployment

After the v0.14 image is published:

```sh
KOUTENDB_VERSION=0.14.0 \
  deploy/self-hosted/bootstrap.sh /opt/koutendb

cd /opt/koutendb
docker compose config
docker compose up -d
docker compose ps
```

The default listener is bound to `127.0.0.1:7301`. Change
`KOUTENDB_BIND_ADDRESS` in `.env` only after reviewing the host firewall and
client trust boundary.

The bootstrap refuses to overwrite a non-empty output directory. It creates:

- random 256-bit password and secret-key files;
- a local CA and a 397-day server certificate for `koutendb`, `localhost`, and
  `127.0.0.1`;
- server and client JSON configurations containing paths, not secret values;
- a pinned GHCR image reference;
- a bounded health watchdog and optional systemd timer units.

Compose keeps the generated source files at mode `0600`. A one-shot,
network-disabled initialization service copies them into a dedicated runtime
volume as UID/GID `10001` with mode `0400`. The database mounts that volume
read-only, so native Linux does not require making host secrets world-readable.

The CA private key remains under `operator/` and is never mounted into the
container. Replace the bootstrap PKI with the deployment's approved issuer
before exposing a production listener.

## Verify The Node

```sh
docker compose exec -T koutendb \
  kouten health --config=/etc/koutendb/client.json

docker compose exec -T koutendb \
  kouten put --config=/etc/koutendb/client.json \
  --ring=ops/first-run --payload='{"ready":true}' --codec=json

docker compose exec -T koutendb \
  kouten get --config=/etc/koutendb/client.json --ring=ops/first-run
```

## Failure Detection And Restart

Compose uses `restart: unless-stopped`. An unexpected `koutend` process exit is
restarted automatically; an explicit operator stop remains stopped.

Container health is a separate signal. Docker does not restart an unhealthy
but still-running process by itself. `watchdog.sh` handles that case with these
fail-closed defaults:

- require three consecutive `unhealthy` observations;
- restart only the configured container name;
- allow at most three watchdog restarts per hour;
- use a 30-second graceful restart timeout;
- stop automation and return non-zero when the restart limit is reached.

Run one check manually:

```sh
cd /opt/koutendb
./watchdog.sh
```

To schedule it with systemd, install the generated files as root:

```sh
sudo install -m 0644 systemd/koutendb-watchdog.service \
  /etc/systemd/system/koutendb-watchdog.service
sudo install -m 0644 systemd/koutendb-watchdog.timer \
  /etc/systemd/system/koutendb-watchdog.timer
sudo install -d -m 0750 /etc/koutendb
sudo install -m 0600 systemd/watchdog.env /etc/koutendb/watchdog.env
sudo systemctl daemon-reload
sudo systemctl enable --now koutendb-watchdog.timer
```

The timer runs every 20 seconds. Review failures with:

```sh
systemctl status koutendb-watchdog.service
journalctl -u koutendb-watchdog.service
```

Automatic restart is not data recovery. Repeated failure, corruption, capacity
exhaustion, or an invalid configuration requires operator diagnosis and the
documented verify/checkpoint/restore workflow.

## Checkpoint And Restore Drill

Create a generation checkpoint through a controlled quiet window:

```sh
./operator.sh checkpoint-create before-upgrade-2026-08-25
```

The command requires a healthy service, drains writes, requests a snapshot
barrier, stops the node, creates and verifies the immutable generation, then
restarts, health-checks, and resumes the node. A failure after drain triggers a
best-effort restart and resume before the command returns non-zero.

Export the complete checkpoint to a mounted backup destination:

```sh
./operator.sh checkpoint-export \
  before-upgrade-2026-08-25 /mnt/koutendb-backups
```

The export is copied under a hidden staging name. Before publication, KoutenDB
verifies the transported artifact, restores it into an independent temporary
volume, and verifies the restored data and segment layout. The final directory
appears only after those checks pass. Existing destinations are never
overwritten.

Repeat the independent restore test without changing the active database:

```sh
./operator.sh restore-drill \
  /mnt/koutendb-backups/before-upgrade-2026-08-25
```

## Verified Upgrade And Rollback

Upgrade to an explicitly versioned image or immutable digest:

```sh
./operator.sh upgrade \
  ghcr.io/puffball1567/koutendb:0.14.0 \
  before-0.14.0
```

The operator rejects an unversioned image and the mutable `latest` tag. Before
replacement, it starts both KoutenDB executables in an isolated container,
validates the Compose configuration, drains and snapshots the active node, and
creates a checkpoint. Both the active and target images must verify that
checkpoint. The target becomes authoritative in `.env` only after those checks.

If the replacement does not become healthy, the operator restores the previous
image reference, recreates the service, waits for health, and resumes writes.
The checkpoint remains available for explicit recovery. Use a digest rather
than a tag when the deployment requires immutable image identity.

## Certificate Rotation

Rotate a server certificate and private key signed by the current CA:

```sh
./operator.sh certificate-rotate \
  /mnt/koutendb-pki/server.crt \
  /mnt/koutendb-pki/server.key
```

To replace the server certificate, key, and CA together, pass the new CA as the
third argument. The operator checks certificate validity, CA capability,
`koutendb` hostname verification, chain validity, and the certificate/key public
key match before draining the node. It stages the inputs with restricted
permissions and recreates the runtime secret volume. A failed TLS health check
restores the previous certificate set and resumes the node.

When changing the CA, distribute the new trust anchor to external clients
before running the command. The single-node bundle does not provide a managed
PKI, client trust-store rollout, KMS integration, or fleet-wide zero-downtime
rotation.

Bounded JSONL evidence is written to `state/operator/operations.jsonl`; paths
and credentials are not recorded. The default keeps the latest 1,000 records
and can be changed with `KOUTENDB_OPERATOR_EVIDENCE_MAX_RECORDS`. A local or
NFS-mounted destination is the OSS provider-neutral boundary. Object-store
upload, cloud credentials, fleet scheduling, and hosted retention policy belong
in external operations tooling.
