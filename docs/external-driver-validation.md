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

## v0.12 Release Result

The clean v0.12 compatibility run on 2026-08-13 completed every driver-owned
suite and every shared security/restart row:

| Driver | Driver suite | Shared TLS/auth/restart matrix |
|---|---|---|
| Rust 0.1.6 | Passed 7 tests, including v0.12 persistence/maintenance/checkpoint coverage and eager-connect failure semantics. | Passed every row. |
| JavaScript/TypeScript 0.1.5 | Passed 3 Node.js tests, including the v0.12 C ABI additions. | Passed every row, including CA verification and restart. |
| PHP 0.1.3 source | Passed in the isolated PHP 8.3 FFI image, including the v0.12 C ABI additions. | Passed every row, including CA verification and restart. |
| C++ 0.1.3 | Passed from a clean CMake build directory, including the v0.12 C ABI additions. | Passed every row, including CA verification and restart. |
| Python 0.2.1 | Passed 12 tests after adopting owner-bearing `FWD` and routed multi-node `BGET`. | Passed every row, including shared-secret CRUD and restart. |

Offline segment verification and persistent authentication-failure audit
evidence also passed. This closes the external-driver compatibility gate for
the v0.12 release.
