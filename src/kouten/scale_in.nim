## Explicit, stop-the-world physical placement scale-in.
##
## This module intentionally does not provide live membership changes. It
## copies an immutable, persistently drained source directory into a smaller,
## already-running target topology. Source data remains untouched.

import std/[algorithm, json, os, tables, times]
when not defined(windows):
  import std/posix
import ./[core, store, wire]

when not defined(windows):
  proc cRename(oldname, newname: cstring): cint {.importc: "rename",
      header: "<stdio.h>".}

const
  ScaleInCheckpointFormat* = "koutendb.scale-in.v1"
  DefaultScaleInCheckpointEvery* = 1_000
  DefaultScaleInRetryLimit* = 8
  DefaultScaleInRetryDelayMs* = 100

type
  ScaleInPlan* = object
    sourceEpoch*: uint32
    sourceNodes*: uint16
    sourceVirtualArcs*: int
    targetEpoch*: uint32
    targetNodes*: uint16
    targetVirtualArcs*: int
    records*: int
    tombstones*: int
    metadataObjects*: int
    recordsByTarget*: seq[int]
    tombstonesByTarget*: seq[int]

  ScaleInCheckpoint* = object
    format*: string
    sourceWalBytes*: BiggestInt
    sourceWalModified*: int64
    sourceItems*: int
    sourceTombstones*: int
    sourceEpoch*: uint32
    sourceNodes*: uint16
    sourceVirtualArcs*: int
    targetPeers*: string
    targetEpoch*: uint32
    targetNodes*: uint16
    targetVirtualArcs*: int
    phase*: string
    ringIndex*: int
    itemIndex*: int
    tombstoneIndex*: int
    recordsAcked*: int
    tombstonesAcked*: int
    metadataTransferred*: bool
    complete*: bool
    verified*: bool

  ScaleInRunStats* = object
    recordsAcked*: int
    tombstonesAcked*: int
    applied*: int
    skipped*: int
    retries*: int
    metadataObjects*: int
    resumed*: bool
    complete*: bool
    checkpoint*: string

  ScaleInVerifyStats* = object
    records*: int
    tombstones*: int
    metadataObjects*: int
    matching*: int
    ahead*: int
    retries*: int
    checkpoint*: string

proc targetVirtualArcs(tbl: ArcTable): int =
  if tbl.nNodes == 0 or tbl.arcs.len == 0 or
      tbl.arcs.len mod int(tbl.nNodes) != 0:
    raise newException(ValueError,
      "target topology has an invalid virtual-arc table")
  tbl.arcs.len div int(tbl.nNodes)

proc sameTopology(a, b: ArcTable): bool =
  a.epoch == b.epoch and a.nNodes == b.nNodes and
    a.targetVirtualArcs == b.targetVirtualArcs

proc discoverScaleInTarget*(client: ClusterClient): ArcTable =
  if client.peers.len == 0:
    raise newException(ValueError, "scale-in target peers are required")
  result = client.topologyReq(0)
  if int(result.nNodes) != client.peers.len:
    raise newException(ValueError,
      "target topology node count does not match target peer count")
  for node in 1 ..< client.peers.len:
    let candidate = client.topologyReq(node)
    if not candidate.sameTopology(result):
      raise newException(ValueError,
        "target peers do not report one settled placement topology")

proc targetPeerSignature(client: ClusterClient): string =
  for i, peer in client.peers:
    if i > 0:
      result.add ","
    result.add peer.host & ":" & $peer.port

proc sourceWalPath(dataDir: string): string =
  dataDir / "kouten.log"

proc sourceWalModified(dataDir: string): int64 =
  let path = dataDir.sourceWalPath
  if not fileExists(path):
    return 0
  getLastModificationTime(path).toUnix

proc syncCheckpointDir(path: string) =
  when not defined(windows):
    let directory =
      if parentDir(path).len == 0: "."
      else: parentDir(path)
    let fd = posix.open(directory.cstring, posix.O_RDONLY)
    if fd < 0:
      raiseOSError(osLastError())
    try:
      if posix.fsync(fd) != 0:
        raiseOSError(osLastError())
    finally:
      discard posix.close(fd)

