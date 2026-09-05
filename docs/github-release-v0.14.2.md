# KoutenDB v0.14.2

KoutenDB v0.14.2 hardens the path from reviewed development work to the public
`main` branch. The release keeps the database runtime unchanged while making
release promotion exact, reproducible, and auditable.

## Protected Branch Routes

- pull requests into `devel` run the complete CI suite;
- `hotfix/*` pull requests into `main` run the complete CI suite;
- `main` synchronization pull requests into `devel` run the complete CI suite;
- `devel` pull requests into `main` validate the exact successful `devel` push
  CI run without repeating the complete suite;
- every other pull-request route into `main` is rejected;
- human direct pushes to `main` remain prohibited.

## Exact-SHA Release Promotion

Normal releases use a `devel`-to-`main` pull request as their auditable
boundary. Its required CI gate verifies these conditions before merge:

- a completed, successful push CI run exists for that exact SHA;
- the pull-request head is the exact current `devel` HEAD;
- the successful run belongs to the repository's `devel` branch.

The gate uses the regular read-only GitHub token only to inspect branch and CI
evidence. No deploy key or direct-push exception is required.

## Validation

- workflow YAML parsing passed;
- the complete allow/reject branch-route matrix passed;
- exact-HEAD and successful-CI promotion checks are enforced;
- the full Linux and macOS CI suite passed on the policy change and its
  one-time `main` bootstrap path.

This patch does not change the storage format, wire protocol, public Nim API,
or C ABI. External driver compatibility remains unchanged.
