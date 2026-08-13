## Exact process-crash boundary helper used by scripts/process_crash_matrix.sh.

import std/[os, parseopt, sequtils, strformat, strutils]
import ../src/kouten/store

const
  MainRing = 701'u64
  OtherRing = 702'u64
  RecordCount = 128
  UpdatedCount = 32

proc require(condition: bool; message: string) =
  if not condition:
    raise newException(AssertionDefect, message)

proc seedStore(store: Store) =
  store.putRingMeta(MainRing, 60.0, 0.1)
  store.putRingName(MainRing, "crash/main")
  store.putRingMeta(OtherRing, 120.0, 0.2)
  store.putRingName(OtherRing, "crash/other")
  for i in 0'u32 ..< RecordCount.uint32:
    store.upsert Particle(parent: MainRing, seq: i, period: 60.0,
                          head: 0.1, tWrite: float(i + 1),
                          payload: "base-" & $i)
  for i in 0'u32 ..< 8'u32:
    store.upsert Particle(parent: OtherRing, seq: i, period: 120.0,
                          head: 0.2, tWrite: float(i + 1),
                          payload: "other-" & $i)

proc applyCandidateUpdate(store: Store) =
  for i in 0'u32 ..< UpdatedCount.uint32:
    store.upsert Particle(parent: MainRing, seq: i, period: 60.0,
                          head: 0.1, tWrite: float(1000 + i.int),
                          payload: "updated-" & $i)

proc assertSourceState(store: Store; candidate = true) =
  require(store.ringLiveCount(MainRing) == RecordCount,
          "main ring live count changed")
  require(store.ringLiveCount(OtherRing) == 8,
          "unrelated ring live count changed")
  for i in 0'u32 ..< RecordCount.uint32:
    let expected =
      if candidate and i < UpdatedCount.uint32: "updated-" & $i
      else: "base-" & $i
    require(store.getParticle(MainRing, i).payload == expected,
            "main ring payload mismatch at " & $i)
  for i in 0'u32 ..< 8'u32:
    require(store.getParticle(OtherRing, i).payload == "other-" & $i,
            "unrelated ring payload mismatch at " & $i)

proc generationFor(store: Store; ring: uint64): uint64 =
  for item in store.segmentReport().rings:
    if item.ring == ring:
      return item.generation
  raise newException(AssertionDefect, "ring generation is missing: " & $ring)

proc armCrashPoint(point, readyPath: string) =
  putEnv("KOUTEN_TEST_CRASH_POINT", point)
  putEnv("KOUTEN_TEST_CRASH_READY", readyPath)

proc runWorker(root, point, readyPath: string) =
  let dataDir = root / "data"
  let checkpointRoot = root / "checkpoints"
  let backupDir = root / "backup"
  var store = openStore(dataDir, durability = durStrong, diskBacked = true)
  store.seedStore()

  if point.startsWith("segment-"):
    discard store.packRingSegment(MainRing)
    discard store.packRingSegment(OtherRing)
    store.applyCandidateUpdate()
    armCrashPoint(point, readyPath)
    discard store.packRingSegment(MainRing)
  elif point.startsWith("checkpoint-"):
    discard store.createCheckpoint(checkpointRoot, "stable")
    store.applyCandidateUpdate()
    armCrashPoint(point, readyPath)
    discard store.createCheckpoint(checkpointRoot, "candidate")
  elif point.startsWith("backup-"):
    discard store.backup(backupDir)
    store.applyCandidateUpdate()
    armCrashPoint(point, readyPath)
    discard store.backup(backupDir)
  else:
    raise newException(ValueError, "unknown crash point: " & point)

  store.close()
  raise newException(AssertionDefect,
    "worker returned without reaching crash point " & point)

proc assertNoSegmentTemps(dataDir: string) =
  let segmentDir = dataDir / "segments"
  if not dirExists(segmentDir):
    return
  for path in walkFiles(segmentDir / "*.tmp"):
    raise newException(AssertionDefect,
      "segment temporary file survived recovery: " & path)

