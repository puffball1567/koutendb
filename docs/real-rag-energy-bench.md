# Trained-Model RAG Quality and Energy Experiment

This optional CPU experiment measures a complete **warm request**, from a real
question through query embedding, routing, KoutenDB retrieval, prompt assembly,
tokenization, generation and decoded answer. It evaluates the answer against
public reference answers, while measuring CPU package energy when available.

It extends the [small untrained Transformer experiment](transformer-energy-bench.md).
Neither experiment compares KoutenDB with a different database engine.

## Sources, Licenses and Local Storage

| Artifact | Official source | Published license |
|---|---|---|
| Answer generator | [Google FLAN-T5-small](https://huggingface.co/google/flan-t5-small) | Apache-2.0 |
| Embedding model | [all-MiniLM-L6-v2](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2) | Apache-2.0 |
| Questions, passages and reference answers | [SQuAD 1.1 development data](https://rajpurkar.github.io/SQuAD-explorer/dataset/dev-v1.1.json) | CC BY-SA 4.0, as identified by the [SQuAD distribution site](https://rajpurkar.github.io/SQuAD-explorer/) |

SQuAD attribution: Pranav Rajpurkar, Jian Zhang, Konstantin Lopyrev and Percy
Liang, *SQuAD: 100,000+ Questions for Machine Comprehension of Text* (2016).
The passages originate from Wikipedia. This experiment splits passages into
overlapping chunks and samples questions from separate paragraphs; these are
local experimental transformations of the dataset.

The models, dataset, dependency environment and generated artifacts remain
under `.tmp/rag-energy/`, which is excluded from Git. The experiment does not
upload documents or call a paid inference API. `sources.json` records model
repository commit revisions and the dataset SHA-256. Subsequent inference uses
local files and does not execute remote model code. Model weights are loaded
from safetensors.

These are licensed resources rather than public-domain material. Redistribution
of Apache-2.0 artifacts requires the applicable license/notice preservation;
sharing SQuAD text or adaptations requires the applicable attribution,
license-link, modification notice and share-alike conditions. See
[Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0) and
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
The repository stores the experiment code and source references rather than
redistributing the downloaded weights or corpus.

## Run

From an interactive terminal in the repository:

```sh
bash examples/real_rag_energy_bench.sh
```

The wrapper prepares an isolated virtual environment which reuses an existing
PyTorch installation, installs the optional pinned experiment dependencies if
missing, downloads the sources if absent, and builds the repository's C ABI.
Initial setup requires network access and the ordinary Nim/C build prerequisites.
The downloaded model files total approximately 385 MiB for the tested snapshots.
No model training is performed.

Corpus embedding is cached and excluded from request measurements. KoutenDB
is loaded into a fresh temporary database on each run, using buffered
persistence with its in-memory vector index. Model loading, corpus import and
warmup are also excluded. Only the fixed read-only RAPL helper uses sudo; the
password is entered directly in the user's terminal. No system permissions,
power limits or performance-monitoring settings are changed.

Defaults are 40 questions, three repetitions, two CPU threads, greedy generation
with up to 32 output tokens, 96-token corpus chunks with 16-token overlap, and
an input budget of 1024 generator tokens. Each question comes from a different
paragraph. Article order and paragraph selection use a fixed random seed.
Questions and comparison conditions are shuffled during measurements.

The model uses its real tokenizer. Prompt packing retains whole retrieved
chunks while they fit the input budget; omitted chunks and actual generated
lengths are recorded. No passage is selected using a reference answer.

A quick quality/time run without requiring energy access is available with:

```sh
bash examples/real_rag_energy_bench.sh --no-energy --queries=12 --repeats=1 \
  --output=.tmp/rag-energy/pilot.json
```

For a longer run:

```sh
bash examples/real_rag_energy_bench.sh --queries=100 --repeats=5
```

## Comparison Conditions

| Condition | Search and context |
|---|---|
| `global_8` | Search all chunks, retrieve up to 8 |
| `global_3` | Search all chunks, retrieve up to 3; same-budget control |
| `oracle_ring_3` | Search the labelled source article's ring, retrieve up to 3 |
| `auto_ring_3` | Select an article ring using the query and document centroids; retrieve up to 3, with global fallback |
| `no_context` | Generate an answer without retrieval; diagnostic for model prior knowledge |

`oracle_ring_3` intentionally uses the dataset's source-article label. It is a
conditional supplied-scope control, **not evidence that automatic routing finds
the right ring**. `auto_ring_3` does not inspect the target article, answers or
retrieval labels. It chooses the closest normalized article centroid if the
top-two cosine-score gap is at least 0.03. Otherwise it uses global search. A
scoped search also falls back globally when no hit is returned or the best hit
scores below 0.25. All routing and fallback work is inside the measured window.
Thresholds are fixed before answer evaluation; they are not optimized on its
results. The journal records routing decisions and fallback work.

## Quality and Energy Interpretation

### Optional Optimized Recipe

```sh
bash examples/real_rag_optimized_bench.sh
```

This opt-in recipe preserves the original result files and evaluates 100
questions starting at offset 200, with three repetitions. Its output is
`.tmp/rag-energy/optimized-results.json` and the corresponding request journal.
Questions at offsets 0–199 are reserved for development/regression checks;
the context/routing rules were fixed before inspecting the offset-200
evaluation results. Model weights and corpus chunks are unchanged.

The additional conditions are:

| Condition | Changes relative to the original three-document condition |
|---|---|
| `global_compact_3` | Global retrieval with overlap merging and query-aware context packing |
| `oracle_compact_3` | Supplied source ring plus the same context packing |
| `auto_compact_3` | Multi-prototype routing over several rings plus the same context packing |

Context packing merges chunks only within the same ring and source paragraph,
removes exact overlap, and keeps source chunk IDs for traceability. Sentence
selection is an English-language heuristic: it retains a contiguous window
only when at least two non-stopword query terms match and that window preserves
every query term found in the full retrieved passage. Weak or distributed
evidence retains the full passage. This is not an answer-preservation guarantee;
quality and actual answer-text recall must still be measured.

The new router represents each article with up to eight document-only
prototypes, rather than a single average. It searches up to four selected rings,
merges their exact top-k candidates, and falls back globally on an ambiguous
prototype score gap or insufficient hit score. No question answers or source
labels are used by this router. Prototype scores are recorded separately as
`router_vectors_scored`; `scanned` continues to count actual document-vector
visits, including fallback work. Prototype initialization is outside the warm
request window and its duration is recorded as `policy_preparation_ms`.

The global compact control is deliberate: a generic context-packing benefit
must not be attributed uniquely to rings. Reports compare optimized ring
conditions against both the ordinary and compact global controls. A gain over
the old recipe does not establish superiority over another vector database.

To verify quality and time without requesting energy access:

```sh
bash examples/real_rag_optimized_bench.sh --no-energy --repeats=1 \
  --output=.tmp/rag-energy/heldout-quality.json
```

`--query-offset`, `--arms`, `--context-sentences`, `--routing-prototypes`,
`--routing-rings` and `--prototype-gap` make these conditions explicit. Keep
development and evaluation question sets separate when changing those settings.
The report includes implementation hashes to distinguish revisions.

With the optimized policy frozen, a local one-repetition quality/time check on
the 100 questions at offsets 200–299 produced:

| Condition | Exact match | Token F1 | Source recall | Mean input tokens | Mean request ms |
|---|---:|---:|---:|---:|---:|
| `global_3` | 0.490 | 0.571 | 0.840 | 295.9 | 277.31 |
| `global_compact_3` | 0.510 | 0.592 | 0.840 | 235.7 | 248.10 |
| `oracle_ring_3` | 0.590 | 0.668 | 0.930 | 297.1 | 271.88 |
| `oracle_compact_3` | 0.600 | 0.681 | 0.930 | 235.6 | 234.88 |
| `auto_ring_3` | 0.460 | 0.534 | 0.760 | 292.3 | 267.57 |
| `auto_compact_3` | 0.500 | 0.582 | 0.830 | 236.8 | 250.31 |

The compact supplied-scope condition reduced input tokens by 20.7% and request
time by 13.6% relative to its full-context counterpart. The compact automatic
condition reduced input tokens by 19.0% and request time by 6.4% relative to
the previous automatic condition. F1 point estimates increased; paired
bootstrap checks remained within the configured five-point tolerance. This
quality/time check had no energy access and establishes no joules/request
claim. Repeat the interactive energy run before drawing an energy conclusion.
The compact global control also improved, so those input savings must not be
presented as exclusive to ring routing.

The subsequent interactive energy run on 2026-11-07 completed all 1,800
requests (100 questions, six conditions, three repetitions), with no missing or
nonpositive energy readings. Implementation hashes and question IDs matched
the frozen quality/time check. Request-level data reproduced the saved
aggregate statistics.

| Condition | Token F1 | Mean request ms | CPU package J/request |
|---|---:|---:|---:|
| `global_3` | 0.571 | 395.19 | 4.2715 |
| `global_compact_3` | 0.592 | 354.97 | 3.8525 |
| `oracle_ring_3` | 0.668 | 383.78 | 4.1745 |
| `oracle_compact_3` | 0.681 | 335.95 | 3.6324 |
| `auto_ring_3` | 0.534 | 387.47 | 4.2239 |
| `auto_compact_3` | 0.582 | 342.94 | 3.7213 |

Relative to `global_3`, the optimized automatic condition used 12.9% less
energy, with a paired question-bootstrap 95% interval of 9.4–16.6%. Its F1
difference interval was -0.0343 to +0.0581, within the configured five-point
noninferiority tolerance. The compact global condition itself used 9.8% less
energy than the plain global condition. Both improvements include context
packing; they do not isolate database-engine changes.

Against `global_compact_3`, the additional energy reduction from optimized
automatic routing was 3.4%, with an interval of -1.4–10.5%. Supplied-scope
compact retrieval reduced energy by 5.7% against that same compact global
control, with an interval of -1.9–15.3%. Both intervals cross zero: this run
does not establish a separate ring-specific energy advantage. Supplied scope
also uses the labelled source article, so its stronger F1 is conditional on
that information being available.

CPU package power remained approximately 10.8–10.9 W. Lower energy per
request primarily accompanied shorter request execution. This remains one
local warm-request experiment, not an independent-session or whole-system
energy result.

### Reading the Metrics

The report includes normalized exact match (EM), token F1 against the best
reference answer, source-paragraph recall, and reference-answer text presence
in the actual packed context. EM/F1 follow the SQuAD normalization convention:
lowercase, remove punctuation and English articles, then normalize whitespace.
These metrics do not evaluate every aspect of answer quality.

Repeated measurements of a question are averaged before paired bootstrap
analysis. The sampling unit is the question, not each repetition. Comparisons
against both global baselines report F1 differences, 95% bootstrap intervals,
and energy-reduction intervals when energy is available. The configured
quality tolerance defaults to 0.05 absolute F1 (five percentage points). The
report's combined flag requires both a quality lower bound within that
tolerance and a positive energy-reduction lower bound. These are exploratory
comparisons, without adjustment for multiple comparisons or article-level
correlation; the flag is not a general production-quality guarantee.

SQuAD may overlap the trained models' training data. This experiment does not
establish generalization to unseen questions. The no-context control helps
inspect prior knowledge but cannot establish the absence of contamination.
This is English, single-source QA; it does not test genuine cross-ring or
multi-hop questions.

RAPL measures CPU package energy, including background work, rather than the
whole system or one process. Idle power is not subtracted. Model loading,
offline embeddings, imports and training are excluded. Run on a quiet machine
and repeat independent sessions before making a public energy-saving claim.

## Saved Artifacts and Checks

An initial local smoke run on 2026-11-07 used 12 questions and one repetition,
with the default model, corpus and routing configuration:

| Condition | Exact match | Token F1 | Source-paragraph recall | Mean input tokens | Mean request ms |
|---|---:|---:|---:|---:|---:|
| `global_8` | 0.667 | 0.722 | 1.000 | 698.3 | 985.63 |
| `global_3` | 0.750 | 0.806 | 0.917 | 277.2 | 451.99 |
| `oracle_ring_3` | 0.833 | 0.889 | 0.917 | 285.9 | 467.97 |
| `auto_ring_3` | 0.667 | 0.708 | 0.667 | 280.3 | 418.80 |
| `no_context` | 0.083 | 0.083 | 0.000 | 27.2 | 171.02 |

This verified that the trained generator answers real questions and that the
pipeline can expose routing-related quality loss. In this small sample,
automatic routing reduced source recall and F1 relative to `global_3`; it did
not establish quality-preserving savings. Energy was unavailable in this smoke
run. Twelve questions are insufficient for a broad quality or efficiency claim.

- `.tmp/rag-energy/results.json`: sources, configuration, quality/energy summary
  and paired comparisons.
- `.tmp/rag-energy/results.requests.jsonl`: per-request answers, scores, token
  counts, timings, energy, retrieval and routing diagnostics.
- `.tmp/rag-energy/output.log`: console output from the most recent wrapper run.
- `.tmp/rag-energy/sources.json`: dataset checksum and model revisions.

Use `--output` to retain multiple independent reports. The per-request journal
uses the same basename with `.requests.jsonl` appended in place of `.json`.

```sh
.tmp/rag-energy/venv/bin/python tests/test_real_rag_energy_bench.py
```
