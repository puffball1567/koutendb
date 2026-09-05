---
layout: page
title: Installation
---

# Installation

KoutenDB installs command-line binaries named `kouten`, `koutend`, `koutencli`,
`koutenbench`, and `koutensim`.

For normal use, the command should be available as `kouten`, not as
`bin/kouten`. The `bin/` form is only for source-tree development and smoke
tests.

## Choose An Installation Path

| Goal | Artifact | Required locally |
|---|---|---|
| Try the CLI or embed KoutenDB in Nim | Nimble package | Nim, C compiler, libsodium |
| Run a persistent TLS/authenticated server | GHCR image and self-host bundle | Docker with Compose, Git, OpenSSL |
| Connect from an existing language | Published language driver | Driver-specific runtime plus a server or native library |
| Develop KoutenDB itself | Source checkout | Full build and test toolchain |

For the shortest introduction to the data model, install the Nimble package and
continue with the [Five-Minute Quickstart](quickstart.md). Choose the container
path when the first question is operational rather than embedded use.

## Prerequisites

- Nim `2.0.0` or newer
- `git`
- `gcc` or another C compiler supported by Nim
- `libsodium` development files for `nimsodium`

## Local CLI And Embedded Nim

Install KoutenDB from Nimble:

```sh
nimble install koutendb
```

Use a source checkout when you want to run the full test suite, examples, or
driver smoke tests:

```sh
git clone https://github.com/puffball1567/koutendb.git
cd koutendb
nimble install -y
```

Nimble installs binaries into `~/.nimble/bin` by default. Add it to your shell
PATH if `kouten --help` is not found:

```sh
export PATH="$HOME/.nimble/bin:$PATH"
```

For a persistent shell setup:

```sh
printf '\nexport PATH="$HOME/.nimble/bin:$PATH"\n' >> ~/.profile
```

Then verify:

```sh
kouten --help
koutend --help
```

The installation is ready when `kouten --help` succeeds. Continue with the
[Five-Minute Quickstart](quickstart.md); cluster configuration is not required
for the first evaluation.

## Self-Hosted Server Image

Versioned `linux/amd64` and `linux/arm64` images are published at:

```text
ghcr.io/puffball1567/koutendb:<version>
```

The supported server path uses the repository's self-host bundle to generate
TLS certificates, external secret files, persistent storage, health checks, and
strong-durability configuration. For v0.14.2:

```sh
git clone --depth 1 --branch v0.14.2 \
  https://github.com/puffball1567/koutendb.git
cd koutendb
KOUTENDB_VERSION=0.14.2 \
  deploy/self-hosted/bootstrap.sh "$PWD/../koutendb-selfhost"
cd ../koutendb-selfhost
docker compose up -d
docker compose ps
```

Read [v0.14 Self-Hosted Operations](v0.14-self-hosted-operations.md) before
exposing the listener outside localhost. The bootstrap PKI is an evaluation and
single-node starting point, not a replacement for an organization's approved
issuer and trust-distribution process.

## Language Drivers

Published drivers are available for Rust, JavaScript/TypeScript, Python, PHP,
and C++. A driver is not a standalone KoutenDB server:

- native C ABI wrappers require a compatible `libkoutendb` build;
- TCP drivers require a reachable `koutend` endpoint;
- the core and driver versions must satisfy the documented compatibility
  matrix.

Use [Driver Installation](driver-installation.md) for package commands, native
library setup, TLS/authentication requirements, and verification examples.

## System Install

For server-style deployments, use `/usr/local/bin`, matching the usual source
install location for database tools such as MySQL or PostgreSQL client/server
binaries.

Build repo-local binaries:

```sh
nim c -d:ssl -d:release --nimcache:/tmp/nimcache_kouten -o:bin/kouten src/koutencli.nim
nim c -d:ssl -d:release --nimcache:/tmp/nimcache_koutend -o:bin/koutend src/koutend.nim
```

Install them onto the system PATH:

```sh
sudo install -m 0755 bin/kouten /usr/local/bin/kouten
sudo install -m 0755 bin/koutend /usr/local/bin/koutend
```

Optional development and benchmark tools:

```sh
nim c -d:release --nimcache:/tmp/nimcache_koutenbench -o:bin/koutenbench src/koutenbench.nim
nim c -d:release --nimcache:/tmp/nimcache_koutensim -o:bin/koutensim src/koutensim.nim
sudo install -m 0755 bin/koutenbench /usr/local/bin/koutenbench
sudo install -m 0755 bin/koutensim /usr/local/bin/koutensim
```

Verify:

```sh
command -v kouten
command -v koutend
kouten --help
```

## Source-Tree Development

Use repo-local binaries only when you explicitly want to test the current
checkout without installing it:

```sh
nim c -d:release --nimcache:/tmp/nimcache_kouten -o:bin/kouten src/koutencli.nim
bin/kouten --help
```

Documentation and examples use `kouten` for installed usage. Test scripts may use
`bin/kouten` to avoid depending on the user's PATH.