proc defaultScaleInCheckpointPath*(dataDir: string,
                                   targetEpoch: uint32): string =
  dataDir / ("kouten.scale-in." & $targetEpoch & ".json")

proc validateScaleInBoundary(source: Store, target: ArcTable,
                             targetPeerCount: int) =
  if not source.isPersistent:
    raise newException(ValueError,
      "scale-in requires a persistent source data directory")
  if not source.maintenanceDrained:
    raise newException(ValueError,
      "scale-in source is not persistently drained")
  if source.placementEpoch == 0 or source.placementNodes == 0 or
      source.placementVirtualArcs <= 0:
    raise newException(ValueError,
      "scale-in source has no valid persisted placement topology")
  if target.epoch <= source.placementEpoch:
    raise newException(ValueError,
      "scale-in target epoch must be greater than the source epoch")
  if target.nNodes >= source.placementNodes:
    raise newException(ValueError,
      "scale-in target must contain fewer placement nodes than the source")
  if int(target.nNodes) != targetPeerCount:
    raise newException(ValueError,
      "scale-in target topology does not match the target peer count")
  discard target.targetVirtualArcs

proc checkpointJson(checkpoint: ScaleInCheckpoint): JsonNode =
  %*{
    "format": checkpoint.format,
    "sourceWalBytes": checkpoint.sourceWalBytes,
    "sourceWalModified": checkpoint.sourceWalModified,
    "sourceItems": checkpoint.sourceItems,
    "sourceTombstones": checkpoint.sourceTombstones,
    "sourceEpoch": checkpoint.sourceEpoch,
    "sourceNodes": checkpoint.sourceNodes,
    "sourceVirtualArcs": checkpoint.sourceVirtualArcs,
    "targetPeers": checkpoint.targetPeers,
    "targetEpoch": checkpoint.targetEpoch,
    "targetNodes": checkpoint.targetNodes,
    "targetVirtualArcs": checkpoint.targetVirtualArcs,
    "phase": checkpoint.phase,
    "ringIndex": checkpoint.ringIndex,
    "itemIndex": checkpoint.itemIndex,
    "tombstoneIndex": checkpoint.tombstoneIndex,
    "recordsAcked": checkpoint.recordsAcked,
    "tombstonesAcked": checkpoint.tombstonesAcked,
    "metadataTransferred": checkpoint.metadataTransferred,
    "complete": checkpoint.complete,
    "verified": checkpoint.verified
  }

proc saveScaleInCheckpoint*(path: string, checkpoint: ScaleInCheckpoint) =
  if path.len == 0:
    raise newException(ValueError, "scale-in checkpoint path is empty")
  let parent = parentDir(path)
  if parent.len > 0:
    createDir(parent)
  let tmp = path & ".tmp"
  var file = open(tmp, fmWrite)
  try:
    file.write($checkpoint.checkpointJson)
    file.write("\n")
    file.flushFile()
    when not defined(windows):
      if posix.fsync(cint(file.getFileHandle())) != 0:
        raiseOSError(osLastError())
  finally:
    file.close()
  when defined(windows):
    if fileExists(path):
      removeFile(path)
    moveFile(tmp, path)
  else:
    if cRename(tmp.cstring, path.cstring) != 0:
      raiseOSError(osLastError())
    path.syncCheckpointDir()

