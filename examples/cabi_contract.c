/* KoutenDB C ABI contract smoke test
 * build: gcc examples/cabi_contract.c -Iinclude -Llib -lkoutendb -Wl,-rpath,'$ORIGIN/../lib' -o bin/cabi_contract
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

  size_t read_len = 0;
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

  if (kouten_put_vec(db, "docs/api", payload, strlen(payload), vec, (size_t)-1, &dummy) != KOUTEN_ERR)
    return fail("oversized vector length should fail");
  err = kouten_last_error();
  if (!err || strstr(err, "vec_len") == NULL) return fail("last_error should mention vec_len");

  if (kouten_put_codec(db, "docs/api", payload, strlen(payload), 9999, &dummy) != KOUTEN_ERR)
    return fail("invalid codec should fail");
  err = kouten_last_error();
  if (!err || strstr(err, "codec") == NULL) return fail("last_error should mention codec");

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

  if (kouten_retrieve(db, vec, (size_t)-1, "docs/api", 1, 1, 50) != NULL)
    return fail("oversized retrieve vector length should fail");
  err = kouten_last_error();
  if (!err || strstr(err, "vec_len") == NULL) return fail("last_error should mention retrieve vec_len");

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
