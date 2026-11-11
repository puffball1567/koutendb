# Internal Learned Ring Memory Experiment

This prototype tests whether a learned ring memory can replace one dense
knowledge layer inside a small neural model. A Transformer processes the question,
and its continuous hidden representation selects memory rings and mixes latent
vectors before a learned classifier produces the answer. The database stores
trained float vectors, rather than documents or answer strings.

The experiment demonstrates a working internal-memory architecture on a synthetic
task. It does not establish a speed or energy advantage over dense weights.
Read `results.json` for the quality, latency, CPU time and available energy
measurements from a particular run.

The separate [bounded capacity probe](ring-memory-capacity-bench.md) increases
generated memory tables to about 40 MiB to measure cost scaling, including actual
disk-backed reads. Its random kernels are not a test of equal answer quality.

The [answer-quality comparison](ring-memory-quality-bench.md) trains dense and
two ring layouts on 384 facts per world across three independent worlds, then
evaluates held-out questions through the actual database.

The optional [product-key router](product-ring-routing.md) avoids comparing a
hidden query with every ring representative. It includes matched training of
flat and structured routers, actual DB answer checks and separate cost scaling.

## Architecture and Controls

The common language parser has two Transformer encoder layers, width 64 and four
attention heads. It learns entity roles, attribute roles and whether a question
asks for a value or a comparison. Parser training never supervises fact values.
The parser is then frozen and copied identically into both model variants.
Continuous entity/attribute probabilities mix fixed random semantic codes into
two read vectors; inference receives no oracle role IDs, fact values or ring IDs.
This explicit semantic bottleneck is a substantial task-specific inductive bias.

The interchangeable knowledge layers are:

| Variant | Computation |
| --- | --- |
| `dense` | Two learned linear maps with GELU, matched to the ring layer's parameter count |
| `tensor_full` | Learned ring routing, score every memory key, then retain the selected rings |
| `tensor_sparse` | Identical routing and outputs, score keys only in the selected rings |
| `koutendb` | Identical routing, retrieve learned keys and raw latent values from actual KoutenDB rings |
| `ablated` | Replace the memory read with zero to test whether answers depend on it |

The ring layer has 16 rings with 32 slots each, 16-dimensional keys and
64-dimensional values. Each of two read vectors selects two rings and four
slots per ring. The learned value mixtures pass through an output projection,
then a common classifier combines both reads and predicts one of eight values
or the answers `same` / `different`.

There are 46,375 dense knowledge-layer parameters and 46,400 ring-layer
parameters with the default configuration. Other weights remain in both models.
The classifier and an auxiliary fact decoder are trained in both variants;
ablation measures dependence on the ring read, rather than proving that every
fact is stored exclusively in one parameter tensor.

The actual database path exports a frozen snapshot of trained keys and values
to the embedded C ABI in buffer mode. Each value is an uncompressed float32
latent vector. The ring names encode learned slot placement, not entities or
attributes. KoutenDB's scoped vector retrieval implements the memory read.
The exported snapshot is not trained or updated online inside the DB.

## Task and Training

All data is generated locally. This experiment downloads no model or dataset.
It requires an existing PyTorch and NumPy installation, plus the project's normal
C ABI build dependencies.

The default random world has 32 named entities, three attributes and eight possible
values: 96 independently assigned facts. The questions request an attribute value
or ask whether two attribute values agree. The latter requires combining two
learned facts, rather than returning a stored question's answer.

- Knowledge training uses 288 single-fact questions and 1,024 balanced comparisons.
- Validation uses 96 single-fact questions and 128 balanced comparisons.
- Test uses 96 single-fact questions and 128 balanced comparisons.
- Comparison pairs are disjoint across splits, including reversed pairs.
- Every test fact appears in knowledge training; this tests recall and composition
  of learned facts, not inference of new facts.
- Test questions' exact strings are absent from both training stages. The parser
  learns the full grammar using additional alias entities without their fact
  values. Consequently this does not test understanding previously unseen grammar
  or unrestricted natural language.
- Vocabulary construction includes all spellings, without revealing fact values.

The shared parser trains for 1,000 steps. Each knowledge variant then receives
1,500 steps with identical batches, AdamW settings and answer/fact supervision.
Ring training uses 250 soft-routing warmup steps, followed by a straight-through
top-k surrogate. This training computes dense memory scores: no sparse training
cost or training energy saving is claimed. Checkpoints are selected using
validation accuracy after warmup; test accuracy is evaluated afterward.
The checkpoint also contains the generated task for reproducibility. Fact labels
and the generated world are not arguments to the inference model or DB reader.

## Run

From the project root, measure CPU package energy:

```sh
bash examples/ring_memory_experiment.sh
```

The script builds the C ABI and reuses a compatible trained checkpoint. It trains
both models if none exists. Only the read-only RAPL helper requests `sudo` in the
terminal; model training, inference and DB operations run as the ordinary user.
An unavailable energy counter stops this command rather than presenting an
estimate as a measurement. Enter a password only in the terminal's sudo prompt.

To run without privileged energy counters:

```sh
bash examples/ring_memory_experiment.sh --no-energy
```

