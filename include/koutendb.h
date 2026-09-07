/* KoutenDB C ABI — src/koutendb_capi.nim と 1:1 対応（設計書 §13）
 *
 * 最小の使い方:
 *   kouten_init();
 *   void *db = kouten_open(8);
 *   kouten_id id;
 *   kouten_put(db, "default", "hello", 5, &id);
 *   size_t len; char *p = kouten_get(db, id, &len);   // 使い終わったら kouten_free(p)
 *   int node = kouten_locate(db, id, -1.0);           // 今どのノードか（問い合わせゼロ）
 *   kouten_close(db);
 */
#ifndef KOUTENDB_H
#define KOUTENDB_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Buffer-returning functions require a non-NULL out_len. It is validated
 * before database work and initialized to zero, including on failure.
 * Rejecting NULL out_len does not perform the requested mutation or file
 * publication. Other failures follow the operation's documented semantics;
 * this rule is not a general rollback guarantee. */

/* 不透明ID（24バイト・値渡し）。中身に触る必要はない。 */
typedef struct kouten_id {
  uint64_t parent;
  uint32_t epoch;
  uint32_t seq;
  double   t_write;
} kouten_id;

typedef struct kouten_hit {
  kouten_id id;
  double   score;
  void    *payload;
  size_t   payload_len;
} kouten_hit;

typedef struct kouten_retrieve_result {
  size_t     len;
  kouten_hit *hits;
  int        total_vectors;
  int        scanned;
  int        skipped_vectors;
  int        returned;
  int        rings_touched;
  int        payload_bytes;
  int        estimated_tokens;
  int        fanout_nodes;
  double     candidate_reduction;
} kouten_retrieve_result;

typedef struct kouten_value {
  void  *data;
  size_t len;
} kouten_value;

typedef struct kouten_batch_result {
  size_t       len;
  kouten_value *values;
} kouten_batch_result;

#define KOUTEN_OK   0
#define KOUTEN_ERR -1

#define KOUTEN_ABI_VERSION 2

/* Allocation and bounded-scan limits enforced by the ABI boundary. */
#define KOUTEN_MAX_INPUT_BYTES    (64u * 1024u * 1024u)
#define KOUTEN_MAX_VECTOR_DIM     1000000u
#define KOUTEN_MAX_BATCH_ITEMS    10000u
#define KOUTEN_MAX_CSTRING_BYTES  (1024u * 1024u)

#define KOUTEN_CODEC_RAW  0
#define KOUTEN_CODEC_JSON 1
#define KOUTEN_CODEC_NIF  2
#define KOUTEN_CODEC_BIF  3

#define KOUTEN_METRICS_KEY_VALUE   0
#define KOUTEN_METRICS_PROMETHEUS  1
#define KOUTEN_METRICS_OPENMETRICS 2

#define KOUTEN_ACK_ACCEPTED 0
#define KOUTEN_ACK_APPLIED  1

#define KOUTEN_APPLY_LATEST_ONLY       0
#define KOUTEN_APPLY_APPEND_ONLY       1
#define KOUTEN_APPLY_BOUNDED_HISTORY   2
#define KOUTEN_APPLY_DELAYED_TIMESTAMP 3

#define KOUTEN_SEARCH_AMOUNT_FEW        0
#define KOUTEN_SEARCH_AMOUNT_NORMAL     1
#define KOUTEN_SEARCH_AMOUNT_MANY       2
#define KOUTEN_SEARCH_AMOUNT_ALL_USEFUL 3

#define KOUTEN_SEARCH_SCOPE_TIGHT 0
#define KOUTEN_SEARCH_SCOPE_NEAR  1
#define KOUTEN_SEARCH_SCOPE_WIDE  2
#define KOUTEN_SEARCH_SCOPE_ALL   3

#define KOUTEN_SEARCH_DEPTH_SHALLOW   0
#define KOUTEN_SEARCH_DEPTH_NORMAL    1
#define KOUTEN_SEARCH_DEPTH_DEEP      2
#define KOUTEN_SEARCH_DEPTH_VERY_DEEP 3

#define KOUTEN_DURABILITY_BUFFERED 0
#define KOUTEN_DURABILITY_STRONG   1

