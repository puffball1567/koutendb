# Product Ring Routing Evidence

`initial-results.json` records the first matched flat/product training and CPU
inference comparison. See [protocol, scope and results](../../product-ring-routing.md).
It includes the fixed training plan, validation history, test answer accuracy,
DB/tensor parity, access counts, randomized timing samples and source hashes.

The product router improves large untrained router-only keyspaces but is slower
end to end at the trained 1,024-ring configuration. There is a small observed
answer-accuracy difference. Energy was unavailable; no joule reduction is claimed.
