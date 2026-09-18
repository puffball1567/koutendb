# Native Driver Conformance

This suite tests drivers that speak the KoutenDB wire protocol directly, without
the KoutenDB shared library. It does not implement another server or change the
wire protocol. Fixtures are in `tests/fixtures/native-wire-v1.json`; the runner
is `scripts/native_driver_conformance.py` (Python standard library).

## Run

```sh
bash scripts/native_driver_conformance.sh php -n ../koutendb-php/tests/tcp_adapter.php
```

The wrapper builds a fresh TLS-enabled `koutend` in a temporary directory.
It requires Nim, nimsodium, libsodium, Python 3, OpenSSL, and the selected driver
runtime. All listeners bind localhost; certificates, stores, and binaries are
temporary. Child processes are stopped on test exit. No production endpoint is used.

For an already built server or fixture-only checks:

```sh
python3 scripts/native_driver_conformance.py --server src/koutend -- php -n ../koutendb-php/tests/tcp_adapter.php
python3 scripts/native_driver_conformance.py --fixtures-only -- php -n ../koutendb-php/tests/tcp_adapter.php
KOUTEN_COMPAT_PHP_DIR=../koutendb-php bash scripts/driver_compat.sh
```

## Adapter Contract

One adapter process consumes one JSON object per stdin line and emits exactly
one JSON object per stdout line. Logs belong on stderr. The process retains its
driver instance across operations. EOF closes the instance and exits with zero.

- Success: `{"ok":true,"result":...}`.
- Failure: `{"ok":false,"error":"ConnectionException","message":"..."}`.
- Operations: `connect`, `put`, `putJson`, `get`, `getJson`, `query`, `health`, `debug`, `close`.
- `connect`: ordered `peers`, positive `timeout`, `readTimeout`, `writeTimeout`,
  and an `options` object as documented by the PHP native transport. Return `"connected"`.
- `put`: `ring`, base64 `payload`, `codec`; return the complete serialized ID.
- `putJson`: `ring`, JSON `value`; return the complete serialized ID.
- `get`: `id`; return `null` or `{"payload":"<base64>","codec":"raw"}`.
- `getJson`: `id`; return the decoded JSON value or null.
- `query`: `id`, `selection`; return the decoded projection or null.
- `health`: return the textual fields after `OK`.
- `debug`: return the public debug representation (never credentials).
- `close`: return `"closed"`.

Adapters normalize their language's exception types to the names asserted in
the fixture: connection, timeout, authentication, protocol, version mismatch,
server rejection, and indeterminate write. Tests compare results, not log text.

Fixtures encode request/response strings as UTF-8 bytes, or use `responseBase64`
for arbitrary binary bytes. `chunk` defines fragmented delivery, `delay` pauses
the peer, and `disconnect` closes after receiving the exact request. A scripted
peer checks headers and body bytes and detects unexpected reconnects. Equivalent
numeric spellings of ID coordinates (such as `60` and `60.0`) are accepted. No orbit
calculation is reimplemented in either the driver or the oracle.

## Coverage Matrix

| Area | Cases |
| --- | --- |
| Negotiation | WIREVER success, mismatch, malformed/oversized header; CODECMETA |
| Payload | Empty, Unicode, NUL/non-UTF-8 binary, 1 MiB, codec preservation, JSON projection |
| Framing | Byte-at-a-time responses, partial body then disconnect, negative/oversized lengths, unknown codec |
| Connection | Reconnect once, retry exhausted, read timeout, stopped server, explicitly closed client |
| Writes | Disconnect after complete PUTR, malformed ID, response timeout; no automatic replay |
| Routing | Owner-index redirect, no-owner forwarder, invalid target, cycle/limit |
| Authentication | Password, token, SECRET_KEY success/failure; wrong galaxy; redacted debug/errors |
| TLS | Trusted certificate, untrusted certificate, wrong hostname, explicit insecure development mode; TLS with SECRET_KEY |

The real-server cases are one-node tests. Multi-node routing is tested with
scripted peers, not claimed as a real clustered load or failover qualification.
This suite is not a soak, throughput, TLS cryptography audit, or a substitute
for each driver's broader API/FFI tests. Run those separately.

## Rollout

The initial adapter is in the PHP driver's native-TCP branch. Merge/publish the
core harness before enabling downstream CI against the core `devel` branch.
External drivers are not dependencies of the database package.

Python already has a native wire client. Its connection/version negotiation and
retry/error handling still need qualification against this suite. The released
JavaScript, Rust, and C++ drivers in the inspected checkouts use the native
library; core's legacy Node wire example is distinct from the published npm
driver. Do not describe those published drivers as library-free based on that
example. Port the adapter contract and pass the same suite for each implementation.

Request-ID deduplication is intentionally separate future work. It needs durable
result retention, duplicate-body validation, expiry behavior, and crash/restart
tests before safe write retry can be promised. The current PUTR wire format is
unchanged; uncertain writes must be surfaced to the application.
