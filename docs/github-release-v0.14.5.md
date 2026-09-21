# KoutenDB v0.14.5

This patch adds a runnable Jazzy Framework integration example alongside
the existing REKT and PRK stacks.

## Jazzy, React And KoutenDB

- Shared React task UI with create, list, detail, update and delete operations.
- Categories select named rings; related records are retrieved from the
  selected category ring and ranked by shared tags.
- Authenticated, persistent KoutenDB server behind a Jazzy API.
- Docker Compose setup with a loopback-only HTTP port and no exposed DB port.
- Request-owned Nim clients compatible with Jazzy's multithreaded workers.

The example pins Jazzy commit `d45d49d07a6d130b56c1070f723cf668094e276b`
(package version 0.5.3). Jazzy is an optional example dependency, not a new
dependency of the KoutenDB engine.

## Validation

The local HTTP integration matrix covers shared CRUD, category relocation,
related-result scope, malformed and oversized input, ID boundaries, 32
concurrent Unicode writes/readbacks, exact list membership, persistence after
DB/API restart, database outage, authentication rejection, credential redaction
and verified TLS including wrong-hostname/untrusted-CA rejection.

A dedicated GitHub Actions workflow runs the HTTP matrix and the Docker CRUD
contract; [both passed before release](https://github.com/puffball1567/koutendb/actions/runs/35633165422).
The shared React production build and Compose configurations are
also checked. See the [demo guide](https://github.com/puffball1567/koutendb/tree/v0.14.5/examples/web/jazzy-crud) for
reproduction commands and validation results.

No storage-format, wire-protocol or C ABI version changes are introduced.

## Try It

```sh
docker compose -f examples/web/jazzy-crud/compose.yml up -d --build --wait
```

Open <http://localhost:18082>. This is a local evaluation example, not a
production application-authentication template.

See [Web Integration Demos](https://github.com/puffball1567/koutendb/tree/v0.14.5/examples/web) and
[Test Coverage](https://github.com/puffball1567/koutendb/blob/v0.14.5/docs/test-coverage.md).
