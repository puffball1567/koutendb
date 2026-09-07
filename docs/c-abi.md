---
layout: page
title: C ABI Reference
---

# C ABI Reference

KoutenDB exposes a stable C boundary for Rust, JavaScript native addons, PHP
FFI, C++, and other language bindings. The canonical declarations are in
`include/koutendb.h`; the implementation is in `src/koutendb_capi.nim`.

Build the shared library with:

```bash
scripts/build_capi.sh
```

The canonical build enables TLS support. Existing ABI v2 functions and structs
remain unchanged; newer functions are additive symbols.
The script resolves an installed `nimsodium` package through Nimble. Set
`KOUTENDB_NIMSODIUM_PATH` only when using a local checkout instead.

## Boundary Rules

- Call `kouten_init()` before starting foreign worker threads. Repeated
  serialized calls are safe.
- Treat database, transaction, lock, and prepared-selection handles as opaque.
- Do not call `kouten_close()` concurrently with another operation on the same
  database handle.
- Serialize calls when sharing one handle across threads. Independent database
  handles may be used independently.
- A pointer returned as data or JSON belongs to the caller and must be released
  with `kouten_free()`.
- Buffer-returning functions require a non-NULL `out_len`. They validate it
  before database work and set it to zero before other validation. A NULL
  `out_len` cannot trigger a mutation or file publication. This does not imply
  rollback for unrelated I/O failures.
- A `kouten_retrieve_result` must be released with `kouten_retrieve_free()`.
- A `kouten_batch_result` must be released with `kouten_batch_get_free()`.
- Copy `kouten_last_error()` before making another C ABI call on the same
  thread.
- Recoverable exceptions do not cross the C boundary. Failures return `KOUTEN_ERR`, `NULL`,
  or the documented negative sentinel and set `kouten_last_error()`.
- Unrecoverable Nim defects terminate the process under `--panics:on`; they
  must not be mistaken for recoverable API errors.

Boundary regression tests, including a Linux ASan/UBSan/LSan build of both
the library and C caller, are described in the
[read and C ABI review evidence](read-cabi-boundary-review.md).

## Handles

| Function | Purpose |
|---|---|
| `kouten_open` | Open an in-memory embedded database. |
| `kouten_open_dir` | Open a persistent embedded database. |
| `kouten_open_dir_options` | Select durability and disk-backed ring segments. |
| `kouten_connect` | Connect to a KoutenDB cluster. |
| `kouten_connect_auth` | Connect with galaxy credentials. |
| `kouten_connect_auth_tls` | Connect with authentication and TLS verification controls. |
| `kouten_close` | Close the database and invalidate its outstanding transaction and lock handles. |

## Documents And Ring Reads

The original CRUD functions remain available. Codec-aware variants preserve
`raw`, `json`, `nif`, or `bif` metadata.

| Function | Purpose |
|---|---|
| `kouten_put_codec` / `kouten_put_vec_codec` | Store bytes with codec metadata and an optional vector. |
| `kouten_put_profile` | Store bytes using the ring payload profile's default codec. |
| `kouten_get_codec` | Read bytes and their persisted codec. |
| `kouten_exists` | Distinguish present, absent, and API failure. |
| `kouten_update_codec` / `kouten_remove` | Replace or delete an existing record. |
| `kouten_patch_json` | Apply a JSON merge patch and return the resulting document. |
| `kouten_count_ring` | Return the live record count for one ring. |
| `kouten_read_ring_json` | Filter, project, sort, and paginate one ring. |

All ring-page JSON uses one item shape. JSON payloads are returned as JSON;
other codecs are base64 encoded and marked with `"encoding":"base64"`.

## Prepared Selections

Use a prepared selection when the same projection is applied repeatedly:

```c
void *selection = kouten_selection_prepare("{ title author { name } }");
size_t len = 0;
void *json = kouten_query_prepared(db, id, selection, &len);
kouten_free(json);
kouten_selection_close(selection);
```

A successful `kouten_selection_close()` consumes the selection handle.

## Nearby And Stellar Reads

`kouten_put_near_codec()` derives a concrete `base_ring/ring` coordinate.
`kouten_put_near_id_codec()` derives the base coordinate from an existing
anchor ID. The hint itself is not stored separately.

Stellar lenses group existing ring coordinates without copying their records:

```c
kouten_stellar_attach(db, "customer-view", "users/123");
kouten_stellar_attach(db, "customer-view", "users/123/orders");

size_t len = 0;
void *page = kouten_read_stellar_json(
  db,
  "customer-view",
  "{\"subrings\":[\"users/123/orders\"],\"limitPerRing\":10}",
  &len);
kouten_free(page);
```

The stellar options JSON accepts:

| Property | Type | Meaning |
|---|---|---|
| `filter` | object | Equality filter applied inside each selected ring. |
| `selection` | string | JSON projection. |
| `limitPerRing` | integer | Default maximum records returned from each ring. |
| `subringLimits` | object | Per-subring integer overrides. |
| `subringSortFields` | object | Per-subring `id`, `time`, or `write` overrides. |
| `subringSortDirections` | object | Per-subring `asc` or `desc` overrides. |
| `maxDepth` | integer | Maximum child-ring traversal depth. |
| `branchBudget` | integer | Maximum traversal branches; zero uses the core default. |
| `subrings` | string array | Restrict the visible lens to named subrings. |
| `includeRoot` | boolean | Include records from the root coordinate. |
| `sortField` | string | Default `id`, `time`, or `write` ordering. |
| `sortDirection` | string | Default `asc` or `desc` ordering. |

Use `kouten_stellar_members_json()` and
`kouten_stellar_coordinates_json()` to inspect lens membership.

## Time-Orbit Reads