proc loadScaleInCheckpoint*(path: string): ScaleInCheckpoint =
  if not fileExists(path):
    raise newException(IOError, "scale-in checkpoint not found: " & path)
  let node = parseFile(path)
  if node.kind != JObject or
      node{"format"}.getStr() != ScaleInCheckpointFormat:
    raise newException(ValueError, "invalid scale-in checkpoint format")
  result = ScaleInCheckpoint(
    format: node["format"].getStr(),
    sourceWalBytes: node{"sourceWalBytes"}.getBiggestInt(),
    sourceWalModified: node{"sourceWalModified"}.getBiggestInt().int64,
    sourceItems: node{"sourceItems"}.getInt(),
    sourceTombstones: node{"sourceTombstones"}.getInt(),
    sourceEpoch: node{"sourceEpoch"}.getBiggestInt().uint32,
    sourceNodes: node{"sourceNodes"}.getBiggestInt().uint16,
    sourceVirtualArcs: node{"sourceVirtualArcs"}.getInt(),
    targetPeers: node{"targetPeers"}.getStr(),
    targetEpoch: node{"targetEpoch"}.getBiggestInt().uint32,
    targetNodes: node{"targetNodes"}.getBiggestInt().uint16,
    targetVirtualArcs: node{"targetVirtualArcs"}.getInt(),
    phase: node{"phase"}.getStr(),
    ringIndex: node{"ringIndex"}.getInt(),
    itemIndex: node{"itemIndex"}.getInt(),
    tombstoneIndex: node{"tombstoneIndex"}.getInt(),
    recordsAcked: node{"recordsAcked"}.getInt(),
    tombstonesAcked: node{"tombstonesAcked"}.getInt(),
    metadataTransferred: node{"metadataTransferred"}.getBool(),
    complete: node{"complete"}.getBool(),
    verified: node{"verified"}.getBool())
  if result.sourceWalBytes < 0 or result.sourceWalModified < 0 or
      result.sourceItems < 0 or result.sourceTombstones < 0 or
      result.sourceEpoch == 0 or result.sourceNodes == 0 or
      result.sourceVirtualArcs <= 0 or result.targetEpoch == 0 or
      result.targetNodes == 0 or result.targetVirtualArcs <= 0 or
      result.ringIndex < 0 or result.itemIndex < 0 or
      result.tombstoneIndex < 0 or result.recordsAcked < 0 or
      result.tombstonesAcked < 0 or
      result.phase notin ["records", "tombstones", "complete"]:
    raise newException(ValueError, "invalid scale-in checkpoint values")

proc freshCheckpoint(source: Store, dataDir: string, target: ArcTable,
                     peers: string): ScaleInCheckpoint =
  ScaleInCheckpoint(
    format: ScaleInCheckpointFormat,
    sourceWalBytes: source.logSize,
    sourceWalModified: dataDir.sourceWalModified,
    sourceItems: source.count,
    sourceTombstones: source.tombstones.len,
    sourceEpoch: source.placementEpoch,
    sourceNodes: source.placementNodes,
    sourceVirtualArcs: source.placementVirtualArcs,
    targetPeers: peers,
    targetEpoch: target.epoch,
    targetNodes: target.nNodes,
    targetVirtualArcs: target.targetVirtualArcs,
    phase: "records")

proc sortedRings(source: Store): seq[uint64]
proc sortedTombstones(source: Store): seq[(uint64, uint32)]

