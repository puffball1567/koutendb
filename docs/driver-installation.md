# KoutenDB Driver Installation Guide

This document separates published driver packages from repository-local driver
foundations. The English README records released package versions; this file is
the canonical setup and native-library reference.

KoutenDB drivers currently use two paths:

- Native TCP wire drivers for cluster-oriented use.
- C ABI wrappers for embedded/local use and language binding stability.

The CLI provides a small driver discovery surface:

```sh
kouten driver list
kouten driver info rust
kouten driver install rust
kouten driver install rust --manifest-path=/path/to/Cargo.toml
```

`driver install` prints the official package/repository path and setup command.
For Rust, target selection is shell-friendly: use `--manifest-path=FILE`,
`--project-dir=DIR`, `KOUTEN_DRIVER_MANIFEST`, or `KOUTEN_DRIVER_PROJECT`.
It does not execute package-manager commands unless `--execute` is passed.

The Nim package is available through Nimble. Rust, JavaScript / TypeScript, PHP,
Python, and the C++ source release are published independently from the core.
Installing one of those packages installs a driver, not a KoutenDB server.
Repository-local Go, Swift, C#, and Kotlin foundations are not published
packages; their examples assume a local clone of this repository.

## Build the Native Library

Most C ABI wrappers need `lib/libkoutendb.so`:

```sh
scripts/build_capi.sh
```

This is the canonical C ABI build. It compiles `lib/libkoutendb.so` with
`-d:ssl`, so `kouten_connect_auth_tls` is available to Rust, Node native addons,
PHP FFI, C++, C#, Swift, Kotlin, Go, and other wrappers without each driver
duplicating Nim flags.

For native wire driver tests, build `koutend`:

```sh
nim c -d:release --nimcache:/tmp/nimcache_koutend -o:src/koutend src/koutend.nim
```

## Nim

Install from Nimble:

```sh
nimble install koutendb
kouten --help
```

Then import the public API:

```nim
import koutendb

var db = koutendb.open(dataDir = "data")
let id = db.put("hello", ring = "docs")
echo db.get(id)
```

From a source checkout, run:

```sh
scripts/test_core.sh
```

## C ABI

Include `include/koutendb.h` and link `lib/libkoutendb.so`:

```sh
scripts/build_capi.sh
gcc examples/cabi_contract.c -Iinclude -Llib -lkoutendb -Wl,-rpath,'$ORIGIN/../lib' -o bin/cabi_contract
LD_LIBRARY_PATH=lib bin/cabi_contract
```

Thread-safety contract:

- `kouten_init()` is idempotent.
- `kouten_last_error()` returns text owned by KoutenDB. Copy it before the next
  KoutenDB C ABI call on the same thread.
- Do not call `kouten_close()` concurrently with any other operation on the same
  handle.
- If a driver shares one handle across threads, serialize calls around that
  handle. Separate handles may be used independently.

`kouten_open_dir` retains its existing buffered WAL behavior. Drivers that
need strong durability or the ring-local disk read layout should use the
additive `kouten_open_dir_options` call. The segment diagnostics and bounded
maintenance calls return length-delimited JSON allocated by KoutenDB; release
those buffers with `kouten_free` just like `kouten_get` results.

The same additive ABI v2 surface includes immutable generation checkpoints:

- `kouten_checkpoint_create_json`
- `kouten_checkpoint_status_json`
- `kouten_checkpoint_list_json`
- `kouten_checkpoint_cleanup_json`
- `kouten_checkpoint_restore_json`

These functions return the same `koutendb.checkpoint-*.v1` JSON shapes as the
Nim API and CLI. Creation requires a persistent embedded handle. The remaining
functions operate on filesystem paths and still require `kouten_init()` before
use. Returned buffers must be released with `kouten_free`.

The current ABI version remains `2`. These functions are additive and do not
change existing struct layouts or symbols, so drivers that require ABI v2 keep
working while newer wrappers may bind the additional symbols explicitly.

## Python

The Python driver is released as a separate native TCP wire driver:

