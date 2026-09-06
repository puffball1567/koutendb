/* KoutenDB C ABI contract smoke test
 * build: gcc examples/cabi_contract.c -Iinclude -Llib -lkoutendb -Wl,-rpath,'$ORIGIN/../lib' -o bin/cabi_contract
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "koutendb.h"

static int fail(const char *msg) {
  fprintf(stderr, "FAIL: %s", msg);
  const char *err = kouten_last_error();
  if (err && err[0]) fprintf(stderr, " (%s)", err);
  fprintf(stderr, "\n");
  return 1;
}

int main(void) {
  const char *err;

  kouten_init();
  kouten_init();

  if (kouten_abi_version() != KOUTEN_ABI_VERSION) return fail("ABI version mismatch");
  if (sizeof(kouten_id) != 24) return fail("kouten_id must stay 24 bytes");

  void *bad_db = kouten_open(0);
  if (bad_db != NULL) return fail("open should reject zero nodes");
  err = kouten_last_error();
  if (!err || strstr(err, "nodes") == NULL) return fail("last_error should mention nodes");

  void *db = kouten_open(8);
  if (!db) return fail("open failed");

  if (kouten_set_galaxy_description(db, "Contract test galaxy") != KOUTEN_OK)
    return fail("set galaxy description failed");
  if (kouten_set_ring_description(db, "docs/api", "C ABI documentation") != KOUTEN_OK)
    return fail("set ring description failed");
  size_t read_len = 0;
  char *description = kouten_get_galaxy_description(db, &read_len);
  if (!description || strcmp(description, "Contract test galaxy") != 0)
    return fail("get galaxy description failed");
  kouten_free(description);
  description = kouten_get_ring_description(db, "docs/api", &read_len);
  if (!description || strcmp(description, "C ABI documentation") != 0)
    return fail("get ring description failed");
  kouten_free(description);

  if (kouten_ring_payload_profile_configure(
        db, "docs/api", KOUTEN_CODEC_JSON, "UTF-8", "1") != KOUTEN_OK)
    return fail("configure ring payload profile failed");
  char *profile_json = kouten_ring_payload_profile_json(db, "docs/api", &read_len);
  if (!profile_json || strstr(profile_json, "\"codec\":\"json\"") == NULL ||
      strstr(profile_json, "\"charset\":\"UTF-8\"") == NULL)
    return fail("ring payload profile JSON differs");
  kouten_free(profile_json);
  if (kouten_write_ack_mode_configure(db, KOUTEN_ACK_ACCEPTED) != KOUTEN_OK ||
      kouten_ring_write_ack_mode_configure(
        db, "docs/api", KOUTEN_ACK_APPLIED) != KOUTEN_OK)
    return fail("write acknowledgement configuration failed");
  if (kouten_ring_apply_policy_configure(
        db, "docs/api", KOUTEN_APPLY_BOUNDED_HISTORY, 20, 250) != KOUTEN_OK)
    return fail("ring apply policy configuration failed");
  char *policy_json = kouten_ring_apply_policy_json(db, "docs/api", &read_len);
  if (!policy_json || strstr(policy_json, "\"mode\":\"bounded-history\"") == NULL ||
      strstr(policy_json, "\"historyKeep\":20") == NULL)
    return fail("ring apply policy JSON differs");
  kouten_free(policy_json);
  if (kouten_guardrails_configure(db, 1048576, 128, 100, 1000) != KOUTEN_OK)
    return fail("guardrails configuration failed");
  char *guardrails_json = kouten_guardrails_json(db, &read_len);
  if (!guardrails_json || strstr(guardrails_json, "\"maxVectorDim\":128") == NULL ||
      strstr(guardrails_json, "\"maxRecordsPerRing\":1000") == NULL)
    return fail("guardrails JSON differs");
  kouten_free(guardrails_json);
  if (kouten_ring_apply_policy_configure(db, "docs/api", 99, 0, 0) != KOUTEN_ERR)
    return fail("invalid ring apply mode should fail");
  if (kouten_guardrails_configure(db, -1, 0, 0, 0) != KOUTEN_ERR)
    return fail("negative guardrail should fail");
  if (kouten_time_orbit_profile_configure(
        db, "invalid/time", 61, 1000, 0, "") != KOUTEN_ERR)
    return fail("out-of-range time orbit bits should fail");
  if (kouten_count_ring(db, "docs/api", NULL) != KOUTEN_ERR)
    return fail("count_ring should reject NULL output");

  kouten_id id;
  const char *payload = "hello from C ABI";
  float vec[2] = {1.0f, 0.0f};
  if (kouten_put_vec(db, "docs/api", payload, strlen(payload), vec, 2, &id) != KOUTEN_OK)
    return fail("put_vec failed");

  kouten_id bif_id;
  const unsigned char bif[] = {1, 0, 0, 0};
  if (kouten_put_codec(db, "artifacts/bif", bif, sizeof(bif), KOUTEN_CODEC_BIF, &bif_id) != KOUTEN_OK)
    return fail("put_codec failed");
  size_t bif_len = 0;
  int bif_codec = -1;
  void *bif_out = kouten_get_codec(db, bif_id, &bif_len, &bif_codec);
  if (!bif_out || bif_len != sizeof(bif) || bif_codec != KOUTEN_CODEC_BIF)
    return fail("get_codec failed");
  if (memcmp(bif_out, bif, sizeof(bif)) != 0) return fail("get_codec bytes differ");
  kouten_free(bif_out);

  kouten_id json_id;
  const char *json_payload = "{\"title\":\"C ABI\",\"status\":\"draft\"}";
  if (kouten_put_codec(db, "docs/api", json_payload, strlen(json_payload),
                      KOUTEN_CODEC_JSON, &json_id) != KOUTEN_OK)
    return fail("put_codec json failed");

  char *read_page = kouten_read_ring_json(
    db,
    "docs/api",
    "{\"status\":\"draft\"}",
    "{ title }",
    1,
    "",
    0,
    1,
    20,
    "time",
    1,
    &read_len);
  if (!read_page || read_len == 0) return fail("read_ring_json failed");
  if (strstr(read_page, "\"items\"") == NULL) return fail("read_ring_json misses items");
  if (strstr(read_page, "\"count\":1") == NULL) return fail("read_ring_json misses count");
  if (strstr(read_page, "\"title\":\"C ABI\"") == NULL)
    return fail("read_ring_json misses selected JSON payload");
  kouten_free(read_page);

  void *prepared = kouten_selection_prepare("{ title status }");
  if (!prepared) return fail("selection_prepare failed");
  char *prepared_result = kouten_query_prepared(
    db, json_id, prepared, &read_len);
  if (!prepared_result || strstr(prepared_result, "\"title\":\"C ABI\"") == NULL ||
      strstr(prepared_result, "\"status\":\"draft\"") == NULL)
    return fail("query_prepared failed");
  kouten_free(prepared_result);
  if (kouten_selection_close(prepared) != KOUTEN_OK)
    return fail("selection_close failed");
  if (kouten_query_prepared(db, json_id, prepared, &read_len) != NULL)
    return fail("closed prepared selection should fail");
  if (kouten_selection_prepare("{ title") != NULL)
    return fail("invalid prepared selection should fail");
  if (kouten_selection_prepare(NULL) != NULL)
    return fail("NULL prepared selection should fail");

  char *patched = kouten_patch_json(
    db, json_id, "{\"status\":\"published\",\"reviewed\":true}", &read_len);
  if (!patched || strstr(patched, "\"status\":\"published\"") == NULL ||
      strstr(patched, "\"reviewed\":true") == NULL)
    return fail("patch_json failed");
  kouten_free(patched);

  kouten_id user_id;
  if (kouten_put_codec(db, "users/123", "{\"name\":\"Ada\"}", 14,
                       KOUTEN_CODEC_JSON, &user_id) != KOUTEN_OK)
    return fail("user put failed");
  kouten_id order_id;
  if (kouten_put_near_codec(db, "users/123", "orders",
                            "{\"total\":42}", 12, KOUTEN_CODEC_JSON,
                            NULL, 0, &order_id) != KOUTEN_OK)
    return fail("put_near_codec failed");
  kouten_id notification_id;
  if (kouten_put_near_id_codec(db, user_id, "notifications",
                               "{\"unread\":true}", 15, KOUTEN_CODEC_JSON,
                               NULL, 0, &notification_id) != KOUTEN_OK)
    return fail("put_near_id_codec failed");
  int64_t ring_count = -1;
  if (kouten_count_ring(db, "users/123/orders", &ring_count) != KOUTEN_OK ||
      ring_count != 1)
    return fail("count_ring failed");

  if (kouten_stellar_attach(db, "customer-view", "users/123") != KOUTEN_OK ||
      kouten_stellar_attach(db, "customer-view", "users/123/orders") != KOUTEN_OK ||
      kouten_stellar_attach(db, "customer-view", "users/123/notifications") != KOUTEN_OK)
    return fail("stellar attach failed");
  char *stellar_json = kouten_stellar_members_json(db, "customer-view", &read_len);
  if (!stellar_json || strstr(stellar_json, "users/123/orders") == NULL)
    return fail("stellar members failed");
  kouten_free(stellar_json);
  stellar_json = kouten_stellar_coordinates_json(db, "users/123", &read_len);
  if (!stellar_json || strstr(stellar_json, "customer-view") == NULL)
    return fail("stellar coordinates failed");
  kouten_free(stellar_json);
  stellar_json = kouten_read_stellar_json(
    db, "customer-view",
    "{\"limitPerRing\":5,\"subrings\":[\"users/123/orders\"],"
    "\"includeRoot\":false,\"sortField\":\"time\","
    "\"sortDirection\":\"desc\"}", &read_len);
  if (!stellar_json || strstr(stellar_json, "users/123/orders") == NULL ||
      strstr(stellar_json, "\"total\":42") == NULL ||
      strstr(stellar_json, "notifications") != NULL)
    return fail("read_stellar_json filtering failed");
  kouten_free(stellar_json);
  if (kouten_read_stellar_json(db, "customer-view", "[]", &read_len) != NULL)
    return fail("stellar read should reject non-object options");
  if (kouten_read_stellar_json(
        db, "customer-view", "{\"sortDirection\":\"sideways\"}",
        &read_len) != NULL)
    return fail("stellar read should reject invalid sort direction");
  if (kouten_stellar_detach(db, "customer-view", "users/123/orders") != KOUTEN_OK)
    return fail("stellar detach failed");

  if (kouten_time_orbit_profile_configure(
        db, "logs/app", 20, 1000, 7, "contract") != KOUTEN_OK)
    return fail("configure time orbit profile failed");
  profile_json = kouten_time_orbit_profile_json(db, "logs/app", &read_len);
  if (!profile_json || strstr(profile_json, "\"bits\":20") == NULL ||
      strstr(profile_json, "\"bucketMs\":1000") == NULL ||
      strstr(profile_json, "\"phase\":\"7\"") == NULL)
    return fail("time orbit profile JSON differs");
  kouten_free(profile_json);
  kouten_id event_id;
  if (kouten_put_time(db, "logs/app", 2500,
                      "{\"message\":\"ready\"}", 19,
                      NULL, 0, &event_id) != KOUTEN_OK)
    return fail("put_time failed");
  char *time_json = kouten_read_time_json(
    db, "logs/app", 2000, 2999, "", "", 10, "time", 0, 8, &read_len);
  if (!time_json || strstr(time_json, "\"bucketsVisited\":1") == NULL ||
      strstr(time_json, "\"eventTimeMs\":2500") == NULL)
    return fail("read_time_json failed");
  kouten_free(time_json);
  if (kouten_read_time_json(
        db, "logs/app", 3000, 2000, "", "", 10, "time", 0, 8,
        &read_len) != NULL)
    return fail("time read should reject a reversed range");
  if (kouten_read_time_json(
        db, "logs/app", 0, 9999, "", "", 10, "time", 0, 1,
        &read_len) != NULL)
    return fail("time read should enforce max_buckets");

  void *tx = kouten_tx_begin(db);
  if (!tx) return fail("transaction begin failed");
  kouten_id rolled_back_id;
  if (kouten_tx_put_codec(tx, "tx/items", "rollback", 8, KOUTEN_CODEC_RAW,
                          NULL, 0, &rolled_back_id) != KOUTEN_OK)
    return fail("transaction put failed");
  if (kouten_exists(db, rolled_back_id) != 0)
    return fail("uncommitted transaction value became visible");
  if (kouten_tx_rollback(tx) != KOUTEN_OK ||
      kouten_exists(db, rolled_back_id) != 0)
    return fail("transaction rollback failed");
  if (kouten_tx_rollback(tx) != KOUTEN_ERR)
    return fail("closed transaction handle should fail");

  tx = kouten_tx_begin(db);
  if (!tx) return fail("invalid-ack transaction begin failed");
  kouten_id invalid_ack_id;
  if (kouten_tx_put_codec(tx, "tx/items", "invalid", 7, KOUTEN_CODEC_RAW,
                          NULL, 0, &invalid_ack_id) != KOUTEN_OK)
    return fail("invalid-ack transaction put failed");
  if (kouten_tx_commit(tx, 99) != KOUTEN_ERR)
    return fail("transaction should reject invalid ack mode");
  if (kouten_tx_rollback(tx) != KOUTEN_OK ||
      kouten_exists(db, invalid_ack_id) != 0)
    return fail("failed commit should leave transaction rollback-capable");

  tx = kouten_tx_begin(db);
  if (!tx) return fail("second transaction begin failed");
  kouten_id committed_id;
  if (kouten_tx_put_codec(tx, "tx/items", "commit", 6, KOUTEN_CODEC_RAW,
                          NULL, 0, &committed_id) != KOUTEN_OK ||
      kouten_tx_commit(tx, KOUTEN_ACK_APPLIED) != KOUTEN_OK ||
      kouten_exists(db, committed_id) != 1)
    return fail("transaction commit failed");

  tx = kouten_tx_begin(db);
  if (!tx) return fail("update transaction begin failed");
  if (kouten_tx_update_codec(tx, committed_id, "updated", 7,
                             KOUTEN_CODEC_RAW, NULL, 0) != KOUTEN_OK ||
      kouten_tx_commit(tx, KOUTEN_ACK_ACCEPTED) != KOUTEN_OK)
    return fail("transaction update failed");
  void *updated_value = kouten_get(db, committed_id, &read_len);
  if (!updated_value || read_len != 7 || memcmp(updated_value, "updated", 7) != 0)
    return fail("transaction update value differs");
  kouten_free(updated_value);

  tx = kouten_tx_begin(db);
  if (!tx || kouten_tx_remove(tx, committed_id) != KOUTEN_OK ||
      kouten_tx_commit(tx, KOUTEN_ACK_APPLIED) != KOUTEN_OK ||
      kouten_exists(db, committed_id) != 0)
    return fail("transaction remove failed");

  void *ring_lock = kouten_lock_ring(db, "inventory/sku-1", 30.0, 0);
  if (!ring_lock || kouten_lock_active(ring_lock) != 1)
    return fail("ring lock acquisition failed");
  char *lock_json = kouten_lock_info_json(ring_lock, &read_len);
  if (!lock_json || strstr(lock_json, "\"scope\":\"ring\"") == NULL ||
      strstr(lock_json, "inventory/sku-1") == NULL)
    return fail("ring lock info failed");
  kouten_free(lock_json);
  if (kouten_lock_ring(db, "inventory/sku-1", 30.0, 0) != NULL)
    return fail("conflicting ring lock should fail");
  err = kouten_last_error();
  if (!err || strstr(err, "busy") == NULL)
    return fail("ring lock conflict should set last_error");
  if (kouten_lock_release(ring_lock) != KOUTEN_OK)
    return fail("ring lock release failed");
  if (kouten_lock_active(ring_lock) != KOUTEN_ERR)
    return fail("released lock handle should fail closed");
  if (kouten_lock_ring(db, "inventory/sku-1", 0.0, 0) != NULL)
    return fail("lock should reject non-positive TTL");
  if (kouten_lock_ring(db, "inventory/sku-1", NAN, 0) != NULL)
    return fail("lock should reject NaN TTL");
  if (kouten_lock_ring(db, "inventory/sku-1", 30.0, -1) != NULL)
    return fail("lock should reject negative wait time");
  void *stellar_lock = kouten_lock_stellar(db, "customer-view", 30.0, 0);
  if (!stellar_lock || kouten_lock_active(stellar_lock) != 1)
    return fail("stellar lock acquisition failed");
  if (kouten_lock_release(stellar_lock) != KOUTEN_OK)
    return fail("stellar lock release failed");

  read_page = kouten_read_ring_json(
    db,
    "artifacts/bif",
    "",
    "",
    10,
    "",
    0,
    1,
    20,
    "time",
    1,
    &read_len);
  if (!read_page || strstr(read_page, "\"codec\":\"bif\"") == NULL ||
      strstr(read_page, "\"encoding\":\"base64\"") == NULL)
    return fail("read_ring_json should base64 encode binary payloads");
  kouten_free(read_page);

  kouten_id nif_id;
  const char *nif_payload = "(object (title KoutenDB))";
  if (kouten_put_codec(db, "artifacts/nif", nif_payload, strlen(nif_payload),
                      KOUTEN_CODEC_NIF, &nif_id) != KOUTEN_OK)
    return fail("put_codec nif failed");
  read_page = kouten_read_ring_json(
    db,
    "artifacts/nif",
    "",
    "",
    10,
    "",
    0,
    1,
    20,
    "time",
    1,
    &read_len);
  if (!read_page || strstr(read_page, "\"codec\":\"nif\"") == NULL ||
      strstr(read_page, "\"encoding\":\"base64\"") == NULL)
    return fail("read_ring_json should preserve NIF metadata");
  kouten_free(read_page);

  read_page = kouten_read_ring_json(
    db,
    "docs/api",
    "[]",
    "",
    10,
    "",
    0,
    1,
    20,
    "time",
    1,
    &read_len);
  if (read_page != NULL) return fail("read_ring_json should reject non-object filter");
  err = kouten_last_error();
  if (!err || strstr(err, "filter") == NULL) return fail("last_error should mention filter");

  read_page = kouten_read_ring_json(
    db,
    "docs/api",
    "",
    "",
    10,
    "",
    0,
    1,
    20,
    "payload",
    1,
    &read_len);
  if (read_page != NULL) return fail("read_ring_json should reject invalid sort field");
  err = kouten_last_error();
  if (!err || strstr(err, "sort field") == NULL) return fail("last_error should mention sort field");

  read_page = kouten_read_ring_json(
    db,
    NULL,
    "",
    "",
    10,
    "",
    0,
    1,
    20,
    "time",
    1,
    &read_len);
  if (read_page != NULL) return fail("read_ring_json should reject NULL ring");
  err = kouten_last_error();
  if (!err || strstr(err, "ring") == NULL) return fail("last_error should mention read ring");

  size_t atlas_len = 0;
  char *atlas = kouten_atlas(db, vec, 2, 8, &atlas_len);
  if (!atlas || atlas_len == 0) return fail("atlas failed");
  if (strstr(atlas, "Contract test galaxy") == NULL) return fail("atlas misses galaxy description");
  if (strstr(atlas, "C ABI documentation") == NULL) return fail("atlas misses ring description");
  kouten_free(atlas);

  kouten_id dummy;
  if (kouten_put(db, NULL, payload, strlen(payload), &dummy) != KOUTEN_ERR)
    return fail("NULL ring should fail");
  err = kouten_last_error();
  if (!err || strstr(err, "ring") == NULL) return fail("last_error should mention ring");

  if (kouten_put(db, "docs/api", payload, (size_t)-1, &dummy) != KOUTEN_ERR)
    return fail("oversized payload length should fail");
  err = kouten_last_error();
  if (!err || strstr(err, "length") == NULL) return fail("last_error should mention length");

  if (kouten_put(db, "docs/api", payload, KOUTEN_MAX_INPUT_BYTES + 1u,
                 &dummy) != KOUTEN_ERR)
    return fail("bounded oversized payload length should fail");
  err = kouten_last_error();
  if (!err || strstr(err, "max C input") == NULL)
    return fail("last_error should mention max C input");

  if (kouten_put_vec(db, "docs/api", payload, strlen(payload), vec, (size_t)-1, &dummy) != KOUTEN_ERR)
    return fail("oversized vector length should fail");
  err = kouten_last_error();
  if (!err || strstr(err, "vec_len") == NULL) return fail("last_error should mention vec_len");

  if (kouten_put_vec(db, "docs/api", payload, strlen(payload), vec,
                     KOUTEN_MAX_VECTOR_DIM + 1u, &dummy) != KOUTEN_ERR)
    return fail("bounded oversized vector length should fail");
  err = kouten_last_error();
  if (!err || strstr(err, "max count") == NULL)
    return fail("last_error should mention max vector count");

  if (kouten_put_codec(db, "docs/api", payload, strlen(payload), 9999, &dummy) != KOUTEN_ERR)
    return fail("invalid codec should fail");
  err = kouten_last_error();
  if (!err || strstr(err, "codec") == NULL) return fail("last_error should mention codec");

  char *oversized_ring = malloc(KOUTEN_MAX_CSTRING_BYTES + 2u);
  if (!oversized_ring) return fail("oversized C string allocation failed");
  memset(oversized_ring, 'r', KOUTEN_MAX_CSTRING_BYTES + 1u);
  oversized_ring[KOUTEN_MAX_CSTRING_BYTES + 1u] = '\0';
  if (kouten_ring_configure(db, oversized_ring, 60.0) != KOUTEN_ERR) {
    free(oversized_ring);
    return fail("oversized C string should fail");
  }
  free(oversized_ring);
  err = kouten_last_error();
  if (!err || strstr(err, "max C string") == NULL)
    return fail("last_error should mention max C string");

  if (kouten_get(db, id, NULL) != NULL)
    return fail("NULL out_len should fail for get");
  err = kouten_last_error();
  if (!err || strstr(err, "out_len") == NULL) return fail("last_error should mention out_len");

  if (kouten_get_codec(db, id, &read_len, NULL) != NULL)
    return fail("NULL out_codec should fail for get_codec");
  err = kouten_last_error();
  if (!err || strstr(err, "out_codec") == NULL) return fail("last_error should mention out_codec");

  if (kouten_batch_get(db, &id, (size_t)-1) != NULL)
    return fail("oversized batch length should fail");
  err = kouten_last_error();
  if (!err || strstr(err, "ids_len") == NULL) return fail("last_error should mention ids_len");

  if (kouten_batch_get(db, &id, KOUTEN_MAX_BATCH_ITEMS + 1u) != NULL)
    return fail("bounded oversized batch length should fail");
  err = kouten_last_error();
  if (!err || strstr(err, "max count") == NULL)
    return fail("last_error should mention max batch count");

  if (kouten_retrieve(db, vec, (size_t)-1, "docs/api", 1, 1, 50) != NULL)
    return fail("oversized retrieve vector length should fail");
  err = kouten_last_error();
  if (!err || strstr(err, "vec_len") == NULL) return fail("last_error should mention retrieve vec_len");

  read_page = kouten_read_ring_json(
    db, "docs/api", "", "", 1, "", 2, 1, 20, "time", 0, &read_len);
  if (read_page != NULL) return fail("invalid pagination boolean should fail");
  err = kouten_last_error();
  if (!err || strstr(err, "pagination") == NULL)
    return fail("last_error should mention pagination");

  if (kouten_next_visit(db, id, 8) != -1.0)
    return fail("out-of-range next_visit node should fail");
  err = kouten_last_error();
  if (!err || strstr(err, "node") == NULL)
    return fail("last_error should mention next_visit node");

  kouten_advance(db, -1.0);
  err = kouten_last_error();
  if (!err || strstr(err, "non-negative") == NULL)
    return fail("negative advance should set last_error");

  kouten_id mutable_id;
  if (kouten_put(db, "docs/mutable", "before", 6, &mutable_id) != KOUTEN_OK)
    return fail("mutable put failed");
  if (kouten_exists(db, mutable_id) != 1) return fail("exists should find live id");
  if (kouten_update_codec(db, mutable_id, "{\"state\":\"after\"}", 17,
                          KOUTEN_CODEC_JSON) != KOUTEN_OK)
    return fail("update_codec failed");
  int mutable_codec = -1;
  void *mutable_value = kouten_get_codec(db, mutable_id, &read_len, &mutable_codec);
  if (!mutable_value || mutable_codec != KOUTEN_CODEC_JSON ||
      read_len != 17 || memcmp(mutable_value, "{\"state\":\"after\"}", 17) != 0)
    return fail("updated value differs");
  kouten_free(mutable_value);
  if (kouten_remove(db, mutable_id) != KOUTEN_OK) return fail("remove failed");
  if (kouten_exists(db, mutable_id) != 0) return fail("removed id still exists");
  if (kouten_remove(db, mutable_id) != KOUTEN_ERR)
    return fail("second remove should fail");

  char data_dir[160];
  snprintf(data_dir, sizeof(data_dir), "/tmp/koutendb-cabi-contract-%ld-%ld",
           (long)getpid(), (long)time(NULL));
  if (mkdir(data_dir, 0700) != 0) return fail("cannot create C ABI data dir");
  void *disk_db = kouten_open_dir_options(1, data_dir, 1, 1);
  if (!disk_db) return fail("open_dir_options failed");
  if (kouten_open_dir_options(1, data_dir, 2, 1) != NULL)
    return fail("open_dir_options should reject invalid boolean options");

  kouten_id maintenance_id;
  if (kouten_put(disk_db, "maintenance/cabi", "first", 5,
                 &maintenance_id) != KOUTEN_OK)
    return fail("disk-backed put failed");

  char *maintenance_json = kouten_segment_maintenance_plan_json(
    disk_db, 0.0, 0, 1, 1048576, 1000, &read_len);
  if (!maintenance_json || strstr(maintenance_json, "\"outcome\":\"dry-run\"") == NULL ||
      strstr(maintenance_json, "\"selectedRings\":1") == NULL)
    return fail("maintenance plan failed");
  kouten_free(maintenance_json);

  maintenance_json = kouten_segment_maintenance_run_json(
    disk_db, 0.0, 0, 1, 1048576, 1000, &read_len);
  if (!maintenance_json || strstr(maintenance_json, "\"outcome\":\"completed\"") == NULL ||
      strstr(maintenance_json, "\"packedRings\":1") == NULL)
    return fail("maintenance run failed");
  kouten_free(maintenance_json);

  maintenance_json = kouten_segment_maintenance_status_json(disk_db, &read_len);
  if (!maintenance_json || strstr(maintenance_json, "\"outcome\":\"completed\"") == NULL)
    return fail("maintenance status failed");
  kouten_free(maintenance_json);

  maintenance_json = kouten_segment_status_json(disk_db, 0.0, 0, &read_len);
  if (!maintenance_json || strstr(maintenance_json, "\"diskBacked\":true") == NULL ||
      strstr(maintenance_json, "\"generation\":\"1\"") == NULL)
    return fail("segment status failed");
  kouten_free(maintenance_json);

  char *metrics_text = kouten_metrics_text(
    disk_db, KOUTEN_METRICS_PROMETHEUS, &read_len);
  if (!metrics_text || read_len == 0 ||
      strstr(metrics_text, "# TYPE koutendb_items gauge") == NULL ||
      strstr(metrics_text, "koutendb_segment_wal_fallback_reasons_total") == NULL ||
      strstr(metrics_text, "ring=\"") != NULL)
    return fail("Prometheus metrics contract failed");
  kouten_free(metrics_text);
  metrics_text = kouten_metrics_text(
    disk_db, KOUTEN_METRICS_OPENMETRICS, &read_len);
  if (!metrics_text || strstr(metrics_text, "# EOF\n") == NULL)
    return fail("OpenMetrics contract failed");
  kouten_free(metrics_text);
  if (kouten_metrics_text(disk_db, 99, &read_len) != NULL)
    return fail("metrics should reject an unknown format");
  if (kouten_metrics_text(disk_db, KOUTEN_METRICS_PROMETHEUS, NULL) != NULL)
    return fail("metrics should reject a NULL output length");

  int recovered = -1;
  if (kouten_segment_maintenance_recover(disk_db, &recovered) != KOUTEN_OK ||
      recovered != 0)
    return fail("maintenance recover result failed");
  if (kouten_segment_maintenance_recover(disk_db, NULL) != KOUTEN_ERR)
    return fail("maintenance recover should reject NULL output");
  if (kouten_segment_maintenance_plan_json(
        disk_db, 0.0, 0, 1, -1, 1000, &read_len) != NULL)
    return fail("maintenance plan should reject a negative byte budget");

  char checkpoint_root[200];
  char checkpoint_dir[220];
  char checkpoint_restore[200];
  snprintf(checkpoint_root, sizeof(checkpoint_root), "%s-checkpoints", data_dir);
  snprintf(checkpoint_dir, sizeof(checkpoint_dir), "%s/cabi-1", checkpoint_root);
  snprintf(checkpoint_restore, sizeof(checkpoint_restore), "%s-restored", data_dir);
  char *checkpoint_json = kouten_checkpoint_create_json(
    disk_db, checkpoint_root, "cabi-1", &read_len);
  if (!checkpoint_json || strstr(checkpoint_json, "\"verified\":true") == NULL ||
      strstr(checkpoint_json, "\"id\":\"cabi-1\"") == NULL)
    return fail("checkpoint create failed");
  kouten_free(checkpoint_json);

  checkpoint_json = kouten_checkpoint_status_json(checkpoint_dir, &read_len);
  if (!checkpoint_json || strstr(checkpoint_json, "\"reason\":\"verified\"") == NULL ||
      strstr(checkpoint_json, "\"reasonCode\":\"verified\"") == NULL)
    return fail("checkpoint status failed");
  kouten_free(checkpoint_json);
  checkpoint_json = kouten_checkpoint_list_json(checkpoint_root, &read_len);
  if (!checkpoint_json || strstr(checkpoint_json, "\"count\":1") == NULL)
    return fail("checkpoint list failed");
  kouten_free(checkpoint_json);
  metrics_text = kouten_checkpoint_metrics_text(
    checkpoint_root, KOUTEN_METRICS_PROMETHEUS, &read_len);
  if (!metrics_text ||
      strstr(metrics_text, "koutendb_checkpoint_verified_generations") == NULL ||
      strstr(metrics_text, "cabi-1") != NULL)
    return fail("checkpoint metrics contract failed");
  kouten_free(metrics_text);
  if (kouten_checkpoint_cleanup_json(checkpoint_root, 0, &read_len) != NULL)
    return fail("checkpoint cleanup should retain at least one generation");

  checkpoint_json = kouten_checkpoint_restore_json(
    checkpoint_dir, checkpoint_restore, 0, &read_len);
  if (!checkpoint_json || strstr(checkpoint_json, "\"reason\":\"restored\"") == NULL)
    return fail("checkpoint restore failed");
  kouten_free(checkpoint_json);
  void *restored_db = kouten_open_dir_options(1, checkpoint_restore, 1, 1);
  if (!restored_db || kouten_exists(restored_db, maintenance_id) != 1)
    return fail("restored checkpoint does not contain source data");
  kouten_close(restored_db);

  kouten_close(disk_db);
  disk_db = kouten_open_dir_options(1, data_dir, 1, 1);
  if (!disk_db || kouten_exists(disk_db, maintenance_id) != 1)
    return fail("disk-backed C ABI reopen failed");
  kouten_close(disk_db);
  char cleanup_command[640];
  snprintf(cleanup_command, sizeof(cleanup_command),
           "rm -rf -- '%s' '%s' '%s'", data_dir, checkpoint_root,
           checkpoint_restore);
  if (system(cleanup_command) != 0) return fail("cannot clean C ABI data dir");

  void *lifecycle_db = kouten_open(1);
  if (!lifecycle_db) return fail("lifecycle DB open failed");
  void *lifecycle_tx = kouten_tx_begin(lifecycle_db);
  void *lifecycle_lock = kouten_lock_stellar(
    lifecycle_db, "lifecycle", 30.0, 0);
  if (!lifecycle_tx || !lifecycle_lock)
    return fail("lifecycle child handle creation failed");
  kouten_id lifecycle_id;
  if (kouten_tx_put_codec(lifecycle_tx, "lifecycle", "pending", 7,
                          KOUTEN_CODEC_RAW, NULL, 0,
                          &lifecycle_id) != KOUTEN_OK)
    return fail("lifecycle transaction put failed");
  kouten_close(lifecycle_db);
  if (kouten_tx_rollback(lifecycle_tx) != KOUTEN_ERR)
    return fail("DB close should invalidate and roll back child transaction");
  if (kouten_lock_active(lifecycle_lock) != KOUTEN_ERR)
    return fail("DB close should release and invalidate child lock");

  kouten_close(db);
  if (kouten_get(db, id, &read_len) != NULL)
    return fail("closed handle should not read");
  err = kouten_last_error();
  if (!err || strstr(err, "closed") == NULL) return fail("last_error should mention closed handle");
  kouten_close(db);
  err = kouten_last_error();
  if (!err || strstr(err, "closed") == NULL) return fail("double close should stay fail-closed");
  printf("C ABI contract OK\n");
  return 0;
}
