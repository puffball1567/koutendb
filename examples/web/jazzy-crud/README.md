# Jazzy CRUD Demo

[Jazzy Framework](https://github.com/canermastan/jazzy-framework), React and
KoutenDB, using the same task UI and REST contract as the REKT/PRK examples.
This is a KoutenDB integration example, not a Jazzy SQL query-builder driver
or an endorsement by the Jazzy maintainers.

The fixture pins Jazzy commit `d45d49d07a6d130b56c1070f723cf668094e276b`
(package version 0.5.3). Jazzy is a demo-only dependency; it is not required
by the KoutenDB library or normal core tests.

Jazzy initializes its SQL subsystem at startup. The demo explicitly uses an
empty in-memory SQLite connection for that unused framework subsystem, so a
non-root container does not need to create a SQL database file. All task CRUD
and related-record queries use KoutenDB; SQLite is not a fallback data store.

## Docker

From the KoutenDB repository root:

```sh
docker compose -f examples/web/jazzy-crud/compose.yml up -d --build --wait
```

Open <http://localhost:18082>. Add tasks, categories and tags; open a task to
see related records from its category ring. API requests go through nginx;
the browser never receives database credentials. The HTTP port binds only to
loopback, and the database port is not published.

```sh
docker compose -f examples/web/jazzy-crud/compose.yml --profile test run --rm --build smoke
docker compose -f examples/web/jazzy-crud/compose.yml down
```

The named volume retains data across ordinary shutdown. Add `-v` to `down`
only when intentionally resetting this demo's data.

## Local Integration Matrix

Requires Nim 2.2.10+, Node.js, Python 3, OpenSSL and libsodium. Install Jazzy's
dependencies in its checkout and KoutenDB's dependencies in the core checkout:

```sh
cd ../jazzy-framework
nimble --useSystemNim install -y --depsOnly
cd ../koutendb
nimble --useSystemNim install -y --depsOnly
JAZZY_DIR=../jazzy-framework bash scripts/jazzy_demo_smoke.sh
```

The runner builds a real `koutend` and Jazzy API, allocates loopback ports,
uses fresh temporary data, and removes only its own processes and files.
It tests the HTTP API directly; the Docker contract additionally covers nginx
and the shared UI's delivery path. Additional Nim build flags may be passed
after the script name, for example `--path:<dependency-checkout>` when using
an explicitly checked-out dependency.

| Area | Assertions |
| --- | --- |
| Shared contract | Create, list, detail, update, delete, categories/tags, ring-bounded related results, category relocation |
| Invalid inputs | Malformed JSON, wrong JSON types, empty/long title, bad category/tags, oversized body, overflow/nonfinite IDs |
| Parallel requests | 32 Unicode writes and readbacks with eight clients; distinct IDs and exact list membership |
| Persistence | DB shutdown/restart and API restart preserve records |
| Failure handling | DB outage and wrong credentials return a generic 503; no credential text in responses/logs |
| TLS | Trusted certificate roundtrip; wrong hostname and untrusted CA rejected |

## Connection Ownership

Jazzy's Mummy workers are multithreaded. This demo builds its API with
`--mm:atomicArc --threads:on -d:useMalloc`, matching Jazzy's runtime model.
The separate KoutenDB server keeps its ordinary ARC build.

Each request creates a KoutenDB TCP client on its worker and closes it in
`finally`. No client or embedded database handle is shared between workers.
The synchronous DB work completes without an intervening `await`; this is a
correctness-oriented example, not an asynchronous pool or throughput benchmark.
Writes use applied acknowledgements. Failed writes are not automatically
replayed. A 503 is not proof that a write did not commit.

Each new client registers the demo's fixed category rings and their applied
acknowledgement policy before handling IDs. This restores the per-client ring
metadata needed for point reads after reconnection, without scanning records.
All demo rings use the default period; this is not an example of discovering
arbitrary custom-period rings from opaque IDs.

`/health` checks KoutenDB, rather than only returning a static HTTP response.
Lists read at most 500 records per category; related results read one category
ring and return at most six candidates ranked by shared tags. This demo does
not promise an unbounded task list or cross-request transaction isolation.
Category relocation uses insert then delete, matching the shared demo contract;
it is not an atomic multi-record transaction.

This is a loopback-only evaluation app with demo database credentials, not a
production authorization example. Dev UI and CSRF are disabled explicitly;
add application authentication, authorization, CSRF policy and HTTPS before
exposing a browser app. The DB client can enable verified TLS through
`KOUTEN_TLS=true`, `KOUTEN_TLS_CA_FILE`, and `KOUTEN_TLS_SERVER_NAME`.

## Validation Record

The full local HTTP integration matrix passed on Ubuntu with Nim 2.2.10
and the pinned Jazzy revision on 2026-09-22. Every run used a fresh data
directory. The server used ARC and the multithreaded API used atomicARC.
The React TypeScript/production build and Compose configuration validation
also passed, including the test profile.
The Docker stack itself has not been executed in this validation session
because no Docker daemon was available; its build/runtime result remains
separate from the local integration result.
