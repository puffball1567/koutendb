import std/[json, os, sequtils, strutils, tempfiles, unittest]
import nimsodium
import ../src/kouten/store

const CheckpointChecksumChunkBytes = 1024 * 1024

proc checkpointChecksumForTest(path: string): string =
  var file = open(path, fmRead)
  var buffer = newString(CheckpointChecksumChunkBytes)
  var state = genericHash("KOUTENDB-CHECKPOINT-CHECKSUM-V1\0")
  var total = 0'i64
  var chunkIndex = 0'i64
  try:
    while true:
      let read = file.readChars(buffer.toOpenArray(0, buffer.high))
      if read == 0:
        break
      let chunkHash = genericHash(buffer[0 ..< read])
      state = genericHash("KOUTENDB-CHECKPOINT-CHUNK-V1\0" & state &
                          chunkHash & "\0" & $chunkIndex & "\0" & $read)
      total += read.int64
      inc chunkIndex
  finally:
    file.close()
  "blake2b-chain-v1:" &
    genericHashHex("KOUTENDB-CHECKPOINT-FINAL-V1\0" & state & "\0" &
                   $chunkIndex & "\0" & $total)

proc rewriteCheckpointManifest(checkpointDir: string; manifest: JsonNode) =
  let path = checkpointDir / "checkpoint.json"
  writeFile(path, $manifest)
  writeFile(checkpointDir / "checkpoint.complete",
            checkpointChecksumForTest(path) & "\n")

proc seedStore(st: Store) =
  st.putRingMeta(41, 60.0, 0.1)
  st.putRingName(41, "users/41")
  st.putRingMeta(42, 120.0, 0.2)
  st.putRingName(42, "orders/42")
  for i in 0'u32 ..< 3'u32:
    st.upsert Particle(parent: 41, seq: i, period: 60.0, head: 0.1,
                       tWrite: float(i + 1), payload: "user-" & $i)
  st.upsert Particle(parent: 42, seq: 0, period: 120.0, head: 0.2,
                     tWrite: 10.0, payload: "order-live")
  st.upsert Particle(parent: 42, seq: 1, period: 120.0, head: 0.2,
                     tWrite: 11.0, payload: "order-deleted")
  st.remove(42, 1)

