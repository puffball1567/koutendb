#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include "koutendb.h"

static int failures;
#define CHECK(condition, message) do { \
  if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); ++failures; } \
} while (0)

static int present(const char *path) {
  struct stat st;
  return stat(path, &st) == 0;
}

int main(int argc, char **argv) {
  if (argc != 2) return 2;
  char data[1024], dump[1024], backup[1024], checkpoints[1024], restored[1024];
  snprintf(data, sizeof data, "%s/data", argv[1]);
  snprintf(dump, sizeof dump, "%s/dump.jsonl", argv[1]);
  snprintf(backup, sizeof backup, "%s/backup", argv[1]);
  snprintf(checkpoints, sizeof checkpoints, "%s/checkpoints", argv[1]);
  snprintf(restored, sizeof restored, "%s/restored", argv[1]);
  kouten_init();
  void *db = kouten_open_dir_options(1, data, 1, 1);
  if (!db) return 2;
  kouten_id id;
  const char *original = "{\"value\":1}";
  if (kouten_put_codec(db, "records", original, strlen(original),
                       KOUTEN_CODEC_JSON, &id) != KOUTEN_OK) return 2;
  kouten_init();
  kouten_init();

  CHECK(kouten_patch_json(db, id, "{\"value\":2}", NULL) == NULL,
        "patch rejects NULL length");
  size_t len = 123;
  char *value = kouten_get(db, id, &len);
  CHECK(value && len == strlen(original) && memcmp(value, original, len) == 0,
        "failed patch must not mutate the record");
  kouten_free(value);

  CHECK(kouten_dump_jsonl(db, dump, 1, NULL) == NULL, "dump rejects NULL length");
  CHECK(!present(dump), "failed dump must not create a file");
  CHECK(kouten_backup_json(db, backup, NULL) == NULL, "backup rejects NULL length");
  CHECK(!present(backup), "failed backup must not publish a directory");
  CHECK(kouten_checkpoint_create_json(db, checkpoints, "rejected", NULL) == NULL,
        "checkpoint rejects NULL length");
  CHECK(!present(checkpoints), "failed checkpoint must not publish a generation");

  const char *messages[] = {"{\"name\":\"early\"}", "{\"name\":\"wanted\"}",
                            "{\"name\":\"late\"}"};
  CHECK(kouten_time_orbit_profile_configure(db, "logs", 60, 1000, 0, "logs")
        == KOUTEN_OK, "configure time bucket");
  for (int i = 0; i < 3; ++i) {
    kouten_id event;
    CHECK(kouten_put_time(db, "logs", 1100 + 400 * i, messages[i],
          strlen(messages[i]), NULL, 0, &event) == KOUTEN_OK, "write timed record");
  }
  value = kouten_read_time_json(db, "logs", 1400, 1600, "", "{ name }",
                                1, "time", 0, 8, &len);
  CHECK(value && strstr(value, "wanted") && !strstr(value, "early") &&
        !strstr(value, "late") && strstr(value, "\"count\":1"),
        "time filtering precedes projection and limit through C ABI");
  kouten_free(value);

  char *before = kouten_segment_status_json(db, 0, 0, &len);
  CHECK(kouten_pack_all_json(db, NULL) == NULL, "pack rejects NULL length");
  char *after = kouten_segment_status_json(db, 0, 0, &len);
  CHECK(before && after && strcmp(before, after) == 0,
        "failed pack must not change the segment generation");
  kouten_free(before);
  kouten_free(after);

  value = kouten_dump_jsonl(db, dump, 1, &len);
  CHECK(value != NULL, "valid dump succeeds");
  kouten_free(value);
  int64_t countBefore = 0, countAfter = 0;
  CHECK(kouten_count_ring(db, "records", &countBefore) == KOUTEN_OK, "count before import");
  CHECK(kouten_import_jsonl(db, dump, NULL, NULL) == NULL, "import rejects NULL length");
  CHECK(kouten_count_ring(db, "records", &countAfter) == KOUTEN_OK, "count after import");
  CHECK(countBefore == countAfter, "failed import must not insert records");

  if (!present(backup)) {
    value = kouten_backup_json(db, backup, &len);
    CHECK(value != NULL, "valid backup succeeds");
    kouten_free(value);
  }
  CHECK(kouten_backup_restore_json(backup, restored, 0,
          KOUTEN_DURABILITY_STRONG, NULL) == NULL, "restore rejects NULL length");
  CHECK(!present(restored), "failed restore must not publish data");

  value = kouten_checkpoint_create_json(db, checkpoints, "first", &len);
  CHECK(value != NULL, "create first valid checkpoint");
  kouten_free(value);
  value = kouten_checkpoint_create_json(db, checkpoints, "second", &len);
  CHECK(value != NULL, "create second valid checkpoint");
  kouten_free(value);
  before = kouten_checkpoint_list_json(checkpoints, &len);
  CHECK(kouten_checkpoint_cleanup_json(checkpoints, 1, NULL) == NULL,
        "cleanup rejects NULL length");
  after = kouten_checkpoint_list_json(checkpoints, &len);
  CHECK(before && after && strcmp(before, after) == 0,
        "failed cleanup must preserve checkpoint generations");
  kouten_free(before);
  kouten_free(after);

  /* A rejected output is always empty, including failures before serialization. */
  len = 123;
  CHECK(kouten_get(NULL, id, &len) == NULL && len == 0,
        "failed get clears output length");
  len = 123;
  CHECK(kouten_read_ring_json(db, "records", "[]", "", 1, "", 0,
          1, 20, "time", 0, &len) == NULL && len == 0,
        "failed JSON read clears output length");

  void *previous = NULL;
  for (int i = 0; i < 128; ++i) {
    void *selection = kouten_selection_prepare("{ value }");
    CHECK(selection != NULL, "prepare succeeds");
    if (previous) {
      CHECK(previous != selection, "closed handle identity must not be reused");
      value = kouten_query_prepared(db, id, previous, &len);
      CHECK(value == NULL, "stale selection cannot become a new selection");
      kouten_free(value);
    }
    CHECK(kouten_selection_close(selection) == KOUTEN_OK, "selection close");
    previous = selection;
  }
  kouten_close(db);
  if (failures) { fprintf(stderr, "%d boundary failures\n", failures); return 1; }
  puts("C ABI boundary contract OK");
  return 0;
}
