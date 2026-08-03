## Cluster retrieval locality regression:
## - ring-scoped retrieval contacts only the calculated physical owner;
## - the owner visits only records indexed under that ring;
## - global retrieval still fans out and visits the complete cluster working set.

import std/[hashes, os, osproc, sequtils, strutils, unittest]
import ../src/koutendb
import ../src/kouten/[core, wire]

type NodeProc = object
  handle: Process

proc startNode(id: int, peers, dataDir: string): NodeProc =
  let exe = getCurrentDir() / "src" / "koutend"
  NodeProc(handle: startProcess(
    exe,
    args = ["--id=" & $id, "--peers=" & peers, "--data=" & dataDir,
            "--slow-tick=0.05"],
    options = {poParentStreams}))

proc stopNode(node: var NodeProc) =
  if node.handle.isNil:
    return
  try:
    node.handle.terminate()
    discard node.handle.waitForExit(timeout = 2_000)
  except CatchableError:
    discard
  node.handle.close()
  node.handle = nil

proc waitCluster(client: ClusterClient, count: int): bool =
  for _ in 0 ..< 50:
    var ready = true
    for node in 0 ..< count:
      try:
        discard client.healthReq(node)
      except CatchableError:
        ready = false
    if ready:
      return true
    sleep(100)
  false

proc metricValue(metrics, name: string): int =
  let parts = metrics.splitWhitespace()
  for i in 0 ..< parts.len - 1:
    if parts[i] == name:
      return parseInt(parts[i + 1])
  raise newException(ValueError, "metric not found: " & name)

proc ringKey(name: string): uint64 =
  uint64(hash(name)) or 1'u64