/* ABI バージョンと直近エラー。last_error はスレッドローカル相当で、所有権は呼び出し側にない。
 * Returned text is valid until the next KoutenDB C ABI call on the same thread.
 */
int         kouten_abi_version(void);
const char *kouten_last_error(void);

/* Nim runtime initialization. Call once before starting application worker
 * threads. Repeated serialized calls are idempotent. */
void   kouten_init(void);

/* DB を開く / 閉じる。nodes はノード数（8 が無難な既定）。失敗時 NULL。
 * Handles are opaque and become invalid after kouten_close. Reusing a closed or
 * unknown handle fails closed rather than dereferencing it.
 *
 * Thread-safety contract:
 * - Complete kouten_init() before concurrent calls from foreign threads.
 * - kouten_last_error() is thread-local in practice; copy it before another
 *   KoutenDB C ABI call on the same thread.
 * - Do not call kouten_close() concurrently with any other operation on the same
 *   handle.
 * - If an application or driver shares one handle across threads, serialize
 *   calls around that handle. Separate handles may be used independently.
 */
void  *kouten_open(int nodes);
/* 永続化つきで開く。dir の追記ログに書き、再オープンで復元される。 */
void  *kouten_open_dir(int nodes, const char *dir);
/* Additive persistent-open variant. Strict boolean options accept only 0/1.
 * disk_backed enables the ring-local segment read layout required by segment
 * diagnostics and bounded maintenance. */
void  *kouten_open_dir_options(int nodes,
                               const char *dir,
                               int durability_strong,
                               int disk_backed);
/* クラスタへ接続。peers = "host:port,host:port,..."（koutend の並び順） */
void  *kouten_connect(const char *peers);
/* 認証つきクラスタ接続。不要な引数は NULL または空文字でよい。 */
void  *kouten_connect_auth(const char *peers,
                          const char *username,
                          const char *password,
                          const char *auth_token,
                          const char *secret_key,
                          const char *galaxy);
/* TLS-aware authenticated cluster connection. `tls` enables standard TLS over
 * TCP when the KoutenDB core library is built with -d:ssl.
 *
 * tls_ca_file may point to a CA/self-signed certificate PEM file.
 * tls_server_name overrides hostname verification / SNI.
 * tls_insecure_skip_verify is intended only for local smoke tests.
 */
void  *kouten_connect_auth_tls(const char *peers,
                              const char *username,
                              const char *password,
                              const char *auth_token,
                              const char *secret_key,
                              const char *galaxy,
                              int tls,
                              const char *tls_ca_file,
                              const char *tls_server_name,
                              int tls_insecure_skip_verify);
void   kouten_close(void *db);

/* Operational metrics. The returned UTF-8 buffer is owned by the caller and
 * must be released with kouten_free. Prometheus/OpenMetrics output uses only
 * bounded labels and does not expose ring names by default. */
void  *kouten_metrics_text(void *db, int format, size_t *out_len);
void  *kouten_checkpoint_metrics_text(const char *root,
                                      int format,
                                      size_t *out_len);

/* DB 時計（PoC は決定論のため手動クロック）。 */
double kouten_now(void *db);
void   kouten_advance(void *db, double dt);

/* 環の公転周期を設定（省略時 60s 相当）。JOIN したい2環は 1:2 等の整数比に。 */
int    kouten_ring_configure(void *db, const char *ring, double period);
int    kouten_set_galaxy_description(void *db, const char *description);
int    kouten_set_ring_description(void *db, const char *ring, const char *description);
void  *kouten_get_galaxy_description(void *db, size_t *out_len);
void  *kouten_get_ring_description(void *db, const char *ring, size_t *out_len);

/* Ring payload metadata and ring-local time-orbit placement profiles. */
int    kouten_ring_payload_profile_configure(void *db,
                                             const char *ring,
                                             int codec,
                                             const char *charset,
                                             const char *format_version);
void  *kouten_ring_payload_profile_json(void *db,
                                        const char *ring,
                                        size_t *out_len);
int    kouten_time_orbit_profile_configure(void *db,
                                           const char *ring,
                                           int bits,
                                           int64_t bucket_ms,
                                           uint64_t phase,
                                           const char *salt);
