# KoutenDB v0.14.4

This patch updates driver discovery and installation guidance for the published
native TCP drivers, including the first standalone Go release.

## Published Drivers

| Language | Release | Distribution |
| --- | --- | --- |
| Rust | 0.2.0 | [crates.io](https://crates.io/crates/koutendb) |
| JavaScript / TypeScript | npm 0.1.5; GitHub 0.2.0 | [npm](https://www.npmjs.com/package/koutendb), [GitHub release](https://github.com/puffball1567/koutendb-js/releases/tag/v0.2.0) |
| PHP | 0.2.0 | [Packagist](https://packagist.org/packages/koutendb/koutendb) |
| C++ | 0.2.0 | [GitHub release](https://github.com/puffball1567/koutendb-cpp/releases/tag/v0.2.0) |
| Python | 0.3.0 | [PyPI](https://pypi.org/project/koutendb/) |
| Go | 0.1.0 | [Go module](https://pkg.go.dev/github.com/puffball1567/koutendb-go) |

JavaScript's addon-free TCP transport is in GitHub v0.2.0; npm still distributes
v0.1.5. The installation guide distinguishes these releases explicitly.

## Changes

- Updated README, driver status tables, roadmap and installation guide.
- Updated `kouten driver list/info/install` with released versions, transport
  choices and the standalone Go module command.
- Added CLI discovery regression checks for all six external drivers.
- Included the shared native-driver conformance harness: 27 protocol fixtures
  and six real-server authentication/TLS configurations.
- Corrected TLS test certificates to include server authentication usage.

Native TCP drivers connect without the KoutenDB shared library. Existing C ABI
and FFI transports remain available for embedded applications. Each driver
documents its API coverage; transport support does not imply complete API parity.

No database storage format or C ABI version changes are introduced by this patch.

See [Driver Installation](driver-installation.md) and
[Native Driver Conformance](native-driver-conformance.md) for setup and validation.
