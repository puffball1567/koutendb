# KoutenDB v0.15.1: Measured AI Quality and Lower Inference Cost

KoutenDB v0.15.1 adds reproducible experiments showing how bounded ring reads
can support accurate answers while reducing inference work. It also avoids
unnecessary payload copies during exact top-k retrieval.

## Measured Results

- **12.9% lower CPU package energy per RAG request:** the combined automatic
  routing/context-compaction recipe measured **4.2715 → 3.7213 J/request** on
  100 held-out questions, with token F1 **0.571 → 0.582**. The paired
  question-bootstrap interval for energy reduction was 9.4–16.6%.
- **99.28% held-out comparison accuracy:** trained internal ring memory answered
  **100%** of single-fact questions and **99.28%** of unseen fact combinations
  across three synthetic worlds, versus **100% / 93.29%** for the matched dense
  baseline. Each world contained 384 learned facts; each model faced 2,688
  held-out questions in total. Both fine and coarse ring layouts retained this
  accuracy, and actual DB reads matched tensor predictions on all 5,376 checks.
- **Lower whole-model CPU time in a trained 10 MiB experiment:** the original
  run measured **3.940 → 3.426 ms/question (13.0% lower)**. Rechecking the
  release core measured **6.005 → 5.314 ms/question (11.5% lower)** with unchanged
  ring-model accuracy: **100%** on facts and **99.61%** on held-out comparisons.

These results are promising for reducing work and energy per answer. The RAG
energy improvement includes context compaction; the additional ring-specific
gain over an equally compact global control was not established. CPU package
energy is not whole-system or data-center energy. The internal-memory tests
use synthetic tasks and fixed training budgets, and their electricity use has
not been measured. The larger dense baseline was not tuned to convergence.

The linked evidence records the measured implementation/library hashes and
controls. Historical measurements are identified separately from release-build
compatibility checks; they are not new measurements of a large production LLM.

## Retrieval Fix

Exact retrieval now checks whether a candidate enters the running top-k before
materializing its owned result payload. Embedded and cluster paths preserve
scores, ties, scan counts, and retained-byte accounting. The aggregate wire
response limits introduced in v0.15.0 remain enforced. C ABI version 2 and wire
contracts are unchanged.

## Reproduction and Validation

The new examples include locally generated learned-memory tasks, bounded
capacity probes, a read-only privileged energy reader and an opt-in trained
RAG pipeline. Downloaded models and corpora stay outside Git. CI checks the
experiment contracts with CPU-only PyTorch and actual C ABI reads, alongside
the existing native, security and recovery gates.

See [Recorded Evidence](https://github.com/puffball1567/koutendb/blob/v0.15.1/docs/validation-evidence/v0.15.1-ai/README.md),
[Answer Quality](https://github.com/puffball1567/koutendb/blob/v0.15.1/docs/ring-memory-quality-bench.md), and
[RAG Energy](https://github.com/puffball1567/koutendb/blob/v0.15.1/docs/real-rag-energy-bench.md)
for conditions, controls, raw numerical summaries and commands.
