## Manual integration test: start koutend with --role users before running.

import std/[os, strutils, unittest]
import ../src/kouten/wire

suite "cluster rbac":
  test "reader writer admin roles combine with ring prefixes":
    let peers = getEnv("KOUTEN_TEST_PEERS", "127.0.0.1:17811")
    let ps = parsePeers(peers)

    var writer = newClusterClient(ps, username = "writer", password = "write")
    let id = writer.putRingReq(0, "allowed/docs", "writer-value", @[])
    let gotByWriter = writer.getIdReq(0, id)
    check gotByWriter.found
    check gotByWriter.value == "writer-value"

    expect IOError:
      discard writer.putRingReq(0, "blocked/docs", "blocked", @[])
    writer.close()

    var reader = newClusterClient(ps, username = "reader", password = "read")
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

    writer = newClusterClient(ps, username = "writer", password = "write")
    expect IOError:
      discard writer.metricsReq(0)
    expect IOError:
      discard writer.drainReq(0)
    expect IOError:
      discard writer.snapshotReq(0)
    writer.close()

    var admin = newClusterClient(ps, username = "admin", password = "admin")
    let adminHealth = admin.healthReq(0)
    check adminHealth.contains("items=")
    check adminHealth.contains("pendingTx=")
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

    writer = newClusterClient(ps, username = "writer", password = "write")
    expect IOError:
      discard writer.putRingReq(0, "allowed/docs", "during-drain", @[])
    expect IOError:
      discard writer.transferStatusReq(
        0, id.parent, id.seq, id.period, id.head, id.tWrite,
        "forged-maintenance-transfer", version = MutationVersion(
          physicalMicros: 9_000_000, logical: 0, origin: 9),
        expectedPlacementEpoch = 1, expectedPlacementNodes = 1,
        expectedVirtualArcs = 64, maintenanceMigration = true)
    let stillReadable = writer.getIdReq(0, id)
    check stillReadable.found
    check stillReadable.value == "writer-value"
    writer.close()

    check admin.metricsReq(0).contains("drainRejectedWrites")
    check admin.resumeReq(0).contains("resumed")
    let resumedMetrics = admin.metricsReq(0)
    check resumedMetrics.contains("draining 0")
    check resumedMetrics.contains("drainStartedAt 0")

    writer = newClusterClient(ps, username = "writer", password = "write")
    let resumed = writer.putRingReq(0, "allowed/docs", "after-resume", @[])
    check writer.getIdReq(0, resumed).value == "after-resume"
    writer.close()
    admin.close()
