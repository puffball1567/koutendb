# Bounded Ring Memory Capacity Probe

This probe measures how inference cost changes as the knowledge layer grows.
It uses generated float32 kernels and actual KoutenDB latent-vector reads.
There are no model or dataset downloads. It complements the
[trained internal-memory experiment](ring-memory-experiment.md), which measures
answer accuracy on a small synthetic task.

The generated kernels do not establish that a ring memory has the same answer
quality as a dense layer with an equal parameter count. This experiment can
identify a computational crossover worth investigating with trained models;
it cannot establish the performance of a 12B or 300B language model.

## Bounded Resources and Cleanup

All generated snapshots stay under this project's `.tmp` directory, on the same
drive as the checkout. The default work directory is `.tmp/ring-memory-capacity`.
Each capacity is prepared, measured and deleted before the next capacity starts.
Successful runs retain small JSON results files; temporary snapshots are
also removed when a worker fails.

The default temporary-data budget is 256 MiB, with a 32 MiB stopping margin.
The exporter checks its files every 1,024 records. The driver limits logical
float32 memory parameters to 64 MiB per case and refuses to put work outside the
project `.tmp`. The default largest case is about 40.3 MiB of parameters.
The disk budget includes the generated DB and routing/parity data; filesystem
metadata and existing project files are not counted. This avoids deliberately
filling RAM or disk to simulate an oversized language model.

## Run

```sh
bash examples/ring_memory_capacity_bench.sh --include-wide-ring
```

The wrapper reuses `lib/libkoutendb.so` if present. Build it explicitly with
`bash scripts/build_capi.sh` when testing a changed core. If the library is absent,
the wrapper builds it using a temporary compiler cache under the checkout and
removes that cache. `KOUTEN_BENCH_PYTHON` selects an interpreter with PyTorch and
NumPy; the existing RAG virtual environment is reused when available.

To measure package energy using the existing read-only RAPL helper:

```sh
bash examples/ring_memory_capacity_bench.sh --include-wide-ring --sudo-energy --require-energy
```

Only the energy reader uses sudo. Enter a password in the terminal prompt.
An ordinary run reports `package_j: null` if counters cannot be read; it does not
estimate electricity from CPU time.

Results are saved in `.tmp/ring-memory-capacity/results.json`. Backend measurements
run in separate processes so a resident tensor copy does not remain alongside
the DB memory under test. Startup, allocation, export, file synchronization,
opening the database and parity checks are outside the timed forward calls.

To compare a single cold-file forward pass for dense weights and DB memory,
and repeat the warm controls after host contention has settled:

```sh
bash examples/ring_memory_capacity_bench.sh --work=.tmp/ring-memory-capacity-cold \
  --ring-counts 16 1024 4096 \
  --backends dense koutendb_memory dense_disk_single_advised koutendb_disk_single_advised
```

This mode also saves a temporary dense checkpoint within the same disk budget.
Before each dense cold forward, the old mapping is released, eviction is advised,
and weights are mapped again. Opening the mapping is outside the timer; tensor
page faults, storage reads and matrix computations are inside. Both single-cold
backends use the same one hidden input per round, changing that input each round.
The measured storage-read counter, rather than the advice request alone, indicates
whether the timed call actually needed storage I/O.

## Workload and Comparisons

The layer has width 64, 16-dimensional keys and two latent input vectors per
question, matching the small trained model's interface. The workload contains
64 distinct, reproducible random hidden inputs. Every backend receives the same
inputs. The benchmark runs five rounds with two PyTorch threads. Warm blocks
repeat the workload for at least 0.2 seconds; reported values are per-question
medians across rounds. Whole-model language parsing and classification are
outside these measurements.

The main sweep keeps 32 entries per ring and grows the number of rings:
16, 64, 256, 1,024 and 4,096. This yields approximately 0.18, 0.65, 2.54,
10.08 and 40.27 MiB of memory parameters. A learned-style routing projection
scores ring representatives from the hidden input and selects two rings, then
four latent values per ring. No oracle ring labels are provided.

| Backend | Work performed |
| --- | --- |
| `dense` | Parameter-matched two-layer FFN, GELU, width 64 input and output |
| `tensor_full` | Score all keys, then keep the rings selected by the router |
| `tensor_sparse` | Score local keys only in selected rings |
| `koutendb_memory` | Actual C ABI reads with the ordinary in-memory vector backend |
| `koutendb_disk_warm` | Disk-backed store, OS cache warm from preceding reads |
| `koutendb_disk_advised` | Disk-backed store, one pass following file-specific cache eviction advice |
| `dense_disk_single_advised` | One forward on file-mapped dense weights after eviction advice |
| `koutendb_disk_single_advised` | One DB memory forward after eviction advice |

Dense and memory parameter counts match within 65 parameters. Both use float32.
Their functions differ; parameter matching alone is not a quality match.
All memory backends must numerically match the sparse tensor reference on the
64 inputs before timing. DB workers load only routing/projection weights into
PyTorch; the full key/value tensor tables are absent.

The optional `--include-wide-ring` case holds 16 rings and grows each to 8,192
entries, giving nearly the same total key/value capacity as 4,096 rings of 32
entries. This isolates the cost of enlarging rings rather than adding rings.
KoutenDB's exact scoped backend scans the selected rings. Therefore small output
top-k does not imply a small scan when the rings themselves become large.

## Reading the Results