Use `kouten_time_orbit_profile_configure()` to define a ring-local time
coordinate. `kouten_put_time()` calculates the target bucket ring from the
timestamp; `kouten_read_time_json()` calculates the affected buckets before
reading them.

The profile can be inspected with `kouten_time_orbit_profile_json()`. Its
`phase` is encoded as a decimal string in JSON so bindings do not lose unsigned
64-bit precision.

## Transactions

Transaction handles support embedded atomic transactions and cluster landing
transactions:

```c
void *tx = kouten_tx_begin(db);
kouten_id id;
if (!tx ||
    kouten_tx_put_codec(tx, "orders", payload, payload_len,
                        KOUTEN_CODEC_JSON, NULL, 0, &id) != KOUTEN_OK ||
    kouten_tx_commit(tx, KOUTEN_ACK_APPLIED) != KOUTEN_OK) {
  if (tx) kouten_tx_rollback(tx);
}
```

Successful commit and rollback calls consume the transaction handle. A failed
commit leaves it valid so the caller can retry or roll it back. Closing the
owning database rolls back and invalidates outstanding transaction handles.
Read `kouten_tx_identity()` before an accepted cluster commit to retain its
durable txid and coordinator.
`kouten_wait_cluster_tx_applied()` lets a cluster client distinguish an applied
intent (`1`) from timeout or unknown status (`0`) and an API/transport failure
(`KOUTEN_ERR`).

## Cooperative Locks

`kouten_lock_ring()` and `kouten_lock_stellar()` return opaque lock handles.
These locks are opt-in coordination primitives; ordinary CRUD calls do not
implicitly check them.

Use `kouten_lock_info_json()` to inspect the scope, coordinate, fencing value,
expiry, and captured keys. `kouten_lock_active()` returns `1`, `0`, or
`KOUTEN_ERR`. A successful `kouten_lock_release()` consumes the handle. Closing
the owning database releases and invalidates its outstanding locks.

## Profiles And Guardrails

| Function | Purpose |
|---|---|
| `kouten_ring_payload_profile_configure` | Declare a default codec, charset, and format version for a ring. |
| `kouten_ring_payload_profile_json` | Inspect the effective payload profile. |
| `kouten_write_ack_mode_configure` | Set accepted-versus-applied acknowledgement behavior. |
| `kouten_ring_write_ack_mode_configure` | Override acknowledgement behavior for one ring. |
| `kouten_ring_apply_policy_configure` | Set latest-only, append-only, bounded-history, or delayed-timestamp apply behavior. |
| `kouten_ring_apply_policy_json` | Inspect one ring's apply policy. |
| `kouten_guardrails_configure` | Set payload, vector, ring-count, and records-per-ring bounds. |
| `kouten_guardrails_json` | Inspect active guardrails. |
| `kouten_retrieval_tuning_configure` | Register a named budget/focus/top-ring/depth tuning profile. |
| `kouten_retrieval_tuning_json` | Inspect the effective named tuning profile. |
| `kouten_search_profile_configure` | Register human-facing amount/scope/depth search settings. |
| `kouten_retrieval_plan_json` | Build an expanded plan using stored tuning. |
| `kouten_search_plan_json` | Build a plan from amount/scope/depth without a database handle. |
| `kouten_retrieve_tuned` | Retrieve into the normal C result structure using a named profile. |

Zero guardrail values disable the corresponding bound.

## Retrieval Envelopes And Diagnostics

`kouten_ring_summaries_json()` returns ring centroids, record counts,
coherence, mass, and optional query similarity. The retrieval-envelope calls
return the same versioned RAG/MCP contract as the Nim API:

```c
size_t len = 0;
float query[] = {1.0f, 0.0f};
void *envelope = kouten_retrieval_envelope_tuned_json(
  db, query, 2, "docs/api", "rag-low-token", &len);
void *validation = kouten_retrieval_envelope_validate_json(envelope, &len);
kouten_free(validation);
kouten_free(envelope);
```

Use `kouten_locality_report_json()` for physical WAL locality metrics. It is an
embedded-store operation; cluster administration remains a server concern.

## Embedded Data Lifecycle

The following functions expose the same explicit lifecycle operations used by
the CLI. All result buffers are JSON and must be released with `kouten_free()`.

| Function | Purpose |
|---|---|
| `kouten_dump_jsonl` / `kouten_import_jsonl` | Reproducible, readable migration and audit interchange. |
| `kouten_compact_json` | Rewrite the embedded WAL from live state. |
| `kouten_pack_all_json` / `kouten_pack_ring_json` | Build all or one ring-local derived segment generation. |
| `kouten_backup_json` / `kouten_backup_encrypted_json` | Create compact plain or encrypted recovery snapshots. |
| `kouten_backup_verify_json` / `kouten_backup_encrypted_verify_json` | Strictly verify a snapshot before restore. |
| `kouten_backup_restore_json` / `kouten_backup_encrypted_restore_json` | Restore with explicit overwrite and durability controls. |
| `kouten_operational_verify_json` | Replay and inspect a persistent directory with optional capacity/locality bounds. |

`kouten_dump_jsonl()` requires a real path. Unlike the CLI, the library does
not write a dump to the embedding process's stdout. Import and operational
verification accept optional JSON objects; the exact supported properties are
documented beside their declarations in `include/koutendb.h`.

## Other Operations

The C ABI also exposes vector retrieval, Atlas, metrics, bounded segment
maintenance, immutable generation checkpoints, and orbit-location helpers.
See `include/koutendb.h` for exact signatures and ownership rules.

Cluster topology administration, Universe delivery orchestration, Warp job
control, remote backup transfer policy, and process supervision remain CLI/server
operational surfaces. They are not required for application-driver parity and
are intentionally not exposed as in-process C handles in this ABI revision.