proc validateCheckpoint(checkpoint: ScaleInCheckpoint, source: Store,
                        dataDir: string, target: ArcTable, peers: string) =
  let expected = source.freshCheckpoint(dataDir, target, peers)
  if checkpoint.sourceWalBytes != expected.sourceWalBytes or
      checkpoint.sourceWalModified != expected.sourceWalModified or
      checkpoint.sourceItems != expected.sourceItems or
      checkpoint.sourceTombstones != expected.sourceTombstones or
      checkpoint.sourceEpoch != expected.sourceEpoch or
      checkpoint.sourceNodes != expected.sourceNodes or
      checkpoint.sourceVirtualArcs != expected.sourceVirtualArcs:
    raise newException(ValueError,
      "scale-in source changed since the checkpoint was created")
  if checkpoint.targetPeers != expected.targetPeers or
      checkpoint.targetEpoch != expected.targetEpoch or
      checkpoint.targetNodes != expected.targetNodes or
      checkpoint.targetVirtualArcs != expected.targetVirtualArcs:
    raise newException(ValueError,
      "scale-in target differs from the checkpoint")
  let rings = source.sortedRings
  let tombstones = source.sortedTombstones
  if checkpoint.ringIndex > rings.len or
      checkpoint.tombstoneIndex > tombstones.len:
    raise newException(ValueError,
      "scale-in checkpoint progress is outside the source")
  var expectedRecordsAcked = 0
  for ringIndex in 0 ..< min(checkpoint.ringIndex, rings.len):
    for key in source.itemsByRing.getOrDefault(rings[ringIndex], @[]):
      if source.contains(key[0], key[1]):
        inc expectedRecordsAcked
  if checkpoint.ringIndex < rings.len:
    let keys = source.itemsByRing.getOrDefault(rings[checkpoint.ringIndex], @[])
    if checkpoint.itemIndex > keys.len:
      raise newException(ValueError,
        "scale-in checkpoint item progress is outside the source ring")
    for itemIndex in 0 ..< checkpoint.itemIndex:
      let key = keys[itemIndex]
      if source.contains(key[0], key[1]):
        inc expectedRecordsAcked
  elif checkpoint.itemIndex != 0:
    raise newException(ValueError,
      "scale-in checkpoint has item progress after the final ring")
  if checkpoint.recordsAcked != expectedRecordsAcked:
    raise newException(ValueError,
      "scale-in checkpoint record progress does not match the source")
  if checkpoint.phase == "records":
    if checkpoint.tombstoneIndex != 0 or checkpoint.tombstonesAcked != 0:
      raise newException(ValueError,
        "scale-in checkpoint entered tombstones before records completed")
  else:
    if checkpoint.ringIndex != rings.len or
        checkpoint.recordsAcked != source.count or
        checkpoint.tombstonesAcked != checkpoint.tombstoneIndex:
      raise newException(ValueError,
        "scale-in checkpoint phase progress is inconsistent")
  if checkpoint.complete != (checkpoint.phase == "complete") or
      (checkpoint.phase == "complete" and
       checkpoint.tombstoneIndex != tombstones.len) or
      (checkpoint.verified and not checkpoint.complete) or
      ((checkpoint.recordsAcked > 0 or checkpoint.tombstonesAcked > 0 or
        checkpoint.phase != "records") and not checkpoint.metadataTransferred):
    raise newException(ValueError,
      "scale-in checkpoint completion state is inconsistent")

proc sortedRings(source: Store): seq[uint64] =
  for ring in source.itemsByRing.keys:
    result.add ring
  result.sort()

proc sortedTombstones(source: Store): seq[(uint64, uint32)] =
  for key in source.tombstones.keys:
    result.add key
  result.sort(proc(a, b: (uint64, uint32)): int =
    result = cmp(a[0], b[0])
    if result == 0:
      result = cmp(a[1], b[1]))

proc sortedMetadataRings(source: Store): seq[uint64] =
  var seen = initTable[uint64, bool]()
  for ring in source.ringMeta.keys: seen[ring] = true
  for ring in source.ringNames.keys: seen[ring] = true
  for ring in source.ringDescriptions.keys: seen[ring] = true
  for ring in source.ringPayloadProfiles.keys: seen[ring] = true
  for ring in source.ringTimeOrbitProfiles.keys: seen[ring] = true
  for ring in seen.keys:
    if ring notin source.ringMeta:
      raise newException(ValueError,
        "ring metadata is incomplete for ring " & $ring)
    result.add ring
  result.sort()

proc sortedStellarNames(source: Store): seq[string] =
  for stellar in source.stellarMaps.keys:
    result.add stellar
  result.sort()

proc sortedForwarders(source: Store): seq[(uint64, uint32)] =
  for key in source.forwarders.keys:
    result.add key
  result.sort(proc(a, b: (uint64, uint32)): int =
    result = cmp(a[0], b[0])
    if result == 0:
      result = cmp(a[1], b[1]))

