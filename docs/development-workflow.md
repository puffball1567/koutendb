# Development Workflow

KoutenDB uses a stable-main workflow.

## Branch Roles

| Branch | Role |
| --- | --- |
| `main` | Released, tagged, public-stable state. Documentation and package metadata on `main` should describe what users can install or evaluate now. |
| `devel` | Integration branch for the next release. Feature work targets `devel` first, not `main`. |
| `feature/...` | Focused implementation branches created from `devel`. |
| `docs/...` | Documentation-only branches created from `devel` unless they are patching released docs. |
| `test/...` | Test and CI changes created from `devel` unless they are release hotfixes. |
| `release/vX.Y.Z` | Short-lived release preparation branch cut from `devel` after the next release scope is ready. |
| `hotfix/...` | Urgent fix branch cut from `main` when the released state needs a direct patch. |

## Protected Branch Routes

| Source | Target | Required gate |
| --- | --- | --- |
| `devel` | `main` | The promotion workflow verifies successful CI for the exact `devel` HEAD; no release PR is opened. |
| `hotfix/*` | `main` | Pull request with the complete CI suite. |
| `main` | `devel` | Pull request with the complete CI suite. |
| any other branch | `main` | Rejected by the branch route policy. |
| direct push | `main` | Rejected by the repository ruleset. |

## Normal Feature Flow

1. Update local `devel`.
2. Create a focused branch from `devel`.
3. Implement and test the change.
4. Open a PR into `devel`.
5. Merge only after CI passes.

Feature branches should not target `main` directly. This keeps `main` aligned
with released tags and avoids exposing half-integrated work as the public
default state.

## Release Flow

1. Decide the next release scope on `devel`.
2. Cut `release/vX.Y.Z` from `devel`.
3. Update package metadata, release notes, and release checklist state.
4. Open a PR from `release/vX.Y.Z` into `devel` and merge it after CI passes.
5. Wait for the CI run on the resulting `devel` HEAD to pass.
6. Run the `Promote devel to main` workflow with that exact 40-character
   `devel` commit SHA.
7. Tag the promotion commit on `main`.
8. Create the GitHub Release from the release notes.

The promotion workflow is the only PR-free path into `main`. It verifies that
the requested SHA is still the current `devel` HEAD, that the HEAD came from a
merged PR into `devel`, that its push CI succeeded, and that the resulting tree
is exactly the verified `devel` tree. A `devel` to `main` release PR is not
used. Tags are created only from `main`.

## Hotfix Flow

Use a hotfix only when the currently released state needs a direct correction.

1. Create `hotfix/...` from `main`.
2. Apply the smallest safe fix.
3. PR into `main`.
4. Merge only after the complete PR CI suite passes.
5. Tag a patch release after merge.
6. Open a PR from `main` into `devel` and merge only after the complete PR CI
   suite passes.

Branches other than `hotfix/*` cannot open an accepted PR into `main`. Human
pushes directly to `main` are prohibited by the repository ruleset.

## Work In Progress

Large work should stay on a feature branch until it is coherent enough to enter
`devel`. If work must pause while a release is prepared, stash or commit it on
the feature branch. Do not apply unfinished feature work directly to `devel`.

## CI Expectations

The repository CI is the release gate for merged branches. Pull requests into
`devel`, `hotfix/*` pull requests into `main`, and `main` synchronization pull
requests into `devel` run the complete suite. A push to `devel` runs the same
suite and creates the exact-SHA evidence consumed by the promotion workflow.
Other pull-request routes into `main` fail the branch route policy before the
expensive jobs start.

Core checks include:

- Nim semantic checks;
- SSL-enabled checks;
- C ABI contract checks;
- core tests;
- CLI, cluster, recovery, universe, and TLS smoke tests.

Driver compatibility tests may remain optional when the relevant driver
repositories are developed separately.