void  *kouten_time_orbit_profile_json(void *db,
                                      const char *ring,
                                      size_t *out_len);

/* Write acknowledgement, eventual-apply, and application guardrails. */
int    kouten_write_ack_mode_configure(void *db, int ack_mode);
int    kouten_ring_write_ack_mode_configure(void *db,
                                             const char *ring,
                                             int ack_mode);
int    kouten_ring_apply_policy_configure(void *db,
                                           const char *ring,
                                           int apply_mode,
                                           int history_keep,
                                           int delay_ms);
void  *kouten_ring_apply_policy_json(void *db,
                                     const char *ring,
                                     size_t *out_len);
int    kouten_guardrails_configure(void *db,
                                   int64_t max_payload_bytes,
                                   int64_t max_vector_dim,
                                   int64_t max_ring_count,
                                   int64_t max_records_per_ring);
void  *kouten_guardrails_json(void *db, size_t *out_len);

/* Retrieval planning and named search profiles. Configure calls copy all
 * strings. Returned plans/tuning are JSON buffers owned by the caller. */
int    kouten_retrieval_tuning_configure(void *db,
                                         const char *profile,
                                         int budget,
                                         int focus,
                                         int top_rings,
                                         int branch_budget,
                                         int max_depth,
                                         int include_children,
                                         const char *note);
void  *kouten_retrieval_tuning_json(void *db,
                                    const char *profile,
                                    size_t *out_len);
int    kouten_search_profile_configure(void *db,
                                       const char *name,
                                       int amount,
                                       int scope,
                                       int depth,
                                       const char *note);
void  *kouten_retrieval_plan_json(void *db,
                                  const char *ring,
                                  const char *profile,
                                  int budget,
                                  int top_rings,
                                  int focus,
                                  int include_children,
                                  int max_depth,
                                  int branch_budget,
                                  size_t *out_len);
void  *kouten_search_plan_json(const char *ring,
                               int amount,
                               int scope,
                               int depth,
                               const char *profile,
                               size_t *out_len);

/* 書き込み。out_id に不透明IDが入る。以後この ID だけで所在計算が閉じる。 */
int    kouten_put(void *db, const char *ring,
                 const void *data, size_t len, kouten_id *out_id);
/* Uses the ring payload profile's default codec. */
int    kouten_put_profile(void *db,
                          const char *ring,
                          const void *data,
                          size_t len,
                          const float *vec,
                          size_t vec_len,
                          kouten_id *out_id);
/* Codec-aware variants are additive. NIF/BIF bytes are application-encoded. */
int    kouten_put_codec(void *db, const char *ring,
                       const void *data, size_t len, int codec,
                       kouten_id *out_id);
/* vector 付き書き込み。vec は呼び出しプロセスの通常の float32 配列、
 * vec_len は要素数。C ABI 境界では host-native float を受け取る。
 * TCP wire protocol は別契約で、vector bytes は canonical little-endian
 * IEEE-754 float32 として送受信する。 */
int    kouten_put_vec(void *db, const char *ring,
                     const void *data, size_t len,
                     const float *vec, size_t vec_len,
                     kouten_id *out_id);
int    kouten_put_vec_codec(void *db, const char *ring,
                           const void *data, size_t len, int codec,
                           const float *vec, size_t vec_len,
                           kouten_id *out_id);
/* Place a record under base_ring/ring, or near an existing anchor ID. */
int    kouten_put_near_codec(void *db,
                             const char *base_ring,
                             const char *ring,
                             const void *data,
                             size_t len,
                             int codec,
                             const float *vec,
                             size_t vec_len,
                             kouten_id *out_id);
int    kouten_put_near_id_codec(void *db,
                                kouten_id anchor,
                                const char *relation,
                                const void *data,
                                size_t len,
                                int codec,
                                const float *vec,
                                size_t vec_len,
                                kouten_id *out_id);
/* Time placement accepts JSON or raw bytes. JSON objects receive eventTimeMs
 * and ingestTimeMs when those properties are absent. */
int    kouten_put_time(void *db,
                       const char *ring,
                       int64_t timestamp_ms,
                       const void *data,
                       size_t len,
                       const float *vec,
                       size_t vec_len,
                       kouten_id *out_id);

