---
layout: page
title: Five-Minute Quickstart
---

# Five-Minute Quickstart

This path demonstrates KoutenDB's core behavior: write related data near one
coordinate, read that bounded neighborhood, and narrow it without a global
field scan. It uses the embedded CLI, so it does not require a server or cloud
account.

## Install

KoutenDB requires Nim 2.0 or newer and the prerequisites listed in
[Installation](installation.md).

```sh
nimble install koutendb
kouten --help
```

If `kouten` is not found, add `~/.nimble/bin` to `PATH` as described in the
installation guide.

## Write One Neighborhood

Use a disposable persistent directory:

```sh
export KOUTEN_DATA="$PWD/koutendb-quickstart"
```

Write one user and place related documents near that coordinate:

```sh
kouten put --ring=users/123 \
  --payload='{"kind":"user","name":"Ada"}' --codec=json
kouten put --near=users/123 --ring=profile \
  --payload='{"kind":"profile","plan":"pro"}' --codec=json
kouten put --near=users/123 --ring=orders \
  --payload='{"kind":"order","number":"A-001","total":120}' --codec=json
```

The application supplied the locality at write time. KoutenDB does not need to
discover this relationship by scanning every document later.

## Read Broadly, Then Narrow

Read the user neighborhood:

```sh
kouten get --ring=users/123 --subring=profile,orders
```

Keep the root entity, include only the nearby orders branch, and select the
fields the caller needs:

```sh
kouten get --ring=users/123 --subring=orders \
  --selection='{ kind number total }'
```

Inspect the available coordinates:

```sh
kouten atlas
```

The important result is not merely that three documents were stored. The read
began from `users/123`, so unrelated users, tenants, repositories, or document
families were outside the first candidate set.

## Choose The Next Path

| Goal | Continue with |
|---|---|
| Prove restart, migration, backup, and restore | [Hands-on Evaluation](hands-on-evaluation.md) |
| Embed KoutenDB in Nim | [Public API](public-api.md) |
| Use Rust, TypeScript, Python, PHP, or C++ | [Driver Installation](driver-installation.md) |
| Run an authenticated persistent server | [Self-Hosted Operations](v0.14-self-hosted-operations.md) |
| Evaluate AI/RAG working-set reduction | [Effect Validation](effect-validation.md) |
| Model a real application | [Use Case Recipes](use-case-recipes.md) |
| Understand the path to v1.0 | [v1.0 Stabilization](v1-stabilization.md) |

Use non-sensitive and reconstructible data for the first evaluation.
