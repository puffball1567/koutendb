# KoutenDB v0.10.1

KoutenDB v0.10.1 is a documentation and positioning release.

## What Changed

- Rebuilt the README around the value KoutenDB provides: locality-first
  retrieval for RAG, AI context construction, and related-data application
  reads.
- Added a concise, front-page benchmark summary for scanned candidates,
  candidate memory, estimated tokens, and bounded related-data reads.
- Added the completed 72-hour three-node persistent-cluster result to the
  primary project narrative.
- Moved operational scope information to a dedicated section after the product
  explanation, benchmarks, and installation guidance.

## Evidence Linked From the README

- 100-ring working-set benchmark: scanned records/query `10,000 -> 100`.
- 100-ring memory-pressure benchmark: candidate memory/query `93.079 MiB ->
  0.931 MiB`.
- Synthetic RAG benchmark: recall `1.000`, estimated tokens/query `3,955 ->
  657`.
- Related-data benchmark: a bounded KoutenDB six-subring bundle read measured
  `196.859 us` on the documented 1,050,000-record local workload.
- 72-hour local three-node persistent run: 4,022,516 mixed client operations,
  zero client errors, and successful offline verification after shutdown.

See the README, [Benchmark Comparison](benchmark-comparison.md), and
[Soak Testing](soak-testing.md) for complete conditions and reproduction paths.
