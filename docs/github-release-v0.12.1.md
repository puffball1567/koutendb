# KoutenDB v0.12.1

KoutenDB v0.12.1 aligns the core documentation and driver discovery output
with the current external driver releases.

## Published Drivers

- Rust: [`koutendb` 0.1.6 on crates.io](https://crates.io/crates/koutendb)
- JavaScript / TypeScript: [`koutendb` 0.1.5 on npm](https://www.npmjs.com/package/koutendb)
- Python: [`koutendb` 0.2.1 on PyPI](https://pypi.org/project/koutendb/)
- PHP: [`koutendb/koutendb` 0.1.3 on Packagist](https://packagist.org/packages/koutendb/koutendb)
- C++: [`koutendb-cpp` 0.1.3 on GitHub](https://github.com/puffball1567/koutendb-cpp/releases/tag/v0.1.3)

## Publication Status Clarified

Go, Swift, C#, and Kotlin wrappers remain in-tree foundations. They have not
been published as Go, SwiftPM, NuGet, or Maven packages. The in-tree Node TCP
and Bun paths are also distinguished from the published JavaScript Node-API
driver.

The CLI no longer suggests a remote `go get` command for the unpublished Go
module. It now points users to the repository-local `go.mod replace` workflow.

## Verification

- current package versions were checked against crates.io, npm, PyPI,
  Packagist, and GitHub Releases;
- the release-mode CLI build passed;
- the Go driver discovery output was checked;
- the full GitHub CI matrix passed on the documentation update PR, including
  core, C ABI, TLS, cluster, recovery, Universe, Linux, and macOS checks.

This patch does not change the wire protocol, storage format, or C ABI.
