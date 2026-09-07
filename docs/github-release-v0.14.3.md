# KoutenDB v0.14.3

KoutenDB v0.14.3 fixes read-boundary correctness and C ABI lifecycle issues,
expands the driver-facing API, and adds isolated parallel core testing.

## Correct Reads And Failure Handling

- Filtered cursor pagination no longer skips matching records between pages.
- Time reads evaluate their range before limiting or projecting records.
- Invalid filters and overflowing page calculations return validation errors.
- C ABI buffer functions validate `out_len` before database work, preventing
  rejected calls from silently modifying records or publishing files.
- Shared-library initialization no longer runs twice or leaks its original
  global table allocations.
- Multi-property filters no longer parse the same candidate JSON repeatedly.

## Driver-Facing API

The additive C ABI v2 surface now includes 111 header-verified functions for
prepared selection, ring/stellar/time reads, search profiles and plans,
transaction and lock workflows, maintenance, JSONL import/export,
backup/restore, checkpoints, and operational diagnostics. Existing ABI v2
signatures remain compatible; individual language bindings can adopt the
additional functions independently.

See the [C ABI reference](c-abi.md).

## Verification And Parallel Testing

- Exact-ID cursor matrices across updates, deletes, packing, compaction, and
  reopening in both persistent storage modes.
- Time-range matrices with different limits and projections.
- Rejected-operation tests verify unchanged records, files, and generations,
  rather than checking only error return values.
- Linux ASan, UBSan, and leak detection instrument both the library and caller.
- Core tests default to two isolated workers. Set `KOUTEN_TEST_JOBS=1` for
  serial execution, or select a concurrency of 1 to 16. Child failures fail
  the suite and logs remain grouped by test.

Local verification passed the core suite, GCC/Clang C contracts, C ABI TLS,
CLI CRUD, symbol parity, and sanitizer checks. The detailed findings and
reproduction matrix are in the
[boundary review](read-cabi-boundary-review.md).

This patch does not claim a new 72-hour endurance run or updated benchmarks.
