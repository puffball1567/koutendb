---
layout: page
title: Hands-on Evaluation
---

# Hands-on Evaluation

This guide is the shortest human path from a clean installation to a verified
KoutenDB restore. It is for evaluation and maintainer dogfooding, not only for
CI. Follow it before relying on less familiar cluster or Universe features.

## What You Will Prove

By the end, you will have:

- stored and queried related JSON documents through ring coordinates;
- reopened a persistent database;
- inspected its atlas and physical health;
- exported a portable JSONL copy;
- created and verified an operational backup;
- restored into an independent directory and read the same logical data.

Use disposable directories and non-sensitive data for the first run.

## 1. Install And Identify The Build

Install the released package:

```sh
nimble install koutendb
kouten --help
```

If the command is missing, add `~/.nimble/bin` to `PATH` as described in
[Installation](installation.md). Record the exact KoutenDB release, Nim version,
operating system, and installation method in your evaluation notes.

## 2. Create A Persistent Local Store

Use an isolated working directory:

```sh
export KOUTEN_TRIAL="$PWD/koutendb-human-trial"
mkdir -p "$KOUTEN_TRIAL"
export KOUTEN_DATA="$KOUTEN_TRIAL/data"
```

Write a user and nearby application data:

```sh
kouten put --ring=users/123 \
  --payload='{"kind":"user","name":"Ada"}' --codec=json
kouten put --near=users/123 --ring=profile \
  --payload='{"kind":"profile","plan":"pro"}' --codec=json
kouten put --near=users/123 --ring=orders \
  --payload='{"kind":"order","number":"A-001","total":120}' --codec=json
```

Read the neighborhood and then narrow it:

```sh
kouten get --ring=users/123 --subring=profile,orders
kouten get --ring=users/123 --subring=orders \
  --selection='{ kind number total }'
kouten atlas
```

Expected result: the broad user coordinate can see the nearby profile and
order, while `--subring=orders` excludes the profile. This is the core locality
behavior, not a global field scan.

## 3. Use The Interactive Shell

The shell is useful for manual inspection:

```sh
kouten shell --data="$KOUTEN_DATA"
```

Try:

```text
list users/123 20
count users/123
atlas
help
exit
```

The shell uses KoutenDB commands rather than SQL. Use single-shot commands for
scripts because their arguments and exit status are easier to reproduce.

## 4. Reopen And Verify

Each single-shot command closes its embedded handle before returning. Running a
new command therefore exercises persistent reopen:

```sh
kouten get --ring=users/123 --subring=profile,orders
kouten verify --data="$KOUTEN_DATA" --segments --json
kouten doctor --data="$KOUTEN_DATA" --json
```

Both maintenance commands must exit successfully. Save their JSON output in
your evaluation record.

Do not run direct data-directory maintenance while `koutend` has the same
directory open. The single-writer lock should reject that mistake, but the
correct operational procedure is to stop or drain the server first.

## 5. Test Portable Migration

Dump the logical data and import it into a clean store:

```sh
kouten dump --data="$KOUTEN_DATA" --out="$KOUTEN_TRIAL/export.jsonl"
kouten import-jsonl --data="$KOUTEN_TRIAL/imported" \
  --in="$KOUTEN_TRIAL/export.jsonl" --batch-size=1000
kouten get --data="$KOUTEN_TRIAL/imported" \
  --ring=users/123 --subring=profile,orders
kouten verify --data="$KOUTEN_TRIAL/imported" --json
```

JSONL is the portable cross-version boundary. Imported records receive target
store IDs; compare logical ring, payload, codec, and vector data rather than
internal IDs.

## 6. Test Backup And Restore

Create, verify, and restore an operational backup:

```sh
kouten backup --data="$KOUTEN_DATA" --backup="$KOUTEN_TRIAL/backup"
kouten verify --backup="$KOUTEN_TRIAL/backup" --json
kouten restore --backup="$KOUTEN_TRIAL/backup" \
  --data="$KOUTEN_TRIAL/restored"
kouten verify --data="$KOUTEN_TRIAL/restored" --segments --json
kouten get --data="$KOUTEN_TRIAL/restored" \
  --ring=users/123 --subring=profile,orders
```

A backup is not proven by successful creation. The independent restore and read
are part of the test.

## 7. Continue With A Server Trial

Run the authenticated persistent Compose trial in
[Operational Trials](operational-trials.md), then use the longer
[Service Trial](service-trial.md) when an application is ready to consume the
database.

## Dogfooding Journal

Keep one append-only Markdown or JSONL journal per trial. A minimal entry is:

```text
timestamp:
koutendbVersion:
applicationVersion:
environment:
operationOrIncident:
expected:
observed:
dataAtRisk:
recoveryAction:
result:
linkedIssue:
```

Record successful upgrade, backup, and restore drills too. The absence of an
incident is meaningful only beside operation counts, uptime, and the workload
that actually ran.

## Evaluation Pass Criteria

The human evaluation passes when:

- every command can be understood without reading source code;
- persistent reopen returns the expected logical records;
- JSONL migration produces the expected logical dataset;
- backup verification and independent restore both succeed;
- errors identify a corrective action rather than exposing an internal stack;
- every deviation from this guide is fixed or tracked publicly.

Passing this guide does not by itself prove production readiness. It proves
that the documented operational foundation is usable by a human.