/* 読み出し。NUL 終端付きの複製バッファを返す（kouten_free で解放）。
 * 見つからなければ NULL。 */
void  *kouten_get(void *db, kouten_id id, size_t *out_len);
/* Returns payload bytes and persisted codec. Buffer ownership matches kouten_get. */
void  *kouten_get_codec(void *db, kouten_id id, size_t *out_len, int *out_codec);
/* Returns 1 when present, 0 when absent, and KOUTEN_ERR on API failure. */
int    kouten_exists(void *db, kouten_id id);
int    kouten_update(void *db, kouten_id id,
                     const void *data, size_t len);
int    kouten_update_codec(void *db, kouten_id id,
                           const void *data, size_t len, int codec);
int    kouten_remove(void *db, kouten_id id);
/* JSON merge patch. The returned JSON document must be released with
 * kouten_free. */
void  *kouten_patch_json(void *db,
                         kouten_id id,
                         const char *patch_json,
                         size_t *out_len);
int    kouten_count_ring(void *db, const char *ring, int64_t *out_count);
void   kouten_free(void *p);
/* 複数 ID のまとめ読み。戻り値は kouten_batch_get_free で解放。 */
kouten_batch_result *kouten_batch_get(void *db, const kouten_id *ids, size_t ids_len);
void   kouten_batch_get_free(kouten_batch_result *r);

/* 選択取得（GraphQL 風）: selection 例 "{ title author { name } }"。
 * 選択した部分の JSON 文字列を返す（kouten_free で解放）。失敗時 NULL。 */
void  *kouten_query(void *db, kouten_id id, const char *selection, size_t *out_len);
/* Reusable prepared projection. The selection handle is independent of a DB
 * handle and must be closed exactly once. */
void  *kouten_selection_prepare(const char *selection);
void  *kouten_query_prepared(void *db,
                             kouten_id id,
                             void *selection,
                             size_t *out_len);
int    kouten_selection_close(void *selection);

/* Opaque transaction handles. A successful commit or rollback consumes the
 * handle. A failed commit leaves it valid so the caller can retry or roll it
 * back. Closing the owning DB rolls back all outstanding handles. */
void  *kouten_tx_begin(void *db);
/* Read before commit. Embedded transactions return txid=0 and coordinator=-1;
 * cluster transactions return the durable landing identity needed by
 * kouten_wait_cluster_tx_applied. */
int    kouten_tx_identity(void *tx,
                          uint64_t *out_txid,
                          int *out_coordinator_node);
int    kouten_tx_put_codec(void *tx,
                           const char *ring,
                           const void *data,
                           size_t len,
                           int codec,
                           const float *vec,
                           size_t vec_len,
                           kouten_id *out_id);
int    kouten_tx_update_codec(void *tx,
                              kouten_id id,
                              const void *data,
                              size_t len,
                              int codec,
                              const float *vec,
                              size_t vec_len);
int    kouten_tx_remove(void *tx, kouten_id id);
int    kouten_tx_commit(void *tx, int ack_mode);
int    kouten_tx_rollback(void *tx);

/* Cooperative coordinate locks use opaque handles. They do not implicitly
 * block ordinary CRUD calls; applications use them around workflows that need
 * explicit coordination. A successful release consumes the handle. */
void  *kouten_lock_ring(void *db,
                        const char *ring,
                        double ttl_seconds,
                        int wait_ms);
void  *kouten_lock_stellar(void *db,
                           const char *stellar,
                           double ttl_seconds,
                           int wait_ms);
void  *kouten_lock_info_json(void *lock, size_t *out_len);
int    kouten_lock_active(void *lock);
int    kouten_lock_release(void *lock);

/* Ring read page as JSON. This is the driver-friendly counterpart of
 * `kouten get --ring=...`: it returns one stable shape for one or many records.
 *
 * filter_json: JSON object string, or NULL/"" for no filter.
 * selection: optional JSON projection selection.
 * pagination: 0 = cursor/limit mode, 1 = page/page_limit mode.
 * sort_desc: 0 = ascending, 1 = descending.
 *
 * JSON/non-binary payloads are returned as JSON values when possible.
 * Other payloads are base64 encoded and marked with "encoding": "base64".
 * Returned buffer ownership matches kouten_get: call kouten_free.
 */
