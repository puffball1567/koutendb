# Product Ring Routing Evidence

`initial-results.json` records the first matched flat/product training and CPU
inference comparison. `optimized-results.json` reuses the same checkpoint and
compares original per-ring and batched aggregation within one randomized run.
See [protocol, scope and results](../../product-ring-routing.md).
It includes the fixed training plan, validation history, test answer accuracy,
DB/tensor parity, access counts, randomized timing samples and source hashes.

The product router improves large untrained router-only keyspaces but is slower
end to end at the trained 1,024-ring configuration. There is a small observed
answer-accuracy difference. Energy was unavailable; no joule reduction is claimed.

The batched reader reduces whole-model CPU time by 16.4% for the flat router and
13.6% for the product router, preserving each model's measured accuracy. These
are aggregation gains; they must not be attributed to product routing.

The initial implementation is preserved in commit `0962e3c`; the recheck's
source hashes identify the optimized reader and benchmark. Both reports retain
their checkpoint, parser-source and C ABI library SHA-256 values. Verify the
report files from this directory with `sha256sum -c SHA256SUMS`.
