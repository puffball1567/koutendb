## Bounded tombstone reclamation integration test.

import std/[os, osproc, strutils, tempfiles, times, unittest]
import ../src/kouten/[core, wire]

proc startNode(exe: string, id: int, peers, dataDir: string): Process =
  startProcess(exe, args = [
    "--id=" & $id,
    "--peers=" & peers,
    "--data=" & dataDir,
    "--durability=strong",
    "--slow-tick=1000"
  ], options = {poParentStreams})

proc waitNode(client: ClusterClient, node: int): bool =
  for _ in 0 ..< 100:
    try:
      discard client.healthReq(node)
      return true
    except CatchableError:
      sleep(50)
  false

proc stopNode(process: Process) =
  if process == nil:
    return
  try:
    process.terminate()
    discard process.waitForExit(timeout = 3_000)
  except CatchableError:
    discard
  process.close()

proc metric(metrics, name: string): int =
  let parts = metrics.splitWhitespace()
  for i in countup(0, parts.len - 2, 2):
    if parts[i] == name:
      return parseInt(parts[i + 1])
  raise newException(ValueError, "missing metric: " & name)

suite "bounded tombstone reclamation":
  test "all-node acknowledgement circulates before guard copies are reclaimed":
    let exe = getEnv("KOUTEN_TEST_SERVER")
    check exe.len > 0
    let peers = getEnv("KOUTEN_TEST_PEERS",
      "127.0.0.1:17841,127.0.0.1:17842")
    let parsed = parsePeers(peers)
    check parsed.len == 2
    let root = createTempDir("koutendb", "handoff-reclamation")
    var nodes = [
      startNode(exe, 0, peers, root / "node0"),
      startNode(exe, 1, peers, root / "node1")
    ]
    var client = newClusterClient(parsed)
    try:
      check client.waitNode(0)
      check client.waitNode(1)

      let parent = 9301'u64
      let seq = 7'u32
      let period = 2.0
      let head = 0.2
      let tWrite = epochTime()
      let orbit =
        OrbitalId(parent: parent, epoch: 1, tWrite: tWrite, seq: seq)
          .ringOrbit(period, head)
      let owner = int(equalArcTable(1, uint16(parsed.len)).node(orbit, epochTime()))
      client.transferDeleteReq(
        owner, parent, seq, period, head, tWrite,
        MutationVersion(physicalMicros: 30, logical: 0, origin: 1))

      var reclaimedEverywhere = false
      for _ in 0 ..< 400:
        var complete = true
        for node in 0 ..< parsed.len:
          let metrics = client.metricsReq(node)
          complete = complete and
            metrics.metric("tombstones") == 0 and
            metrics.metric("tombstonesReclaimed") >= 1
        if complete:
          reclaimedEverywhere = true
          break
        sleep(50)
      check reclaimedEverywhere
    finally:
      client.close()
      for node in nodes.mitems:
        stopNode(node)
      removeDir(root)
