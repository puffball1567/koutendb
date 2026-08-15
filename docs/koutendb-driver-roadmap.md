# KoutenDB Driver / FFI Roadmap

KoutenDB drivers are developed on two tracks.

1. **Native wire driver**
   - Production cluster driver that talks to `koutend` over TCP.
   - Uses `PUTR/GETID/QRYID`, so language drivers do not reimplement
     `ringKey` / `period` / `head` internals.

2. **C ABI / FFI**
   - Foundation for embedded mode, high-speed local use, and language bindings.
   - Based on `include/koutendb.h` and `src/koutendb_capi.nim`.

The `kouten driver` command is the stable discovery surface for official
drivers:

```sh
kouten driver list
kouten driver info rust
kouten driver install rust
KOUTEN_DRIVER_MANIFEST=/path/to/Cargo.toml kouten driver install rust
```

It prints official package/repository metadata and setup commands. For Rust it
can target a specific `Cargo.toml` with `--manifest-path`,
`--project-dir`, `KOUTEN_DRIVER_MANIFEST`, or `KOUTEN_DRIVER_PROJECT`. It does
not execute package-manager commands unless `--execute` is passed, and
unpublished drivers are refused even with `--execute`.

## Foundation

The C ABI / FFI layer is the shared foundation for embedded mode, high-speed
local use, and non-Nim language bindings. It is not treated as one language
driver in the publication priority list. The current C ABI already covers ABI
versioning, last-error handling, vector put, auth connect, retrieve, batch get,
and atlas access.

## Publication Priority

| Priority | Target | Reason | Status |
|---:|---|---|---|
| 1 | Rust driver | High-performance infrastructure, gateway, and systems integration path | Published: crates.io [`koutendb` v0.1.6](https://crates.io/crates/koutendb), repository [`puffball1567/koutendb-rust`](https://github.com/puffball1567/koutendb-rust) |
| 2 | JavaScript / TypeScript driver | Web API, SaaS, Studio, GUI, and local AI client entry point | Published: npm [`koutendb` v0.1.5](https://www.npmjs.com/package/koutendb), repository [`puffball1567/koutendb-js`](https://github.com/puffball1567/koutendb-js). Bun remains experimental on the same Node-API path |
| 3 | PHP driver | Laravel and existing business web systems | Published: Packagist [`koutendb/koutendb` v0.1.3](https://packagist.org/packages/koutendb/koutendb), repository [`puffball1567/koutendb-php`](https://github.com/puffball1567/koutendb-php) |
| 4 | C++ driver | Generic native and engine integration base. Unreal plugin stays separate | Repository released: [`puffball1567/koutendb-cpp` v0.1.3](https://github.com/puffball1567/koutendb-cpp); CMake smoke passes in CI |
| 5 | Python native wire driver | AI/RAG and broad scripting entry point without making big-data positioning the first message | Published: PyPI [`koutendb` v0.2.1](https://pypi.org/project/koutendb/), repository [`puffball1567/koutendb-python`](https://github.com/puffball1567/koutendb-python) |
| 6 | Swift driver | Apple local AI client, browser companion, and app state path | In-tree C ABI wrapper only; not published to SwiftPM. Docker smoke added |
| 7 | Kotlin-first JVM driver | JVM backend and Android path, Java-compatible | In-tree JNI / C ABI wrapper only; not published to Maven |
| 8 | Go driver | Cloud backend and ops tooling; lower initial priority than Rust/Node/PHP for KoutenDB positioning | In-tree C ABI wrapper only; no Go module or external repository published. Native wire comes later |
| 9 | C# driver | Generic .NET backend entry point. Unity official asset stays separate | In-tree C ABI wrapper only; not published to NuGet |
| 10 | DB trust work | Crash recovery, compatibility suite, failure benchmarks, operational docs | Ongoing core work |

## Browser / Wasm Track

Wasm is tracked separately from language-driver publication priority. It is a
frontend and local-state deployment path, not just another server-side driver.
The goal is to make KoutenDB usable inside browser-like sandboxed runtimes for
local context/state management while keeping the same ring-oriented data model.

Current target:

- Browser / Wasm embedded KoutenDB
- React Native local/global state boundary
- IndexedDB / OPFS-style persistence exploration
- Local-first context windows and client-side retrieval experiments

This track may be pulled forward if browser/local-state demand becomes the
clearest adoption path. It is kept separate so the server-side driver
publication order can remain stable while Wasm moves opportunistically.

## Minimum Common API

Each native driver first aligns on the following API:

- `connect(peers, timeout)`
- `close`
- `put(ring, payload, vector?) -> KoutenId`
- `get(id) -> bytes | nil`
- `query(id, selection) -> bytes | nil`
- `health(node?)`
- typed `KoutenId`
- one reconnect retry

The next layer adds auth / secret-key transport, connection pooling, package
publishing, and protocol compatibility tests in the publication order above.

The C ABI uses `examples/cabi_contract.c` as its contract smoke test.
Rust, Go, PHP, Swift, C#, and C++ first wrap the C ABI safely. Native TCP drivers can
be added later without changing their ownership and error contracts.

PHP can be verified with `drivers/php/docker-test.sh` when local PHP does not
provide FFI. Swift can be verified with `drivers/swift/docker-test.sh` on Linux.
The shared compatibility suite verifies the C ABI contract, embedded FFI
wrappers, and native wire drivers:

```sh
scripts/driver_compat.sh
```

By default it does not run Docker-backed drivers. Enable those with:

```sh
KOUTEN_COMPAT_DOCKER=1 scripts/driver_compat.sh
```

Cluster transaction smoke can be run separately:

```sh
scripts/cluster_tx_smoke.sh
```

Individual C#, C++, and Kotlin checks can be run with:

```sh
dotnet run --project drivers/csharp/ContractSmoke/ContractSmoke.csproj
g++ -std=c++17 -Iinclude -Idrivers/cpp/include drivers/cpp/examples/contract_smoke.cpp -Llib -lkoutendb -o /tmp/kouten_cpp_smoke
LD_LIBRARY_PATH=lib /tmp/kouten_cpp_smoke
drivers/kotlin/docker-test.sh
```

## Guardrail

Drivers do not reimplement KoutenDB placement rules. They pass a ring name and
let KoutenDB issue the ID. This keeps language drivers stable as long as the wire
protocol / C ABI contract remains compatible.

Native wire drivers must treat vector bytes as canonical little-endian IEEE-754
`float32` values and should check `WIREVER` before assuming command
compatibility. C ABI wrappers receive host-native `float` arrays because they
run in-process. See [protocol-compatibility.md](./protocol-compatibility.md).
