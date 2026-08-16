## Recoverable cluster transaction coordinator matrix:
## - reject commit acknowledgement while the standby is unavailable
## - accept identical intent/completion replay and reject txid collisions
## - commit while the owner is unavailable
## - verify the primary and standby both retain the intent
## - restart the standby from its own WAL
## - crash the primary coordinator
## - fence and promote the standby through a surviving-node quorum
## - recover the owner and converge without duplicate visible data

import std/[json, os, osproc, strutils, unittest]
import ../src/koutendb
import ../src/kouten/wire

type NodeProc = object
  id: int
  process: Process

proc startNode(id: int, peers, dataRoot: string, epoch: int,
               coordinator, replica: int): NodeProc =
  let exe = getCurrentDir() / "src" / "koutend"
  result = NodeProc(
    id: id,
    process: startProcess(exe,
      args = @["--id=" & $id, "--peers=" & peers,
               "--data=" & (dataRoot / ("node" & $id)),
               "--slow-tick=0.05", "--durability=strong",
               "--coordinator-epoch=" & $epoch,
               "--coordinator-node=" & $coordinator,
               "--coordinator-replica=" & $replica],
      options = {poParentStreams}))

proc stopNode(node: var NodeProc, crash = false) =
  if node.process.isNil:
    return
  try:
    if crash:
      node.process.kill()
    else:
      node.process.terminate()
    discard node.process.waitForExit(timeout = 2_000)
  except CatchableError:
    discard
  node.process.close()
  node.process = nil

proc waitNode(client: ClusterClient, node: int, expected = true): bool =
  for _ in 0 ..< 80:
    try:
      discard client.healthReq(node)
      if expected:
        return true
    except CatchableError:
      if not expected:
        return true
    sleep(100)
  false

proc metricValue(metrics, name: string): int =
  let parts = metrics.splitWhitespace()
  for i in 0 ..< parts.len - 1:
    if parts[i] == name:
      return parseInt(parts[i + 1])
  raise newException(ValueError, "metric not found: " & name)

proc waitMetric(client: ClusterClient, node: int, name: string,
                expected: int): bool =
  for _ in 0 ..< 100:
    try:
      if metricValue(client.metricsReq(node), name) == expected:
        return true
    except CatchableError:
      discard
    sleep(100)
  false

proc waitMetricAtLeast(client: ClusterClient, node: int, name: string,
                       expected: int): bool =
  for _ in 0 ..< 100:
    try:
      if metricValue(client.metricsReq(node), name) >= expected:
        return true
    except CatchableError:
      discard
    sleep(100)
  false