To retrain explicitly or use a separate reproducible run:

```sh
bash examples/ring_memory_experiment.sh --no-energy --train
KOUTEN_RING_WORK=.tmp/ring-memory-seed732 bash examples/ring_memory_experiment.sh --no-energy --seed=732
```

`KOUTEN_BENCH_PYTHON` selects the interpreter. By default the wrapper reuses the
existing RAG benchmark virtual environment when present, otherwise `python3`.
It does not install dependencies. `--help` lists model and measurement controls.
With an existing checkpoint, its saved model configuration and task take
precedence over training options; use a new work directory or `--train` to change
them. Current checkpoint schema is 4.

Outputs default to `.tmp/ring-memory-model/checkpoint.pt`, `results.json` and
`output.log`. Results include validation history, parameter counts, test quality,
DB/reference parity, raw timing rounds, code/checkpoint/library hashes and runtime
settings. A DB/reference prediction disagreement fails the run.

## Interpreting Measurements

All backends receive the same pre-tokenized workload. Default timing uses
16 single-fact questions and 16 comparisons, batch size one, two PyTorch threads
and five rounds. Backend and scope order are shuffled each round. Blocks run for
at least 0.5 seconds. Reported timing and energy are medians of per-round values
per question. `cpu_ms` sums process CPU time across threads; `wall_ms` measures
elapsed time. Whole-model and isolated knowledge-layer forward passes are timed
separately. The latter receives precomputed parser outputs.

For one question, the full tensor control scores 1,024 local keys, while sparse
tensor and KoutenDB score 128. Each additionally scores 32 ring-routing keys.
All three read 16 latent value vectors; the DB returns 4,096 payload bytes through
four C ABI retrieval calls. These are algorithmic operation/access counts, not
hardware cache misses, DRAM bytes or isolated weight-access times. With larger
inference batches, `access_counts` covers the recorded `access_count_batch_size`.

Sparse scoring can do less arithmetic while taking longer overall. This small
memory can fit in CPU cache, and dense matrix kernels are efficient. Routing,
gathering, C ABI calls, allocations and tensor reconstruction add overhead. Use
the dense control to assess substitution of weights, and full versus sparse
tensor controls to isolate the effect of scoring fewer keys. Comparing only full
and sparse memory does not establish an advantage over an ordinary neural layer.

Initialization, training, checkpoint loading, DB export and tokenization are
outside inference timing. Reference tensors remain resident for backend parity;
this implementation does not demonstrate deployment RAM savings. CPU package
RAPL includes other activity in the package and excludes parts of whole-machine
power use. It does not directly measure data-center electricity or cooling.
Single-seed synthetic accuracy and short CPU timings cannot establish general
LLM quality, accelerator throughput or data-center energy savings.

## Related Research

Learned key/value memory within neural inference is an established research
direction. Relevant examples are [Large Memory Layers with Product Keys](https://arxiv.org/abs/1907.05242),
[Memory Layers at Scale](https://arxiv.org/abs/2412.09764) and
[Memorizing Transformers](https://arxiv.org/abs/2203.08913).
This small ring-routed prototype is not a reproduction of those papers, and
their results do not establish a KoutenDB-specific advantage.

The separate [RAG experiment](real-rag-energy-bench.md) measures retrieved text
passed to pretrained models. Its results answer a different question and should
not be presented as evidence that ring memory replaces neural weights.

## Observed CPU Pilot

A local seed-731 run used the default trained architecture on an AMD Ryzen 5
5600H, PyTorch 2.12.1+cpu, two threads and batch size one. Timing used three
rounds with blocks of at least 0.25 seconds, shorter than the default run.
The test contains 96 value questions and 128 comparison questions.

| Backend | Value accuracy | Comparison accuracy | Model ms/question | Knowledge layer ms/question |
| --- | ---: | ---: | ---: | ---: |
| Dense | 96/96 | 111/128 | 1.236 | 0.099 |
| Full tensor memory | 96/96 | 121/128 | 1.569 | 0.373 |
| Sparse tensor memory | 96/96 | 121/128 | 1.400 | 0.342 |
| Actual KoutenDB | 96/96 | 121/128 | 2.030 | 0.857 |
| Ablated memory | 6/96 | 64/128 | — | — |

DB and sparse-tensor predictions agreed on all 224 questions; the maximum logit
difference was approximately 0.0000107. The trained checkpoint SHA-256 was
`a46348818081266cd0141a0c1d2d2ebee633f70fae4d1a36f524750348b4da97`.

This run supports functional substitution on this limited task and dependence on
the learned memory read. It demonstrates neither a latency advantage over dense
weights nor an energy saving: the dense model was faster, and package energy was
unavailable without privileged counter access. The accuracy difference is from
one synthetic seed and is not evidence of general model-quality superiority.

## Implementation Checks

With the same Python environment used by the experiment:

```sh
bash scripts/build_capi.sh
python3 tests/test_ring_memory_model.py
```

The tests check learned gradients, full/sparse equivalence, memory ablation,
actual C ABI tensor reads, parameter matching, parser freezing and split leakage.
The actual DB test is skipped if the shared library has not been built.
