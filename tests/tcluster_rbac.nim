## Manual integration test: start koutend with --role users before running.

import std/[json, net, os, strutils, unittest]
import ../src/kouten/wire

proc metricValue(metrics, name: string): int64 =
  let parts = metrics.splitWhitespace()
  for i in 0 ..< parts.len - 1:
    if parts[i] == name:
      return parseBiggestInt(parts[i + 1])
  raise newException(ValueError, "metric not found: " & name)

proc universeEventJson(ring, key, payload: string): string =
  $(%*{
    "eventKey": key,
    "sourceUniverse": "rbac-test",
    "sourceGalaxy": "default",
    "ring": ring,
    "op": "put",
    "logicalKey": key,
    "payload": payload,
    "vec": [],
    "timestamp": 1.0,
    "originSeq": 1
  })

proc rbacClient(peers: seq[Peer], user, password: string): ClusterClient =
  newClusterClient(peers, username = user, password = password,
                   secretKey = getEnv("KOUTEN_SECRET_KEY"))

suite "cluster rbac":
  test "reader writer admin roles combine with ring prefixes":
    let peers = getEnv("KOUTEN_TEST_PEERS", "127.0.0.1:17811")
    let ps = parsePeers(peers)

    var unauthenticated = newSocket()
    unauthenticated.connect(ps[0].host, Port(ps[0].port))
    unauthenticated.sendFrame("HEALTH")
    check unauthenticated.readHeader() == @["ERR", "auth-required"]
    unauthenticated.close()

    var unknown = newSocket()
    unknown.connect(ps[0].host, Port(ps[0].port))
    unknown.sendFrame("AUTHCHAL missing-role-user")
    let unknownChallenge = unknown.readHeader()
    check unknownChallenge.len == 2
    check unknownChallenge[0] == "CHAL"
    unknown.sendFrame("AUTHRESP invalid")
    check unknown.readHeader() == @["ERR", "auth-required"]
    unknown.close()

    var plaintext = newSocket()
    plaintext.connect(ps[0].host, Port(ps[0].port))
    plaintext.sendFrame("AUTH admin admin")
    check plaintext.readHeader() == @["ERR", "auth-required"]
    plaintext.close()

    var writer = rbacClient(ps, "writer", "write")
    let id = writer.putRingReq(0, "allowed/docs", "writer-value", @[])
    let gotByWriter = writer.getIdReq(0, id)
    check gotByWriter.found
    check gotByWriter.value == "writer-value"

    expect IOError:
      discard writer.putRingReq(0, "blocked/docs", "blocked", @[])
    writer.close()

    var reader = rbacClient(ps, "reader", "read")
    let gotByReader = reader.getIdReq(0, id)
    check gotByReader.found
    check gotByReader.value == "writer-value"
    let readerHealth = reader.healthReq(0)
    check readerHealth.contains("node=0")
    check not readerHealth.contains("items=")
    check not readerHealth.contains("pendingTx=")

    expect IOError:
      discard reader.putRingReq(0, "allowed/docs", "reader-write", @[])
    reader.close()

    var admin = rbacClient(ps, "admin", "admin")
    discard admin.putRingReq(0, "allowed/vector", "allowed-vector",
                             @[1.0'f32, 0.0'f32])
    discard admin.putRingReq(0, "blocked/vector", "blocked-vector",
                             @[1.0'f32, 0.0'f32])
    let beforeRetrieve = admin.metricsReq(0)

    reader = rbacClient(ps, "reader", "read")
    let restricted = reader.retrieveReq(0, false, 0'u64,
                                        @[1.0'f32, 0.0'f32], 8)
    check restricted.totalVectors == 1
    check restricted.scanned == 1
    check restricted.ringsTouched == 1
    check restricted.hits.len == 1
    check restricted.hits[0].payload == "allowed-vector"
    check reader.statsReq(0).count == 2
    reader.close()

    let afterRetrieve = admin.metricsReq(0)
    check afterRetrieve.metricValue("retrievePhysicalVisited") -
      beforeRetrieve.metricValue("retrievePhysicalVisited") == 1

    writer = rbacClient(ps, "writer", "write")
    expect IOError:
      discard writer.metricsReq(0)
    expect IOError:
      discard writer.drainReq(0)
    expect IOError:
      discard writer.snapshotReq(0)
    writer.close()

    let adminHealth = admin.healthReq(0)
    check adminHealth.contains("items=")
    check adminHealth.contains("pendingTx=")
    check admin.statsReq(0).count == 3
    let metrics = admin.metricsReq(0)
    check metrics.contains("items")
    check metrics.contains("uptimeSec")
    check metrics.contains("requests")
    check metrics.contains("errors")
    check metrics.contains("authFailures")
    check metrics.contains("authzDenied")
    check metrics.contains("walBytes")
    check metrics.contains("warpJobs")
    check metrics.contains("activeConnections")

    check admin.drainReq(0).contains("draining")
    let drainedMetrics = admin.metricsReq(0)
    check drainedMetrics.contains("draining 1")
    let snapshot = admin.snapshotReq(0)
    check snapshot.contains("draining 1")
    check snapshot.contains("pendingTx")

    writer = rbacClient(ps, "writer", "write")
    expect IOError:
      discard writer.putRingReq(0, "allowed/docs", "during-drain", @[])
    expect IOError:
      discard writer.transferStatusReq(
        0, id.parent, id.seq, id.period, id.head, id.tWrite,
        "forged-maintenance-transfer", version = MutationVersion(
          physicalMicros: 9_000_000, logical: 0, origin: 9),
        expectedPlacementEpoch = 1, expectedPlacementNodes = 1,
        expectedVirtualArcs = 64, maintenanceMigration = true)
    writer.close()
    writer = rbacClient(ps, "writer", "write")
    let stillReadable = writer.getIdReq(0, id)
    check stillReadable.found
    check stillReadable.value == "writer-value"
    writer.close()

    check admin.metricsReq(0).contains("drainRejectedWrites")
    check admin.resumeReq(0).contains("resumed")
    let resumedMetrics = admin.metricsReq(0)
    check resumedMetrics.contains("draining 0")
    check resumedMetrics.contains("drainStartedAt 0")

    writer = rbacClient(ps, "writer", "write")
    expect IOError:
      discard writer.universeApplyReq(0,
        universeEventJson("allowed/docs", "writer-uapply", "denied"))
    writer.close()

    var replicator = rbacClient(ps, "replicator", "replicate")
    let forwarded = replicator.forwardPutRingReq(
      0, "allowed/docs", "peer-forwarded", @[])
    check forwarded.parent != 0
    check replicator.universeApplyReq(0,
      universeEventJson("allowed/docs", "replicator-uapply", "applied")) ==
        "APPLIED"
    expect IOError:
      discard replicator.transferStatusReq(
        0, forwarded.parent, forwarded.seq, forwarded.period, forwarded.head,
        forwarded.tWrite, "forged-migration", version = MutationVersion(
          physicalMicros: 9_100_000, logical: 0, origin: 9),
        expectedPlacementEpoch = 1, expectedPlacementNodes = 1,
        expectedVirtualArcs = 64, maintenanceMigration = true)
    replicator.close()

    replicator = rbacClient(ps, "replicator", "replicate")
    expect IOError:
      discard replicator.putRingReq(0, "allowed/docs", "public-write", @[])
    replicator.close()

    replicator = rbacClient(ps, "replicator", "replicate")
    expect IOError:
      discard replicator.getIdReq(0, forwarded)
    replicator.close()

    replicator = rbacClient(ps, "replicator", "replicate")
    expect IOError:
      discard replicator.statsReq(0)
    replicator.close()

    writer = rbacClient(ps, "writer", "write")
    let resumed = writer.putRingReq(0, "allowed/docs", "after-resume", @[])
    check writer.getIdReq(0, resumed).value == "after-resume"
    writer.close()
    admin.close()
