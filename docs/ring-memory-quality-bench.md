# Trained Ring Memory Answer Quality

This experiment compares held-out answer accuracy of a dense knowledge layer and
two learned ring-memory layouts. It extends the
[small internal-memory prototype](ring-memory-experiment.md) to more facts and
three independent generated worlds. It addresses answer quality separately from
the [generated capacity/cost probe](ring-memory-capacity-bench.md).

The primary comparison uses separately trained models and true held-out answer
labels. DB/tensor agreement is an implementation check; it does not by itself
establish answer accuracy.

## Fixed Protocol

Seeds 731, 732 and 733 each generate 128 entities with three attributes and eight
possible values: 384 facts per world. All facts are taught during training.
Questions ask for an attribute value or whether two facts have the same value.

Per world:

- Knowledge training: 1,152 single-fact phrasings and 4,096 balanced comparisons.
- Validation: 384 single-fact questions and 512 balanced comparisons.
- Test: 384 single-fact questions and 512 balanced comparisons.
- Test questions' exact strings are absent from knowledge and parser training.
- Comparison fact pairs are disjoint across splits, including reversed pairs.
- The parser learns all grammar templates on additional alias entities without
  their factual-value labels. This holds out wording for factual entities,
  rather than testing previously unseen grammar.

All three worlds are trained before any final test results are evaluated.
Each checkpoint is selected only by validation macro accuracy. The run's plan
is written to disk before training starts.

## Matched Models and Ring Layouts

All variants use the same two-layer Transformer role parser, frozen random token
embeddings, width 64, common semantic codes and classifier architecture. The
parser trains once per world for 3,000 steps using entity/attribute/operation
labels, then is frozen and copied identically to all variants. The classifier
and other shared components also have identical initial weights.

| Variant | Knowledge layer | Knowledge parameters |
| --- | --- | ---: |
| `dense` | Two linear maps and GELU | 170,086 |
| `ring_coarse` | 16 rings, 128 entries per ring | 169,280 |
| `ring_fine` | 64 rings, 32 entries per ring | 170,048 |

Both ring layouts have 2,048 latent memory entries. Knowledge parameter counts
are within 0.5%. Each hidden read selects two rings and four values per ring;
there are two reads per question. Values are learned 64-dimensional float32
vectors and keys have 16 dimensions. Neither entities nor correct ring labels
are passed to the memory reader at inference time.

Each model receives exactly the same minibatches for 2,000 knowledge-training
steps, batch size 64, AdamW learning rate 0.003 and weight decay 0.001. The loss
is answer cross-entropy plus 0.5 times an auxiliary latent fact-decoding loss.
The ring variants use 250 soft-routing warmup steps followed by straight-through
top-k training. The training surrogate scores dense tables; this run does not
measure sparse training cost or training energy savings.

The two layouts test a partition-granularity choice at the same memory capacity.
How related information is placed and traversed resembles a data-model/access
design question. Here placement and routing are learned from examples; this is
not a manually supplied ER schema or an oracle entity-to-ring assignment.

## Accuracy and Diagnostics

Primary end-to-end accuracy includes parser errors. Final dense and memory model
predictions use one question at a time. Each trained ring snapshot is exported to
actual embedded KoutenDB, and DB answer accuracy is evaluated independently
against the test labels. DB and tensor predictions are compared on every test
question.

The report records per-world scores, their mean, raw counts and per-question
predictions. An exploratory check asks whether each ring variant is within two
percentage points of dense accuracy in both task categories in every world.
This predeclared tolerance is not a statistical noninferiority result. Questions
reuse facts, and three generated worlds do not establish broad generalization.

Additional diagnostics include:

- Discrete parser role correctness and accuracy conditional on correct roles.
- Whether the auxiliary decoder recovers both factual values from the read
  vectors, plus final errors despite both decoded values being correct.
- Zeroing memory reads while retaining the rest of the trained model.
- Cyclically shifting ring-routing representatives relative to their stored
  keys/values, then restoring the original weights.

Conditional scores do not replace the overall accuracy. Auxiliary fact decoding
is a diagnostic of the learned representation, not ground-truth recall of a
particular physical memory slot. The shifted-routing and zero-read interventions
are applied to already trained models; they are not independently trained
competitors.

## Run and Resources

With an existing C ABI build and Python environment containing PyTorch and NumPy:

```sh
bash examples/ring_memory_quality_bench.sh
```

The wrapper reuses the existing RAG virtual environment when present.
`KOUTEN_BENCH_PYTHON` selects another interpreter. The run uses two CPU threads,
downloads no model or dataset, and requests no privileged counters.

Data stays in `.tmp/ring-memory-quality` under the checkout. Argument limits and
a 128 MiB file-budget guard keep this accuracy experiment small. Temporary DB
snapshots are removed immediately after evaluation. After results are collected,
checkpoints for the second and third seeds are removed. The first seed's trained
models remain available for inspection and re-evaluation, alongside small JSON
reports and the fixed plan.

The command retrains the fixed protocol; it does not reuse existing checkpoints
automatically. Results are written to `.tmp/ring-memory-quality/results.json`,
with per-world reports under `seed-<seed>/results.json`. Defaults test 2,688 held-out
questions per model across the three worlds.

Implementation contracts can be checked with the same Python environment:

```sh
python3 tests/test_ring_memory_quality.py
python3 tests/test_ring_memory_model.py
```

## Scope