suite "cluster ring-scoped retrieval locality":
  test "owner routing and ring index avoid cluster-wide physical scans":
    let basePort = parseInt(
      getEnv("KOUTEN_CLUSTER_RETRIEVE_BASE_PORT", "17681"))
    let peers = "127.0.0.1:" & $basePort & ",127.0.0.1:" & $(basePort + 1)
    let dataRoot = getTempDir() /
      ("koutendb-cluster-retrieve-" & $getCurrentProcessId())
    createDir(dataRoot)
    var nodes = @[startNode(0, peers, dataRoot / "node0"),
                  startNode(1, peers, dataRoot / "node1")]
    var client = newClusterClient(parsePeers(peers))
    var db: KoutenDb = nil
    try:
      check client.waitCluster(nodes.len)
      db = connect(peers)
      let topology = client.topologyReq(0)

      var targetRing = ""
      var distractorRing = ""
      var targetOwner = -1
      for i in 0 ..< 128:
        let candidate = "locality/ring-" & $i
        let owner = int(topology.placementOwner(candidate.ringKey))
        if targetRing.len == 0:
          targetRing = candidate
          targetOwner = owner
        elif owner == targetOwner:
          distractorRing = candidate
          break
      check targetRing.len > 0
      check distractorRing.len > 0

      var targetIds: seq[KoutenId] = @[]
      for i in 0 ..< 3:
        targetIds.add db.put("target-" & $i, ring = targetRing,
                             vec = @[1.0'f32,
                                     float32(i) / 100.0'f32])
      for i in 0 ..< 17:
        discard db.put("distractor-" & $i, ring = distractorRing,
                       vec = @[0.0'f32, 1.0'f32])

      let otherNode = (targetOwner + 1) mod nodes.len
      let ownerBefore = client.metricsReq(targetOwner)
      let otherBefore = client.metricsReq(otherNode)
      let scoped = db.retrieveWithStats(
        @[1.0'f32, 0.0'f32], ring = targetRing, budget = 3)
      let ownerAfter = client.metricsReq(targetOwner)
      let otherAfter = client.metricsReq(otherNode)

      check scoped.hits.len == 3
      check scoped.hits.allIt(it.payload.startsWith("target-"))
      check scoped.stats.scanned == 3
      check scoped.stats.fanoutNodes == 1
      check metricValue(ownerAfter, "retrieveScopedRequests") -
            metricValue(ownerBefore, "retrieveScopedRequests") == 1
      check metricValue(ownerAfter, "retrievePhysicalVisited") -
            metricValue(ownerBefore, "retrievePhysicalVisited") == 3
      check metricValue(ownerAfter, "retrieveCandidatesScored") -
            metricValue(ownerBefore, "retrieveCandidatesScored") == 3
      check metricValue(otherAfter, "retrieveRequests") ==
            metricValue(otherBefore, "retrieveRequests")

      var emptyRing = ""
      var emptyOwner = -1
      for i in 0 ..< 128:
        let candidate = "locality/empty-" & $i
        let owner = int(topology.placementOwner(candidate.ringKey))
        if owner != targetOwner:
          emptyRing = candidate
          emptyOwner = owner
          break
      check emptyRing.len > 0
      let emptyOther = (emptyOwner + 1) mod nodes.len
      let emptyOwnerBefore = client.metricsReq(emptyOwner)
      let emptyOtherBefore = client.metricsReq(emptyOther)
      let empty = db.retrieveWithStats(
        @[1.0'f32, 0.0'f32], ring = emptyRing, budget = 3)
      check empty.hits.len == 0
      check empty.stats.scanned == 0
      check empty.stats.fanoutNodes == 1
      check metricValue(client.metricsReq(emptyOwner), "retrieveRequests") -
            metricValue(emptyOwnerBefore, "retrieveRequests") == 1
      check metricValue(client.metricsReq(emptyOther), "retrieveRequests") ==
            metricValue(emptyOtherBefore, "retrieveRequests")

      let remoteId = db.put("remote-target", ring = emptyRing,
                            vec = @[1.0'f32, 0.0'f32])
      var remoteVisible = false
      for _ in 0 ..< 50:
        let remote = db.retrieveWithStats(
          @[1.0'f32, 0.0'f32], ring = emptyRing, budget = 1)
        if remote.hits.len == 1:
          check remote.hits[0].payload == "remote-target"
          check remote.stats.scanned == 1
          check remote.stats.fanoutNodes == 1
          remoteVisible = true
          break
        sleep(20)
      check remoteVisible

      db.configureRingWriteAckMode(emptyRing, wamApplied)
      db.update(remoteId, "remote-target-updated")
      check db.retrieveWithStats(
        @[1.0'f32, 0.0'f32], ring = emptyRing,
        budget = 1).hits[0].payload == "remote-target-updated"
      db.remove(remoteId)
      check db.retrieveWithStats(
        @[1.0'f32, 0.0'f32], ring = emptyRing, budget = 1).hits.len == 0

      var visitedBefore = 0
      for node in 0 ..< nodes.len:
        visitedBefore += metricValue(client.metricsReq(node),
                                     "retrievePhysicalVisited")
      let global = db.retrieveWithStats(@[1.0'f32, 0.0'f32], budget = 3)
      var visitedAfter = 0
      for node in 0 ..< nodes.len:
        visitedAfter += metricValue(client.metricsReq(node),
                                    "retrievePhysicalVisited")
      check global.hits.len == 3
      check global.stats.fanoutNodes == nodes.len
      check visitedAfter - visitedBefore == 20

      check client.drainReq(targetOwner).contains("draining")
      expect IOError:
        discard db.retrieveWithStats(
          @[1.0'f32, 0.0'f32], ring = targetRing, budget = 3)
      check client.resumeReq(targetOwner).contains("resumed")
      check db.retrieveWithStats(
        @[1.0'f32, 0.0'f32], ring = targetRing, budget = 3).hits.len == 3

      db.configureRingWriteAckMode(targetRing, wamApplied)
      let rolledBack = db.beginTransaction()
      discard rolledBack.put("rolled-back", ring = targetRing,
                             vec = @[1.0'f32, 0.0'f32])
      rolledBack.rollback()
      check db.retrieveWithStats(
        @[1.0'f32, 0.0'f32], ring = targetRing, budget = 4).stats.scanned == 3

      db.update(targetIds[0], "target-0-updated",
                vec = @[1.0'f32, 0.0'f32])
      db.remove(targetIds[1])
      let mutated = db.retrieveWithStats(
        @[1.0'f32, 0.0'f32], ring = targetRing, budget = 3)
      check mutated.stats.scanned == 2
      check mutated.hits.len == 2
      check mutated.hits.anyIt(it.payload == "target-0-updated")
      check mutated.hits.allIt(it.payload != "target-1")

      nodes[targetOwner].stopNode()
      nodes[targetOwner] = startNode(
        targetOwner, peers, dataRoot / ("node" & $targetOwner))
      check client.waitCluster(nodes.len)
      let restarted = db.retrieveWithStats(
        @[1.0'f32, 0.0'f32], ring = targetRing, budget = 3)
      check restarted.stats.scanned == 2
      check restarted.hits.len == 2
      check restarted.hits.anyIt(it.payload == "target-0-updated")
      check restarted.hits.allIt(it.payload != "target-1")

      nodes[targetOwner].stopNode()
      var ownerFailure = false
      try:
        discard db.retrieveWithStats(
          @[1.0'f32, 0.0'f32], ring = targetRing, budget = 3)
      except IOError, OSError:
        ownerFailure = true
      check ownerFailure
    finally:
      if not db.isNil:
        db.close()
      client.close()
      for i in 0 ..< nodes.len:
        nodes[i].stopNode()
      removeDir(dataRoot)
