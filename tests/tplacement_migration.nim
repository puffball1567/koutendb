## Physical-placement lifecycle integration test.

import std/[hashes, json, os, osproc, strutils, tempfiles, unittest]
import ../src/kouten/[core, wire]

proc startNode(exe: string, id: int, peers, dataDir: string,
               placementEpoch: int, startDrained = false): Process =
  var args = @[
    "--id=" & $id,
    "--peers=" & peers,
    "--data=" & dataDir,
    "--durability=strong",
    "--placement-epoch=" & $placementEpoch,
    "--virtual-arcs-per-node=64",
    "--slow-tick=1000"
  ]
  if startDrained:
    args.add "--start-drained"
  startProcess(exe, args = args, options = {poParentStreams})

proc stopNode(p: var Process) =
  if p == nil:
    return
  try:
    p.terminate()
    discard p.waitForExit(timeout = 5_000)
  except CatchableError:
    discard
  p.close()
  p = nil

proc metric(metrics, name: string): int =
  let parts = metrics.splitWhitespace()
  for i in countup(0, parts.len - 2, 2):
    if parts[i] == name:
      return parseInt(parts[i + 1])
  raise newException(ValueError, "missing metric: " & name)

proc waitNode(c: ClusterClient, node: int): bool =
  for _ in 0 ..< 100:
    try:
      discard c.healthReq(node)
      return true
    except CatchableError:
      sleep(50)
  false

proc waitMigration(c: ClusterClient, nodes: int): bool =
  for _ in 0 ..< 300:
    var done = true
    for node in 0 ..< nodes:
      try:
        done = done and c.metricsReq(node).metric("migrationRemaining") == 0
      except CatchableError:
        done = false
    if done:
      return true
    sleep(50)
  false

proc keyForRing(name: string): uint64 =
  uint64(hash(name)) or 1'u64

