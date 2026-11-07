# AI Quality, CPU Cost and Energy Evidence

These numerical records accompany v0.15.1. They contain configurations, scores,
controls, sampled timings and implementation/library hashes. They do not contain
downloaded model weights, source passages, reference-answer text, credentials or
private filesystem paths.

## Main Findings

| Experiment | Observation | Scope |
| --- | --- | --- |
| RAG request energy | 4.2715 → 3.7213 CPU package J/request, **12.9% lower**; F1 0.571 → 0.582 | Automatic routing plus context compaction; 100 held-out questions, three repetitions, six conditions |
| Trained memory answer quality | **100%** fact answers; **99.28%** unseen comparisons versus 93.29% dense | Three synthetic worlds, 384 learned facts each; 2,688 questions per model |
| Trained 10 MiB model CPU time | **13.0% lower** originally; **11.5% lower** on the release-core recheck | Whole-model process CPU time, two threads; DB accuracy 100% / 99.61% |

The RAG energy reduction interval was 9.4–16.6% under the recorded paired
question-bootstrap procedure. Average CPU package power stayed approximately
10.8–10.9 W; the improvement was energy per request as requests completed sooner,
rather than a demonstrated reduction in instantaneous power.

The compact global control is essential: the additional optimized-ring energy
gain over that equally compact baseline was 3.4%, with an interval crossing zero.
The measured 12.9% must not be attributed solely to ring selection. No electricity
measurement has been completed for the internal learned-memory model itself.

## Records and Provenance

| Record | Contents |
| --- | --- |
| [rag-energy.json](rag-energy.json) | Sources and licenses, pinned model revisions, six-condition summaries and all control comparisons |
| [trained-quality.json](trained-quality.json) | Three-world training protocol, accuracy counts, diagnostics, per-world results and DB/tensor parity |
| [trained-large.json](trained-large.json) | Original trained 10 MiB experiment, validation history, accuracy, CPU/wall timing samples and source-parser verification |
| [capacity-generated.json](capacity-generated.json) | Generated-kernel memory/disk cost sweep and the adverse wide-ring control |
| [capacity-cold.json](capacity-cold.json) | Warm repeats and single cold-file dense/DB forward passes, including observed storage-read bytes |
| [release-build.json](release-build.json) | Inference-only checks against the updated release core, using retained trained weights without retraining |

The original experiments were recorded on a development checkout based on
`e88930994d58ac73562604b042225a628c03e882`, with the experiment and payload-selection
changes under evaluation. The per-record library and implementation hashes
identify those measured snapshots. They are historical experimental evidence,
not newly rerun measurements of every v0.15.1 scenario.

For release preparation, the changes were ported onto the current v0.15.0 core
at `53a1a38`. Its retained-byte and wire security protections were preserved.
The first world's two small memory layouts and the trained 10 MiB model were
checked against the rebuilt C ABI. Accuracy was unchanged and DB/tensor
predictions matched on all rechecked questions. The large-model recheck consumed
6.00455 ms CPU/question for dense versus 5.31368 ms for DB memory, an 11.5%
reduction. Absolute times differed between sessions, so neither percentage is a
hardware-independent performance guarantee.

The release-core local checks include 37 Python contracts, the core suite,
cluster retrieval routing, the 13-test wire security matrix, package validation
and a TLS-enabled server semantic check. Protected-branch CI remains the merge
and release gate.

## Interpretation and Reproduction

The learned-memory results show that a small model can answer through trained
latent vectors stored in actual KoutenDB rings. The reader receives hidden
vectors, not correct answers or oracle ring labels. Both tested partitions had
the same 2,048 entries; their accuracy remained high despite selecting a small
read subset.

The capacity probes use random kernels and do not establish answer quality.
The trained tasks use a supervised role parser, known factual entities and a
fixed answer vocabulary. Their dense baselines use the same fixed training
budget and are not the best achievable dense models. The 10 MiB case keeps the
same 384 facts; allocating more parameters is not a demonstration of billions
of facts or a general-purpose LLM. RSS did not show a memory-saving advantage
for the current implementation, and large individual rings made reads worse.

See [RAG Energy](../../real-rag-energy-bench.md),
[Trained Answer Quality](../../ring-memory-quality-bench.md),
[Internal Memory](../../ring-memory-experiment.md), and
[Bounded Capacity Probe](../../ring-memory-capacity-bench.md) for commands,
data licensing, controls and resource limits. The recorded summaries deliberately
exclude the SQuAD text and request-answer journal; those remain in the optional
local experiment directory.
