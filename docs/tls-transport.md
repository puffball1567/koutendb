# TLS Transport

KoutenDB supports standard TLS for `koutend` TCP connections when the server and
client are built with Nim's SSL support:

```sh
nim c -d:ssl -d:release -o:src/koutend src/koutend.nim
nim c -d:ssl -d:release -o:src/koutencli src/koutencli.nim
```

TLS is a transport layer. It is separate from KoutenDB's username/password
authentication, secret-key challenge response, and libsodium-backed secure frame
mode. They can be combined:

```text
TCP -> TLS -> KoutenDB wire protocol -> AUTH / AUTHCHAL -> optional secure frames
```

For public or VPC deployments, prefer TLS plus username/password plus
`--secret-key`.

## Server

Start `koutend` with a certificate and private key:

```sh
src/koutend \
  --id=0 \
  --peers=127.0.0.1:7301 \
  --data=/var/lib/koutendb \
  --user=alice \
  --password-file=/run/secrets/kouten_password \
  --secret-key-file=/run/secrets/kouten_secret_key \
  --tls-cert=/etc/koutendb/server.crt \
  --tls-key=/etc/koutendb/server.key \
  --tls-ca=/etc/koutendb/ca.crt
```

`--tls-ca`, `--tls-server-name`, and `--tls-insecure-skip-verify` are used by
the server's own peer client for cluster handoff and maintenance requests. In a
single-node local smoke test they are less important; in a TLS cluster they
should match the peer certificate policy.

## CLI Client

Use `--tls` to connect to a TLS-enabled `koutend`:

```sh
src/koutencli health \
  --peers=127.0.0.1:7301 \
  --user=alice \
  --password-file=/run/secrets/kouten_password \
  --secret-key-file=/run/secrets/kouten_secret_key \
  --tls \
  --tls-ca=/etc/koutendb/ca.crt
```

For local self-signed experiments only:

```sh
src/koutencli health \
  --peers=127.0.0.1:7301 \
  --user=alice \
  --password-file=/run/secrets/kouten_password \
  --secret-key-file=/run/secrets/kouten_secret_key \
  --tls \
  --tls-insecure-skip-verify
```

Do not use `--tls-insecure-skip-verify` for production deployments.
For local smoke tests, direct `--password` / `--secret-key` values are accepted.
For shared systems, prefer `--password-file`, `--secret-key-file`, or the
`KOUTEN_PASSWORD` / `KOUTEN_SECRET_KEY` environment variables so secrets do not
appear in shell history or process listings.

## C ABI

The C ABI exposes `kouten_connect_auth_tls` for native drivers and FFI wrappers.
The existing `kouten_connect` and `kouten_connect_auth` entry points remain
available for non-TLS and backward-compatible use.

## Smoke Test

The TLS smoke test builds TLS-enabled binaries, generates a short-lived
self-signed certificate, starts `koutend`, verifies authenticated TLS health,
writes and reads JSON over TLS, and confirms that a plain TCP client cannot talk
to the TLS listener:

```sh
scripts/cluster_tls_smoke.sh
```

This test opens a local TCP listener. In restricted sandboxes it may need to run
outside the sandbox.

## Container Validation

The heavier manual container matrix verifies TLS and authentication together
with named-volume persistence, restart, container replacement, network
interruption, credential rotation, authorization denial, audit persistence, and
offline storage verification:

```sh
scripts/container_security_matrix.sh
```

See [Container Persistence and Security Validation](container-security-validation.md)
for the complete matrix and the recorded local result.