suite "physical placement lifecycle":
  test "topology epoch migration is bounded, retryable, and restart-safe":
    let exe = getEnv("KOUTEN_TEST_SERVER")
    check exe.len > 0
    let root = createTempDir("koutendb", "placement-migration")
    let peers2 = "127.0.0.1:17941,127.0.0.1:17942"
    let peers3 = peers2 & ",127.0.0.1:17943"
    let oldTable = virtualArcTable(1, 2, 64)
    let newTable = virtualArcTable(2, 3, 64)
    var ring = ""
    var parent = 0'u64
    for i in 0 ..< 10_000:
      let candidate = "migration/ring-" & $i
      let key = candidate.keyForRing
      if newTable.placementOwner(key) == 2'u16:
        ring = candidate
        parent = key
        break
    check ring.len > 0
    let oldOwner = int(oldTable.placementOwner(parent))
    check oldOwner in 0 .. 1
    let ringMetadata = $(%*{
      "kind": "ring",
      "key": $parent,
      "period": 60.0,
      "head": 0.25,
      "name": ring,
      "description": "rolling activation metadata",
      "payloadProfile": {
        "defaultCodec": "json",
        "charset": "UTF-8",
        "formatVersion": "1"
      },
      "timeOrbitProfile": {
        "bits": 60,
        "bucketMs": 60000,
        "phase": "7",
        "salt": "rolling"
      }
    })

    var nodes: array[3, Process]
    var ids: seq[WireId] = @[]
    try:
      nodes[0] = startNode(exe, 0, peers2, root / "node0", 1)
      nodes[1] = startNode(exe, 1, peers2, root / "node1", 1)
      var oldClient = newClusterClient(parsePeers(peers2))
      try:
        check oldClient.waitNode(0)
        check oldClient.waitNode(1)
        oldClient.migrationMetadataReq(
          oldOwner, ringMetadata, 1, 2, 64)
        for i in 0 ..< 600:
          ids.add oldClient.putRingReq(
            i mod 2, ring, """{"seq":""" & $i & "}", codec = pcJson)

        # A very short logical orbit must not create periodic physical work.
        let shortParent = keyForRing("migration/short-logical-orbit")
        let shortOwner = int(oldTable.placementOwner(shortParent))
        for i in 0 ..< 32:
          discard oldClient.putReq(shortOwner, shortParent, 0.2, 0.0,
                                   "short-" & $i)
        sleep(1_000)
        check oldClient.metricsReq(0).metric("handoffQueued") == 0
        check oldClient.metricsReq(1).metric("handoffQueued") == 0
        check oldClient.drainReq(0).contains("draining")
        check oldClient.drainReq(1).contains("draining")
      finally:
        oldClient.close()
      stopNode(nodes[0])
      stopNode(nodes[1])

      # Activate epoch 2 with the new destination unavailable. The source must
      # retain data and report retryable backlog instead of deleting it.
      nodes[0] = startNode(exe, 0, peers3, root / "node0", 2)
      nodes[1] = startNode(exe, 1, peers3, root / "node1", 2)
      var degraded = newClusterClient(parsePeers(peers3))
      try:
        check degraded.waitNode(0)
        check degraded.waitNode(1)
        var sawRetry = false
        for _ in 0 ..< 80:
          let m = degraded.metricsReq(oldOwner)
          if m.metric("handoffFailed") > 0 and
              m.metric("migrationRemaining") > 0:
            sawRetry = true
            break
          sleep(50)
        check sawRetry
        check degraded.statsReq(oldOwner).count >= ids.len
      finally:
        degraded.close()

      # A reachable destination with the wrong epoch is rejected before any
      # transfer is applied.
      nodes[2] = startNode(exe, 2, peers3, root / "node2", 1,
                           startDrained = true)
      var mismatched = newClusterClient(parsePeers(peers3))
      try:
        check mismatched.waitNode(2)
        sleep(750)
        check mismatched.statsReq(2).count == 0
        check mismatched.metricsReq(oldOwner).metric("migrationRemaining") > 0
        expect IOError:
          discard mismatched.resumeReq(0)
        expect IOError:
          discard mismatched.putRingReq(0, ring, """{"mixed":true}""",
                                        codec = pcJson)
      finally:
        mismatched.close()
      stopNode(nodes[2])

      nodes[2] = startNode(exe, 2, peers3, root / "node2", 2)
      var migrated = newClusterClient(parsePeers(peers3))
      try:
        check migrated.waitNode(0)
        check migrated.waitNode(1)
        check migrated.waitNode(2)
        for node in 0 ..< 3:
          check migrated.metricsReq(node).metric("draining") == 1
        check migrated.waitMigration(3)
        expect IOError:
          discard migrated.putRingReq(0, ring, """{"blocked":true}""",
                                      codec = pcJson)
        check migrated.topologyReq(0).epoch == 2
        check migrated.statsReq(2).count >= ids.len
        migrated.migrationMetadataVerifyReq(2, ringMetadata, 2, 3, 64)
        for index in [0, 299, 599]:
          let got = migrated.getIdReq(index mod 2, ids[index])
          check got.found
          check got.value == """{"seq":""" & $index & "}"
        let queued = [
          migrated.metricsReq(0).metric("handoffQueued"),
          migrated.metricsReq(1).metric("handoffQueued"),
          migrated.metricsReq(2).metric("handoffQueued")
        ]
        sleep(1_000)
        for node in 0 ..< 3:
          check migrated.metricsReq(node).metric("handoffQueued") == queued[node]
        for node in 0 ..< 3:
          check migrated.resumeReq(node) in ["resumed", "active"]
        let afterResume = migrated.putRingReq(
          0, ring, """{"resumed":true}""", codec = pcJson)
        check migrated.getIdReq(0, afterResume).value == """{"resumed":true}"""
      finally:
        migrated.close()

      for node in nodes.mitems:
        stopNode(node)

      # Same topology restart reconstructs an empty migration plan.
      for id in 0 ..< 3:
        nodes[id] = startNode(exe, id, peers3, root / ("node" & $id), 2)
      var restarted = newClusterClient(parsePeers(peers3))
      try:
        for id in 0 ..< 3:
          check restarted.waitNode(id)
        check restarted.waitMigration(3)
        check restarted.getIdReq(0, ids[123]).value == """{"seq":123}"""
      finally:
        restarted.close()
    finally:
      for node in nodes.mitems:
        stopNode(node)
      removeDir(root)