- repository: [`puffball1567/koutendb-python` v0.2.1](https://github.com/puffball1567/koutendb-python)
- mode: pure Python TCP driver for `koutend`
- PyPI: [`koutendb` v0.2.1](https://pypi.org/project/koutendb/)

```sh
python3 -m pip install koutendb
KOUTENDB_CORE_DIR=/path/to/koutendb python3 -m unittest discover -s tests
```

Example:

```python
from koutendb import KoutenClient

db = KoutenClient.connect("127.0.0.1:17301")
doc_id = db.put("docs", b'{"title":"hello"}')
print(db.get(doc_id))
db.close()
```

## JavaScript / TypeScript

The published JavaScript / TypeScript driver is a Node-API wrapper over the
KoutenDB C ABI:

- npm: [`koutendb` v0.1.5](https://www.npmjs.com/package/koutendb)
- repository: [`puffball1567/koutendb-js`](https://github.com/puffball1567/koutendb-js)

Install it in an application:

```sh
npm install koutendb
```

Build the KoutenDB core shared library first and set `KOUTENDB_CORE_DIR` during
install/rebuild. See the driver repository README for the full setup flow.

The core repository also keeps a repository-local native TCP wire driver used
for protocol smoke tests:

```sh
nim c -d:release --nimcache:/tmp/nimcache_koutend -o:src/koutend src/koutend.nim
node --test drivers/node/test/*.test.js
bun test drivers/node/test-bun/*.test.ts
```

Repository-local wire-driver example:

```js
import { KoutenClient } from "./drivers/node/src/index.js";

const db = KoutenClient.connect("127.0.0.1:17301");
const id = await db.put("docs", Buffer.from('{"title":"hello"}'));
console.log((await db.get(id)).toString("utf8"));
await db.close();
```

## Rust

The Rust driver is published as a C ABI wrapper:

- crates.io: [`koutendb` v0.1.6](https://crates.io/crates/koutendb)
- repository: [`puffball1567/koutendb-rust`](https://github.com/puffball1567/koutendb-rust)

Install it in a Rust project:

```sh
cargo add koutendb
```

Or ask the KoutenDB CLI to print the official setup command:

```sh
kouten driver install rust --manifest-path=/path/to/Cargo.toml
```

Build the KoutenDB core shared library first and set `KOUTENDB_CORE_DIR` or
`KOUTENDB_LIB_DIR` when building/testing the Rust project. See the Rust driver
repository README for the full setup flow.

## Go

The Go driver is a repository-local C ABI wrapper. It has not been published as
a Go module or separate driver repository.

```sh
scripts/build_capi.sh
cd drivers/go
GOCACHE="${GOCACHE:-/tmp/kouten-go-cache}" go test ./...
```

Use a local module replace until publication:

```text
replace github.com/koutendb/koutendb-go => ../drivers/go
```

## PHP

The PHP driver uses FFI over the C ABI. Local PHP must have `ext-ffi` enabled.
It is published on Packagist:

- Packagist: [`koutendb/koutendb` v0.1.3](https://packagist.org/packages/koutendb/koutendb)
- repository: [`puffball1567/koutendb-php`](https://github.com/puffball1567/koutendb-php)
- package name: `koutendb/koutendb`

Install it in a Composer project:

```sh
composer require koutendb/koutendb:^0.1
```

Build the KoutenDB core shared library first and point the PHP driver at it:

```sh
scripts/build_capi.sh
export KOUTENDB_CORE_DIR=/path/to/koutendb
```

For local driver development from a checkout of `koutendb-php`, use the Docker
smoke test:

```sh
KOUTENDB_CORE_DIR=/path/to/koutendb ./docker-test.sh
```

For Composer path development against a local `koutendb-php` checkout:

```json
{
  "repositories": [
    { "type": "path", "url": "../koutendb-php" }
  ],
  "require": {
    "koutendb/koutendb": "*"
  }
}
```

## Swift

The Swift driver is a SwiftPM wrapper over the C ABI. Linux smoke is Docker
backed.

```sh
scripts/build_capi.sh
drivers/swift/docker-test.sh
```

Use a local package dependency:

```swift
.package(path: "../drivers/swift")
```

iOS/macOS packaging, sandbox paths, XCFramework packaging, and SwiftUI/UIKit
integration are still future validation work.

## C#

The C# driver is a generic .NET C ABI wrapper.

```sh
scripts/build_capi.sh
dotnet run --project drivers/csharp/ContractSmoke/ContractSmoke.csproj
```

Use a project reference until NuGet publication:

```xml
<ProjectReference Include="../drivers/csharp/KoutenDB/KoutenDB.csproj" />
```

Unity-specific lifecycle, editor tooling, and asset packaging are intentionally
separate from this generic OSS driver.

## C++

The C++ driver is released as a separate C++17 wrapper over the C ABI:

- repository: [`puffball1567/koutendb-cpp` v0.1.3](https://github.com/puffball1567/koutendb-cpp)
- mode: C++17 RAII wrapper over `libkoutendb.so`

```sh
git clone https://github.com/puffball1567/koutendb-cpp.git
cd koutendb-cpp
cmake -S . -B build -DKOUTENDB_CORE_DIR=/path/to/koutendb
cmake --build build
./build/koutendb_cpp_contract_smoke
```

Unreal-specific module packaging, Blueprint bindings, editor tooling, and
engine lifecycle integration are intentionally separate from this generic OSS
driver.

## Kotlin / JVM

The Kotlin driver is Kotlin-first and Java-compatible at the bytecode level. It
uses a small JNI bridge over the C ABI.

```sh
scripts/build_capi.sh
drivers/kotlin/docker-test.sh
```

Maven Central publishing and Android packaging are future work.

## Compatibility Suite

Run non-Docker checks:

```sh
scripts/driver_compat.sh
```

Run Docker-backed PHP / Swift / Kotlin checks:

```sh
KOUTEN_COMPAT_DOCKER=1 scripts/driver_compat.sh
```

Skip wire checks when only C ABI and Docker wrapper checks are needed:

```sh
KOUTEN_COMPAT_DOCKER=1 KOUTEN_COMPAT_WIRE=0 scripts/driver_compat.sh
```