proc ringMetadataJson(source: Store, ring: uint64): string =
  let meta = source.ringMeta[ring]
  var node = %*{
    "kind": "ring",
    "key": $ring,
    "period": meta.period,
    "head": meta.head,
    "name": source.ringNames.getOrDefault(ring, ""),
    "description": source.ringDescriptions.getOrDefault(ring, "")
  }
  if ring in source.ringPayloadProfiles:
    let profile = source.ringPayloadProfiles[ring]
    node["payloadProfile"] = %*{
      "defaultCodec": profile.defaultCodec.payloadCodecName,
      "charset": profile.charset,
      "formatVersion": profile.formatVersion
    }
  if ring in source.ringTimeOrbitProfiles:
    let profile = source.ringTimeOrbitProfiles[ring]
    node["timeOrbitProfile"] = %*{
      "bits": profile.bits,
      "bucketMs": profile.bucketMs,
      "phase": $profile.phase,
      "salt": profile.salt
    }
  $node

proc retryDelay(baseMs, attempt: int): int =
  if baseMs <= 0:
    return 0
  baseMs * (1 shl min(attempt, 5))

proc sendMetadata(client: ClusterClient, target: ArcTable, node: int,
                  metadata: string, retryLimit, retryDelayMs: int,
                  retries: var int) =
  for attempt in 0 .. retryLimit:
    try:
      client.migrationMetadataReq(
        node, metadata, target.epoch, target.nNodes,
        target.targetVirtualArcs)
      return
    except CatchableError:
      if attempt >= retryLimit:
        raise
      inc retries
      sleep(retryDelay(retryDelayMs, attempt))

proc migrateMetadata(source: Store, client: ClusterClient, target: ArcTable,
                     retryLimit, retryDelayMs: int,
                     retries: var int): int =
  let globalMetadata = $(%*{
    "kind": "global",
    "galaxy": source.galaxy,
    "description": source.galaxyDescription
  })
  for node in 0 ..< int(target.nNodes):
    client.sendMetadata(target, node, globalMetadata, retryLimit,
                        retryDelayMs, retries)
    inc result
  for ring in source.sortedMetadataRings:
    client.sendMetadata(
      target, int(target.placementOwner(ring)),
      source.ringMetadataJson(ring), retryLimit, retryDelayMs, retries)
    inc result
  for stellar in source.sortedStellarNames:
    let metadata = $(%*{
      "kind": "stellar",
      "stellar": stellar,
      "blob": source.stellarMaps[stellar]
    })
    for node in 0 ..< int(target.nNodes):
      client.sendMetadata(target, node, metadata, retryLimit,
                          retryDelayMs, retries)
      inc result
  for key in source.sortedForwarders:
    let forwarder = source.forwarders[key]
    let metadata = $(%*{
      "kind": "forwarder",
      "oldParent": $key[0],
      "oldSeq": key[1],
      "newParent": $forwarder.newParent,
      "newSeq": forwarder.newSeq,
      "newTWrite": forwarder.newTWrite,
      "expiresAt": forwarder.expiresAt
    })
    client.sendMetadata(
      target, int(target.placementOwner(key[0])), metadata, retryLimit,
      retryDelayMs, retries)
    inc result

proc planScaleIn*(dataDir: string, client: ClusterClient): ScaleInPlan =
  if dataDir.len == 0:
    raise newException(ValueError, "scale-in source data directory is required")
  var source = openStore(dataDir)
  try:
    let target = client.discoverScaleInTarget()
    source.validateScaleInBoundary(target, client.peers.len)
    result = ScaleInPlan(
      sourceEpoch: source.placementEpoch,
      sourceNodes: source.placementNodes,
      sourceVirtualArcs: source.placementVirtualArcs,
      targetEpoch: target.epoch,
      targetNodes: target.nNodes,
      targetVirtualArcs: target.targetVirtualArcs,
      recordsByTarget: newSeq[int](int(target.nNodes)),
      tombstonesByTarget: newSeq[int](int(target.nNodes)))
    for ring, keys in source.itemsByRing:
      let owner = int(target.placementOwner(ring))
      for key in keys:
        if source.contains(key[0], key[1]):
          inc result.records
          inc result.recordsByTarget[owner]
    for key in source.tombstones.keys:
      inc result.tombstones
      inc result.tombstonesByTarget[int(target.placementOwner(key[0]))]
    result.metadataObjects =
      int(target.nNodes) + source.sortedMetadataRings.len +
      source.sortedStellarNames.len * int(target.nNodes) +
      source.forwarders.len
  finally:
    source.close()

