# KoutenDB v0.15.2: Lower Learned-Memory CPU Cost

KoutenDB v0.15.2 reduces CPU overhead in the optional internal learned-memory
prototype. Batched latent-vector aggregation improves inference using existing
checkpoints, and an optional product-key router reduces representative-selection
work at larger ring counts.

## Lower CPU Cost with Measured Accuracy Preserved

The DB memory reader now packs returned vectors and scores into contiguous CPU
arrays and performs shared tensor reductions. Scoped retrieval requests, read
budgets, returned bytes and trained weights stay the same. The original
per-ring reader remains available as a correctness and performance control.

A controlled recheck reuses the same trained checkpoint and interleaves both
reader implementations across seven randomized timing rounds, with blocks of
at least 0.5 seconds, two CPU threads and 32 balanced questions:

| Trained model | Original CPU ms/question | Batched CPU ms/question | Reduction |
| --- | ---: | ---: | ---: |
| Flat router | 2.192 | 1.833 | **16.4%** |
| Product router | 2.400 | 2.073 | **13.6%** |

Each model preserves its measured answer accuracy. The flat model answers
**384/384 single-fact questions (100%)** and **511/512 fact comparisons (99.80%)**
correctly. The product model scores **383/384 (99.74%)** and **506/512 (98.83%)**.
Both have zero DB/tensor prediction mismatches on all 896 held-out questions.
The flat model benefits from the reader optimization without retraining.

## Optional Product-Key Routing

The new router represents ring keys as two learned factor tables and selects
top rings from a bounded Cartesian candidate set. At 1,024 rings, each hidden
read scores 64 partial representatives instead of 1,024 full representatives.
It supports both tensor reads and actual KoutenDB snapshots, including disk
snapshots without resident local key/value tables. Flat routing stays the default.

The initial router-only probe measured **91.7% lower routing CPU time** at
262,144 virtual rings, with representative storage falling from 16 MiB to
32 KiB. These larger keyspaces are untrained and contain no corresponding local
memory tables. At the trained 1,024-ring configuration, product routing adds
overhead and has the small accuracy gap shown above. Arbitrary flat-router
checkpoints require retraining for the structured representative family.

## Scope and Compatibility

These are small synthetic CPU experiments, not a large production LLM evaluation.
CPU-time reductions are promising for reducing work per answer; electricity
was not measured and no matching percentage reduction in joules is claimed.
Product-router training still computes dense scores. The aggregation improvement
is separate from the product-router result and applies to the flat model too.

The examples download no models or datasets. The bounded runner uses a 128 MiB
temporary-file budget; measured files including both DB snapshots were about
63.3 MiB, and snapshots were removed after evaluation. Source/checkpoint hashes,
raw samples and checksum files accompany the results. C ABI version 2, wire
contracts and native storage behavior are unchanged.

CI covers 47 CPU experiment contracts, alongside the native, C ABI, macOS,
security, recovery, self-host and container checks required for this release.
The v1.0 continuous-service evidence tracked in issue #108 remains a separate
open stabilization gate.

See [Protocol and Results](https://github.com/puffball1567/koutendb/blob/v0.15.2/docs/product-ring-routing.md)
and [Recorded Evidence](https://github.com/puffball1567/koutendb/blob/v0.15.2/docs/validation-evidence/product-ring-routing/README.md)
for reproduction commands, controls and limitations.
