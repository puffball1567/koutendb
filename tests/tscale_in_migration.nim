## Explicit scale-in integration lifecycle.

import std/[json, os, osproc, tables, tempfiles, unittest]
import ../src/kouten/[core, payload, scale_in, store, wire]

proc version(n: int64, origin: uint32): MutationVersion =
  MutationVersion(physicalMicros: n, logical: 0, origin: origin)

proc startNode(exe: string, id: int, peers, dataDir: string,
               placementEpoch: int): Process =
  startProcess(exe, args = [
    "--id=" & $id,
    "--peers=" & peers,
    "--data=" & dataDir,
    "--durability=strong",
    "--placement-epoch=" & $placementEpoch,
    "--virtual-arcs-per-node=64",
    "--galaxy=scale-in-test",
    "--slow-tick=1000"
  ], options = {poParentStreams})

proc stopNode(process: var Process) =
  if process == nil:
    return
  try:
    process.terminate()
    discard process.waitForExit(timeout = 5_000)
  except CatchableError:
    discard
  process.close()
  process = nil

proc waitNode(client: ClusterClient, node: int): bool =
  for _ in 0 ..< 100:
    try:
      discard client.healthReq(node)
      return true
    except CatchableError:
      sleep(50)
  false

suite "explicit physical placement scale-in":
  test "drained sources migrate resumably without losing metadata":
    let exe = getEnv("KOUTEN_TEST_SERVER")
    check exe.len > 0
    let root = createTempDir("koutendb", "scale-in")
    let oldTable = virtualArcTable(1, 3, 64)
    let targetTable = virtualArcTable(2, 2, 64)
    let targetPeers = "127.0.0.1:17961,127.0.0.1:17962"
    var targetNodes: array[2, Process]
    var firstBySource = initTable[int, Particle]()
    var expectedLive = 0
    var expectedTombstones = 0
    var firstTombstone: Tombstone
    var metadataRings: seq[uint64]
    var sourceWalSizes: array[3, BiggestInt]

    try:
      var sources: array[3, Store]
      for node in 0 ..< 3:
        sources[node] = openStore(root / ("source-" & $node),
                                  durability = durStrong,
                                  mutationOrigin = uint32(node + 1))
        sources[node].setGalaxy("scale-in-test")
        sources[node].configurePlacement(1, 3, 64)
      sources[0].putGalaxyDescription("scale-in migration fixture")

      for ringIndex in 0 ..< 24:
        let ring = uint64(10_000 + ringIndex)
        let owner = int(oldTable.placementOwner(ring))
        metadataRings.add ring
        sources[owner].putRingMeta(ring, 60.0 + float(ringIndex),
                                   float(ringIndex) / 10.0)
        sources[owner].putRingName(ring, "scale/ring-" & $ringIndex)
        sources[owner].putRingDescription(ring,
          "ring description " & $ringIndex)
        sources[owner].putRingPayloadProfile(ring, RingPayloadProfile(
          defaultCodec: pcJson, charset: "UTF-8", formatVersion: "1"))
        sources[owner].putTimeOrbitProfile(ring, TimeOrbitProfile(
          bits: 60, bucketMs: 60_000, phase: uint64(ringIndex),
          salt: "scale-in"))
        for seq in 0 ..< 8:
          let particle = Particle(
            parent: ring, seq: uint32(seq), period: 60.0 + float(ringIndex),
            head: float(ringIndex) / 10.0, tWrite: float(seq + 1),
            payload: $(%*{"ring": ringIndex, "seq": seq}),
            codec: pcJson, vec: @[float32(ringIndex), float32(seq)],
            version: version(int64(1_000_000 + ringIndex * 100 + seq),
                             uint32(owner + 1)))
          check sources[owner].upsert(particle, preserveVersion = true)
          if owner notin firstBySource:
            firstBySource[owner] = particle
          inc expectedLive

      for owner in 0 ..< 3:
        let base = firstBySource[owner]
        let tombstoneSeq = 1000'u32 + uint32(owner)
        let live = Particle(
          parent: base.parent, seq: tombstoneSeq, period: base.period,
          head: base.head, tWrite: 100.0 + float(owner),
          payload: "deleted-" & $owner,
          version: version(2_000_000 + int64(owner), uint32(owner + 1)))
        check sources[owner].upsert(live, preserveVersion = true)
        let tombstone = Tombstone(
          parent: live.parent, seq: live.seq, period: live.period,
          head: live.head, tWrite: live.tWrite,
          version: version(2_100_000 + int64(owner), uint32(owner + 1)))
        check sources[owner].applyTombstone(tombstone)
        if owner == 0:
          firstTombstone = tombstone
        inc expectedTombstones

      sources[0].putStellarMap(
        "scale/stellar",
        """{"stellar":"scale/stellar","members":["scale/ring-0","scale/ring-1"]}""")
      let forwardSource = firstBySource[0]
      let forwardTarget = firstBySource[1]
      sources[0].putForwarder(
        forwardSource.parent, forwardSource.seq,
        Forwarder(newParent: forwardTarget.parent, newSeq: forwardTarget.seq,
                  newTWrite: forwardTarget.tWrite, expiresAt: 9_999_999_999.0))

      for node in 0 ..< 3:
        sources[node].setMaintenanceDrained(true)
        sourceWalSizes[node] = sources[node].logSize
        sources[node].close()

      # A persistent source without a drain marker is never accepted.
      let unsafeDir = root / "unsafe-source"
      var unsafe = openStore(unsafeDir)
      unsafe.configurePlacement(1, 3, 64)
      unsafe.close()

      # All target peers must be reachable and report one settled epoch.
      targetNodes[0] = startNode(exe, 0, targetPeers, root / "target-0", 2)
      var client = newClusterClient(parsePeers(targetPeers),
                                    galaxy = "scale-in-test")
      check client.waitNode(0)
      var rejected = false
      try:
        discard planScaleIn(root / "source-0", client)
      except CatchableError:
        rejected = true
      check rejected
      client.close()

      targetNodes[1] = startNode(exe, 1, targetPeers, root / "target-1", 1)
      client = newClusterClient(parsePeers(targetPeers),
                                galaxy = "scale-in-test")
      check client.waitNode(1)
      expect ValueError:
        discard planScaleIn(root / "source-0", client)
      client.close()
      stopNode(targetNodes[1])

      targetNodes[1] = startNode(exe, 1, targetPeers, root / "target-1", 2)
      client = newClusterClient(parsePeers(targetPeers),
                                galaxy = "scale-in-test")
      check client.waitNode(0)
      check client.waitNode(1)
      expect ValueError:
        discard planScaleIn(unsafeDir, client)
      expect ValueError:
        discard migrateScaleIn(root / "source-0", client,
                               checkpointEvery = 0)
      expect ValueError:
        discard migrateScaleIn(root / "source-0", client,
                               maxTransfers = -1)
      expect ValueError:
        discard verifyScaleIn(root / "source-0", client,
                              retryLimit = -1)

      # Durable operational queues require their own explicit resolution.
      for queueKind in ["cluster-tx", "warp", "universe"]:
        let blockedDir = root / ("blocked-" & queueKind)
        var blocked = openStore(blockedDir, durability = durStrong)
        blocked.setGalaxy("scale-in-test")
        blocked.configurePlacement(1, 3, 64)
        case queueKind
        of "cluster-tx":
          blocked.putClusterTxIntent ClusterTxIntent(
            id: 77,
            ops: @[ClusterTxOp(
              kind: ctxPut, parent: 42, seq: 1, period: 60.0, head: 0.0,
              tWrite: 1.0, payload: "pending")],
            committed: true)
        of "warp":
          blocked.putWarpJob(77, """{"status":"pending"}""")
        of "universe":
          blocked.putUniverseSyncEvent(77, """{"status":"pending"}""")
        else:
          discard
        blocked.setMaintenanceDrained(true)
        blocked.close()
        expect ValueError:
          discard migrateScaleIn(blockedDir, client)

      let plan = planScaleIn(root / "source-0", client)
      check plan.sourceEpoch == 1
      check plan.sourceNodes == 3
      check plan.targetEpoch == 2
      check plan.targetNodes == 2
      check plan.records > 0
      check plan.metadataObjects > 0

      # Bound one invocation and resume from the durable checkpoint.
      let partial = migrateScaleIn(root / "source-0", client,
                                   checkpointEvery = 2,
                                   maxTransfers = 5)
      check not partial.complete
      check partial.recordsAcked == 5
      let checkpointPath = partial.checkpoint
      let checkpoint = loadScaleInCheckpoint(checkpointPath)
      check checkpoint.metadataTransferred
      check not checkpoint.complete

      # A missing target leaves the source and checkpoint unchanged.
      stopNode(targetNodes[1])
      let beforeOutage = loadScaleInCheckpoint(checkpointPath)
      var unavailable = newClusterClient(parsePeers(targetPeers),
                                         galaxy = "scale-in-test")
      rejected = false
      try:
        discard migrateScaleIn(root / "source-0", unavailable,
                               checkpointEvery = 2, retryLimit = 1,
                               retryDelayMs = 1)
      except CatchableError:
        rejected = true
      check rejected
      unavailable.close()
      let afterOutage = loadScaleInCheckpoint(checkpointPath)
      check afterOutage.recordsAcked == beforeOutage.recordsAcked
      check getFileSize((root / "source-0") / "kouten.log") ==
        sourceWalSizes[0]

      targetNodes[1] = startNode(exe, 1, targetPeers, root / "target-1", 2)
      client.close()
      client = newClusterClient(parsePeers(targetPeers),
                                galaxy = "scale-in-test")
      check client.waitNode(1)

      for source in 0 ..< 3:
        let migrated = migrateScaleIn(root / ("source-" & $source), client,
                                      checkpointEvery = 3)
        check migrated.complete
        check getFileSize((root / ("source-" & $source)) / "kouten.log") ==
          sourceWalSizes[source]

      # Re-running a completed source is idempotent and performs no data writes.
      let repeated = migrateScaleIn(root / "source-0", client)
      check repeated.complete
      check repeated.applied == 0
      check repeated.skipped == 0

      # A newer target mutation is accepted as AHEAD during verification.
      let older = firstBySource[0]
      var newer = older
      newer.payload = """{"newer":true}"""
      newer.version = version(9_000_000, 9)
      let newerOwner = int(targetTable.placementOwner(newer.parent))
      check client.transferStatusReq(
        newerOwner, newer.parent, newer.seq, newer.period, newer.head,
        newer.tWrite, newer.payload, newer.vec, newer.codec, newer.version,
        expectedPlacementEpoch = 2, expectedPlacementNodes = 2,
        expectedVirtualArcs = 64) == "APPLIED"

      var verifiedTotal = 0
      var sawAhead = false
      for source in 0 ..< 3:
        let verified = verifyScaleIn(root / ("source-" & $source), client)
        verifiedTotal += verified.records
        sawAhead = sawAhead or verified.ahead > 0
        check verified.metadataObjects > 0
        check verified.records + verified.tombstones ==
          loadScaleInCheckpoint(
            defaultScaleInCheckpointPath(root / ("source-" & $source), 2)
          ).recordsAcked +
          loadScaleInCheckpoint(
            defaultScaleInCheckpointPath(root / ("source-" & $source), 2)
          ).tombstonesAcked
      check verifiedTotal == expectedLive
      check sawAhead

      # Verification distinguishes missing, behind, and wrong-kind mutations.
      expect IOError:
        discard client.migrationVerifyReq(
          0, 999_999, 1, version(99, 1), false)
      expect IOError:
        discard client.migrationVerifyReq(
          newerOwner, newer.parent, newer.seq, version(10_000_000, 9), false)
      let tombstoneOwner =
        int(targetTable.placementOwner(firstTombstone.parent))
      expect IOError:
        discard client.migrationVerifyReq(
          tombstoneOwner, firstTombstone.parent, firstTombstone.seq,
          firstTombstone.version, false)

      # A rejected body-carrying frame is drained before the next command.
      expect IOError:
        client.migrationMetadataReq(
          0, """{"kind":"global"}""", 3, 2, 64)
      check client.healthReq(0).len > 0
      expect IOError:
        client.migrationMetadataReq(0, "{", 2, 2, 64)
      check client.healthReq(0).len > 0

      # Metadata verification is independent and never marks a failed
      # checkpoint as verified.
      var source0Checkpoint = loadScaleInCheckpoint(checkpointPath)
      source0Checkpoint.verified = false
      saveScaleInCheckpoint(checkpointPath, source0Checkpoint)
      client.migrationMetadataReq(0, $(%*{
        "kind": "global",
        "galaxy": "scale-in-test",
        "description": "unexpected"
      }), 2, 2, 64)
      expect IOError:
        discard verifyScaleIn(root / "source-0", client, retryLimit = 0)
      check not loadScaleInCheckpoint(checkpointPath).verified
      client.migrationMetadataReq(0, $(%*{
        "kind": "global",
        "galaxy": "scale-in-test",
        "description": "scale-in migration fixture"
      }), 2, 2, 64)
      discard verifyScaleIn(root / "source-0", client)

      # Checkpoint/source fingerprint mismatches are rejected.
      var altered = loadScaleInCheckpoint(checkpointPath)
      inc altered.sourceWalBytes
      saveScaleInCheckpoint(checkpointPath, altered)
      expect ValueError:
        discard verifyScaleIn(root / "source-0", client)
      dec altered.sourceWalBytes
      saveScaleInCheckpoint(checkpointPath, altered)
      discard verifyScaleIn(root / "source-0", client)
      inc altered.recordsAcked
      saveScaleInCheckpoint(checkpointPath, altered)
      expect ValueError:
        discard verifyScaleIn(root / "source-0", client)
      dec altered.recordsAcked
      saveScaleInCheckpoint(checkpointPath, altered)
      discard verifyScaleIn(root / "source-0", client)
      let malformedCheckpoint = root / "malformed-checkpoint.json"
      writeFile(malformedCheckpoint, "{}")
      expect ValueError:
        discard loadScaleInCheckpoint(malformedCheckpoint)
      client.close()

      stopNode(targetNodes[0])
      stopNode(targetNodes[1])

      var targetStores: array[2, Store]
      for node in 0 ..< 2:
        targetStores[node] = openStore(root / ("target-" & $node))
        check targetStores[node].galaxy == "scale-in-test"
        check targetStores[node].galaxyDescription ==
          "scale-in migration fixture"
        check "scale/stellar" in targetStores[node].stellarMaps

      var liveCount = 0
      var tombstoneCount = 0
      for node in 0 ..< 2:
        liveCount += targetStores[node].count
        tombstoneCount += targetStores[node].tombstones.len
      check liveCount == expectedLive
      check tombstoneCount >= expectedTombstones

      for ring in metadataRings:
        let owner = int(targetTable.placementOwner(ring))
        check ring in targetStores[owner].ringMeta
        check ring in targetStores[owner].ringNames
        check ring in targetStores[owner].ringDescriptions
        check ring in targetStores[owner].ringPayloadProfiles
        check ring in targetStores[owner].ringTimeOrbitProfiles
      let forwardOwner =
        int(targetTable.placementOwner(forwardSource.parent))
      check (forwardSource.parent, forwardSource.seq) in
        targetStores[forwardOwner].forwarders

      for store in targetStores.mitems:
        store.close()
    finally:
      for process in targetNodes.mitems:
        stopNode(process)
      if dirExists(root):
        removeDir(root)
