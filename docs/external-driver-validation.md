---
layout: page
title: External Driver Validation
---

# External Driver Validation

KoutenDB keeps a manual compatibility gate for the separately maintained Rust,
JavaScript/TypeScript, PHP, C++, and Python drivers:

```sh
scripts/external_driver_matrix.sh
```

By default, the script expects the five driver repositories beside the core
checkout. `KOUTEN_EXTERNAL_DRIVER_ROOT` or the language-specific
`KOUTEN_*_DRIVER_DIR` variables can point at another layout. The script does not
clone, modify, commit, or publish a driver repository.

Set `KOUTEN_EXTERNAL_DRIVER_SUITES=0` to rerun only the shared security/restart
matrix while developing the harness. The release gate uses the default value
and runs every driver-owned suite.

## Matrix

The gate first runs each driver's own test suite against the current
TLS-enabled C ABI or wire server. It then applies the same server-side matrix to
all five drivers:

| Boundary | Verification |
|---|---|
| Normal path | Verified TLS plus username, password, and secret-key authentication performs a JSON write. Driver probes that expose a read path also verify the roundtrip. |
| Password | An incorrect password is rejected. |
| Secret key | An incorrect secret key is rejected. |
| Certificate authority | A certificate signed by a different CA is rejected. |
| Transport | Plaintext is rejected by the TLS listener. |
| Restart | The server reopens the same strong-durability disk-backed store and every driver repeats the verified operation. |
| Recovery evidence | The stopped store passes offline segment verification and retains authentication-failure audit events. |

The PHP path uses a uniquely named temporary Docker image because the host does
not need to enable PHP FFI globally. The cleanup trap removes that image and all
matrix-owned temporary data. The matrix is intentionally outside normal CI.

## Current Development Result

The first v0.12 development run established that the core-side harness works
and identified external-driver release blockers rather than hiding them:

| Driver | Driver suite | Shared TLS/auth/restart matrix |
|---|---|---|
| Rust 0.1.5 | 5 of 6 tests passed. One stale test still expects a failed TLS connection to be deferred until the first operation; the current core fails during `connect`. | Passed every row. |
| JavaScript/TypeScript 0.1.4 | Passed. | Passed every row, including CA verification and restart. |
| PHP | Passed in the isolated PHP 8.3 FFI image. | Passed every row, including CA verification and restart. |
| C++ 0.1.2 | Passed from a clean CMake build directory. | Passed every row, including CA verification and restart. |
| Python 0.2.0 | 10 of 12 tests passed. The driver has not yet adopted the extended `FWD` response and current routed `BGET` behavior. | Rejection rows passed. Valid shared-secret requests returned `bad-request` before and after restart. |

These failures are not accepted as a completed release gate. The core keeps its
current early connection failure, forwarding metadata, and routing behavior;
the separately maintained Rust and Python drivers must update their contracts.
The matrix should be rerun and this result replaced before the final v0.12
endurance gate.
