# Exact Vector Retrieval

KoutenDB uses one dependency-free exact vector path. Ring routing is the
primary optimization: the database identifies the relevant coordinate first,
then ranks only vectors in the selected ring set.

The execution model is:

```text
ring / retrieval plan
  -> bounded candidate set
  -> exact cosine ranking
  -> top-k payloads
```

KoutenDB does not maintain a second global vector index. This avoids duplicate
vector memory, native vector-engine dependencies, index build time, and a
separate recovery lifecycle.

## Ring-Scoped And Broad Reads

A ring-scoped read walks only the selected ring's vector entries. A broad read
without a ring walks every vector and should be treated as an explicit fallback,
not the normal retrieval path.

Use Atlas, ring descriptions, retrieval profiles, or an application/import rule
to select the smallest valid scope before ranking. Retrieval statistics expose
`totalVectors`, `scanned`, `skippedVectors`, and `candidateReduction` so broad
queries remain visible.

## Local Benchmark

Run the deterministic comparison between broad and ring-scoped exact retrieval:

```sh
examples/vector_backend_bench.sh
```

Optional parameters:

```sh
DOCS=100000 RINGS=100 DIM=128 QUERIES=500 BUDGET=8 \
  examples/vector_backend_bench.sh
```

The benchmark is a local engineering measurement, not a universal performance
claim. Record the CPU, compiler, dimensions, ring sizes, query count, and build
flags when publishing results.

## Operational Rule

If one ring leaves an excessive vector candidate set, first refine placement or
retrieval scope. KoutenDB's design goal is to avoid broad vector work rather
than compensate for it with a duplicate global index.