`cpu_ms` measures CPU time consumed by the worker, summed across its threads.
`wall_ms` includes scheduling and I/O waits. Other host activity can affect both
timing and power; these exploratory measurements do not establish a precise
hardware-independent crossover. Backend process order is shuffled per capacity,
while capacities increase sequentially.

`storage_read_bytes_per_question` comes from the worker's Linux `/proc/self/io`
counter, which records storage reads rather than bytes served from the page cache.
The advised run requests eviction only for the experiment's own files, before
each round and outside the timer. It does not drop system-wide caches. This
advice is not guaranteed eviction, so the actual read counter must be checked.
Each advised round uses a single pass to avoid masking an initial storage read
with many repeated warm passes. It has a different sample count from warm blocks.

The data fits in the host's RAM. A file-cache-advised disk run is not the same
as executing under real RAM exhaustion, swapping or CPU-to-GPU offload pressure.
It offers a bounded view of selective disk access, not a 300B deployment result.

Algorithmic access counts report two hidden queries per question. In the main
sweep, local key scoring remains at 128 keys and the returned value count stays
at 16. Router scoring still grows with the number of rings, from 32 to 8,192 keys.
The current flat router does not have constant cost as total capacity increases.
These counts are not measured DRAM traffic. Process peak RSS includes Python,
PyTorch, database metadata and initialization; it is not just model storage.

Any observed speed benefit must ultimately be paired with answer quality on a
trained model of comparable capability. The probe's random tables cannot establish
knowledge capacity, long-context behavior, training cost or data-center savings.

## Observed Capacity Sweep

A seed-731 CPU run used PyTorch 2.12.1+cpu and an AMD Ryzen 5 5600H, two threads,
five rounds and the default 64 inputs. Values below are CPU milliseconds per
question for the knowledge layer only.

| Logical memory parameters | Dense | DB, memory | DB, disk warm | DB, advised one pass |
| --- | ---: | ---: | ---: | ---: |
| 0.177 MiB | 0.662 | 5.835 | 5.639 | 6.439 |
| 0.649 MiB | 0.346 | 2.197 | 4.545 | 5.744 |
| 2.535 MiB | 0.794 | 1.873 | 4.470 | 6.442 |
| 10.082 MiB | 2.381 | 2.037 | 4.291 | 6.170 |
| 40.270 MiB | 9.865 | 2.364 | 4.416 | 7.017 |

The host had substantial CPU contention during the earliest case, so the
smallest-capacity row should not be used to infer monotonic scaling. The later
cases suggest a warm CPU-cost crossover somewhere between a few MiB and about
10 MiB in this implementation. At 40.270 MiB, memory-backed DB CPU time was
approximately 24% of the dense control. These are exploratory costs for different
random functions, not an equal-answer-quality comparison or a universal threshold.

The layout matters: with 16 rings of 8,192 entries, nearly the same 40 MiB capacity
used 19.436 ms of memory-backed DB CPU time, versus 10.060 ms for dense. Disk-backed
warm reads used 179.915 ms. The bounded read budget returned 16 vectors but still
scored 32,768 keys. Small ring populations are essential to the observed advantage.

The 4,096-ring case scored 128 local keys and 8,192 router keys per question and
returned 4,096 latent bytes. Its advised one-pass worker actually read a median
62,208 storage bytes per question. Warm workers reported zero storage-read bytes.

Memory use did not show an advantage for this prototype. At 40.270 MiB, peak
process RSS was approximately 276.6 MiB for dense, 459.7 MiB for memory-backed DB
and 335.4 MiB for disk-backed warm DB. These peaks include initialization and
runtime overhead, and OS page-cache memory is additional. The current many-small-
record layout carries significant database metadata overhead.

The sweep's peak temporary file contents totaled 137.54 MiB, excluding filesystem
allocation overhead. Every generated snapshot was removed after measurement.
Package energy counters were unavailable, so this run establishes no energy saving.

## Warm Repeat and Single Cold-File Forwards

A second run repeated warm controls after the initial host contention and added
five single-question cold-file forwards per backend. The layer shapes, seed,
precision, input workload and thread count were unchanged.

| Capacity | Warm dense CPU ms | Warm DB-memory CPU ms | Cold dense wall ms | Cold DB-disk wall ms |
| --- | ---: | ---: | ---: | ---: |
| 0.177 MiB | 0.190 | 1.820 | 0.719 | 3.830 |
| 10.082 MiB | 2.141 | 1.782 | 34.855 | 3.548 |
| 40.270 MiB | 8.425 | 1.601 | 139.293 | 3.699 |

At 40.270 MiB, the dense cold forward actually read a median 42,156,032 bytes
from storage, versus 65,536 bytes for the DB cold forward. CPU time was
55.005 ms versus 5.808 ms. Timing includes CPU page-fault handling and database
record parsing as well as computation and I/O waits. File mapping and checkpoint
metadata reads are outside the timer, so some checkpoint pages can already be
cached; the read counter reports the transfer actually observed inside it.

This supports the narrower hypothesis that selective reads can keep inference
kernel costs low as table capacity grows, including when storage reads occur.
It does not show that a 300B memory can provide 300B dense-model answer quality
at these latencies. The flat router and database metadata still grow with capacity,
and neither true RAM exhaustion nor GPU offload was exercised.

The second run's peak temporary file contents totaled 177.07 MiB, excluding
filesystem allocation overhead, within the 256 MiB configured budget. All
snapshots, including dense checkpoints, were removed. Only small result JSONs
and logs remain. No energy saving was measured in this run.
