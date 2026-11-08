# Product-Key Ring Routing

The optional learned-memory prototype can now select rings without comparing a
hidden query with every ring representative. This targets inference work inside
the model: rings hold learned latent vectors used in place of one knowledge
layer. It extends [internal ring memory](ring-memory-experiment.md), rather than
adding document retrieval before an unchanged language model.

This is an experimental PyTorch integration. It does not modify an existing
large language model automatically. Lower routing cost is a step toward lower
inference energy; CPU time and measured joules remain separate outcomes.

## Structured Representatives

An ordinary flat router learns `R` independent keys of dimension `d` and scores
all of them. A product router learns two key tables with `a` and `b` rows, where
`a * b = R`. The virtual representative for ring `i * b + j` is:

```text
key(i,j) = concat(normalize(left[i]), normalize(right[j])) / sqrt(2)
score(q,i,j) = dot(q_left, normalize(left[i])) / sqrt(2)
             + dot(q_right, normalize(right[j])) / sqrt(2)
```

To select `k` rings, score the two factors, keep their best `min(k,a)` and
`min(k,b)` entries, and rank their Cartesian combinations. In exact arithmetic,
the global top `k` is present among these candidates. Inference never constructs
all `R` scores. Equal factor and candidate scores use the lowest ring ID first;
floating-point near ties can differ from a separately expanded matrix multiply.

For 1,024 rings and two selected rings, the balanced shape is 32 by 32: 64
partial-key scores and at most four combinations per read, instead of 1,024
full-key scores. The partial keys each have half the dimensions. Two hidden
reads per question double both counts. Local retrieval still scans two rings
and returns four latent vectors per ring, exactly as before.

The default factor shape uses the closest exact integer divisors. A prime ring
count degenerates to `1 * R` and provides no sublinear routing benefit. Composite
counts with balanced factors are the intended use. Stable factor sorting costs
roughly `O((a+b) log(a+b))`; the implementation does not claim constant routing
time or a fixed latency at arbitrary capacity. Requesting large `k` also grows
the candidate set.

Product representatives are a restricted learned family. An arbitrary trained
flat router cannot be losslessly converted into this structure. Train or fine
tune the product router and check downstream quality. Training currently uses
full ring scores and dense local tables for its differentiable surrogate, so
this feature makes no training-energy saving claim.

