# KoutenDB v0.14.2

KoutenDB v0.14.2 hardens the path from reviewed development work to the public
`main` branch. The release keeps the database runtime unchanged while making
release promotion exact, reproducible, and auditable.

## Protected Branch Routes

- pull requests into `devel` run the complete CI suite;
- `hotfix/*` pull requests into `main` run the complete CI suite;
- `main` synchronization pull requests into `devel` run the complete CI suite;
- every other pull-request route into `main` is rejected;
- human direct pushes to `main` remain prohibited.

## Exact-SHA Release Promotion

Normal releases no longer require a second `devel`-to-`main` release pull
request. The dedicated promotion workflow requires the exact current `devel`
commit SHA and verifies all of these conditions before updating `main`:

- a completed, successful push CI run exists for that exact SHA;
- the SHA is associated with a merged pull request into `devel`;
- neither `main` nor `devel` moves during promotion;
- the promoted Git tree is identical to the verified `devel` tree.

The workflow uses a dedicated write deploy key for the final branch update.
Its regular GitHub token has read-only repository permissions and is used only
to inspect CI and pull-request evidence.

## Validation

- workflow YAML parsing passed;
- the complete allow/reject branch-route matrix passed;
- promotion tree-equivalence and divergent-tree rejection tests passed;
- the full Linux and macOS CI suite passed on the policy change and its
  one-time `main` bootstrap path.

This patch does not change the storage format, wire protocol, public Nim API,
or C ABI. External driver compatibility remains unchanged.
