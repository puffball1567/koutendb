## Regression coverage for TCP reads from a disk-backed server. Payloads are
## intentionally absent from Store.items in this mode, so every wire read must
## use the Store read boundary rather than the in-memory table directly.

import std/[os, osproc, tempfiles, unittest]
import ../src/kouten/[payload, wire]

proc startNode(exe, peers, dataDir: string): Process =
  startProcess(exe, args = [
    "--id=0", "--peers=" & peers, "--data=" & dataDir,
    "--disk-backed", "--durability=strong", "--slow-tick=0.05"
  ], options = {poParentStreams})

proc stopNode(process: var Process) =
  if process.isNil:
    return
  try:
    process.terminate()
    discard process.waitForExit(timeout = 3_000)
  except CatchableError:
    discard
  process.close()
  process = nil

proc waitNode(client: ClusterClient): bool =
  for _ in 0 ..< 100:
    try:
      discard client.healthReq(0)
      return true
    except CatchableError:
      sleep(50)
  false

proc assertReadContracts(client: ClusterClient; id: WireId; payload: string) =
  let byId = client.getIdReq(0, id)
  check byId.found
  check byId.value == payload
  check byId.codec == pcJson

  let projected = client.queryIdReq(0, id, "{ name }")
  check projected.found
  check projected.value == "{\"name\":\"alpha\"}"

  let legacy = client.getReq(0, id.parent, id.seq, id.period, id.head,
                             id.tWrite)
  check legacy.found
  check legacy.value == payload
  check legacy.codec == pcJson

  let batch = client.batchGetReq(0, @[
    (parent: id.parent, seq: id.seq, period: id.period,
     head: id.head, tWrite: id.tWrite)
  ])
  check batch == @[payload]

suite "disk-backed cluster wire reads":
  test "point, projected, legacy, and batch reads survive restart":
    let port = getEnv("KOUTEN_DISK_READ_PORT", "18841")
    let peers = "127.0.0.1:" & port
    let root = createTempDir("koutendb", "cluster-disk-reads")
    let exe = getEnv("KOUTEN_TEST_KOUTEND", getCurrentDir() / "src" / "koutend")
    let payload = "{\"name\":\"alpha\",\"revision\":1}"
    var node = startNode(exe, peers, root / "node0")
    var client = newClusterClient(parsePeers(peers))
    try:
      check client.waitNode()
      let id = client.putRingReq(0, "users/alpha", payload,
                                 codec = pcJson)
      client.assertReadContracts(id, payload)

      client.close()
      stopNode(node)
      node = startNode(exe, peers, root / "node0")
      client = newClusterClient(parsePeers(peers))
      check client.waitNode()
      client.assertReadContracts(id, payload)
    finally:
      client.close()
      stopNode(node)
      removeDir(root)
