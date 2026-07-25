## Driver-facing wire protocol smoke test.
##
## Starts a small local koutend cluster and verifies that drivers can use
## ring names without knowing ringKey/period/head derivation rules.

import std/[net, os, osproc, strutils, times, unittest]
import ../src/kouten/[core, wire]

proc startNode(id: int, peers: string): Process =
  let exe = getCurrentDir() / "src" / "koutend"
  startProcess(exe, args = ["--id=" & $id, "--peers=" & peers,
                            "--slow-tick=1000"],
               options = {poParentStreams})

proc waitCluster(c: ClusterClient, n: int): bool =
  for _ in 0 ..< 50:
    var ok = true
    for node in 0 ..< n:
      try:
        discard c.healthReq(node)
      except CatchableError:
        ok = false
    if ok:
      return true
    sleep(100)
  false

suite "driver wire protocol":
  test "PUTR/GETID/QRYID hide ring internals from external drivers":
    let peers = getEnv("KOUTEN_TEST_PEERS", "127.0.0.1:17631,127.0.0.1:17632")
    let ps = parsePeers(peers)
    check ps.len == 2

    var procs: seq[Process] = @[]
    for i in 0 ..< ps.len:
      procs.add startNode(i, peers)

    var c = newClusterClient(ps)
    try:
      check c.waitCluster(ps.len)
      check c.codecsReq(0) == @[pcRaw, pcJson, pcNif, pcBif]

      let first = c.putRingReq(0, "japan/tokyo",
                               """{"title":"Tokyo","country":"JP"}""",
                               @[1.0'f32, 0.0'f32], pcJson)
      let tbl = c.topologyReq(0)
      check tbl.epoch == first.epoch
      let owner = int(tbl.placementOwner(first.parent))
      let nonOwner = (owner + 1) mod ps.len

      var fencedParent = 1'u64
      while tbl.placementOwner(fencedParent) != 0'u16:
        inc fencedParent
      let fencedVersion =
        MutationVersion(physicalMicros: 1, logical: 0, origin: 1)
      expect IOError:
        c.transferReq(0, fencedParent, 0, 60.0, 0.0, epochTime(),
                      "wrong-topology", version = fencedVersion,
                      expectedPlacementEpoch = tbl.epoch + 1,
                      expectedPlacementNodes = tbl.nNodes,
                      expectedVirtualArcs = tbl.arcs.len div int(tbl.nNodes))
      check not c.getReq(0, fencedParent, 0, 60.0, 0.0, 0.0).found
      c.transferReq(0, fencedParent, 0, 60.0, 0.0, epochTime(),
                    "correct-topology", version = fencedVersion,
                    expectedPlacementEpoch = tbl.epoch,
                    expectedPlacementNodes = tbl.nNodes,
                    expectedVirtualArcs = tbl.arcs.len div int(tbl.nNodes))
      check c.getReq(0, fencedParent, 0, 60.0, 0.0, 0.0).value ==
        "correct-topology"

      let id = c.putRingReq(nonOwner, "japan/tokyo",
                            """{"title":"Shinjuku","country":"JP"}""",
                            @[0.95'f32, 0.05'f32], pcJson)
      check int(tbl.placementOwner(id.parent)) == owner

      let got = c.getIdReq(nonOwner, id)
      check got.found
      check got.value == """{"title":"Shinjuku","country":"JP"}"""
      check got.codec == pcJson

      # A non-owner may hold a handoff copy, but reads must still follow current
      # ownership instead of returning a potentially stale local value.
      let currentOwner = int(tbl.placementOwner(id.parent))
      let calculatedNonOwner = (currentOwner + 1) mod ps.len
      let routed = c.getIdReq(calculatedNonOwner, id)
      check routed.found
      check routed.value == """{"title":"Shinjuku","country":"JP"}"""

      var legacy = newSocket()
      legacy.connect(ps[owner].host, Port(ps[owner].port))
      legacy.sendFrame("GETID " & $id.parent & " " & $id.epoch & " " &
                       $id.seq & " " & $id.tWrite & " " & $id.period & " " &
                       $id.head)
      let legacyHeader = legacy.readHeader()
      check legacyHeader.len == 3
      check legacyHeader[0] == "VAL"
      discard legacy.readExact(parseInt(legacyHeader[2]))
      legacy.close()

      let projected = c.queryIdReq(nonOwner, id, "{ title }")
      check projected.found
      check projected.value == """{"title":"Shinjuku"}"""
      check projected.codec == pcJson

      # Repeated projections exercise the server's bounded compiled-selection cache.
      let projectedAgain = c.queryIdReq(owner, id, "{ title }")
      check projectedAgain.value == projected.value

      # Destination-side mutation ordering is authoritative. Delayed and
      # duplicate handoff frames must not overwrite newer state or resurrect a
      # value after a transferred tombstone.
      let orderedParent = 9001'u64
      let orderedSeq = 7'u32
      let orderedPeriod = 3600.0
      let orderedHead = 0.1
      let orderedTWrite = epochTime()
      let v1 = MutationVersion(physicalMicros: 1, logical: 0, origin: 1)
      let v2 = MutationVersion(physicalMicros: 2, logical: 0, origin: 1)
      let v3 = MutationVersion(physicalMicros: 3, logical: 0, origin: 1)
      let v4 = MutationVersion(physicalMicros: 4, logical: 0, origin: 1)
      c.transferReq(0, orderedParent, orderedSeq, orderedPeriod, orderedHead,
                    orderedTWrite, "v2", version = v2)
      c.transferReq(0, orderedParent, orderedSeq, orderedPeriod, orderedHead,
                    orderedTWrite, "v1-stale", version = v1)
      check c.getReq(0, orderedParent, orderedSeq, orderedPeriod, orderedHead,
                     orderedTWrite).value == "v2"
      c.transferDeleteReq(0, orderedParent, orderedSeq, orderedPeriod,
                          orderedHead, orderedTWrite, v3)
      check not c.getReq(0, orderedParent, orderedSeq, orderedPeriod,
                         orderedHead, orderedTWrite).found
      c.transferReq(0, orderedParent, orderedSeq, orderedPeriod, orderedHead,
                    orderedTWrite, "v2-resurrect", version = v2)
      check not c.getReq(0, orderedParent, orderedSeq, orderedPeriod,
                         orderedHead, orderedTWrite).found
      c.transferReq(0, orderedParent, orderedSeq, orderedPeriod, orderedHead,
                    orderedTWrite, "v4", version = v4)
      check c.getReq(0, orderedParent, orderedSeq, orderedPeriod, orderedHead,
                     orderedTWrite).value == "v4"

      let bif = c.putRingReq(0, "japan/tokyo", "\x01\x00\x00\x00", @[], pcBif)
      let bifGot = c.getIdReq(0, bif)
      check bifGot.found
      check bifGot.codec == pcBif
      expect ValueError:
        discard c.queryIdReq(0, bif, "{ title }")
    finally:
      c.close()
      for p in procs:
        try:
          p.terminate()
          discard p.waitForExit(timeout = 2_000)
        except CatchableError:
          discard
        p.close()