This is a synthetic recall and two-fact comparison task with explicit role
supervision for the common parser, fixed answer classes and a task-specific
classifier. It is not unrestricted natural-language generation or multi-hop graph
reasoning. The factual entities and facts themselves are known from training.

The trained knowledge layers are about 0.65 MiB. Accuracy here cannot be combined
with the separate random-kernel 10/40 MiB speed measurements to claim simultaneous
equal-quality speed or energy gains. Such a claim needs a larger trained-model
comparison. Dense hyperparameters and classifier architecture are fixed to the
same budget; this is not a comparison against every optimized dense architecture.

## Observed Three-World Results

The fixed protocol above completed with 2,688 held-out questions per model:
1,152 single-fact questions and 1,536 comparisons across three worlds.
Memory results below use the actual database path.

| Model | Single-fact answers | Comparison answers |
| --- | ---: | ---: |
| Dense | 1,152/1,152 (100%) | 1,433/1,536 (93.29%) |
| 16 rings of 128 entries | 1,152/1,152 (100%) | 1,525/1,536 (99.28%) |
| 64 rings of 32 entries | 1,152/1,152 (100%) | 1,525/1,536 (99.28%) |

| World seed | Dense comparison | Coarse-ring comparison | Fine-ring comparison |
| --- | ---: | ---: | ---: |
| 731 | 492/512 | 510/512 | 511/512 |
| 732 | 474/512 | 512/512 | 509/512 |
| 733 | 467/512 | 503/512 | 505/512 |

Both layouts passed the predeclared two-point exploratory check for every world
and task. DB and tensor predictions agreed on all 5,376 memory-model questions.
Test strings overlapped neither training stage, and the common parser's discrete
roles were correct on all single-fact questions and 1,527/1,536 comparisons.

The auxiliary fact-decoding results matter for interpreting the accuracy gap:
97 of the dense model's 103 comparison errors occurred even though both fact
values were decoded correctly. Much of this particular gap is therefore in the
trained final comparison readout, rather than a failure to learn the facts.
It does not establish that a tuned dense model cannot achieve comparable accuracy.

Misaligning routing representatives with their rings reduced fine-ring single-
fact accuracy to approximately 15.5%, and comparison accuracy to approximately
51.2%, averaged across the worlds. Zero-read interventions also strongly reduced
accuracy. The trained routing/memory read is necessary for this implementation's
observed answers; labels are not supplied to the DB reader.

Peak recorded file contents were approximately 17.90 MiB. All temporary DB
snapshots and the two additional seed checkpoints were removed. The first seed's
checkpoint is retained for inspection and for the larger-layer follow-up.

## Trained 10 MiB Follow-up

A separate, fixed seed-731 follow-up increased the knowledge layer to 1,024 rings
of 32 entries, approximately 10.08 MiB. It reused only the frozen language parser
and generated task from the first experiment. Knowledge weights, the final answer
classifier and the auxiliary fact decoder started fresh in both variants.
The same 384 facts and 896 held-out questions were retained; this tests a larger
allocated memory, not a larger collection of learned facts.

Before viewing these test results, the follow-up fixed 1,500 training steps,
batch size 32, 250 soft warmup steps and validation every 150 steps. Checkpoints
were selected using validation only. This differs from the three-world training
budget; compare the variants within this follow-up, not their convergence rate
against the smaller experiment.

| Trained variant | Fact accuracy | Comparison accuracy | Whole-model CPU ms/question | Knowledge-layer CPU ms/question |
| --- | ---: | ---: | ---: | ---: |
| Dense, 2,643,016 knowledge parameters | 374/384 (97.40%) | 408/512 (79.69%) | 3.940 | 1.772 |
| DB ring, 2,643,008 knowledge parameters | 384/384 (100%) | 510/512 (99.61%) | 3.426 | 1.439 |

The DB-backed ring model used approximately 13.0% less whole-model CPU time
and 18.8% less knowledge-layer CPU time in this run. Whole-model wall times
were 1.971 and 1.715 ms per question, respectively. Timing used five rounds,
blocks of at least 0.25 seconds, batch size one and two threads. The 32 timed
questions were evenly split between the two task categories and identical
for every backend. Loading, training, export and tokenization were excluded.

DB and reference tensor predictions agreed on all 896 questions. Maximum
logit difference was approximately 0.0000111. Zeroing the memory read reduced
accuracy to 47/384 fact answers and 256/512 comparisons.

This is a joint accuracy/CPU-cost example using trained weights. Its dense
baseline had substantially lower accuracy under this fixed training budget,
including lower fact accuracy, so it does not establish an advantage against a
fully converged or otherwise tuned dense model. Nor does allocating 10 MiB for
384 facts establish useful-knowledge scaling to billions of parameters.
No energy saving was measured. Temporary DB data stayed under the configured
128 MiB file budget and was removed; the trained checkpoint is retained for
re-evaluation.

Reproduce from the first experiment's retained checkpoint:

```sh
python3 examples/ring_memory_experiment.py \
  --work=.tmp/ring-memory-quality-large \
  --parser-checkpoint=.tmp/ring-memory-quality/seed-731/checkpoint.pt \
  --entities=128 --training-pairs=4096 --rings=1024 --slots=32 \
  --steps=1500 --batch-size=32 --validate-every=150 \
  --disk-budget-mib=128 --rounds=5 --min-block-seconds=.25
```

Use the same Python environment as the quality wrapper. An existing checkpoint
is reused; add `--train` to retrain. The plan and results are under
`.tmp/ring-memory-quality-large`.
