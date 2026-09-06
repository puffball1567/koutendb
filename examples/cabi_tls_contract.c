/* KoutenDB C ABI TLS smoke.
 *
 * This verifies the native-driver path:
 *   libkoutendb.so -> kouten_connect_auth_tls -> KoutenDB wire TLS -> koutend
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "koutendb.h"

static int fail(const char *msg) {
  fprintf(stderr, "FAIL: %s", msg);
  const char *err = kouten_last_error();
  if (err && err[0]) fprintf(stderr, " (%s)", err);
  fprintf(stderr, "\n");
  return 1;
}

int main(void) {
  const char *peers = getenv("KOUTEN_TLS_PEERS");
  const char *ca = getenv("KOUTEN_TLS_CA");
  const char *insecure_env = getenv("KOUTEN_TLS_INSECURE");
  int insecure = insecure_env && strcmp(insecure_env, "0") != 0;
  if (!peers || !peers[0]) peers = "localhost:17651";
  if (!ca) ca = "";

  kouten_init();

  void *db = kouten_connect_auth_tls(
    peers,
    "alice",
    "secret",
    "",
    "shared-secret",
    "",
    1,
    ca,
    "localhost",
    insecure);
  if (!db) return fail("TLS connect through C ABI failed");

  void *tx = kouten_tx_begin(db);
  if (!tx) return fail("TLS cluster transaction begin failed");
  uint64_t txid = 0;
  int coordinator = -1;
  if (kouten_tx_identity(tx, &txid, &coordinator) != KOUTEN_OK ||
      txid == 0 || coordinator < 0)
    return fail("TLS cluster transaction identity failed");
  kouten_id tx_record;
  const char *tx_payload = "{\"title\":\"C ABI TLS transaction\"}";
  if (kouten_tx_put_codec(tx, "secure/cabi", tx_payload, strlen(tx_payload),
                          KOUTEN_CODEC_JSON, NULL, 0, &tx_record) != KOUTEN_OK)
    return fail("TLS cluster transaction put failed");
  if (kouten_tx_commit(tx, KOUTEN_ACK_ACCEPTED) != KOUTEN_OK)
    return fail("TLS cluster transaction accepted commit failed");
  if (kouten_wait_cluster_tx_applied(db, txid, coordinator, 10000, 20) != 1)
    return fail("TLS cluster transaction apply wait failed");
  size_t tx_len = 0;
  char *tx_got = kouten_get(db, tx_record, &tx_len);
  if (!tx_got || strstr(tx_got, "TLS transaction") == NULL)
    return fail("TLS cluster transaction result differs");
  kouten_free(tx_got);

  kouten_id id;
  const char *payload = "{\"title\":\"C ABI TLS\",\"ok\":true}";
  if (kouten_put_codec(db, "secure/cabi", payload, strlen(payload),
                      KOUTEN_CODEC_JSON, &id) != KOUTEN_OK)
    return fail("TLS put through C ABI failed");

  size_t len = 0;
  int codec = -1;
  char *got = kouten_get_codec(db, id, &len, &codec);
  if (!got || len == 0) return fail("TLS get through C ABI failed");
  if (codec != KOUTEN_CODEC_JSON) return fail("TLS get codec mismatch");
  if (strstr(got, "C ABI TLS") == NULL) return fail("TLS payload mismatch");
  kouten_free(got);

  kouten_close(db);
  printf("C ABI TLS contract OK\n");
  return 0;
}