proc verifySegmentCase(root, point: string) =
  let dataDir = root / "data"
  let expectedGeneration =
    if point in ["segment-after-manifest", "segment-cleanup"]: 2'u64
    else: 1'u64
  var store = openStore(dataDir, durability = durStrong, diskBacked = true)
  store.assertSourceState()
  require(store.generationFor(MainRing) == expectedGeneration,
          &"unexpected active generation after {point}")
  require(store.generationFor(OtherRing) == 1'u64,
          "unrelated ring generation changed")
  let packed = store.packRingSegment(MainRing)
  require(packed.records == RecordCount,
          "recovery pack did not rewrite the complete main ring")
  store.close()

  var reopened = openStore(dataDir, durability = durStrong, diskBacked = true)
  reopened.assertSourceState()
  require(reopened.generationFor(MainRing) == expectedGeneration + 1,
          "post-recovery generation did not advance exactly once")
  require(reopened.segmentReport().walFallbacks == 0,
          "post-recovery reads fell back to the WAL")
  reopened.close()
  assertNoSegmentTemps(dataDir)

proc verifyCheckpointCase(root, point: string) =
  let dataDir = root / "data"
  let checkpointRoot = root / "checkpoints"
  let candidateDir = checkpointRoot / "candidate"
  let stagedDir = checkpointRoot / ".tmp-candidate"

  var source = openStore(dataDir, durability = durStrong, diskBacked = true)
  source.assertSourceState()
  let listed = listCheckpoints(checkpointRoot)
  if point == "checkpoint-before-publish":
    require(not dirExists(candidateDir),
            "unpublished checkpoint became visible")
    require(dirExists(stagedDir), "checkpoint staging directory is missing")
    require(checkpointStatus(stagedDir).verified,
            "completed checkpoint staging generation is not verifiable")
    require(listed.len == 1 and listed[0].id == "stable" and listed[0].verified,
            "checkpoint listing exposed an unpublished generation")
  else:
    require(dirExists(candidateDir), "published checkpoint is missing")
    require(not dirExists(stagedDir),
            "published checkpoint left a staging directory")
    require(listed.anyIt(it.id == "candidate" and it.verified),
            "published checkpoint is not listed as verified")

  let selected =
    if point == "checkpoint-before-publish": checkpointRoot / "stable"
    else: candidateDir
  let restoredDir = root / "restored-selected"
  discard restoreCheckpoint(selected, restoredDir)
  var restored = openStore(restoredDir, durability = durStrong,
                           diskBacked = true)
  restored.assertSourceState(candidate = point != "checkpoint-before-publish")
  restored.close()

  let retry = source.createCheckpoint(checkpointRoot, "post-crash")
  require(retry.verified, "checkpoint creation did not recover after SIGKILL")
  let cleanup = cleanupCheckpoints(checkpointRoot, keep = 1)
  require(cleanup.kept == 1, "checkpoint cleanup did not retain one generation")
  source.close()

proc verifyBackupCase(root, point: string) =
  let dataDir = root / "data"
  let backupDir = root / "backup"
  let restoredDir = root / "restored-backup"
  let expectCandidate = point == "backup-after-publish"
  let status = verifyBackup(backupDir)
  require(status.items == RecordCount + 8,
          "backup item count changed across publication crash")
  discard restoreBackup(backupDir, restoredDir, durability = durStrong)
  var restored = openStore(restoredDir, durability = durStrong,
                           diskBacked = true)
  restored.assertSourceState(candidate = expectCandidate)
  restored.close()

  var source = openStore(dataDir, durability = durStrong, diskBacked = true)
  source.assertSourceState()
  discard source.backup(backupDir)
  source.close()
  require(not fileExists(backupDir / "kouten.log.tmp"),
          "backup temporary file survived the recovery retry")

proc runVerify(root, point: string) =
  if point.startsWith("segment-"):
    verifySegmentCase(root, point)
  elif point.startsWith("checkpoint-"):
    verifyCheckpointCase(root, point)
  elif point.startsWith("backup-"):
    verifyBackupCase(root, point)
  else:
    raise newException(ValueError, "unknown crash point: " & point)
  echo &"process-crash-matrix OK point={point}"

proc usage() =
  quit("usage: process_crash_matrix --mode=worker|verify --root=DIR " &
       "--point=NAME [--ready=FILE]", 2)

proc main() =
  var mode = ""
  var root = ""
  var point = ""
  var readyPath = ""
  for kind, key, value in getopt():
    if kind != cmdLongOption:
      continue
    case key
    of "mode": mode = value
    of "root": root = value
    of "point": point = value
    of "ready": readyPath = value
    else: usage()
  if root.len == 0 or point.len == 0:
    usage()
  case mode
  of "worker":
    if readyPath.len == 0:
      usage()
    runWorker(root, point, readyPath)
  of "verify":
    runVerify(root, point)
  else:
    usage()

when isMainModule:
  main()
