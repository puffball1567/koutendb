---
layout: page
title: Read and C ABI Boundary Review
---

# Read and C ABI Boundary Review

This review covers public embedded reads, C ABI output validation and
initialization, and the tests exercising those boundaries. It is not a claim
that every subsystem has undergone an exhaustive audit.

## Reproduced Failures And Fixes

| Finding | Before the fix | Corrected behavior |
| --- | --- | --- |
| Filtered cursor skips unconsumed rows | A 237-document fixture with 79 matches returned only 3 matches across `limit=1` cursor pages. The cursor advanced to the end of the internal fetch, not the last consumed row. | The continuation cursor preserves unconsumed rows. Every expected ID is returned exactly once. |
| Time filtering runs too late | An in-range record could disappear behind an out-of-range record consuming the limit. Projecting away `eventTimeMs` could also return out-of-range records. | The time predicate runs on original records before limit/pagination; projection occurs after time ordering and the final limit. |
| Invalid filters are silently accepted | Non-object filters could behave like no filter, including on absent rings. | Ring and stellar reads reject non-object filters and non-string ID predicates with `ValueError`, independently of whether data exists. |
| Pagination multiplication overflows | A page of `high(int)` with page limit 2 caused an unrecoverable overflow defect. | Invalid pagination arithmetic is rejected before reading. |
| C output validation follows side effects | NULL output lengths returned errors after patch/import, dump, backup, restore, packing, or checkpoint creation had already changed state. Early failures could leave stale output lengths. | All 49 buffer-returning entry points validate the output-length pointer before database work and initialize it to zero. |
| Shared-library initialization repeats | The loader invoked `NimMain`, then the first exported initializer invoked it again. LSan reported 9,256 leaked bytes in five initial allocations in this build. | Module initialization marks the runtime ready; exported initialization no longer reinitializes global tables. |
| Multi-property filtering repeats parsing | Each payload property predicate reparsed the same JSON. ID strings were also constructed without an ID predicate. | JSON is parsed once per candidate in the property-filter matcher, and ID formatting is conditional. |

The output-length rule does not promise rollback for unrelated I/O failures.
The filter optimization is a reduction in repeated work, not a measured
cross-database performance claim. Page-local sorting and bucket-level time
read controls remain distinct from a global ordered-query engine.

## Regression Matrix

| Surface | Dimensions | Assertions |
| --- | --- | --- |
| Filtered ring cursors | Memory-held and disk-backed persistent stores; limits 1, 7, 99, 100, 101, 300; fresh data, update/delete, compact/pack, reopen | Exact independently maintained ID set; no duplicate IDs; bounded page size; advancing cursor; termination |
| Input validation | Existing/absent ring and stellar roots; array, null, boolean, integer, invalid ID type; pagination overflow | `ValueError`, not silent acceptance or process termination |
| JSON predicates | Multiple fields, nested arrays/objects, malformed payload | Exact matching payload semantics |
| Time ranges | Both persistent storage modes; a single bucket containing early/in-range/late records; limits 1 and 10; projection retaining/omitting event time | Exactly the expected record ID, regardless of projection |
| C rejected operations | Patch, import, dump, backup, restore, pack, checkpoint creation/cleanup | Original payload/count, file absence, unchanged segment status and checkpoint list, not merely an error return |
| C outputs and lifetime | Invalid handles/filters; repeated init with a live DB; prepare/close cycles; time-read projection/limit | Zero failed output lengths, preserved live data, stale selection rejection in the exercised cycles, correct time result |
| Memory instrumentation | Linux Clang; ARC; `useMalloc`; TLS-enabled library and caller both instrumented | ASan, UBSan, and LSan fail on diagnostics; no leak suppression |

The normal C contract now uses `mkdtemp` instead of PID/second-derived names
to avoid fixture directory collisions during repeated runs.

## Reproduction

Install the normal Nim dependencies first. GCC or Clang and libsodium are
required; the sanitizer script additionally requires Linux and Clang.

```sh
nimble install -y --depsOnly
scripts/test_core.sh
scripts/build_capi.sh
bash scripts/cabi_boundary_contract.sh
CC=clang bash scripts/cabi_boundary_contract.sh
scripts/cabi_symbol_contract.sh
scripts/cabi_tls_smoke.sh
scripts/cli_crud_smoke.sh
bash scripts/cabi_sanitizer_contract.sh
```

The sanitizer script builds an isolated shared library and caller under a
temporary directory and removes its fixtures on exit. It does not replace the
normal library. LeakSanitizer needs a runtime environment that permits its
process inspection; a ptrace-restricted sandbox is not such an environment.

## Local Verification

On local Linux with Nim 2.2.10, the core suite and the added read matrix passed.
The existing and added C contracts passed with GCC and Clang. The 111-symbol
contract, C ABI TLS contract, and CLI CRUD smoke passed. The instrumented
boundary test passed with ASan, UBSan, and LSan after the initialization fix.

Linux CI includes the sanitizer boundary test. Linux and macOS CI include the
ordinary C boundary test. GitHub Actions records platform-specific results
independently; local Linux results do not imply a completed macOS run.

This review did not rerun the 72-hour soak, large benchmarks, external-language
driver suites, or a multi-node filtered-cursor matrix. Those remain separate
validation scopes.