void  *kouten_read_ring_json(void *db,
                            const char *ring,
                            const char *filter_json,
                            const char *selection,
                            int limit,
                            const char *cursor,
                            int pagination,
                            int page,
                            int page_limit,
                            const char *sort_field,
                            int sort_desc,
                            size_t *out_len);

/* Ring-local time range read. It calculates affected bucket rings before
 * reading and returns one JSON document containing rings/items metadata. */
void  *kouten_read_time_json(void *db,
                             const char *ring,
                             int64_t from_ms,
                             int64_t to_ms,
                             const char *filter_json,
                             const char *selection,
                             int limit,
                             const char *sort_field,
                             int sort_desc,
                             int max_buckets,
                             size_t *out_len);

/* Stellar lenses group existing ring coordinates without copying records.
 * options_json accepts filter, selection, limitPerRing, subringLimits,
 * subringSortFields, subringSortDirections, maxDepth, branchBudget, subrings,
 * includeRoot, sortField, and sortDirection. */
int    kouten_stellar_attach(void *db,
                             const char *stellar,
                             const char *ring);
int    kouten_stellar_detach(void *db,
                             const char *stellar,
                             const char *ring);
void  *kouten_stellar_members_json(void *db,
                                   const char *stellar,
                                   size_t *out_len);
void  *kouten_stellar_coordinates_json(void *db,
                                       const char *ring,
                                       size_t *out_len);
void  *kouten_read_stellar_json(void *db,
                                const char *root,
                                const char *options_json,
                                size_t *out_len);

/* vector 近傍検索。ring は NULL/空文字で global。戻り値は kouten_retrieve_free で解放。 */
kouten_retrieve_result *kouten_retrieve(void *db,
                                      const float *vec, size_t vec_len,
                                      const char *ring,
                                      int budget,
                                      int top_rings,
                                      int focus);
/* Uses a named retrieval/search profile configured on this handle. */
kouten_retrieve_result *kouten_retrieve_tuned(void *db,
                                              const float *vec,
                                              size_t vec_len,
                                              const char *ring,
                                              const char *profile);
void   kouten_retrieve_free(kouten_retrieve_result *r);

/* Retrieval diagnostics and adapter-ready RAG envelopes. Ring summaries are
 * ordered by score and then count. Envelope validation returns
 * {"valid":bool,"errors":[...]}; malformed JSON is an API error. */
void  *kouten_ring_summaries_json(void *db,
                                  const float *query_vec,
                                  size_t query_vec_len,
                                  size_t *out_len);
void  *kouten_retrieval_envelope_json(void *db,
                                      const float *query_vec,
                                      size_t query_vec_len,
                                      const char *ring,
                                      int budget,
                                      int top_rings,
                                      int focus,
                                      size_t *out_len);
void  *kouten_retrieval_envelope_tuned_json(void *db,
                                            const float *query_vec,
                                            size_t query_vec_len,
                                            const char *ring,
                                            const char *profile,
                                            size_t *out_len);
void  *kouten_retrieval_envelope_validate_json(const char *envelope_json,
                                               size_t *out_len);
void  *kouten_locality_report_json(void *db, size_t *out_len);

/* Atlas JSON。LLM/agent が最初に読む galaxy/ring map。戻り値は kouten_free で解放。 */
void  *kouten_atlas(void *db, const float *query_vec, size_t query_vec_len,
                   int max_centroid_dims, size_t *out_len);

/* Embedded lifecycle and migration operations. JSONL dump requires a file
 * path; the C ABI never writes a dump to the host process's stdout.
 *
 * Import options JSON supports defaultRing, ringField, ringPrefix,
 * payloadField, vecField, maxRecords, batchSize, and packSegments.
 * Operational verification options JSON supports diskBacked, verifySegments,
 * maxWalBytes, maxSegmentFiles, maxItems, maxRings, maxSegmentBytes,
 * maxDeadRecords, maxDeadRatio, maxSegmentGeneration, staleRatioThreshold,
 * and minStaleRecords. NULL/empty options use the Nim API defaults. */
void  *kouten_compact_json(void *db, size_t *out_len);
void  *kouten_dump_jsonl(void *db,
                         const char *path,
                         int include_vectors,
                         size_t *out_len);
