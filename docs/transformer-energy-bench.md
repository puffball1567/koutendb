# Small Transformer Compute and Energy Experiment

This optional benchmark feeds **actual KoutenDB retrieval results** into a
small, locally initialized causal Transformer. It tests whether smaller context
reduces downstream inference work. No model download, training, or external
LLM API is involved.

The model has token and position embeddings, causal multi-head attention,
residual connections, layer normalization, GELU feed-forward layers, and an
output projection. Autoregressive decoding uses a per-layer KV cache and a fixed
output length. It runs on CPU in float32, with batch size one and one thread by
default. It uses PyTorch's
[scaled dot-product attention](https://docs.pytorch.org/docs/main/generated/torch.nn.functional.scaled_dot_product_attention.html).

## Reproduce

Requires the normal Nim build dependencies, Python 3, and PyTorch (tested with
PyTorch `2.12.1+cpu`). PyTorch is an optional benchmark dependency, not a
KoutenDB runtime dependency.

```sh
OUTPUT=/tmp/koutendb-transformer-results.json \
  bash examples/transformer_energy_bench.sh
```

The wrapper generates the existing 400-document AI/RAG corpus, imports it into
a fresh temporary KoutenDB data directory, exports the retrieved prompts, and
runs the Transformer. Temporary data is removed on exit; the JSON report is
retained. Without `OUTPUT`, the report is `transformer-energy-results.json` in
the repository directory.

Adjust model size, generated tokens, or measurement duration explicitly:

```sh
OUTPUT=/tmp/koutendb-transformer-larger.json \
  bash examples/transformer_energy_bench.sh \
  --width=256 --heads=4 --layers=4 --new-tokens=16 \
  --rounds=12 --min-block-seconds=0.5
```

`GLOBAL_BUDGET`, `ROUTED_BUDGET`, `DOCS_PER_RING`, and `NOISE_DOCS` configure
the existing corpus/retrieval helper. Prompts exceeding 4096 tokens including
the output budget are rejected rather than truncated.

To keep prompts for inspection or rerun inference without rebuilding the DB:

```sh
PROMPTS_OUT=/tmp/koutendb-prompts.jsonl bash examples/ai_rag_case_study.sh
python3 examples/transformer_energy_bench.py \
  --prompts=/tmp/koutendb-prompts.jsonl \
  --output=/tmp/koutendb-transformer-results.json
```

## Run With Protected Energy Counters

From a local interactive terminal, run:

```sh
bash examples/transformer_energy_bench_sudo.sh
```

This prepares the same retrieval prompts, then requests the password directly
in that terminal. Only `rapl_energy_reader.py`, a standard-library-only reader,
runs with administrator privileges; the database, PyTorch, and model stay under
the current user. The reader opens CPU package energy counters and accepts only
a `read` request. It does not change permissions, power limits, or system
settings, and exits when the measurement process closes its input.

The default run uses 12 rounds and blocks of at least 0.5 seconds. It requires
energy access and stops on a measurement failure. The report is saved to
`.tmp/transformer-energy/results.json`, and stdout is retained in
`.tmp/transformer-energy/output.log`. Set `OUTPUT` to change the report path.
Additional model/measurement options are forwarded to the Python benchmark.
The sudo helper requires Linux with `sudo` and `/usr/bin/python3`.

## Comparison Conditions

| Condition | Retrieval scope | Default returned document budget |
|---|---|---:|
| `global` | Entire corpus | 8 |
| `routed` | Correct ring supplied by the fixture | 3 |
| `global_same_budget` | Entire corpus | 3 |
| `wrong_ring` | Incorrect ring supplied by the fixture | 3 |

The first three conditions run inference with identical weights and generation
settings. The incorrect-ring condition is exported as a retrieval-quality
guardrail; inference on it is omitted. Target recall means presence of one
designated reference document, **not answer quality or general Recall@k**.

The tokenizer splits words and punctuation into a shared, deterministic
corpus-local vocabulary. Reported input token counts are exact for this toy
tokenizer; they are neither the existing `estimatedTokens` statistic nor token
counts for a production model.

Each condition is warmed up. Repeated blocks cycle through the same five
queries until the minimum duration is reached. Condition order is randomized
with a fixed seed in each round to reduce order bias. The report retains every
block and reports medians of block means per request; these are not individual
request latency percentiles.

## Energy Versus Power

When readable, Linux RAPL `energy_uj` counters measure CPU package energy. The
benchmark calculates:

- **joules/request** from counter differences divided by completed requests;
- **average watts** from the same energy divided by elapsed block time;
- wall time and process CPU time per request independently of energy access.

Only package domains are summed, without adding overlapping core subdomains.
Aliases are deduplicated. If a discovered package cannot be read, energy is
reported as unavailable, not as zero or a time-derived estimate. Counter wrap
is handled assuming fewer than one full counter range per block. Keep blocks
short relative to that range. RAPL counters and domains are described in the
[Linux powercap documentation](https://docs.kernel.org/power/powercap/powercap.html).

These readings include other activity on the CPU packages. They do not measure
the whole machine, GPU, or an individual process, and no idle-baseline
subtraction is applied. Use a quiet host and repeated independent runs. An
external power meter is needed to establish whole-system energy savings.
Shorter runtime can lower joules/request even when active watts stay the same
or rise; shorter runtime alone does not establish either result.

## Initial Local Compute Result

A local run on 2026-11-06 used PyTorch `2.12.1+cpu`, two layers, width 128,
four heads, 469,632 random parameters, eight output tokens, one CPU thread,
eight rounds, and blocks of at least 0.3 seconds:

| Condition | Mean toy input tokens | Target recall | Mean scanned records | Median wall ms/request | Median CPU ms/request |
|---|---:|---:|---:|---:|---:|
| `global` | 346 | 1.000 | 400 | 11.138 | 11.137 |
| `routed` | 139 | 1.000 | 40 | 5.665 | 5.664 |
| `global_same_budget` | 139 | 1.000 | 400 | 5.714 | 5.714 |

The routed input was 59.8% shorter and took about 49.1% less inference wall
time. Incorrect-ring target recall was zero. CPU package energy counters were
not readable, so **joules/request and watts were not measured**. These timing
results support a compute-reduction hypothesis, not a measured energy claim.

The same-budget control is important: this generated corpus also preserves
target recall when global retrieval returns only three documents. Its downstream
inference time is approximately the same as the routed case. This experiment
does not establish a unique ring-based token advantage. The difference in
records scanned remains a DB-side observation; DB work is outside the inference
measurement window.

## Interpretation and Next Validation

The [trained-model RAG experiment](real-rag-energy-bench.md) implements the next
step with real questions, trained models, answer scoring, automatic-routing and
same-budget controls, and a warm request measurement window.

The random model performs real Transformer operations but cannot provide a
meaningful answer. The measured window includes prefill and fixed-length cached
generation. It excludes retrieval, ring selection, tokenization, model setup,
import, and training. No external Vector DB is compared here.

To establish application-level savings, use a trained model with its real
tokenizer, real questions and relevance labels, fixed answer-quality criteria,
and measure routing plus retrieval plus inference together. Include ambiguous
and cross-ring questions, routing failures, fallback work, and the same-budget
global control. Larger or GPU-backed models require their own measurements;
do not extrapolate these small CPU timing ratios to them.

Correctness checks for cached decoding, causal masking, fixed output length,
paired query sets, and energy accounting are available with:

```sh
python3 tests/test_transformer_energy_bench.py
```