proc transferParticle(client: ClusterClient, target: ArcTable, p: Particle,
                      retryLimit, retryDelayMs: int,
                      retries: var int): string =
  let owner = int(target.placementOwner(p.parent))
  for attempt in 0 .. retryLimit:
    try:
      return client.transferStatusReq(
        owner, p.parent, p.seq, p.period, p.head, p.tWrite, p.payload, p.vec,
        p.codec, p.version, expectedPlacementEpoch = target.epoch,
        expectedPlacementNodes = target.nNodes,
        expectedVirtualArcs = target.targetVirtualArcs,
        maintenanceMigration = true)
    except CatchableError:
      if attempt >= retryLimit:
        raise
      inc retries
      sleep(retryDelay(retryDelayMs, attempt))

proc transferTombstone(client: ClusterClient, target: ArcTable,
                       tombstone: Tombstone, retryLimit, retryDelayMs: int,
                       retries: var int): string =
  let owner = int(target.placementOwner(tombstone.parent))
  for attempt in 0 .. retryLimit:
    try:
      # Acknowledgements belong to the old topology. The target rebuilds its
      # own acknowledgement set and reclamation deadline.
      return client.transferDeleteStatusReq(
        owner, tombstone.parent, tombstone.seq, tombstone.period,
        tombstone.head, tombstone.tWrite, tombstone.version,
        acknowledgedNodes = @[], reclaimAfter = 0.0,
        expectedPlacementEpoch = target.epoch,
        expectedPlacementNodes = target.nNodes,
        expectedVirtualArcs = target.targetVirtualArcs,
        maintenanceMigration = true)
    except CatchableError:
      if attempt >= retryLimit:
        raise
      inc retries
      sleep(retryDelay(retryDelayMs, attempt))

