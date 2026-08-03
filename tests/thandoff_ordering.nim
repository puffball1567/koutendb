## Persistent handoff ordering integration test.
##
## Exercises the failure window where a destination restarts after accepting a
## delete but before an old source copy is retried.

import std/[os, osproc, tempfiles, times, unittest]
import ../src/kouten/wire

proc startNode(id: int, peers, dataDir: string): Process =
  let exe = getCurrentDir() / "src" / "koutend"
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

suite "persistent handoff mutation ordering":
  test "restart between delete and stale transfer does not resurrect data":
    let peers = getEnv("KOUTEN_TEST_PEERS",
      "127.0.0.1:17831,127.0.0.1:17832")
    let parsed = parsePeers(peers)
    check parsed.len == 2
    let root = createTempDir("koutendb", "handoff-ordering")
    let node0Dir = root / "node0"
    let node1Dir = root / "node1"
    var node0 = startNode(0, peers, node0Dir)
    var node1 = startNode(1, peers, node1Dir)
    var client = newClusterClient(parsed)
    try:
      check client.waitNode(0)
      check client.waitNode(1)

      let parent = 9101'u64
      let seq = 3'u32
      let period = 1_000_000_000.0
      let head = 0.1
      let tWrite = epochTime()
      let valueVersion =
        MutationVersion(physicalMicros: 10, logical: 0, origin: 1)
      let deleteVersion =
        MutationVersion(physicalMicros: 11, logical: 0, origin: 1)
      let recreateVersion =
        MutationVersion(physicalMicros: 12, logical: 0, origin: 2)

      client.transferReq(0, parent, seq, period, head, tWrite, "before-delete",
                         version = valueVersion)
      client.transferDeleteReq(0, parent, seq, period, head, tWrite,
                               deleteVersion)
      check not client.getReq(0, parent, seq, period, head, tWrite).found

      client.close()
      stopNode(node0)
      node0 = startNode(0, peers, node0Dir)
      client = newClusterClient(parsed)
      check client.waitNode(0)

      client.transferReq(0, parent, seq, period, head, tWrite,
                         "stale-after-restart", version = valueVersion)
      check not client.getReq(0, parent, seq, period, head, tWrite).found

      client.transferReq(0, parent, seq, period, head, tWrite,
                         "new-after-delete", version = recreateVersion)
      let recreated = client.getReq(0, parent, seq, period, head, tWrite)
      check recreated.found
      check recreated.value == "new-after-delete"
    finally:
      client.close()
      stopNode(node0)
      stopNode(node1)
      removeDir(root)
