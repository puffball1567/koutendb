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

#define KOUTEN_CODEC_RAW  0
#define KOUTEN_CODEC_JSON 1
#define KOUTEN_CODEC_NIF  2
#define KOUTEN_CODEC_BIF  3

/* ABI バージョンと直近エラー。last_error はスレッドローカル相当で、所有権は呼び出し側にない。
 * Returned text is valid until the next KoutenDB C ABI call on the same thread.
 */
int         kouten_abi_version(void);
const char *kouten_last_error(void);

/* Nim ランタイム初期化。冪等なので、driver setup paths may call it more than once. */
void   kouten_init(void);

/* DB を開く / 閉じる。nodes はノード数（8 が無難な既定）。失敗時 NULL。
 * Handles are opaque and become invalid after kouten_close. Reusing a closed or
 * unknown handle fails closed rather than dereferencing it.
 *
 * Thread-safety contract:
 * - kouten_init() is idempotent.
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

/* DB 時計（PoC は決定論のため手動クロック）。 */
double kouten_now(void *db);
void   kouten_advance(void *db, double dt);

/* 環の公転周期を設定（省略時 60s 相当）。JOIN したい2環は 1:2 等の整数比に。 */
int    kouten_ring_configure(void *db, const char *ring, double period);
int    kouten_set_galaxy_description(void *db, const char *description);
int    kouten_set_ring_description(void *db, const char *ring, const char *description);

/* 書き込み。out_id に不透明IDが入る。以後この ID だけで所在計算が閉じる。 */
int    kouten_put(void *db, const char *ring,
                 const void *data, size_t len, kouten_id *out_id);
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
void   kouten_free(void *p);
/* 複数 ID のまとめ読み。戻り値は kouten_batch_get_free で解放。 */
kouten_batch_result *kouten_batch_get(void *db, const kouten_id *ids, size_t ids_len);
void   kouten_batch_get_free(kouten_batch_result *r);

/* 選択取得（GraphQL 風）: selection 例 "{ title author { name } }"。
 * 選択した部分の JSON 文字列を返す（kouten_free で解放）。失敗時 NULL。 */
void  *kouten_query(void *db, kouten_id id, const char *selection, size_t *out_len);

/* Ring read page as JSON. This is the driver-friendly counterpart of
 * `kouten get --ring=...`: it returns one stable shape for one or many records.
 *
 * filter_json: JSON object string, or NULL/"" for no filter.
 * selection: optional JSON projection selection.
 * pagination: 0 = cursor/limit mode, non-zero = page/page_limit mode.
 * sort_desc: 0 = ascending, non-zero = descending.
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

/* vector 近傍検索。ring は NULL/空文字で global。戻り値は kouten_retrieve_free で解放。 */
kouten_retrieve_result *kouten_retrieve(void *db,
                                      const float *vec, size_t vec_len,
                                      const char *ring,
                                      int budget,
                                      int top_rings,
                                      int focus);
void   kouten_retrieve_free(kouten_retrieve_result *r);

/* Atlas JSON。LLM/agent が最初に読む galaxy/ring map。戻り値は kouten_free で解放。 */
void  *kouten_atlas(void *db, const float *query_vec, size_t query_vec_len,
                   int max_centroid_dims, size_t *out_len);

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