proc migrateScaleIn*(dataDir: string, client: ClusterClient,
                     checkpointPath = "", checkpointEvery =
                       DefaultScaleInCheckpointEvery,
                     retryLimit = DefaultScaleInRetryLimit,
                     retryDelayMs = DefaultScaleInRetryDelayMs,
                     resetCheckpoint = false,
                     maxTransfers = 0): ScaleInRunStats =
  if dataDir.len == 0:
    raise newException(ValueError, "scale-in source data directory is required")
  if checkpointEvery <= 0:
    raise newException(ValueError, "checkpointEvery must be positive")
  if retryLimit < 0 or retryDelayMs < 0:
    raise newException(ValueError,
      "scale-in retry settings must be non-negative")
  if maxTransfers < 0:
    raise newException(ValueError, "maxTransfers must be non-negative")
  var source = openStore(dataDir)
  try:
    let target = client.discoverScaleInTarget()
    source.validateScaleInBoundary(target, client.peers.len)
    let peers = client.targetPeerSignature
    let statePath =
      if checkpointPath.len > 0: checkpointPath
      else: dataDir.defaultScaleInCheckpointPath(target.epoch)
    if resetCheckpoint and fileExists(statePath):
      removeFile(statePath)
    var checkpoint =
      if fileExists(statePath):
        result.resumed = true
        loadScaleInCheckpoint(statePath)
      else:
        source.freshCheckpoint(dataDir, target, peers)
    checkpoint.validateCheckpoint(source, dataDir, target, peers)
    result.checkpoint = statePath
    if checkpoint.complete:
      result.recordsAcked = checkpoint.recordsAcked
      result.tombstonesAcked = checkpoint.tombstonesAcked
      result.complete = true
      return

    if source.clusterTxPending > 0:
      raise newException(ValueError,
        "scale-in source has pending cluster transactions")
    if source.warpJobs.len > 0:
      raise newException(ValueError,
        "scale-in source has pending warp jobs")
    if source.universeSyncEvents.len > 0:
      raise newException(ValueError,
        "scale-in source has pending universe sync events")
    if not checkpoint.metadataTransferred:
      result.metadataObjects = source.migrateMetadata(
        client, target, retryLimit, retryDelayMs, result.retries)
      checkpoint.metadataTransferred = true
      checkpoint.verified = false
      saveScaleInCheckpoint(statePath, checkpoint)

    var invocationTransfers = 0
    let rings = source.sortedRings
    while checkpoint.phase == "records" and
        checkpoint.ringIndex < rings.len:
      let ring = rings[checkpoint.ringIndex]
      let keys = source.itemsByRing.getOrDefault(ring, @[])
      while checkpoint.itemIndex < keys.len:
        let key = keys[checkpoint.itemIndex]
        if source.contains(key[0], key[1]):
          let status = client.transferParticle(
            target, source.getParticle(key[0], key[1]), retryLimit,
            retryDelayMs, result.retries)
          if status == "APPLIED": inc result.applied else: inc result.skipped
          inc checkpoint.recordsAcked
          inc invocationTransfers
        inc checkpoint.itemIndex
        checkpoint.verified = false
        if (checkpoint.recordsAcked + checkpoint.tombstonesAcked) mod
            checkpointEvery == 0:
          saveScaleInCheckpoint(statePath, checkpoint)
        if maxTransfers > 0 and invocationTransfers >= maxTransfers:
          saveScaleInCheckpoint(statePath, checkpoint)
          result.recordsAcked = checkpoint.recordsAcked
          result.tombstonesAcked = checkpoint.tombstonesAcked
          return
      inc checkpoint.ringIndex
      checkpoint.itemIndex = 0
      saveScaleInCheckpoint(statePath, checkpoint)
    if checkpoint.phase == "records":
      checkpoint.phase = "tombstones"
      saveScaleInCheckpoint(statePath, checkpoint)

    let tombstones = source.sortedTombstones
    while checkpoint.phase == "tombstones" and
        checkpoint.tombstoneIndex < tombstones.len:
      let key = tombstones[checkpoint.tombstoneIndex]
      let status = client.transferTombstone(
        target, source.tombstones[key], retryLimit, retryDelayMs,
        result.retries)
      if status == "APPLIED": inc result.applied else: inc result.skipped
      inc checkpoint.tombstonesAcked
      inc invocationTransfers
      inc checkpoint.tombstoneIndex
      checkpoint.verified = false
      if (checkpoint.recordsAcked + checkpoint.tombstonesAcked) mod
          checkpointEvery == 0:
        saveScaleInCheckpoint(statePath, checkpoint)
      if maxTransfers > 0 and invocationTransfers >= maxTransfers:
        saveScaleInCheckpoint(statePath, checkpoint)
        result.recordsAcked = checkpoint.recordsAcked
        result.tombstonesAcked = checkpoint.tombstonesAcked
        return

    checkpoint.phase = "complete"
    checkpoint.complete = true
    checkpoint.verified = false
    saveScaleInCheckpoint(statePath, checkpoint)
    result.recordsAcked = checkpoint.recordsAcked
    result.tombstonesAcked = checkpoint.tombstonesAcked
    result.complete = true
  finally:
    source.close()

proc verifyMutation(client: ClusterClient, target: ArcTable, parent: uint64,
                    seq: uint32, version: MutationVersion, deleted: bool,
                    retryLimit, retryDelayMs: int,
                    retries: var int): tuple[ahead: bool, deleted: bool] =
  let owner = int(target.placementOwner(parent))
  for attempt in 0 .. retryLimit:
    try:
      return client.migrationVerifyReq(owner, parent, seq, version, deleted)
    except CatchableError:
      if attempt >= retryLimit:
        raise
      inc retries
      sleep(retryDelay(retryDelayMs, attempt))