void  *kouten_import_jsonl(void *db,
                           const char *path,
                           const char *options_json,
                           size_t *out_len);
void  *kouten_pack_all_json(void *db, size_t *out_len);
void  *kouten_pack_ring_json(void *db,
                             const char *ring,
                             size_t *out_len);
void  *kouten_backup_json(void *db,
                          const char *destination,
                          size_t *out_len);
void  *kouten_backup_encrypted_json(void *db,
                                    const char *destination,
                                    const char *passphrase,
                                    size_t *out_len);
void  *kouten_backup_verify_json(const char *backup_dir,
                                 size_t *out_len);
void  *kouten_backup_encrypted_verify_json(const char *backup_dir,
                                           const char *passphrase,
                                           size_t *out_len);
void  *kouten_backup_restore_json(const char *backup_dir,
                                  const char *data_dir,
                                  int overwrite,
                                  int durability,
                                  size_t *out_len);
void  *kouten_backup_encrypted_restore_json(const char *backup_dir,
                                            const char *data_dir,
                                            const char *passphrase,
                                            int overwrite,
                                            int durability,
                                            size_t *out_len);
void  *kouten_operational_verify_json(const char *data_dir,
                                      const char *options_json,
                                      size_t *out_len);

/* Cluster-only wait helper. Returns 1 when applied, 0 for timeout/unknown,
 * and KOUTEN_ERR on invalid input or transport failure. */
int    kouten_wait_cluster_tx_applied(void *db,
                                      uint64_t txid,
                                      int coordinator_node,
                                      int timeout_ms,
                                      int poll_ms);

/* Disk-backed segment diagnostics and bounded maintenance. Returned JSON
 * buffers follow the normal ownership rule and must be released with
 * kouten_free. A zero maintenance budget means unlimited for explicit calls;
 * callers that schedule these operations should pass positive bounds. */
void  *kouten_segment_status_json(void *db,
                                  double stale_ratio,
                                  int min_stale_records,
                                  size_t *out_len);
void  *kouten_segment_maintenance_plan_json(void *db,
                                            double stale_ratio,
                                            int min_stale_records,
                                            int max_rings,
                                            int64_t max_bytes,
                                            int64_t max_elapsed_ms,
                                            size_t *out_len);
void  *kouten_segment_maintenance_run_json(void *db,
                                           double stale_ratio,
                                           int min_stale_records,
                                           int max_rings,
                                           int64_t max_bytes,
                                           int64_t max_elapsed_ms,
                                           size_t *out_len);
void  *kouten_segment_maintenance_status_json(void *db, size_t *out_len);
int    kouten_segment_maintenance_recover(void *db, int *out_recovered);

/* Immutable generation checkpoints. Creation uses an embedded persistent
 * handle; verification/list/cleanup/restore operate on checkpoint paths.
 * Returned JSON buffers must be released with kouten_free. NULL root/id on
 * create selects the data-directory default and an automatic identity. */
void  *kouten_checkpoint_create_json(void *db,
                                     const char *root,
                                     const char *checkpoint_id,
                                     size_t *out_len);
void  *kouten_checkpoint_status_json(const char *checkpoint_dir,
                                     size_t *out_len);
void  *kouten_checkpoint_list_json(const char *root,
                                   size_t *out_len);
void  *kouten_checkpoint_cleanup_json(const char *root,
                                      int keep,
                                      size_t *out_len);
void  *kouten_checkpoint_restore_json(const char *checkpoint_dir,
                                      const char *data_dir,
                                      int overwrite,
                                      size_t *out_len);

/* 所在。at < 0 で「現在」。未来時刻も渡せる（ephemeris）。失敗時 -1。 */
int    kouten_locate(void *db, kouten_id id, double at);

/* その ID が指定ノードに次に到着する時刻。 */
double kouten_next_visit(void *db, kouten_id id, int node);

/* 2つの ID が次に同一ノードへ同居する時刻（ローカル JOIN 窓）。会合しなければ -1。 */
double kouten_next_join(void *db, kouten_id a, kouten_id b);

#ifdef __cplusplus
}
#endif

#endif /* KOUTENDB_H */