suite "cluster coordinator failover":
  test "promotion boundary matrix fails closed before activation":
    let basePort = parseInt(getEnv("KOUTEN_COORDINATOR_BASE_PORT", "17631")) + 30
    let peers = "127.0.0.1:" & $basePort & ",127.0.0.1:" & $(basePort + 1) &
                ",127.0.0.1:" & $(basePort + 2)
    let dataRoot = getTempDir() /
      ("koutendb-coordinator-promotion-matrix-" & $getCurrentProcessId())
    createDir(dataRoot)
    var nodes: seq[NodeProc] = @[]
    var client = newClusterClient(parsePeers(peers))
    try:
      for id in 0 ..< 3:
        nodes.add startNode(id, peers, dataRoot, 1, 0, 1)
      for id in 0 ..< 3:
        check client.waitNode(id)

      checkpoint "promotion requires durable drain"
      expect IOError:
        discard client.coordinatorPromoteReq(0, 2, 1, 2)
      check metricValue(client.metricsReq(0), "coordinatorEpoch") == 1

      check client.drainReq(0).contains("draining")
      checkpoint "invalid node indexes are rejected"
      expect IOError:
        discard client.coordinatorPromoteReq(0, 2, 3, 1)
      checkpoint "primary and standby must differ"
      expect IOError:
        discard client.coordinatorPromoteReq(0, 2, 1, 1)
      checkpoint "same epoch cannot change assignment"
      expect IOError:
        discard client.coordinatorPromoteReq(0, 1, 1, 2)

      check client.coordinatorPromoteReq(0, 2, 1, 2).contains("staged")
      # Replaying the exact stage operation is idempotent.
      check client.coordinatorPromoteReq(0, 2, 1, 2).contains("staged")
      checkpoint "epoch rollback is rejected"
      expect IOError:
        discard client.coordinatorPromoteReq(0, 1, 0, 1)
      checkpoint "same promoted epoch is assignment-fenced"
      expect IOError:
        discard client.coordinatorPromoteReq(0, 2, 2, 1)
      checkpoint "one staged node is not a quorum"
      expect IOError:
        discard client.coordinatorResumeReq(0, 2)
      expect IOError:
        discard client.txBeginReq(0)

      check client.drainReq(1).contains("draining")
      check client.coordinatorPromoteReq(1, 2, 1, 2).contains("staged")
      checkpoint "quorum cannot activate before the assigned standby is ready"
      expect IOError:
        discard client.coordinatorResumeReq(1, 2)
      expect IOError:
        discard client.txBeginReq(1)

      check client.drainReq(2).contains("draining")
      check client.coordinatorPromoteReq(2, 2, 1, 2).contains("staged")
      check client.coordinatorResumeReq(0, 2).contains("active")
      check client.coordinatorResumeReq(2, 2).contains("active")
      check client.coordinatorResumeReq(1, 2).contains("active")
      check client.waitMetric(0, "coordinatorRole", 0)
      check client.waitMetric(1, "coordinatorRole", 1)
      check client.waitMetric(2, "coordinatorRole", 2)
      check client.waitMetric(1, "coordinatorReplicaReachable", 1)

      checkpoint "promoted assignment and active state survive restart"
      nodes[1].stopNode(crash = true)
      check client.waitNode(1, expected = false)
      nodes[1] = startNode(1, peers, dataRoot, 2, 1, 2)
      check client.waitNode(1)
      check client.waitMetric(1, "coordinatorRole", 1)
      let txid = client.txBeginReq(1)
      check (txid shr 32) == 2'u64
    finally:
      client.close()
      for i in 0 ..< nodes.len:
        nodes[i].stopNode()
      if dirExists(dataRoot):
        removeDir(dataRoot)

  test "commit is not acknowledged until the standby durably accepts it":
    let basePort = parseInt(getEnv("KOUTEN_COORDINATOR_BASE_PORT", "17631")) + 20
    let peers = "127.0.0.1:" & $basePort & ",127.0.0.1:" & $(basePort + 1) &
                ",127.0.0.1:" & $(basePort + 2)
    let dataRoot = getTempDir() /
      ("koutendb-coordinator-ack-gate-" & $getCurrentProcessId())
    createDir(dataRoot)
    var nodes: seq[NodeProc] = @[]
    var client = newClusterClient(parsePeers(peers))
    var db: KoutenDb = nil
    try:
      for id in 0 ..< 3:
        nodes.add startNode(id, peers, dataRoot, 1, 0, 1)
      for id in 0 ..< 3:
        check client.waitNode(id)
      check client.waitMetric(0, "coordinatorRole", 1)
      check client.waitMetric(1, "coordinatorRole", 2)
      check client.waitMetric(2, "coordinatorRole", 0)
      check client.waitMetric(0, "coordinatorReplicaReachable", 1)

      let replayTxid = client.txBeginReq(0)
      let reservation = client.txReserveReq(0, replayTxid, 101'u64,
                                            315_360_000.0, 0.25)
      let replayOp = TxWireOp(
        parent: 101'u64, seq: reservation.seq, period: 315_360_000.0,
        head: 0.25, tWrite: reservation.tWrite, payload: "replayed-intent")
      client.txMirrorReq(1, 1, 0, replayTxid, @[replayOp])
      client.txMirrorReq(1, 1, 0, replayTxid, @[replayOp])
      var conflictingOp = replayOp
      conflictingOp.payload = "different-intent"
      expect IOError:
        client.txMirrorReq(1, 1, 0, replayTxid, @[conflictingOp])
      client.txMirrorAppliedReq(1, 1, 0, replayTxid)
      client.txMirrorAppliedReq(1, 1, 0, replayTxid)
      check client.waitMetric(1, "clusterTxPending", 0)

      db = connect(peers)
      for crash in [false, true]:
        let stopMode = if crash: "sigkill" else: "terminate"
        checkpoint "standby stop mode: " & stopMode
        let ring = "coordinator/ack-gate/" & stopMode
        db.configureRing(ring, 315_360_000.0)
        let tx = db.beginTransaction()
        let id = tx.put(
          $(%*{"value": "exactly-once-after-retry", "mode": stopMode}),
          ring = ring)

        nodes[1].stopNode(crash = crash)
        check client.waitNode(1, expected = false)
        expect IOError:
          tx.commit()
        check client.waitMetric(0, "clusterTxPending", 1)
        check client.waitMetric(0, "coordinatorReplicaReachable", 0)
        check metricValue(client.metricsReq(0),
                          "coordinatorReplicaLastError") > 0

        nodes[1] = startNode(1, peers, dataRoot, 1, 0, 1)
        check client.waitNode(1)
        # Retry the same transaction identity. Duplicate intent delivery is
        # accepted only when the complete request is identical.
        tx.commit()
        check client.waitMetric(0, "clusterTxPending", 0)
        check client.waitMetric(1, "clusterTxPending", 0)
        check client.waitMetric(0, "coordinatorReplicaReachable", 1)
        check metricValue(client.metricsReq(0),
                          "coordinatorReplicaLastOk") > 0

        check db.get(id).contains("exactly-once-after-retry")
        check db.readRing(ring).count == 1
    finally:
      if not db.isNil:
        db.close()
      client.close()
      for i in 0 ..< nodes.len:
        nodes[i].stopNode()
      if dirExists(dataRoot):
        removeDir(dataRoot)

  test "standby completion acknowledgement converges after an outage":
    let basePort = parseInt(getEnv("KOUTEN_COORDINATOR_BASE_PORT", "17631")) + 10
    let peers = "127.0.0.1:" & $basePort & ",127.0.0.1:" & $(basePort + 1) &
                ",127.0.0.1:" & $(basePort + 2)
    let dataRoot = getTempDir() /
      ("koutendb-coordinator-ack-recovery-" & $getCurrentProcessId())
    createDir(dataRoot)
    var nodes: seq[NodeProc] = @[]
    var client = newClusterClient(parsePeers(peers))
    var db: KoutenDb = nil
    try:
      for id in 0 ..< 3:
        nodes.add startNode(id, peers, dataRoot, 1, 0, 1)
      for id in 0 ..< 3:
        check client.waitNode(id)

      db = connect(peers)
      var tx: KoutenTx = nil
      var id: KoutenId
      var selectedRing = ""
      for i in 0 ..< 128:
        let ring = "coordinator/ack-recovery/" & $i
        db.configureRing(ring, 315_360_000.0)
        tx = db.beginTransaction()
        id = tx.put($(%*{"value": "survives-standby-ack-loss", "attempt": i}),
                    ring = ring)
        if db.locate(id) == 2:
          selectedRing = ring
          break
        tx.rollback()
        tx = nil
      check not tx.isNil
      check selectedRing.len > 0

      nodes[2].stopNode(crash = true)
      check client.waitNode(2, expected = false)
      tx.commit()
      check client.waitMetric(0, "clusterTxPending", 1)
      check client.waitMetric(1, "clusterTxPending", 1)

      nodes[1].stopNode(crash = true)
      check client.waitNode(1, expected = false)
      nodes[2] = startNode(2, peers, dataRoot, 1, 0, 1)
      check client.waitNode(2)
      check client.waitMetricAtLeast(0, "coordinatorMirrorFailed", 1)
      # The primary must remain pending until the standby durably accepts the
      # completion state; otherwise no later retry would be possible.
      check client.waitMetric(0, "clusterTxPending", 1)

      nodes[1] = startNode(1, peers, dataRoot, 1, 0, 1)
      check client.waitNode(1)
      check client.waitMetric(0, "clusterTxPending", 0)
      check client.waitMetric(1, "clusterTxPending", 0)

      db.close()
      db = connect(peers)
      db.configureRing(selectedRing, 315_360_000.0)
      check db.get(id).contains("survives-standby-ack-loss")
    finally:
      if not db.isNil:
        db.close()
      client.close()
      for i in 0 ..< nodes.len:
        nodes[i].stopNode()
      if dirExists(dataRoot):
        removeDir(dataRoot)

  test "mirrored intent survives primary crash and fenced promotion":
    let basePort = parseInt(getEnv("KOUTEN_COORDINATOR_BASE_PORT", "17631"))
    let peers = "127.0.0.1:" & $basePort & ",127.0.0.1:" & $(basePort + 1) &
                ",127.0.0.1:" & $(basePort + 2)
    let dataRoot = getTempDir() /
      ("koutendb-coordinator-failover-" & $getCurrentProcessId())
    createDir(dataRoot)
    var nodes: seq[NodeProc] = @[]
    var client = newClusterClient(parsePeers(peers))
    var db: KoutenDb = nil
    try:
      for id in 0 ..< 3:
        nodes.add startNode(id, peers, dataRoot, 1, 0, 1)
      for id in 0 ..< 3:
        check client.waitNode(id)

      db = connect(peers)
      let epochOneTxid = client.txBeginReq(0)
      check (epochOneTxid shr 32) == 1'u64
      var tx: KoutenTx = nil
      var id: KoutenId
      var owner = -1
      var selectedRing = ""
      for i in 0 ..< 128:
        let ring = "coordinator/failover/" & $i
        # Keep placement stable while this test exercises coordinator failure;
        # orbital handoff is covered by its own matrices.
        db.configureRing(ring, 315_360_000.0)
        tx = db.beginTransaction()
        id = tx.put($(%*{"value": "survives-primary-crash", "attempt": i}),
                    ring = ring)
        owner = db.locate(id)
        if owner == 2:
          selectedRing = ring
          break
        tx.rollback()
        tx = nil
      check owner == 2
      check not tx.isNil

      nodes[2].stopNode(crash = true)
      check client.waitNode(2, expected = false)
      tx.commit()
      check client.waitMetric(0, "clusterTxPending", 1)
      check client.waitMetric(1, "clusterTxPending", 1)
      check metricValue(client.metricsReq(0),
                        "coordinatorMirrorSucceeded") >= 1

      # Restart the standby from its own WAL before promotion. The mirrored
      # intent and pending state must survive process replacement.
      nodes[1].stopNode(crash = true)
      check client.waitNode(1, expected = false)
      nodes[1] = startNode(1, peers, dataRoot, 1, 0, 1)
      check client.waitNode(1)
      check client.waitMetric(1, "clusterTxPending", 1)

      nodes[0].stopNode(crash = true)
      check client.waitNode(0, expected = false)
      check client.drainReq(1).contains("draining")
      check client.coordinatorPromoteReq(1, 2, 1, 2).contains("staged")
      expect IOError:
        discard client.coordinatorResumeReq(1, 2)
      expect IOError:
        discard client.txBeginReq(1)

      nodes[2] = startNode(2, peers, dataRoot, 1, 0, 1)
      check client.waitNode(2)
      let promotion = db.promoteCoordinator(2, 1, 2)
      check promotion.len == 6
      check promotion[^1].contains("node1 resume")

      let discovered = client.discoverCoordinator()
      check discovered.epoch == 2
      check discovered.node == 1
      check discovered.replica == 2
      let publicStatus = db.coordinatorStatus()
      check publicStatus.epoch == 2
      check publicStatus.node == 1
      check publicStatus.replica == 2
      check metricValue(client.metricsReq(1), "coordinatorEpoch") == 2
      check metricValue(client.metricsReq(1), "coordinatorNode") == 1
      check metricValue(client.metricsReq(1), "coordinatorReplica") == 2
      check client.waitMetric(1, "clusterTxPending", 0)
      check client.waitMetric(2, "clusterTxPending", 0)

      db.close()
      db = connect(peers)
      db.configureRing(selectedRing, 315_360_000.0)
      var restored = false
      for _ in 0 ..< 80:
        try:
          if db.get(id).contains("survives-primary-crash"):
            restored = true
            break
        except KeyError, IOError, OSError:
          discard
        sleep(100)
      check restored

      let epochTwoTxid = client.txBeginReq(1)
      check (epochTwoTxid shr 32) == 2'u64

      # A recovered old primary still has epoch 1. Its former standby now
      # rejects the stale mirror, so it cannot acknowledge a split-brain commit.
      nodes[0] = startNode(0, peers, dataRoot, 1, 0, 1)
      check client.waitNode(0)
      check db.readRing(selectedRing).count == 1
      let staleTxid = client.txBeginReq(0)
      check (staleTxid shr 32) == 1'u64
      expect IOError:
        client.txCommitReq(0, staleTxid, @[])
      check metricValue(client.metricsReq(0), "coordinatorMirrorFailed") >= 1

      # Even if a stale client reaches the new coordinator directly, the
      # transaction ID epoch is fenced before reservation or payload apply.
      expect IOError:
        discard client.txReserveReq(1, staleTxid, id.toRaw.parent,
                                    315_360_000.0, 0.0)
      expect IOError:
        client.txCommitReq(1, staleTxid, @[])
      let stillCurrent = client.discoverCoordinator()
      check stillCurrent.epoch == 2
      check stillCurrent.node == 1
    finally:
      if not db.isNil:
        db.close()
      client.close()
      for i in 0 ..< nodes.len:
        nodes[i].stopNode()
      if dirExists(dataRoot):
        removeDir(dataRoot)