proc verifyMetadataAt(client: ClusterClient, target: ArcTable, node: int,
                      metadata: string, retryLimit, retryDelayMs: int,
                      retries: var int) =
  for attempt in 0 .. retryLimit:
    try:
      client.migrationMetadataVerifyReq(
        node, metadata, target.epoch, target.nNodes,
        target.targetVirtualArcs)
      return
    except CatchableError:
      if attempt >= retryLimit:
        raise
      inc retries
      sleep(retryDelay(retryDelayMs, attempt))

proc verifyMetadata(source: Store, client: ClusterClient, target: ArcTable,
                    retryLimit, retryDelayMs: int,
                    retries: var int): int =
  let globalMetadata = $(%*{
    "kind": "global",
    "galaxy": source.galaxy,
    "description": source.galaxyDescription
  })
  for node in 0 ..< int(target.nNodes):
    client.verifyMetadataAt(target, node, globalMetadata, retryLimit,
                            retryDelayMs, retries)
    inc result
  for ring in source.sortedMetadataRings:
    client.verifyMetadataAt(
      target, int(target.placementOwner(ring)),
      source.ringMetadataJson(ring), retryLimit, retryDelayMs, retries)
    inc result
  for stellar in source.sortedStellarNames:
    let metadata = $(%*{
      "kind": "stellar",
      "stellar": stellar,
      "blob": source.stellarMaps[stellar]
    })
    for node in 0 ..< int(target.nNodes):
      client.verifyMetadataAt(target, node, metadata, retryLimit,
                              retryDelayMs, retries)
      inc result
  for key in source.sortedForwarders:
    let forwarder = source.forwarders[key]
    client.verifyMetadataAt(target, int(target.placementOwner(key[0])), $(%*{
      "kind": "forwarder",
      "oldParent": $key[0],
      "oldSeq": key[1],
      "newParent": $forwarder.newParent,
      "newSeq": forwarder.newSeq,
      "newTWrite": forwarder.newTWrite,
      "expiresAt": forwarder.expiresAt
    }), retryLimit, retryDelayMs, retries)
    inc result

proc verifyScaleIn*(dataDir: string, client: ClusterClient,
                    checkpointPath = "",
                    retryLimit = DefaultScaleInRetryLimit,
                    retryDelayMs = DefaultScaleInRetryDelayMs):
                    ScaleInVerifyStats =
  if dataDir.len == 0:
    raise newException(ValueError, "scale-in source data directory is required")
  if retryLimit < 0 or retryDelayMs < 0:
    raise newException(ValueError,
      "scale-in retry settings must be non-negative")
  var source = openStore(dataDir)
  try:
    let target = client.discoverScaleInTarget()
    source.validateScaleInBoundary(target, client.peers.len)
    let peers = client.targetPeerSignature
    let statePath =
      if checkpointPath.len > 0: checkpointPath
      else: dataDir.defaultScaleInCheckpointPath(target.epoch)
    var checkpoint = loadScaleInCheckpoint(statePath)
    checkpoint.validateCheckpoint(source, dataDir, target, peers)
    if not checkpoint.complete:
      raise newException(ValueError,
        "scale-in migration is not complete")
    result.checkpoint = statePath
    result.metadataObjects = source.verifyMetadata(
      client, target, retryLimit, retryDelayMs, result.retries)
    for particle in source.allParticles:
      let verified = client.verifyMutation(
        target, particle.parent, particle.seq, particle.version, false,
        retryLimit, retryDelayMs, result.retries)
      inc result.records
      if verified.ahead: inc result.ahead else: inc result.matching
    for _, tombstone in source.tombstones:
      let verified = client.verifyMutation(
        target, tombstone.parent, tombstone.seq, tombstone.version, true,
        retryLimit, retryDelayMs, result.retries)
      inc result.tombstones
      if verified.ahead: inc result.ahead else: inc result.matching
    checkpoint.verified = true
    saveScaleInCheckpoint(statePath, checkpoint)
  finally:
    source.close()
