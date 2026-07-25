## Mutation-ordering check against an already running authenticated/TLS cluster.

import std/[os, times, unittest]
import ../src/kouten/wire

suite "remote handoff mutation ordering":
  test "authenticated transport preserves version and tombstone ordering":
    let peers = parsePeers(getEnv("KOUTEN_TEST_PEERS"))
    check peers.len > 0
    var client = newClusterClient(
      peers,
      username = getEnv("KOUTEN_TEST_USER", "alice"),
      password = getEnv("KOUTEN_TEST_PASSWORD", "secret"),
      secretKey = getEnv("KOUTEN_TEST_SECRET_KEY", "shared-secret"),
      tls = true,
      tlsCaFile = getEnv("KOUTEN_TEST_CA"),
      tlsServerName = getEnv("KOUTEN_TEST_SERVER_NAME", "localhost"))
    try:
      let parent = 9201'u64
      let seq = 5'u32
      let period = 1_000_000_000.0
      let head = 0.1
      let tWrite = epochTime()
      let oldVersion =
        MutationVersion(physicalMicros: 20, logical: 0, origin: 1)
      let deleteVersion =
        MutationVersion(physicalMicros: 21, logical: 0, origin: 1)

      client.transferReq(0, parent, seq, period, head, tWrite, "tls-value",
                         version = oldVersion)
      client.transferDeleteReq(0, parent, seq, period, head, tWrite,
                               deleteVersion)
      client.transferReq(0, parent, seq, period, head, tWrite,
                         "tls-stale-value", version = oldVersion)
      check not client.getReq(0, parent, seq, period, head, tWrite).found
    finally:
      client.close()