The design follows [Large Memory Layers with Product Keys (Lample et al.,
2019)](https://arxiv.org/abs/1907.05242). This implementation covers ring
selection and is not a reproduction of that paper's full model or results.

## Use in a Model

From Python with `examples` on the import path:

```python
from ring_memory_model import RingMemory

memory = RingMemory(width=64, rings=1024, slots=32, router_kind="product")
# Train with continuous hidden representations and the task's loss.
memory.eval()
latent = memory(hidden)  # hidden: [..., 64]; no entity IDs or answer labels
```

The default remains `router_kind="flat"`, preserving existing checkpoints.
`TaskModel` accepts the same option. Both tensor inference backends and the
actual KoutenDB latent-memory reader support product routing. The router also
works with `allocate_tables=False` and an existing disk-backed snapshot; it
still needs its small representative tables and query/output projections.

`last_stats` reports actual algorithmic representative and local-key counts.
These counts are not hardware memory-traffic measurements. Factorization
reduces representative storage; it does not remove local keys or value tables,
nor imply that hundreds of billions of ordinary parameters fit in RAM.

## Matched Quality and Cost Experiment

With an existing local PyTorch/NumPy environment and built C ABI:

```sh
bash scripts/build_capi.sh
bash examples/ring_memory_product_bench.sh --train
```

No model or dataset is downloaded. The default output is
`.tmp/product-ring-memory/`. The runner restricts model dimensions and keeps
temporary data within a 128 MiB budget, with 16 MiB headroom; DB snapshots are
removed after evaluation. Keep the checkpoint and JSON for later measurement,
or remove this experiment directory when they are no longer needed.

To reuse only the language parser from the prior generated quality experiment:

```sh
bash examples/ring_memory_product_bench.sh --train \
  --parser-checkpoint .tmp/ring-memory-quality/seed-731/checkpoint.pt
```

Otherwise the shared parser is trained locally. The runner copies every common
initial tensor between flat and product models, including the local memory,
query/output projections and answer heads. It copies no trained factual values
from the parser source. Both models receive identical minibatches and training
budgets. Validation selects each checkpoint before held-out tests are opened.
The default task has 384 learned facts, 384 held-out single-fact questions and
512 held-out fact comparisons. This is a test of recall/composition on the
generated task, not unrestricted language understanding.

The report separates:

- Separately trained flat/product answer accuracy against held-out labels.
- Agreement between actual DB and tensor predictions on every test question.
- A full-score product reference, as an implementation check on the same model.
- Whole-model and memory-layer CPU/wall time, with real DB reads included.
- Router-only scaling to larger **untrained** virtual keyspaces. These allocate
  representatives only, not full latent tables or additional learned facts.
- CPU package joules when counters are accessible, otherwise `null`.

For terminal-based read-only energy access on supported machines:

```sh
bash examples/ring_memory_product_bench.sh --sudo-energy --require-energy
```

This reuses the saved checkpoint without training again. Only the existing
read-only energy helper requests the terminal password. Warm-cache timing
excludes training, initialization, export and tokenization. Both tensor tables
remain resident for the comparison, so it is not a deployment-RAM measurement.

## Next Evaluation Gates

### Initial CPU Run

The [recorded initial run](validation-evidence/product-ring-routing/initial-results.json)
uses seed 731, 1,024 rings with 32 slots, two CPU threads and five interleaved
timing rounds. Both routers trained for 1,500 steps on identical batches; the
validation-selected checkpoints were steps 1,200 (flat) and 1,050 (product).

| Held-out actual DB result | Flat | Product |
| --- | ---: | ---: |
| Single-fact answers | 384/384 (100%) | 383/384 (99.74%) |
| Fact comparisons | 511/512 (99.80%) | 506/512 (98.83%) |
| Whole-model CPU ms/question | 2.697 | 2.968 |
| Representative scores/question | 2,048 | 128 |

The product model has a small observed accuracy loss and is **10.0% slower**
end to end at this small ring count. Both models have zero DB/tensor prediction
mismatches on all 896 questions. These are one-world results, not a statistical
equivalence claim. Package-energy counters were permission-protected, so joules
were not measured.

The separate router-only comparison uses the same structured key family in
both paths, with expanded matrix multiplication plus `torch.topk` as the dense
control. CPU milliseconds per hidden read:

| Untrained virtual rings | Expanded control | Implicit product |
| ---: | ---: | ---: |
| 1,024 | 0.0218 | 0.1269 |
| 4,096 | 0.0525 | 0.1348 |
| 65,536 | 0.5580 | 0.1823 |
| 262,144 | 3.0065 | 0.2496 |

At 262,144 virtual rings, routing CPU time falls by 91.7% and representative
storage falls from 16 MiB to 32 KiB. This is **routing only**, with no full local
memory tables or trained large-capacity task. It does not demonstrate an
equivalent reduction in complete-model time, electricity or required RAM.
The observed crossover is between 4,096 and 65,536 rings on this CPU; it is not
a portable deployment threshold. Measured temporary files including both DB
snapshots were about 63.2 MiB and were removed after evaluation; the reusable
checkpoint and reports remain.

### Larger Model Integration

Before proposing integration with a large pretrained model, validate the
product router on independent worlds and useful natural-language tasks. Then
measure a model with trained memory layers at matched answer quality, including
CPU/GPU energy and memory-transfer cost. The following work would address the
remaining costs:

- Batch selected-ring reads and latent-vector transfers to reduce per-read
  language/C ABI overhead.
- Bound a device-resident working set and stage selected latent values from
  host memory or disk; measure transfer and cache-miss energy.
- Add a calibrated extra-read/fallback policy when the initial memory budget
  cannot answer reliably; report its accuracy and average/worst-case work.

These are evaluation gates and future work, not capabilities demonstrated by
the current prototype.