suite "generation checkpoints":
  test "checkpoint captures one verified WAL and segment generation":
    let root = createTempDir("kouten-checkpoint", "create-restore")
    let data = root / "source"
    let checkpointRoot = root / "checkpoints"
    let restoredDir = root / "restored"
    var st = openStore(data, durability = durStrong, diskBacked = true)
    st.seedStore()
    let sourceHighWater = st.logSize().int64
    let created = st.createCheckpoint(checkpointRoot, "stable-1")
    check created.id == "stable-1"
    check created.complete
    check created.verified
    check created.reason == "verified"
    check created.sourceWalHighWater == sourceHighWater
    check created.snapshotWalBytes > 0
    check created.items == 4
    check created.tombstones == 1
    check created.rings == 2
    check created.files.anyIt(it.path == "kouten.log" and it.kind == "wal")
    check created.files.anyIt(it.path == "segments/manifest")
    check created.files.countIt(it.kind == "segment") == 2
    check created.files.countIt(it.kind == "segment-index") == 2
    check created.files.filterIt(it.kind in ["segment", "segment-index"]).allIt(
      it.generation == 1 and it.checksum.startsWith("blake2b-chain-v1:"))

    st.upsert Particle(parent: 41, seq: 3, period: 60.0, head: 0.1,
                       tWrite: 20.0, payload: "after-checkpoint")
    let restored = restoreCheckpoint(created.path, restoredDir)
    check restored.reason == "restored"
    check restored.items == 4
    var reopened = openStore(restoredDir, durability = durStrong,
                             diskBacked = true)
    check reopened.getParticle(41, 0).payload == "user-0"
    check reopened.getParticle(42, 0).payload == "order-live"
    expect KeyError:
      discard reopened.getParticle(41, 3)
    expect KeyError:
      discard reopened.getParticle(42, 1)
    let report = reopened.segmentReport()
    check report.rings.len == 2
    check report.rings.allIt(it.generation == 1)
    reopened.close()
    st.close()
    removeDir(root)

  test "checkpoint verification rejects file and manifest corruption":
    let root = createTempDir("kouten-checkpoint", "corruption")
    var st = openStore(root / "source", diskBacked = true)
    st.seedStore()
    let created = st.createCheckpoint(root / "checkpoints", "corrupt-me")
    let segment = created.files.filterIt(it.kind == "segment")[0]
    var file = open(created.path / segment.path, fmAppend)
    file.write("corruption")
    file.close()
    let damaged = checkpointStatus(created.path)
    check not damaged.verified
    check "size mismatch" in damaged.reason or "checksum mismatch" in damaged.reason
    expect IOError:
      discard verifyCheckpoint(created.path)

    let checksumOnly = st.createCheckpoint(root / "checkpoints", "checksum-only")
    let checksumSegment = checksumOnly.files.filterIt(it.kind == "segment")[0]
    let checksumPath = checksumOnly.path / checksumSegment.path
    var sameSize = readFile(checksumPath)
    check sameSize.len > 0
    sameSize[0] = char(ord(sameSize[0]) xor 1)
    writeFile(checksumPath, sameSize)
    let checksumDamaged = checkpointStatus(checksumOnly.path)
    check not checksumDamaged.verified
    check "checksum mismatch" in checksumDamaged.reason

    let second = st.createCheckpoint(root / "checkpoints", "bad-manifest")
    let manifestPath = second.path / "checkpoint.json"
    var manifest = parseJson(readFile(manifestPath))
    manifest["files"][0]["path"] = %"../kouten.log"
    rewriteCheckpointManifest(second.path, manifest)
    let invalid = checkpointStatus(second.path)
    check not invalid.verified
    check "invalid checkpoint file path" in invalid.reason

    let malformed = st.createCheckpoint(root / "checkpoints", "missing-stats")
    var malformedManifest = parseJson(
      readFile(malformed.path / "checkpoint.json"))
    malformedManifest.delete("stats")
    rewriteCheckpointManifest(malformed.path, malformedManifest)
    let malformedStatus = checkpointStatus(malformed.path)
    check not malformedStatus.verified
    check "checkpoint stats are missing" in malformedStatus.reason

    let incomplete = st.createCheckpoint(root / "checkpoints", "incomplete")
    removeFile(incomplete.path / "checkpoint.complete")
    let missingMarker = checkpointStatus(incomplete.path)
    check not missingMarker.verified
    check "completion marker is missing" in missingMarker.reason
    when not defined(windows):
      let linked = st.createCheckpoint(root / "checkpoints", "linked")
      let linkedSegment = linked.files.filterIt(it.kind == "segment")[0]
      let segmentPath = linked.path / linkedSegment.path
      let externalPath = root / "external-segment"
      moveFile(segmentPath, externalPath)
      createSymlink(externalPath, segmentPath)
      let linkedStatus = checkpointStatus(linked.path)
      check not linkedStatus.verified
      check "symlinks are not allowed" in linkedStatus.reason

      let linkedDir = st.createCheckpoint(root / "checkpoints", "linked-dir")
      let segmentDir = linkedDir.path / "segments"
      let externalSegments = root / "external-segments"
      moveDir(segmentDir, externalSegments)
      createSymlink(externalSegments, segmentDir)
      let linkedDirStatus = checkpointStatus(linkedDir.path)
      check not linkedDirStatus.verified
      check "directory symlinks are not allowed" in linkedDirStatus.reason
    st.close()
    removeDir(root)

  test "cleanup retains the newest verified checkpoint and every invalid one":
    let root = createTempDir("kouten-checkpoint", "cleanup")
    let checkpointRoot = root / "checkpoints"
    var st = openStore(root / "source", diskBacked = true)
    st.seedStore()
    let old = st.createCheckpoint(checkpointRoot, "old")
    sleep(2)
    let middle = st.createCheckpoint(checkpointRoot, "middle")
    sleep(2)
    let newest = st.createCheckpoint(checkpointRoot, "newest")
    writeFile(old.path / "kouten.log", "damaged")
    createDir(checkpointRoot / ".tmp-interrupted")
    writeFile(checkpointRoot / ".tmp-interrupted" / "partial", "staged")

    expect ValueError:
      discard cleanupCheckpoints(checkpointRoot, keep = 0)
    let cleanup = cleanupCheckpoints(checkpointRoot, keep = 1)
    check cleanup.kept == 1
    check cleanup.removed == @[middle.id]
    check cleanup.invalid == @[old.id]
    check dirExists(old.path)
    check not dirExists(middle.path)
    check dirExists(newest.path)
    let listed = listCheckpoints(checkpointRoot)
    check listed.len == 2
    check listed.countIt(it.verified) == 1
    check dirExists(checkpointRoot / ".tmp-interrupted")
    st.close()
    removeDir(root)

  test "identity and restore overwrite boundaries fail closed":
    let root = createTempDir("kouten-checkpoint", "boundaries")
    let target = root / "target"
    var memory = openStore("")
    expect ValueError:
      discard memory.createCheckpoint(root / "memory", "memory")
    memory.close()

    var st = openStore(root / "source", diskBacked = true)
    st.seedStore()
    expect ValueError:
      discard st.createCheckpoint(root / "checkpoints", "../escape")
    expect ValueError:
      discard st.createCheckpoint(root / "checkpoints", ".tmp-hidden")
    expect ValueError:
      discard st.createCheckpoint(root / "source" / "checkpoints", "nested")
    when not defined(windows):
      createSymlink(root / "source", root / "source-alias")
      expect ValueError:
        discard st.createCheckpoint(root / "source-alias" / "checkpoints",
                                    "symlink-nested")
    let created = st.createCheckpoint(root / "checkpoints", "selected")
    expect IOError:
      discard st.createCheckpoint(root / "checkpoints", "selected")
    expect ValueError:
      discard restoreCheckpoint(created.path, created.path / "nested")

    let activeTargetDir = root / "active-target"
    var activeTarget = openStore(activeTargetDir, durability = durStrong,
                                 diskBacked = true)
    activeTarget.upsert Particle(parent: 77, seq: 0, period: 60.0, head: 0.0,
                                 tWrite: 1.0, payload: "active")
    expect IOError:
      discard restoreCheckpoint(created.path, activeTargetDir,
                                overwrite = true)
    check activeTarget.getParticle(77, 0).payload == "active"
    activeTarget.close()

    when not defined(windows):
      let realTarget = root / "real-target"
      createDir(realTarget)
      let linkedTarget = root / "linked-target"
      createSymlink(realTarget, linkedTarget)
      expect IOError:
        discard restoreCheckpoint(created.path, linkedTarget,
                                  overwrite = true)
    createDir(target)
    writeFile(target / "existing", "do-not-replace-without-consent")
    expect IOError:
      discard restoreCheckpoint(created.path, target)
    when defined(linux):
      let restored = restoreCheckpoint(created.path, target, overwrite = true)
      check restored.verified
      check not fileExists(target / "existing")
      var reopened = openStore(target, diskBacked = true)
      check reopened.getParticle(41, 2).payload == "user-2"
      reopened.close()
    else:
      expect IOError:
        discard restoreCheckpoint(created.path, target, overwrite = true)
      check readFile(target / "existing") == "do-not-replace-without-consent"
      let freshTarget = root / "fresh-target"
      let restored = restoreCheckpoint(created.path, freshTarget)
      check restored.verified
      var reopened = openStore(freshTarget, diskBacked = true)
      check reopened.getParticle(41, 2).payload == "user-2"
      reopened.close()
    st.close()
    removeDir(root)

  test "empty persistent stores produce a complete WAL-only checkpoint":
    let root = createTempDir("kouten-checkpoint", "empty")
    var st = openStore(root / "source", durability = durStrong,
                       diskBacked = true)
    let created = st.createCheckpoint(root / "checkpoints", "empty")
    check created.verified
    check created.items == 0
    check created.files.len == 1
    check created.files[0].path == "kouten.log"
    let restored = restoreCheckpoint(created.path, root / "restored")
    check restored.items == 0
    st.close()
    removeDir(root)
