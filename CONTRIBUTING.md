# Contributing to KoutenDB

KoutenDB is currently developed as a tightly controlled technical-preview
database project. The core implementation direction is maintained by the project
owner.

At this stage, the most useful contributions are not broad feature pull
requests. They are real-world verification reports that help evaluate whether
KoutenDB behaves correctly outside the author's local environment.

## Preferred Contributions

Please focus on:

- benchmark results on real hardware;
- cloud deployment reports on AWS, GCP, Azure, or bare-metal environments;
- failure and recovery test reports;
- driver compatibility reports;
- exact retrieval reports across ring sizes, vector dimensions, and CPU architectures;
- WAL / backup / restore / compact verification reports;
- reproducible bug reports with logs, commands, versions, and data shape;
- documentation corrections for tested behavior.

Good reports include:

- KoutenDB commit or tag;
- OS, CPU, memory, disk, filesystem, and container/runtime details;
- exact commands used;
- dataset size, ring count, vector dimensions, payload size, and workload shape;
- expected behavior;
- actual behavior;
- logs, metrics, benchmark output, or minimal reproduction data.

## Pull Request Policy

Small documentation fixes are welcome.

Development follows the branch policy documented in
[Development Workflow](docs/development-workflow.md). In short, normal feature,
test, and documentation work targets `devel`; `main` is reserved for released,
tagged state and direct hotfixes.

Implementation pull requests may be closed or redirected unless they were
discussed first. KoutenDB's data model, transaction behavior, persistence format,
wire protocol, and recovery semantics are intentionally kept under central
design control while the project is pre-1.0.

If you want to propose a code change, open an issue or discussion first with:

- the problem being solved;
- why it belongs in KoutenDB core rather than a driver, adapter, or external
  tool;
- compatibility impact;
- recovery / durability impact;
- test plan.

## What Not To Submit Yet

Please do not send large unsolicited PRs for:

- new query languages;
- alternative storage engines;
- new consensus systems;
- large refactors;
- cloud-specific managed-service integrations;
- enterprise plugin features;
- package publication automation;
- API-breaking driver rewrites.

These may become relevant later, but the current project priority is
measurable correctness, recovery behavior, operational evidence, and carefully
controlled design evolution.

## Security

Do not open public issues for suspected security vulnerabilities involving
authentication, secret keys, encrypted backups, or data exposure. Contact the
project owner privately first.

## License

By contributing documentation, reports, tests, or code, you agree that your
contribution is provided under the repository license unless a separate written
agreement says otherwise.
