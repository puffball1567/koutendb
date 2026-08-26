## kouten/store の永続化テスト

import std/[algorithm, os, osproc, posix, random, sequtils, strutils, tables,
            tempfiles, unittest]
import nimsodium
import ../src/kouten/store

if paramCount() == 2 and paramStr(1) == "--lock-child":
  let dir = paramStr(2)
  var st = openStore(dir)
  writeFile(dir / "locked.ready", "1")
  sleep(5_000)
  st.close()
  quit 0

proc ringSignature(st: Store, ring: uint64): seq[string] =
  if ring notin st.itemsByRing:
    return @[]
  for k in st.itemsByRing[ring]:
    if k in st.items:
      let p = st.items[k]
      result.add p.payload & "|" & $p.codec & "|" & $p.seq & "|" & $p.tWrite
  result.sort()

proc diskRingSignature(st: Store, ring: uint64): seq[string] =
  for p in st.particlesByRing(ring):
    result.add $p.seq & "|" & p.payload & "|" & $p.version
  result.sort()

proc legacyEncryptedBackup(plaintext, passphrase: string): string =
  let key = secretBoxKeyFromBytes(
    genericHash("koutendb-backup-v1\0" & passphrase, SecretBoxKeyBytes))
  result = "KOUTENDB-BACKUP-SECRETBOX-V1\n" &
    encryptSecretBox(plaintext, key)

proc mutationVersion(n: int64, origin = 1'u32): MutationVersion =
  MutationVersion(physicalMicros: n, logical: 0, origin: origin)

suite "store persistence":
  test "closed store transactions return validation errors":
    let dir = createTempDir("kouten-store", "closed-transaction")
    var st = openStore(dir)
    let tx = st.beginTxn()
    tx.commit()
    expect ValueError:
      tx.commit()
    expect ValueError:
      tx.upsert Particle(parent: 1'u64, seq: 0'u32, period: 60.0,
                         head: 0.0, tWrite: 1.0, payload: "late")
    st.close()
    removeDir(dir)

  test "persistent artifacts use owner-only POSIX permissions":
    when not defined(windows):
      let dir = createTempDir("kouten-store", "private-modes")
      let backupDir = createTempDir("kouten-store", "private-backup")
      removeDir(dir)
      removeDir(backupDir)

      var st = openStore(dir, diskBacked = true)
      st.upsert Particle(parent: 1'u64, seq: 0'u32, period: 60.0,
                         head: 0.0, tWrite: 1.0, payload: "private")
      st.sync()
      discard st.backup(backupDir)
      check getFilePermissions(dir) ==
        {fpUserRead, fpUserWrite, fpUserExec}
      check getFilePermissions(dir / "kouten.log") ==
        {fpUserRead, fpUserWrite}
      check getFilePermissions(dir / "segments") ==
        {fpUserRead, fpUserWrite, fpUserExec}
      for kind, path in walkDir(dir / "segments"):
        if kind == pcFile:
          check getFilePermissions(path) == {fpUserRead, fpUserWrite}
      check getFilePermissions(backupDir) ==
        {fpUserRead, fpUserWrite, fpUserExec}
      check getFilePermissions(backupDir / "kouten.log") ==
        {fpUserRead, fpUserWrite}
      st.close()
      removeDir(dir)
      removeDir(backupDir)

  test "private files ignore a permissive parent directory":
    when not defined(windows):
      let dir = createTempDir("kouten-store", "private-create")
      setFilePermissions(dir, {
        fpUserRead, fpUserWrite, fpUserExec,
        fpGroupRead, fpGroupWrite, fpGroupExec,
        fpOthersRead, fpOthersWrite, fpOthersExec
      })
      let path = dir / "artifact.bin"
      var file = openPrivateStoreFile(path, fmWrite)
      file.write("secret")
      file.close()
      check getFilePermissions(path) == {fpUserRead, fpUserWrite}
      removeDir(dir)

  test "private file open rejects symbolic-link destinations":
    when not defined(windows) and declared(O_NOFOLLOW):
      let dir = createTempDir("kouten-store", "private-symlink")
      let target = dir / "target.bin"
      let link = dir / "link.bin"
      writeFile(target, "unchanged")
      createSymlink(target, link)
      expect OSError:
        discard openPrivateStoreFile(link, fmWrite)
      check readFile(target) == "unchanged"
      removeDir(dir)

  test "placement topology is durable and epoch-fenced":
    let dir = createTempDir("kouten-store", "placement")
    var st = openStore(dir)
    st.configurePlacement(3, 4, 96)
    check st.placementEpoch == 3
    check st.placementNodes == 4
    check st.placementVirtualArcs == 96
    st.configurePlacement(3, 4, 96)
    expect ValueError:
      st.configurePlacement(3, 5, 96)
    expect ValueError:
      st.configurePlacement(2, 4, 96)
    expect ValueError:
      st.configurePlacement(4, 3, 96)
    expect ValueError:
      st.configurePlacement(4, 5, 64)
    st.close()

    var replayed = openStore(dir)
    check replayed.placementEpoch == 3
    check replayed.placementNodes == 4
    check replayed.placementVirtualArcs == 96
    replayed.setMaintenanceDrained(true)
    replayed.configurePlacement(4, 5, 64)
    discard replayed.compact()
    replayed.close()

    var compacted = openStore(dir)
    check compacted.placementEpoch == 4
    check compacted.placementNodes == 5
    check compacted.placementVirtualArcs == 64
    compacted.close()
    removeDir(dir)

  test "coordinator assignment is durable and epoch-fenced":
    let dir = createTempDir("kouten-store", "coordinator-fence")
    var st = openStore(dir)
    expect ValueError:
      st.configureCoordinator(0, 0, 1)
    expect ValueError:
      st.configureCoordinator(1, 0, 0)
    expect ValueError:
      st.configureCoordinator(1, 0, -2)
    st.configureCoordinator(1, 0, 1)
    st.close()

    var replayed = openStore(dir)
    check replayed.coordinatorEpoch == 1
    check replayed.coordinatorNode == 0
    check replayed.coordinatorReplica == 1
    expect ValueError:
      replayed.configureCoordinator(1, 1, 2)
    expect ValueError:
      replayed.configureCoordinator(2, 1, 2)
    replayed.setMaintenanceDrained(true)
    replayed.configureCoordinator(2, 1, 2)
    discard replayed.compact()
    replayed.close()

    var promoted = openStore(dir)
    check promoted.coordinatorEpoch == 2
    check promoted.coordinatorNode == 1
    check promoted.coordinatorReplica == 2
    expect ValueError:
      promoted.configureCoordinator(1, 0, 1)
    promoted.close()
    removeDir(dir)

  test "coordinator transaction ids encode epoch and persist their sequence":
    let dir = createTempDir("kouten-store", "coordinator-txid")
    var st = openStore(dir)
    let first = st.reserveCoordinatorTxId(3)
    let second = st.reserveCoordinatorTxId(3)
    check first == ((3'u64 shl 32) or 1'u64)
    check second == ((3'u64 shl 32) or 2'u64)
    st.close()

    var replayed = openStore(dir)
    let third = replayed.reserveCoordinatorTxId(4)
    check third == ((4'u64 shl 32) or 3'u64)
    replayed.close()
    removeDir(dir)

  test "maintenance drain state survives replay and compaction":
    let dir = createTempDir("kouten-store", "maintenance-drain")
    var st = openStore(dir)
    check not st.maintenanceDrained
    st.setMaintenanceDrained(true)
    check st.maintenanceDrained
    st.close()

    var replayed = openStore(dir)
    check replayed.maintenanceDrained
    discard replayed.compact()
    replayed.close()

    var compacted = openStore(dir)
    check compacted.maintenanceDrained
    compacted.setMaintenanceDrained(false)
    compacted.close()

    var resumed = openStore(dir)
    check not resumed.maintenanceDrained
    resumed.close()
    removeDir(dir)

  test "topology activation rejects pending cluster transaction intent":
    let dir = createTempDir("kouten-store", "placement-pending-tx")
    var st = openStore(dir)
    st.configurePlacement(1, 1, 64)
    st.setMaintenanceDrained(true)
    st.putClusterTxIntent ClusterTxIntent(
      id: 11,
      committed: true,
      ops: @[ClusterTxOp(
        parent: 7, seq: 0, period: 60.0, head: 0.0, tWrite: 1.0,
        payload: "pending")])
    expect ValueError:
      st.configurePlacement(2, 2, 64)
    st.markClusterTxApplied(11)
    st.configurePlacement(2, 2, 64)
    st.close()
    removeDir(dir)

  test "invalid maintenance drain WAL values fail closed":
    let dir = createTempDir("kouten-store", "maintenance-drain-invalid")
    writeFile(dir / "kouten.log", "MD 2\n")
    expect IOError:
      discard openStore(dir)
    removeDir(dir)

  test "mutation state distinguishes live data and tombstones":
    var st = openStore("")
    let live = Particle(parent: 8'u64, seq: 1'u32, period: 60.0,
                        head: 0.0, tWrite: 1.0, payload: "live",
                        version: mutationVersion(10))
    check st.upsert(live, preserveVersion = true)
    let liveState = st.mutationState(8, 1)
    check liveState.found
    check not liveState.deleted
    check liveState.version == mutationVersion(10)

    check st.applyTombstone(Tombstone(
      parent: 8, seq: 1, period: 60.0, head: 0.0, tWrite: 1.0,
      version: mutationVersion(11)))
    let deletedState = st.mutationState(8, 1)
    check deletedState.found
    check deletedState.deleted
    check deletedState.version == mutationVersion(11)
    check not st.mutationState(8, 2).found

  test "migration metadata setters are durable and idempotent":
    let dir = createTempDir("kouten-store", "metadata-idempotent")
    var st = openStore(dir, durability = durStrong)
    let payloadProfile = RingPayloadProfile(
      defaultCodec: pcJson, charset: "UTF-8", formatVersion: "1")
    let timeProfile = TimeOrbitProfile(
      bits: 60, bucketMs: 60_000, phase: 7, salt: "migration")
    let zeroForwarder = Forwarder()
    st.putRingMeta(9, 60.0, 0.25)
    st.putRingName(9, "docs/test")
    st.putGalaxyDescription("migration")
    st.putRingDescription(9, "description")
    st.putRingPayloadProfile(9, payloadProfile)
    st.putTimeOrbitProfile(9, timeProfile)
    st.putStellarMap(
      "docs/stellar",
      """{"stellar":"docs/stellar","members":["docs/test"]}""")
    st.putForwarder(9, 1, zeroForwarder)
    let firstSize = st.logSize
    check (9'u64, 1'u32) in st.forwarders

    st.putRingMeta(9, 60.0, 0.25)
    st.putRingName(9, "docs/test")
    st.putGalaxyDescription("migration")
    st.putRingDescription(9, "description")
    st.putRingPayloadProfile(9, payloadProfile)
    st.putTimeOrbitProfile(9, timeProfile)
    st.putStellarMap(
      "docs/stellar",
      """{"stellar":"docs/stellar","members":["docs/test"]}""")
    st.putForwarder(9, 1, zeroForwarder)
    check st.logSize == firstSize
    st.close()

    var replayed = openStore(dir)
    check replayed.ringNames[9] == "docs/test"
    check replayed.ringPayloadProfiles[9] == payloadProfile
    check replayed.ringTimeOrbitProfiles[9] == timeProfile
    check (9'u64, 1'u32) in replayed.forwarders
    replayed.close()
    removeDir(dir)

  test "persistent data dirs are locked across processes":
    let dir = createTempDir("kouten-store", "lock")
    let child = startProcess(getAppFilename(), args = ["--lock-child", dir])
    try:
      for _ in 0 ..< 50:
        if fileExists(dir / "locked.ready"):
          break
        sleep(100)
      check fileExists(dir / "locked.ready")
      expect IOError:
        discard openStore(dir)
    finally:
      try:
        child.terminate()
        discard child.waitForExit(timeout = 2_000)
      except CatchableError:
        discard
      child.close()
      removeDir(dir)

  test "persistent data dirs are locked within one process and by canonical path":
    let root = createTempDir("kouten-store", "same-process-lock")
    let dir = root / "data"
    var st = openStore(dir)
    expect IOError:
      discard openStore(dir)
    when not defined(windows):
      let alias = root / "data-alias"
      createSymlink(dir, alias)
      expect IOError:
        discard openStore(alias)
    st.close()
    var reopened = openStore(dir)
    reopened.close()
    removeDir(root)

  test "Particle vec は E レコードで復元される":
    let dir = createTempDir("kouten-store", "vec")
    var st = openStore(dir)
    st.upsert Particle(parent: 11'u64, seq: 3'u32, period: 60.0, head: 1.2,
                       tWrite: 4.5, payload: "payload",
                       vec: @[0.25'f32, -0.5'f32, 1.0'f32])
    st.close()

    var st2 = openStore(dir)
    check st2.items[(11'u64, 3'u32)].payload == "payload"
    check st2.items[(11'u64, 3'u32)].vec == @[0.25'f32, -0.5'f32, 1.0'f32]
    st2.close()
    removeDir(dir)

  test "payload codec survives WAL replay while legacy records default to raw":
    let dir = createTempDir("kouten-store", "payload-codec")
    var st = openStore(dir)
    st.upsert Particle(parent: 12'u64, seq: 0'u32, period: 60.0, head: 0.0,
                       tWrite: 1.0, payload: "(object (name KoutenDB))",
                       codec: pcNif)
    st.close()

    var restored = openStore(dir)
    check restored.items[(12'u64, 0'u32)].codec == pcNif
    restored.close()
    removeDir(dir)

    let legacyDir = createTempDir("kouten-store", "legacy-payload-codec")
    writeFile(legacyDir / "kouten.log",
              "P 13 0 60.0 0.0 1.0 5 0\nhello\n")
    var legacy = openStore(legacyDir)
    check legacy.items[(13'u64, 0'u32)].codec == pcRaw
    legacy.close()
    removeDir(legacyDir)

  test "mutation versions reject stale and duplicate values around tombstones":
    var st = openStore("")
    let base = Particle(parent: 14'u64, seq: 0'u32, period: 60.0,
                        head: 0.2, tWrite: 1.0, payload: "v2",
                        version: mutationVersion(2))
    check st.upsert(base, preserveVersion = true)

    var stale = base
    stale.payload = "v1"
    stale.version = mutationVersion(1)
    check not st.upsert(stale, preserveVersion = true)
    check st.getParticle(14'u64, 0'u32).payload == "v2"

    var duplicate = base
    duplicate.payload = "duplicate"
    check not st.upsert(duplicate, preserveVersion = true)
    check st.getParticle(14'u64, 0'u32).payload == "v2"

    let deleted = Tombstone(parent: base.parent, seq: base.seq,
                            period: base.period, head: base.head,
                            tWrite: base.tWrite, version: mutationVersion(3))
    check st.applyTombstone(deleted)
    check not st.contains(base.parent, base.seq)
    check st.tombstones[(base.parent, base.seq)].version == deleted.version
    check not st.upsert(base, preserveVersion = true)

    var recreated = base
    recreated.payload = "v4"
    recreated.version = mutationVersion(4)
    check st.upsert(recreated, preserveVersion = true)
    check st.getParticle(base.parent, base.seq).payload == "v4"
    check (base.parent, base.seq) notin st.tombstones
    st.close()

  test "mutation version clock remains monotonic after observing future state":
    var st = openStore("")
    let future = MutationVersion(
      physicalMicros: int64.high - 10_000, logical: 7, origin: 3)
    check st.upsert(Particle(
      parent: 141'u64, seq: 0'u32, period: 60.0, head: 0.1,
      tWrite: 1.0, payload: "future", version: future),
      preserveVersion = true)
    let next = st.nextMutationVersion(origin = 4)
    check next > future
    let nextAgain = st.nextMutationVersion(origin = 4)
    check nextAgain > next

    expect ValueError:
      discard st.upsert(Particle(
        parent: 141'u64, seq: 1'u32, period: 60.0, head: 0.1,
        tWrite: 1.0, payload: "invalid",
        version: MutationVersion(
          physicalMicros: 0, logical: 1, origin: 1)),
        preserveVersion = true)
    st.close()

  test "logical delete ordering survives replay compact backup and restore":
    let dir = createTempDir("kouten-store", "mutation-order")
    let backupDir = createTempDir("kouten-store", "mutation-order-backup")
    let restoreDir = createTempDir("kouten-store", "mutation-order-restore")
    let original = Particle(parent: 15'u64, seq: 2'u32, period: 120.0,
                            head: 0.4, tWrite: 2.0, payload: "live",
                            version: mutationVersion(10, 2))
    var st = openStore(dir)
    check st.upsert(original, preserveVersion = true)
    let deleted = Tombstone(parent: original.parent, seq: original.seq,
                            period: original.period, head: original.head,
                            tWrite: original.tWrite,
                            version: mutationVersion(11, 2),
                            acknowledgedNodes: @[0'u16, 2'u16],
                            reclaimAfter: 9_999_999_999.0)
    check st.applyTombstone(deleted)
    st.close()

    var replayed = openStore(dir)
    check not replayed.contains(original.parent, original.seq)
    check replayed.tombstones[(original.parent, original.seq)].version ==
      deleted.version
    check replayed.tombstones[(original.parent, original.seq)].acknowledgedNodes ==
      @[0'u16, 2'u16]
    check replayed.tombstones[(original.parent, original.seq)].reclaimAfter ==
      deleted.reclaimAfter
    check not replayed.upsert(original, preserveVersion = true)
    let compactStats = replayed.compact()
    check compactStats.tombstones == 1
    let backupStats = replayed.backup(backupDir)
    check backupStats.tombstones == 1
    replayed.close()

    var compacted = openStore(dir)
    check not compacted.upsert(original, preserveVersion = true)
    compacted.close()

    discard restoreBackup(backupDir, restoreDir)
    var restored = openStore(restoreDir)
    check restored.tombstones[(original.parent, original.seq)].version ==
      deleted.version
    check restored.tombstones[(original.parent, original.seq)].acknowledgedNodes ==
      @[0'u16, 2'u16]
    check restored.tombstones[(original.parent, original.seq)].reclaimAfter ==
      deleted.reclaimAfter
    check not restored.upsert(original, preserveVersion = true)
    restored.close()
    removeDir(dir)
    removeDir(backupDir)
    removeDir(restoreDir)

  test "equal tombstone versions merge acknowledgements and final reclaim replays":
    let dir = createTempDir("kouten-store", "tombstone-reclaim")
    let k = (151'u64, 4'u32)
    let version = mutationVersion(20, 1)
    var st = openStore(dir)
    check st.applyTombstone(Tombstone(
      parent: k[0], seq: k[1], period: 60.0, head: 0.4, tWrite: 2.0,
      version: version, acknowledgedNodes: @[2'u16, 0'u16]))
    check st.tombstones[k].acknowledgedNodes == @[0'u16, 2'u16]
    check st.applyTombstone(Tombstone(
      parent: k[0], seq: k[1], period: 60.0, head: 0.4, tWrite: 2.0,
      version: version, acknowledgedNodes: @[1'u16, 2'u16],
      reclaimAfter: 12345.0))
    check st.tombstones[k].acknowledgedNodes == @[0'u16, 1'u16, 2'u16]
    check st.tombstones[k].reclaimAfter == 12345.0
    check not st.applyTombstone(Tombstone(
      parent: k[0], seq: k[1], period: 60.0, head: 0.4, tWrite: 2.0,
      version: version, acknowledgedNodes: @[0'u16]))
    expect ValueError:
      discard st.applyTombstone(Tombstone(
        parent: k[0], seq: k[1], period: 60.0, head: 0.4, tWrite: 2.0,
        version: version, reclaimAfter: -1.0))
    st.close()

    var replayed = openStore(dir)
    check replayed.tombstones[k].acknowledgedNodes == @[0'u16, 1'u16, 2'u16]
    check replayed.tombstones[k].reclaimAfter == 12345.0
    check replayed.reclaimTombstone(k[0], k[1])
    check k notin replayed.tombstones
    replayed.close()

    var reclaimed = openStore(dir)
    check k notin reclaimed.tombstones
    check not reclaimed.reclaimTombstone(k[0], k[1])
    reclaimed.close()
    removeDir(dir)

  test "tombstone acknowledgement encoding is canonical and strict":
    check canonicalAcknowledgedNodes(@[3'u16, 1'u16, 3'u16, 0'u16]) ==
      @[0'u16, 1'u16, 3'u16]
    check acknowledgedNodesField(@[2'u16, 0'u16, 2'u16]) == "0,2"
    check parseAcknowledgedNodes("2,0,2") == @[0'u16, 2'u16]
    check @[0'u16, 1'u16, 2'u16].acknowledgesAllNodes(3)
    check not @[0'u16, 2'u16].acknowledgesAllNodes(3)
    expect ValueError:
      discard parseAcknowledgedNodes("0,,2")
    expect ValueError:
      discard parseAcknowledgedNodes("65536")
    expect ValueError:
      discard parseMutationVersion(@["1", "4294967296", "1"], 0, 1.0)
    expect ValueError:
      discard parseMutationVersion(@["1", "0", "4294967296"], 0, 1.0)

  test "transaction delete persists a tombstone while handoff eviction does not":
    let dir = createTempDir("kouten-store", "transaction-tombstone")
    var st = openStore(dir)
    st.upsert Particle(parent: 16'u64, seq: 0'u32, period: 60.0,
                       head: 0.5, tWrite: 3.0, payload: "delete-me")
    let tx = st.beginTxn()
    tx.remove(16'u64, 0'u32)
    tx.commit()
    check not st.contains(16'u64, 0'u32)
    check (16'u64, 0'u32) in st.tombstones

    st.upsert Particle(parent: 17'u64, seq: 0'u32, period: 60.0,
                       head: 0.6, tWrite: 4.0, payload: "move-me")
    st.evict(17'u64, 0'u32)
    check not st.contains(17'u64, 0'u32)
    check (17'u64, 0'u32) notin st.tombstones
    st.close()

    var restored = openStore(dir)
    check (16'u64, 0'u32) in restored.tombstones
    check (17'u64, 0'u32) notin restored.tombstones
    restored.close()
    removeDir(dir)

  test "transaction delete uses the latest staged particle metadata":
    let dir = createTempDir("kouten-store", "transaction-staged-delete")
    var st = openStore(dir)
    let tx = st.beginTxn()
    tx.upsert Particle(parent: 18'u64, seq: 2'u32, period: 720.0,
                       head: 1.75, tWrite: 42.5, payload: "staged")
    tx.remove(18'u64, 2'u32)
    tx.commit()
    check not st.contains(18'u64, 2'u32)
    check (18'u64, 2'u32) in st.tombstones
    let tombstone = st.tombstones[(18'u64, 2'u32)]
    check tombstone.period == 720.0
    check tombstone.head == 1.75
    check tombstone.tWrite == 42.5

    let noOp = st.beginTxn()
    noOp.remove(18'u64, 99'u32)
    noOp.commit()
    check (18'u64, 99'u32) notin st.tombstones
    st.close()

    var restored = openStore(dir)
    check restored.tombstones[(18'u64, 2'u32)].period == 720.0
    check (18'u64, 99'u32) notin restored.tombstones
    restored.close()
    removeDir(dir)

  test "stellar map blobs are validated before write and replay":
    let dir = createTempDir("kouten-store", "stellar-map-validate")
    var st = openStore(dir)
    st.putStellarMap("commerce/order/A-001",
                     """{"stellar":"commerce/order/A-001","members":["users/123","shops/1123"]}""")
    expect ValueError:
      st.putStellarMap("commerce/order/A-001", """{"members":["users/123"]}""")
    expect ValueError:
      st.putStellarMap("commerce/order/A-001",
                       """{"stellar":"other","members":["users/123"]}""")
    expect ValueError:
      st.putStellarMap("commerce/order/A-001",
                       """{"stellar":"commerce/order/A-001","members":[123]}""")
    st.close()

    var restored = openStore(dir)
    check restored.stellarMaps["commerce/order/A-001"].contains("users/123")
    restored.close()
    removeDir(dir)

    let legacyDir = createTempDir("kouten-store", "stellar-map-bad-replay")
    let malformed = """{"stellar":"commerce/order/A-001","members":[123]}"""
    writeFile(legacyDir / "kouten.log", "SM " & $malformed.len & "\n" & malformed & "\n")
    expect IOError:
      discard openStore(legacyDir)
    removeDir(legacyDir)

  test "time orbit profile survives WAL replay and compact":
    let dir = createTempDir("kouten-store", "time-orbit")
    var st = openStore(dir)
    let profile = TimeOrbitProfile(bits: 60, bucketMs: 1000'i64,
                                   phase: 1234'u64, salt: "logs-api")
    st.putTimeOrbitProfile(77'u64, profile)
    st.close()

    var restored = openStore(dir)
    check restored.ringTimeOrbitProfiles[77'u64] == profile
    discard restored.compact()
    restored.close()

    var compacted = openStore(dir)
    check compacted.ringTimeOrbitProfiles[77'u64] == profile
    compacted.close()
    removeDir(dir)

  when declared(poisonWritesForTest):
    test "poisoned write path rejects later persistent mutations":
      let dir = createTempDir("kouten-store", "poison")
      var st = openStore(dir, durability = durStrong)
      st.upsert Particle(parent: 20'u64, seq: 0'u32, period: 60.0,
                         head: 0.0, tWrite: 1.0, payload: "before")
      st.poisonWritesForTest("simulated fsync failure")
      check st.writeFailed
      expect IOError:
        st.upsert Particle(parent: 20'u64, seq: 1'u32, period: 60.0,
                           head: 0.0, tWrite: 2.0, payload: "after")
      st.close()
      removeDir(dir)

  test "new WAL records have magic header and checksums":
    let dir = createTempDir("kouten-store", "wal-v2")
    var st = openStore(dir)
    st.upsert Particle(parent: 14'u64, seq: 0'u32, period: 60.0, head: 0.0,
                       tWrite: 1.0, payload: "checksummed",
                       codec: pcJson)
    st.close()

    let raw = readFile(dir / "kouten.log")
    check raw.startsWith("!KOUTENDB-WAL 2\n@ ")
    check raw.contains("\nP 14 0 ")

    var restored = openStore(dir)
    check restored.items[(14'u64, 0'u32)].payload == "checksummed"
    check restored.items[(14'u64, 0'u32)].codec == pcJson
    restored.close()
    removeDir(dir)

  test "versioned WAL checksum mismatch refuses open without repair":
    let dir = createTempDir("kouten-store", "wal-v2-corrupt")
    var st = openStore(dir)
    st.upsert Particle(parent: 15'u64, seq: 0'u32, period: 60.0, head: 0.0,
                       tWrite: 1.0, payload: "checksum")
    st.close()

    let path = dir / "kouten.log"
    let raw = readFile(path)
    writeFile(path, raw.replace("checksum", "checksux"))

    expect IOError:
      discard openStore(dir)
    check readFile(path).contains("checksux")
    removeDir(dir)

  test "versioned WAL torn tail repairs to last checked record":
    let dir = createTempDir("kouten-store", "wal-v2-tail")
    var st = openStore(dir)
    st.upsert Particle(parent: 16'u64, seq: 0'u32, period: 60.0, head: 0.0,
                       tWrite: 1.0, payload: "stable")
    st.close()

    let path = dir / "kouten.log"
    let good = readFile(path)
    writeFile(path, good & "@ 80 0\nP 16 1 60.0 0.0 2.0 7 0 raw\npartial")

    var restored = openStore(dir)
    check restored.count() == 1
    check restored.items[(16'u64, 0'u32)].payload == "stable"
    check not restored.contains(16'u64, 1'u32)
    restored.close()
    check readFile(path) == good
    removeDir(dir)

  test "Forwarder は F レコードで復元される":
    let dir = createTempDir("kouten-store", "fwd")
    var st = openStore(dir)
    st.putForwarder(0'u64, 7'u32,
                    Forwarder(newParent: 99'u64, newSeq: 2'u32,
                              newTWrite: 12.5, expiresAt: 123.0))
    st.close()

    var st2 = openStore(dir)
    let f = st2.forwarders[(0'u64, 7'u32)]
    check f.newParent == 99'u64
    check f.newSeq == 2'u32
    check f.newTWrite == 12.5
    check f.expiresAt == 123.0
    st2.close()
    removeDir(dir)

  test "Warp job snapshot は WJ レコードで復元される":
    let dir = createTempDir("kouten-store", "warp")
    var st = openStore(dir)
    st.putWarpJob(42'u64, """{"id":42,"status":"wsPending"}""")
    st.close()

    var st2 = openStore(dir)
    check st2.warpJobs[42'u64].contains("\"status\":\"wsPending\"")
    discard st2.compact()
    st2.close()

    var st3 = openStore(dir)
    check st3.warpJobs[42'u64].contains("\"id\":42")
    st3.deleteWarpJob(42'u64)
    check 42'u64 notin st3.warpJobs
    st3.close()

    var st4 = openStore(dir)
    check 42'u64 notin st4.warpJobs
    discard st4.compact()
    st4.close()

    var st5 = openStore(dir)
    check 42'u64 notin st5.warpJobs
    st5.close()
    removeDir(dir)

  test "Universe sync event は UJ/UA/UD レコードで復元される":
    let dir = createTempDir("kouten-store", "universe-sync")
    var st = openStore(dir)
    st.putUniverseSyncEvent(7'u64, """{"id":7,"eventKey":"tokyo|social|posts|p1","ring":"posts"}""")
    st.markUniverseSyncEventApplied("tokyo|social|posts|p1")
    st.close()

    var st2 = openStore(dir)
    check st2.universeSyncEvents[7'u64].contains("\"ring\":\"posts\"")
    check st2.isUniverseSyncEventApplied("tokyo|social|posts|p1")
    discard st2.compact()
    st2.close()

    var st3 = openStore(dir)
    check 7'u64 in st3.universeSyncEvents
    check st3.isUniverseSyncEventApplied("tokyo|social|posts|p1")
    st3.deleteUniverseSyncEvent(7'u64)
    st3.close()

    var st4 = openStore(dir)
    check 7'u64 notin st4.universeSyncEvents
    check st4.isUniverseSyncEventApplied("tokyo|social|posts|p1")
    st4.close()
    removeDir(dir)

  test "Universe sync sequence は prune 後も UQ レコードで巻き戻らない":
    let dir = createTempDir("kouten-store", "universe-seq")
    var st = openStore(dir)
    st.putUniverseSyncEvent(1'u64, """{"id":1,"eventKey":"e1","ring":"r"}""")
    st.setNextUniverseSyncId(9'u64)
    st.deleteUniverseSyncEvent(1'u64)
    st.close()

    var st2 = openStore(dir)
    check st2.universeSyncEvents.len == 0
    check st2.nextUniverseSyncId == 9'u64
    discard st2.compact()
    st2.close()

    var st3 = openStore(dir)
    check st3.universeSyncEvents.len == 0
    check st3.nextUniverseSyncId == 9'u64
    st3.close()
    removeDir(dir)

  test "Universe sync applied dedup set can be pruned with WAL replay":
    let dir = createTempDir("kouten-store", "universe-applied-prune")
    var st = openStore(dir)
    st.markUniverseSyncEventApplied("event-1")
    st.markUniverseSyncEventApplied("event-2")
    st.markUniverseSyncEventApplied("event-3")
    check st.pruneAppliedUniverseSyncEvents(2) == 1
    check not st.isUniverseSyncEventApplied("event-1")
    check st.isUniverseSyncEventApplied("event-2")
    check st.isUniverseSyncEventApplied("event-3")
    st.close()

    var reopened = openStore(dir)
    check not reopened.isUniverseSyncEventApplied("event-1")
    check reopened.isUniverseSyncEventApplied("event-2")
    check reopened.isUniverseSyncEventApplied("event-3")
    reopened.close()
    removeDir(dir)

  test "Universe sync event は store transaction commit まで可視化されない":
    let dir = createTempDir("kouten-store", "universe-tx")
    var st = openStore(dir)
    var tx = st.beginTxn()
    tx.putUniverseSyncEvent(3'u64, """{"id":3,"eventKey":"e3","ring":"r"}""")
    tx.rollback()
    st.close()

    var st2 = openStore(dir)
    check 3'u64 notin st2.universeSyncEvents
    tx = st2.beginTxn()
    tx.putUniverseSyncEvent(3'u64, """{"id":3,"eventKey":"e3","ring":"r"}""")
    tx.commit()
    st2.close()

    var st3 = openStore(dir)
    check st3.universeSyncEvents[3'u64].contains("\"eventKey\":\"e3\"")
    check st3.nextUniverseSyncId == 3'u64
    st3.close()
    removeDir(dir)

  test "transaction commit は atomic に復元される":
    let dir = createTempDir("kouten-store", "tx")
    var st = openStore(dir)
    let tx = st.beginTxn()
    tx.upsert Particle(parent: 1'u64, seq: 0'u32, period: 30.0, head: 0.5,
                       tWrite: 1.0, payload: "a")
    tx.upsert Particle(parent: 1'u64, seq: 1'u32, period: 30.0, head: 0.5,
                       tWrite: 2.0, payload: "b",
                       vec: @[1.0'f32, 0.0'f32])
    tx.commit()
    st.close()

    var st2 = openStore(dir)
    check st2.items[(1'u64, 0'u32)].payload == "a"
    check st2.items[(1'u64, 1'u32)].payload == "b"
    check st2.items[(1'u64, 1'u32)].vec == @[1.0'f32, 0.0'f32]
    st2.close()
    removeDir(dir)

  test "strong durability は単発 write と transaction を再open後も復元する":
    let dir = createTempDir("kouten-store", "strong")
    var st = openStore(dir, durability = durStrong)
    st.upsert Particle(parent: 10'u64, seq: 0'u32, period: 30.0, head: 0.1,
                       tWrite: 1.0, payload: "single",
                       vec: @[0.5'f32, 0.5'f32])
    let tx = st.beginTxn()
    tx.upsert Particle(parent: 10'u64, seq: 1'u32, period: 30.0, head: 0.1,
                       tWrite: 2.0, payload: "tx")
    tx.commit()
    st.close()

    var st2 = openStore(dir, durability = durStrong)
    check st2.items[(10'u64, 0'u32)].payload == "single"
    check st2.items[(10'u64, 0'u32)].vec == @[0.5'f32, 0.5'f32]
    check st2.items[(10'u64, 1'u32)].payload == "tx"
    st2.close()
    removeDir(dir)

  test "commit marker のない transaction は replay で無視される":
    let dir = createTempDir("kouten-store", "tx-partial")
    writeFile(dir / "kouten.log",
              "T 7\n" &
              "XP 7 2 0 60.0 0.0 1.0 5 0\nhello\n")
    var st = openStore(dir)
    check not st.contains(2'u64, 0'u32)
    st.close()
    removeDir(dir)

  test "legacy transaction delete of a missing key remains a no-op":
    let dir = createTempDir("kouten-store", "legacy-missing-delete")
    writeFile(dir / "kouten.log",
              "T 7\n" &
              "XD 7 2 0\n" &
              "C 7\n")
    var st = openStore(dir)
    check not st.contains(2'u64, 0'u32)
    check (2'u64, 0'u32) notin st.tombstones
    st.close()
    removeDir(dir)

  test "WAL 末尾の不完全レコードは最後の完全レコードまで repair される":
    let dir = createTempDir("kouten-store", "torn-tail")
    let good = "P 2 0 60.0 0.0 1.0 5\nhello\n"
    writeFile(dir / "kouten.log",
              good &
              "P 2 1 60.0 0.0 2.0 11\npartial")

    var st = openStore(dir)
    check st.count() == 1
    check st.items[(2'u64, 0'u32)].payload == "hello"
    check not st.contains(2'u64, 1'u32)
    check readFile(dir / "kouten.log") == good
    st.upsert Particle(parent: 2'u64, seq: 2'u32, period: 60.0, head: 0.0,
                       tWrite: 3.0, payload: "after")
    st.close()

    var st2 = openStore(dir)
    check st2.count() == 2
    check st2.items[(2'u64, 0'u32)].payload == "hello"
    check st2.items[(2'u64, 2'u32)].payload == "after"
    check not st2.contains(2'u64, 1'u32)
    st2.close()
    removeDir(dir)

  test "WAL 末尾の不正な長さ指定は repair される":
    let dir = createTempDir("kouten-store", "bad-len-tail")
    let good = "P 2 0 60.0 0.0 1.0 5\nhello\n"
    writeFile(dir / "kouten.log",
              good &
              "P 2 1 60.0 0.0 2.0 -1 0\n")

    var st = openStore(dir)
    check st.count() == 1
    check st.items[(2'u64, 0'u32)].payload == "hello"
    check not st.contains(2'u64, 1'u32)
    check readFile(dir / "kouten.log") == good
    st.close()
    removeDir(dir)

  test "WAL 末尾の不正な vector 次元は repair される":
    let dir = createTempDir("kouten-store", "bad-vec-tail")
    let good = "P 2 0 60.0 0.0 1.0 5\nhello\n"
    writeFile(dir / "kouten.log",
              good &
              "E 2 0 -1\n")

    var st = openStore(dir)
    check st.count() == 1
    check st.items[(2'u64, 0'u32)].payload == "hello"
    check st.items[(2'u64, 0'u32)].vec.len == 0
    check readFile(dir / "kouten.log") == good
    st.close()
    removeDir(dir)

  test "WAL 中間破損は tail repair せず起動を拒否する":
    let dir = createTempDir("kouten-store", "mid-corrupt")
    let wal = "P 2 0 60.0 0.0 1.0 5\nhello\n" &
              "P 2 1 60.0 0.0 2.0 -1 0\n" &
              "P 2 2 60.0 0.0 3.0 5 0\nlater\n"
    writeFile(dir / "kouten.log", wal)

    expect IOError:
      discard openStore(dir)
    check readFile(dir / "kouten.log") == wal
    removeDir(dir)

  test "commit marker が torn tail の transaction は repair 後も適用されない":
    let dir = createTempDir("kouten-store", "tx-torn-tail")
    let good = "P 1 0 60.0 0.0 1.0 4\nbase\n"
    writeFile(dir / "kouten.log",
              good &
              "T 12\n" &
              "XP 12 1 1 60.0 0.0 2.0 6 0\ninside\n" &
              "C")

    var st = openStore(dir)
    check st.count() == 1
    check st.items[(1'u64, 0'u32)].payload == "base"
    check not st.contains(1'u64, 1'u32)
    check readFile(dir / "kouten.log") == good &
      "T 12\n" &
      "XP 12 1 1 60.0 0.0 2.0 6 0\ninside\n"
    st.close()

    var st2 = openStore(dir)
    check st2.count() == 1
    check not st2.contains(1'u64, 1'u32)
    st2.close()
    removeDir(dir)

  test "cluster transaction intent は applied まで保持される":
    let dir = createTempDir("kouten-store", "cluster-tx")
    var st = openStore(dir)
    st.putClusterTxIntent ClusterTxIntent(
      id: 9'u64,
      ops: @[ClusterTxOp(parent: 3'u64, seq: 1'u32, period: 60.0,
                         head: 0.2, tWrite: 10.0, payload: "v",
                         vec: @[1.0'f32, 0.0'f32])],
      committed: true)
    st.close()

    var st2 = openStore(dir)
    check 9'u64 in st2.clusterTx
    check st2.clusterTx[9'u64].committed
    check not st2.clusterTx[9'u64].applied
    st2.markClusterTxApplied(9'u64)
    st2.markClusterTxApplied(9'u64)
    st2.close()

    check readFile(dir / "kouten.log").count("CA 9\n") == 1

    var st3 = openStore(dir)
    check st3.clusterTx[9'u64].applied
    st3.close()
    removeDir(dir)

  test "cluster transaction mirror state survives replay and compact":
    let dir = createTempDir("kouten-store", "cluster-tx-replicated")
    let request = ClusterTxIntent(
      id: 19'u64,
      ops: @[ClusterTxOp(parent: 8'u64, seq: 2'u32, period: 60.0,
                         head: 0.4, tWrite: 20.0, payload: "mirrored",
                         vec: @[0.0'f32, 1.0'f32])],
      committed: true)
    var st = openStore(dir)
    st.putClusterTxIntent(request)
    check not st.clusterTxIntent(19).replicated
    st.markClusterTxReplicated(19, 3, 2)
    st.markClusterTxReplicated(19, 3, 2) # acknowledgement replay is idempotent
    check st.clusterTxIntent(19).replicated
    check st.clusterTxIntent(19).replicatedEpoch == 3
    check st.clusterTxIntent(19).replicatedNode == 2
    st.close()

    var replayed = openStore(dir)
    check replayed.clusterTxIntent(19).replicated
    check replayed.clusterTxIntent(19).replicatedEpoch == 3
    check replayed.clusterTxIntent(19).replicatedNode == 2
    discard replayed.compact()
    replayed.close()

    var compacted = openStore(dir)
    check compacted.clusterTxIntent(19).replicated
    check compacted.clusterTxIntent(19).replicatedEpoch == 3
    check compacted.clusterTxIntent(19).replicatedNode == 2
    compacted.close()
    removeDir(dir)

  test "legacy cluster transaction mirror marker survives compact":
    let dir = createTempDir("kouten-store", "cluster-tx-legacy-replicated")
    var st = openStore(dir)
    st.putClusterTxIntent ClusterTxIntent(
      id: 20'u64,
      ops: @[ClusterTxOp(parent: 9'u64, seq: 1'u32, period: 60.0,
                         head: 0.5, tWrite: 21.0, payload: "legacy")],
      committed: true)
    st.markClusterTxReplicated(20)
    st.close()

    var replayed = openStore(dir)
    check replayed.clusterTxIntent(20).replicated
    check replayed.clusterTxIntent(20).replicatedEpoch == 0
    check replayed.clusterTxIntent(20).replicatedNode == -1
    discard replayed.compact()
    replayed.close()

    var compacted = openStore(dir)
    check compacted.clusterTxIntent(20).replicated
    check compacted.clusterTxIntent(20).replicatedEpoch == 0
    check compacted.clusterTxIntent(20).replicatedNode == -1
    compacted.close()
    removeDir(dir)

  test "cluster transaction retry accepts the same intent and rejects collision":
    var st = openStore("")
    let request = ClusterTxIntent(
      id: 23'u64,
      ops: @[ClusterTxOp(parent: 4'u64, seq: 1'u32, period: 60.0,
                         head: 0.1, tWrite: 3.0, payload: "same")],
      committed: true)
    st.putClusterTxIntent(request)
    st.putClusterTxIntent(request)
    check st.clusterTxCommitted == 1
    var collision = request
    collision.ops[0].payload = "different"
    expect ValueError:
      st.putClusterTxIntent(collision)
    st.close()

  test "cluster transaction identity collision matrix fails closed":
    proc baseIntent(): ClusterTxIntent =
      ClusterTxIntent(
        id: 24'u64,
        ops: @[ClusterTxOp(
          kind: ctxPut, parent: 4'u64, seq: 1'u32, period: 60.0,
          head: 0.1, tWrite: 3.0, payload: "same", codec: pcJson,
          vec: @[1.0'f32, 0.0'f32])],
        committed: true)

    let dir = createTempDir("kouten-store", "cluster-tx-collision-matrix")
    var st = openStore(dir)
    st.putClusterTxIntent(baseIntent())
    st.close()

    st = openStore(dir)
    # An identical request with an implicit version remains retryable after
    # WAL replay even though the stored intent now has a generated version.
    st.putClusterTxIntent(baseIntent())
    let names = ["op-count", "kind", "parent", "seq", "period", "head",
                 "tWrite", "payload", "codec", "vector", "version"]
    for variant in 0 .. names.high:
      checkpoint names[variant]
      var changed = baseIntent()
      case variant
      of 0:
        changed.ops.add changed.ops[0]
      of 1:
        changed.ops[0].kind = ctxDelete
      of 2:
        changed.ops[0].parent = 5'u64
      of 3:
        changed.ops[0].seq = 2'u32
      of 4:
        changed.ops[0].period = 61.0
      of 5:
        changed.ops[0].head = 0.2
      of 6:
        changed.ops[0].tWrite = 4.0
      of 7:
        changed.ops[0].payload = "different"
      of 8:
        changed.ops[0].codec = pcNif
      of 9:
        changed.ops[0].vec = @[0.0'f32, 1.0'f32]
      of 10:
        changed.ops[0].version = mutationVersion(9_000)
      else:
        discard
      expect ValueError:
        st.putClusterTxIntent(changed)
    check st.clusterTxCommitted == 1
    st.close()
    removeDir(dir)

  test "orphan cluster transaction WAL records fail closed":
    for record in ["CP 31 P 4 1 60.0 0.1 3.0 0 0\n\n",
                   "CC 31\n"]:
      let dir = createTempDir("kouten-store", "cluster-tx-orphan")
      writeFile(dir / "kouten.log", record)
      expect IOError:
        discard openStore(dir)
      removeDir(dir)

  test "compact 中断で tmp だけ残った場合は tmp を正規 WAL として復旧する":
    let dir = createTempDir("kouten-store", "compact-tmp")
    writeFile(dir / "kouten.log.compact",
              "G 11\nrecover-tmp\n" &
              "P 5 0 60.0 0.0 1.0 4\nlive\n")

    var st = openStore(dir)
    check st.galaxy == "recover-tmp"
    check st.count() == 1
    check st.items[(5'u64, 0'u32)].payload == "live"
    check fileExists(dir / "kouten.log")
    check not fileExists(dir / "kouten.log.compact")
    st.close()
    removeDir(dir)

  test "compact 中断で正規 WAL と tmp が両方ある場合は正規 WAL を優先する":
    let dir = createTempDir("kouten-store", "compact-log-tmp")
    writeFile(dir / "kouten.log",
              "P 6 0 60.0 0.0 1.0 4\nkeep\n")
    writeFile(dir / "kouten.log.compact",
              "P 6 1 60.0 0.0 2.0 4\ndrop\n")

    var st = openStore(dir)
    check st.count() == 1
    check st.items[(6'u64, 0'u32)].payload == "keep"
    check not st.contains(6'u64, 1'u32)
    check not fileExists(dir / "kouten.log.compact")
    st.close()
    removeDir(dir)

  test "compact 中断で bak だけ残った場合は bak を正規 WAL として復旧する":
    let dir = createTempDir("kouten-store", "compact-bak")
    writeFile(dir / "kouten.log.bak",
              "P 7 0 60.0 0.0 1.0 4\nback\n")

    var st = openStore(dir)
    check st.count() == 1
    check st.items[(7'u64, 0'u32)].payload == "back"
    check fileExists(dir / "kouten.log")
    check not fileExists(dir / "kouten.log.bak")
    st.close()
    removeDir(dir)

  test "compact は生存レコードだけで WAL を再構築する":
    let dir = createTempDir("kouten-store", "compact")
    var st = openStore(dir)
    st.setGalaxy("compact-galaxy")
    st.putGalaxyDescription("compact galaxy description")
    st.putRingName(1'u64, "docs")
    st.putRingDescription(1'u64, "docs ring description")
    st.putRingMeta(1'u64, 60.0, 0.25)
    for i in 0'u32 ..< 40'u32:
      st.upsert Particle(parent: 1'u64, seq: i, period: 60.0, head: 0.25,
                         tWrite: float(i), payload: repeat("x", 128),
                         vec: @[1.0'f32, 0.0'f32])
    for i in 0'u32 ..< 35'u32:
      st.remove(1'u64, i)
    let stats = st.compact()
    check stats.beforeBytes > stats.afterBytes
    check stats.items == 5
    check st.count() == 5
    st.close()

    var st2 = openStore(dir)
    check st2.galaxy == "compact-galaxy"
    check st2.galaxyDescription == "compact galaxy description"
    check st2.ringNames[1'u64] == "docs"
    check st2.ringDescriptions[1'u64] == "docs ring description"
    check st2.ringMeta[1'u64].period == 60.0
    check st2.count() == 5
    check not st2.contains(1'u64, 0'u32)
    check st2.contains(1'u64, 39'u32)
    check st2.items[(1'u64, 39'u32)].payload == repeat("x", 128)
    check st2.items[(1'u64, 39'u32)].vec == @[1.0'f32, 0.0'f32]
    let nextSeq = st2.nextSeq(1'u64)
    check nextSeq == 40'u32
    check st2.maxTWrite == 39.0
    st2.close()
    removeDir(dir)

  test "bare delete replay keeps itemsByRing consistent":
    let dir = createTempDir("kouten-store", "delete-replay-index")
    var st = openStore(dir)
    st.upsert Particle(parent: 30'u64, seq: 0'u32, period: 60.0, head: 0.0,
                       tWrite: 1.0, payload: "deleted")
    st.upsert Particle(parent: 30'u64, seq: 1'u32, period: 60.0, head: 0.0,
                       tWrite: 2.0, payload: "live")
    st.remove(30'u64, 0'u32)
    st.close()

    var reopened = openStore(dir)
    check reopened.count() == 1
    check not reopened.contains(30'u64, 0'u32)
    check reopened.contains(30'u64, 1'u32)
    check reopened.itemsByRing[30'u64] == @[(30'u64, 1'u32)]
    reopened.close()
    removeDir(dir)

  test "locality report は interleaved WAL と compact 後の ring grouping を測る":
    let dir = createTempDir("kouten-store", "locality")
    var st = openStore(dir)
    for i in 0'u32 ..< 12'u32:
      let ring = uint64((i mod 3) + 1)
      st.upsert Particle(parent: ring, seq: i div 3, period: 60.0,
                         head: float(ring), tWrite: float(i),
                         payload: "p" & $i, codec: pcRaw)

    let before = st.localityReport()
    check before.persistent
    check before.liveParticleRecords == 12
    check before.ringCount == 3
    check before.ringRuns == 12
    check before.fragmentedRings == 3
    check before.localityScore < 1.0

    discard st.compact()
    let after = st.localityReport()
    check after.liveParticleRecords == 12
    check after.ringCount == 3
    check after.ringRuns == 3
    check after.fragmentedRings == 0
    check after.localityScore == 1.0
    check after.avgRunRecords == 4.0
    st.close()
    removeDir(dir)

  test "locality report は上書き済み particle record を dead として数える":
    let dir = createTempDir("kouten-store", "locality-dead")
    var st = openStore(dir)
    st.upsert Particle(parent: 7'u64, seq: 0'u32, period: 60.0,
                       head: 0.0, tWrite: 1.0, payload: "old",
                       codec: pcRaw)
    st.upsert Particle(parent: 7'u64, seq: 0'u32, period: 60.0,
                       head: 0.0, tWrite: 2.0, payload: "new",
                       codec: pcRaw)
    let report = st.localityReport()
    check report.totalParticleRecords == 2
    check report.liveParticleRecords == 1
    check report.deadParticleRecords == 1
    st.close()
    removeDir(dir)

  test "locality report matrix covers delete and backfill fragmentation":
    let dir = createTempDir("kouten-store", "locality-matrix")
    var st = openStore(dir)

    for i in 0'u32 ..< 24'u32:
      let ring = uint64((i mod 4) + 1)
      st.upsert Particle(parent: ring, seq: i div 4, period: 60.0,
                         head: float(ring), tWrite: float(i),
                         payload: "p" & $i, codec: pcRaw)

    for i in countup(0'u32, 20'u32, 4):
      st.remove(1'u64, i div 4)

    for i in 0'u32 ..< 8'u32:
      let ring = uint64(((i * 3) mod 4) + 1)
      st.upsert Particle(parent: ring, seq: 100'u32 + i, period: 60.0,
                         head: float(ring), tWrite: 100.0 + float(i),
                         payload: "b" & $i, codec: pcRaw)

    let before = st.localityReport()
    let ring1Before = st.ringSignature(1'u64)
    let ring2Before = st.ringSignature(2'u64)
    let ring3Before = st.ringSignature(3'u64)
    let ring4Before = st.ringSignature(4'u64)
    check before.totalParticleRecords == 32
    check before.liveParticleRecords == 26
    check before.deadParticleRecords == 6
    check before.ringCount == 4
    check before.fragmentedRings > 0
    check before.localityScore < 1.0

    discard st.compact()
    let after = st.localityReport()
    check st.ringSignature(1'u64) == ring1Before
    check st.ringSignature(2'u64) == ring2Before
    check st.ringSignature(3'u64) == ring3Before
    check st.ringSignature(4'u64) == ring4Before
    check after.totalParticleRecords == 26
    check after.liveParticleRecords == 26
    check after.deadParticleRecords == 0
    check after.ringCount == 4
    check after.ringRuns == 4
    check after.fragmentedRings == 0
    check after.localityScore == 1.0
    st.close()
    removeDir(dir)

  test "disk-backed locality report classifies current update delete and transaction records":
    let dir = createTempDir("kouten-store", "disk-locality")
    var st = openStore(dir, diskBacked = true)
    st.upsert Particle(parent: 7'u64, seq: 0'u32, period: 60.0,
                       head: 0.0, tWrite: 1.0, payload: "old")
    st.upsert Particle(parent: 7'u64, seq: 0'u32, period: 60.0,
                       head: 0.0, tWrite: 2.0, payload: "current")
    st.upsert Particle(parent: 8'u64, seq: 0'u32, period: 60.0,
                       head: 0.0, tWrite: 3.0, payload: "deleted")
    st.remove(8'u64, 0'u32)

    let tx = st.beginTxn()
    tx.upsert Particle(parent: 9'u64, seq: 0'u32, period: 60.0,
                       head: 0.0, tWrite: 4.0, payload: "transaction")
    tx.commit()
    for i in 0'u32 ..< 16'u32:
      st.upsert Particle(parent: 10'u64, seq: i, period: 60.0,
                         head: 0.0, tWrite: 10.0 + float(i),
                         payload: "packed-" & $i)

    check st.items.len == 0
    check st.itemOffsets.len == 18
    let before = st.localityReport()
    check before.totalParticleRecords == 20
    check before.liveParticleRecords == 18
    check before.deadParticleRecords == 2
    check before.ringCount == 3
    check before.ringRuns == 3
    check before.fragmentedRings == 0
    check before.localityScore == 1.0
    st.close()

    var reopened = openStore(dir, diskBacked = true)
    check reopened.items.len == 0
    check reopened.itemOffsets.len == 18
    check reopened.itemSegmentOffsets.len == 18
    check reopened.getParticle(7'u64, 0'u32).payload == "current"
    check reopened.getParticle(9'u64, 0'u32).payload == "transaction"
    let after = reopened.localityReport()
    check after.totalParticleRecords == 20
    check after.liveParticleRecords == 18
    check after.deadParticleRecords == 2
    check after.ringCount == 3
    check after.ringRuns == 3
    check after.fragmentedRings == 0
    check after.localityScore == 1.0
    reopened.close()
    removeDir(dir)

  test "disk-backed reopen reuses validated ring segments without a WAL rebuild":
    let dir = createTempDir("kouten-store", "segment-index-reuse")
    let ring = 61'u64
    let segment = dir / "segments" / (toHex(ring, 16) & ".seg")
    let index = dir / "segments" / (toHex(ring, 16) & ".idx")
    var st = openStore(dir, diskBacked = true)
    for i in 0'u32 ..< 4'u32:
      st.upsert Particle(parent: ring, seq: i, period: 60.0, head: 0.0,
                         tWrite: float(i), payload: "segment-" & $i)
    st.sync()
    let beforeSegment = readFile(segment)
    let beforeIndex = readFile(index)
    st.close()

    var reopened = openStore(dir, diskBacked = true)
    check reopened.itemSegmentOffsets.len == 4
    check reopened.getParticle(ring, 3'u32).payload == "segment-3"
    reopened.close()
    check readFile(segment) == beforeSegment
    check readFile(index) == beforeIndex
    removeDir(dir)

  test "checksummed segments remain compatible with a legacy unframed record":
    let dir = createTempDir("kouten-store", "segment-legacy-frame")
    let ring = 611'u64
    let segment = dir / "segments" / (toHex(ring, 16) & ".seg")
    var st = openStore(dir, diskBacked = true)
    st.upsert Particle(parent: ring, seq: 0'u32, period: 60.0, head: 0.0,
                       tWrite: 1.0, payload: "legacy-compatible")
    st.sync()
    st.close()

    let framed = readFile(segment)
    check framed.startsWith("@ ")
    let headerEnd = framed.find('\n')
    check headerEnd > 0
    writeFile(segment, framed[headerEnd + 1 .. ^1])

    var reopened = openStore(dir, diskBacked = true)
    check reopened.getParticle(ring, 0'u32).payload == "legacy-compatible"
    check reopened.segmentReport().segmentHits == 1
    reopened.close()
    removeDir(dir)

  test "damaged ring segment falls back to its authoritative WAL record":
    let dir = createTempDir("kouten-store", "segment-wal-fallback")
    let ring = 62'u64
    let segment = dir / "segments" / (toHex(ring, 16) & ".seg")
    var st = openStore(dir, diskBacked = true)
    st.upsert Particle(parent: ring, seq: 0'u32, period: 60.0, head: 0.0,
                       tWrite: 1.0, payload: "durable-payload")
    st.sync()
    st.close()
    writeFile(segment, "X")

    var reopened = openStore(dir, diskBacked = true)
    check reopened.getParticle(ring, 0'u32).payload == "durable-payload"
    check reopened.itemSegmentOffsets.len == 0
    let fallbackReport = reopened.segmentReport()
    check fallbackReport.walFallbacks == 1
    check fallbackReport.walFallbackReasons[ssfrPointRead] == 1
    reopened.close()
    removeDir(dir)

  test "mid-segment corruption discards partial output and replays the whole ring from WAL":
    let dir = createTempDir("kouten-store", "segment-full-scan-fallback")
    let ring = 620'u64
    let segment = dir / "segments" / (toHex(ring, 16) & ".seg")
    var st = openStore(dir, diskBacked = true)
    for i in 0'u32 ..< 5'u32:
      st.upsert Particle(parent: ring, seq: i, period: 60.0, head: 0.0,
                         tWrite: float(i), payload: "payload-" & $i)
    st.sync()
    st.close()

    let original = readFile(segment)
    check original.contains("payload-2")
    writeFile(segment, original.replace("payload-2", "payload-X"))

    var reopened = openStore(dir, diskBacked = true)
    var seen: seq[string] = @[]
    for p in reopened.particlesByRing(ring):
      seen.add $p.seq & ":" & p.payload
    check seen == @["0:payload-0", "1:payload-1", "2:payload-2",
                    "3:payload-3", "4:payload-4"]
    let report = reopened.segmentReport()
    check report.segmentHits == 0
    check report.walFallbacks == 1
    check report.walFallbackReasons[ssfrRingScan] == 1
    reopened.close()
    removeDir(dir)

  test "malformed segment index is rebuilt from WAL without data loss":
    let dir = createTempDir("kouten-store", "segment-index-recover")
    let ring = 63'u64
    let index = dir / "segments" / (toHex(ring, 16) & ".idx")
    var st = openStore(dir, diskBacked = true)
    st.upsert Particle(parent: ring, seq: 0'u32, period: 60.0, head: 0.0,
                       tWrite: 1.0, payload: "recover-index")
    st.sync()
    st.close()
    writeFile(index, "broken index\n")

    var reopened = openStore(dir, diskBacked = true)
    check reopened.getParticle(ring, 0'u32).payload == "recover-index"
    check reopened.itemSegmentOffsets.len == 1
    check readFile(index).startsWith("P ")
    reopened.close()
    removeDir(dir)

  test "valid-looking index offset for the wrong record falls back to WAL":
    let dir = createTempDir("kouten-store", "segment-index-mismatch")
    let ring = 630'u64
    let index = dir / "segments" / (toHex(ring, 16) & ".idx")
    var st = openStore(dir, diskBacked = true)
    for i in 0'u32 ..< 3'u32:
      st.upsert Particle(parent: ring, seq: i, period: 60.0, head: 0.0,
                         tWrite: float(i), payload: "indexed-" & $i)
    st.sync()
    st.close()

    var rows = readFile(index).splitLines()
    let second = rows[1].splitWhitespace()
    var first = rows[0].splitWhitespace()
    check first.len == 5
    check second.len == 5
    first[4] = second[4]
    rows[0] = first.join(" ")
    writeFile(index, rows.join("\n") & "\n")

    var reopened = openStore(dir, diskBacked = true)
    check reopened.itemSegmentOffsets.len == 3
    check reopened.getParticle(ring, 0'u32).payload == "indexed-0"
    check reopened.itemSegmentOffsets.len == 2
    let report = reopened.segmentReport()
    check report.walFallbacks == 1
    check report.walFallbackReasons[ssfrPointRead] == 1
    reopened.close()
    removeDir(dir)

  test "ring metadata keeps sequence order for out-of-order first writes":
    let dir = createTempDir("kouten-store", "ring-key-sequence-order")
    let ring = 630'u64
    var st = openStore(dir, diskBacked = true)
    for sequence in [9'u32, 1'u32, 5'u32, 3'u32]:
      st.upsert Particle(parent: ring, seq: sequence, period: 60.0, head: 0.0,
                         tWrite: float(sequence), payload: "item-" & $sequence)
    check st.itemsByRing[ring].mapIt(it[1]) ==
      @[1'u32, 3'u32, 5'u32, 9'u32]
    check st.particlesByRingWindow(ring, 10).mapIt(it.seq) ==
      @[1'u32, 3'u32, 5'u32, 9'u32]
    let firstPage = st.itemKeysByRingPage(ring, -1, 2)
    check firstPage.items.mapIt(it[1]) == @[1'u32, 3'u32]
    check firstPage.hasMore
    let secondPage = st.itemKeysByRingPage(ring, 3, 2)
    check secondPage.items.mapIt(it[1]) == @[5'u32, 9'u32]
    check not secondPage.hasMore
    st.close()

    var reopened = openStore(dir, diskBacked = true)
    check reopened.itemsByRing[ring].mapIt(it[1]) ==
      @[1'u32, 3'u32, 5'u32, 9'u32]
    reopened.close()
    removeDir(dir)

  test "bounded ring windows handle limits direction deletes and post-pack writes":
    let dir = createTempDir("kouten-store", "segment-window-boundaries")
    let ring = 631'u64
    var st = openStore(dir, diskBacked = true)
    for i in 0'u32 ..< 6'u32:
      st.upsert Particle(parent: ring, seq: i, period: 60.0, head: 0.0,
                         tWrite: float(i), payload: "base-" & $i)
    discard st.packRingSegment(ring)
    st.upsert Particle(parent: ring, seq: 0'u32, period: 60.0, head: 0.0,
                       tWrite: 100.0, payload: "updated-0")
    discard st.remove(ring, 1'u32)
    st.upsert Particle(parent: ring, seq: 6'u32, period: 60.0, head: 0.0,
                       tWrite: 101.0, payload: "new-6")

    check st.particlesByRingWindow(ring, 0).len == 0
    let forward = st.particlesByRingWindow(ring, 2)
    check forward.mapIt(it.seq) == @[0'u32, 2'u32]
    check forward[0].payload == "updated-0"
    let reverse = st.particlesByRingWindow(ring, 2, reverse = true)
    check reverse.mapIt(it.seq) == @[6'u32, 5'u32]
    check reverse[0].payload == "new-6"
    check st.particlesByRingWindow(ring, 100).mapIt(it.seq) ==
      @[0'u32, 2'u32, 3'u32, 4'u32, 5'u32, 6'u32]
    st.close()

    var reopened = openStore(dir, diskBacked = true)
    check reopened.particlesByRingWindow(ring, 2).mapIt(it.seq) ==
      @[0'u32, 2'u32]
    check reopened.particlesByRingWindow(ring, 2, reverse = true).mapIt(it.seq) ==
      @[6'u32, 5'u32]
    reopened.close()
    removeDir(dir)

  test "disk-backed compact refreshes WAL offsets and ring segments in-process":
    let dir = createTempDir("kouten-store", "disk-compact-offsets")
    var st = openStore(dir, diskBacked = true)
    st.upsert Particle(parent: 64'u64, seq: 0'u32, period: 60.0, head: 0.0,
                       tWrite: 1.0, payload: "old")
    st.upsert Particle(parent: 64'u64, seq: 0'u32, period: 60.0, head: 0.0,
                       tWrite: 2.0, payload: "current")
    st.upsert Particle(parent: 65'u64, seq: 0'u32, period: 60.0, head: 0.0,
                       tWrite: 3.0, payload: "removed")
    discard st.remove(65'u64, 0'u32)
    discard st.compact()
    check st.getParticle(64'u64, 0'u32).payload == "current"
    check not st.contains(65'u64, 0'u32)
    st.upsert Particle(parent: 64'u64, seq: 1'u32, period: 60.0, head: 0.0,
                       tWrite: 4.0, payload: "after-compact")
    check st.getParticle(64'u64, 1'u32).payload == "after-compact"
    st.close()

    var reopened = openStore(dir, diskBacked = true)
    check reopened.getParticle(64'u64, 0'u32).payload == "current"
    check reopened.getParticle(64'u64, 1'u32).payload == "after-compact"
    check not reopened.contains(65'u64, 0'u32)
    reopened.close()
    removeDir(dir)

  test "disk-backed backup and restore preserve segment-resident records":
    let dir = createTempDir("kouten-store", "disk-backup-src")
    let backupDir = createTempDir("kouten-store", "disk-backup")
    let restoredDir = createTempDir("kouten-store", "disk-backup-restore")
    var st = openStore(dir, diskBacked = true)
    st.upsert Particle(parent: 66'u64, seq: 0'u32, period: 60.0, head: 0.0,
                       tWrite: 1.0, payload: "first")
    st.upsert Particle(parent: 66'u64, seq: 1'u32, period: 60.0, head: 0.0,
                       tWrite: 2.0, payload: "second")
    let stats = st.backup(backupDir)
    check stats.items == 2
    st.close()

    removeDir(restoredDir)
    discard restoreBackup(backupDir, restoredDir)
    var restored = openStore(restoredDir, diskBacked = true)
    check restored.getParticle(66'u64, 0'u32).payload == "first"
    check restored.getParticle(66'u64, 1'u32).payload == "second"
    restored.close()
    removeDir(dir)
    removeDir(backupDir)
    removeDir(restoredDir)

  test "uncommitted disk-backed transaction never reaches a ring segment":
    let dir = createTempDir("kouten-store", "disk-segment-transaction")
    var st = openStore(dir, diskBacked = true)
    let tx = st.beginTxn()
    tx.upsert Particle(parent: 67'u64, seq: 0'u32, period: 60.0, head: 0.0,
                       tWrite: 1.0, payload: "uncommitted")
    tx.rollback()
    st.close()

    var reopened = openStore(dir, diskBacked = true)
    check not reopened.contains(67'u64, 0'u32)
    check reopened.itemSegmentOffsets.len == 0
    reopened.close()
    removeDir(dir)

  test "ring pack switches only its manifest generation":
    let dir = createTempDir("kouten-store", "ring-pack-generation")
    let packedRing = 68'u64
    let untouchedRing = 69'u64
    let manifest = dir / "segments" / "manifest"
    var st = openStore(dir, diskBacked = true)
    for i in 0'u32 ..< 3'u32:
      st.upsert Particle(parent: packedRing, seq: i, period: 60.0, head: 0.0,
                         tWrite: float(i), payload: "packed-" & $i)
      st.upsert Particle(parent: untouchedRing, seq: i, period: 60.0, head: 0.0,
                         tWrite: float(i), payload: "untouched-" & $i)
    let packed = st.packRingSegment(packedRing)
    check packed.records == 3
    check packed.rings == 1
    check fileExists(manifest)
    check st.getParticle(packedRing, 2'u32).payload == "packed-2"
    check st.getParticle(untouchedRing, 2'u32).payload == "untouched-2"
    st.close()

    var reopened = openStore(dir, diskBacked = true)
    check reopened.getParticle(packedRing, 0'u32).payload == "packed-0"
    check reopened.getParticle(untouchedRing, 0'u32).payload == "untouched-0"
    reopened.close()
    removeDir(dir)

  test "segment diagnostics recommend stale rings and reset after pack":
    let dir = createTempDir("kouten-store", "segment-diagnostics")
    let ring = 71'u64
    var st = openStore(dir, diskBacked = true)
    for i in 0'u32 ..< 4'u32:
      st.upsert Particle(parent: ring, seq: i, period: 60.0, head: 0.0,
                         tWrite: float(i), payload: "base-" & $i)
    for i in 0'u32 ..< 8'u32:
      let seq = i mod 4
      st.upsert Particle(parent: ring, seq: seq, period: 60.0, head: 0.0,
                         tWrite: 100.0 + float(i), payload: "update-" & $i)

    let before = st.segmentReport(staleRatioThreshold = 0.5,
                                  minStaleRecords = 4)
    check before.rings.len == 1
    check before.rings[0].liveRecords == 4
    check before.rings[0].coveredRecords == 4
    check before.rings[0].segmentRecords == 12
    check before.rings[0].staleRecords == 8
    check before.rings[0].staleRatio > 0.66
    check before.rings[0].packRecommended
    check before.recommendedRings == 1
    let exactBoundary = st.segmentReport(
      staleRatioThreshold = before.rings[0].staleRatio,
      minStaleRecords = before.rings[0].staleRecords)
    check exactBoundary.rings[0].packRecommended
    check not st.segmentReport(
      staleRatioThreshold = before.rings[0].staleRatio,
      minStaleRecords = before.rings[0].staleRecords + 1).rings[0].packRecommended
    expect ValueError:
      discard st.segmentReport(staleRatioThreshold = -0.01)
    expect ValueError:
      discard st.segmentReport(staleRatioThreshold = 1.01)
    expect ValueError:
      discard st.segmentReport(minStaleRecords = -1)

    discard st.packRingSegment(ring)
    let after = st.segmentReport(staleRatioThreshold = 0.5,
                                 minStaleRecords = 4)
    check after.rings[0].generation == 1
    check after.rings[0].segmentRecords == 4
    check after.rings[0].staleRecords == 0
    check not after.rings[0].packRecommended
    check after.recommendedRings == 0
    st.close()
    removeDir(dir)

  test "corrupt segment manifest rebuilds the cache from WAL":
    let dir = createTempDir("kouten-store", "segment-manifest-recover")
    let ring = 70'u64
    let manifest = dir / "segments" / "manifest"
    var st = openStore(dir, diskBacked = true)
    st.upsert Particle(parent: ring, seq: 0'u32, period: 60.0, head: 0.0,
                       tWrite: 1.0, payload: "manifest-recovery")
    discard st.packRingSegment(ring)
    st.close()
    writeFile(manifest, "not a segment manifest\n")

    var reopened = openStore(dir, diskBacked = true)
    check reopened.getParticle(ring, 0'u32).payload == "manifest-recovery"
    check reopened.itemSegmentOffsets.len == 1
    reopened.close()
    removeDir(dir)

  test "disk-backed random update delete backfill matrix preserves ring results across pack":
    let dir = createTempDir("kouten-store", "segment-random-matrix")
    const Rings = 5
    const PerRing = 40
    var st = openStore(dir, diskBacked = true)
    randomize(42)
    for seq in 0'u32 ..< PerRing.uint32:
      var order = toSeq(0 ..< Rings)
      shuffle(order)
      for r in order:
        let ring = uint64(80 + r)
        st.upsert Particle(parent: ring, seq: seq, period: 60.0,
                           head: float(r), tWrite: float(seq),
                           payload: "base-" & $r & "-" & $seq)
    for i in 0 ..< 120:
      let r = rand(Rings - 1)
      let seq = uint32(rand(PerRing - 1))
      let ring = uint64(80 + r)
      st.upsert Particle(parent: ring, seq: seq, period: 60.0,
                         head: float(r), tWrite: 1_000.0 + float(i),
                         payload: "update-" & $r & "-" & $seq & "-" & $i)
    for _ in 0 ..< 30:
      let r = rand(Rings - 1)
      discard st.remove(uint64(80 + r), uint32(rand(PerRing - 1)))
    for i in 0'u32 ..< 50'u32:
      let r = int(i mod Rings.uint32)
      st.upsert Particle(parent: uint64(80 + r), seq: 100'u32 + i,
                         period: 60.0, head: float(r),
                         tWrite: 2_000.0 + float(i),
                         payload: "backfill-" & $r & "-" & $i)
    var before: seq[seq[string]] = @[]
    for r in 0 ..< Rings:
      before.add st.diskRingSignature(uint64(80 + r))
      discard st.packRingSegment(uint64(80 + r))
      check st.diskRingSignature(uint64(80 + r)) == before[^1]
    st.close()

    var reopened = openStore(dir, diskBacked = true)
    for r in 0 ..< Rings:
      check reopened.diskRingSignature(uint64(80 + r)) == before[r]
    reopened.close()
    removeDir(dir)

  test "locality report does not claim perfect locality when every record is dead":
    let dir = createTempDir("kouten-store", "disk-locality-no-live")
    var st = openStore(dir, diskBacked = true)
    st.upsert Particle(parent: 11'u64, seq: 0'u32, period: 60.0,
                       head: 0.0, tWrite: 1.0, payload: "deleted")
    st.remove(11'u64, 0'u32)

    let report = st.localityReport()
    check report.totalParticleRecords == 1
    check report.liveParticleRecords == 0
    check report.deadParticleRecords == 1
    check report.ringCount == 0
    check report.ringRuns == 0
    check report.localityScore == 0.0
    st.close()
    removeDir(dir)

  test "locality report fails visibly when the open WAL becomes corrupted":
    let dir = createTempDir("kouten-store", "locality-corrupt")
    var st = openStore(dir, diskBacked = true)
    st.upsert Particle(parent: 12'u64, seq: 0'u32, period: 60.0,
                       head: 0.0, tWrite: 1.0, payload: "checksum")
    st.sync()

    let walPath = dir / "kouten.log"
    writeFile(walPath, readFile(walPath).replace("checksum", "checksux"))
    expect IOError:
      discard st.localityReport()
    st.close()
    removeDir(dir)

  test "strong durability の compact 後も WAL は復元できる":
    let dir = createTempDir("kouten-store", "strong-compact")
    var st = openStore(dir, durability = durStrong)
    for i in 0'u32 ..< 10'u32:
      st.upsert Particle(parent: 8'u64, seq: i, period: 60.0, head: 0.0,
                         tWrite: float(i), payload: "v" & $i)
    for i in 0'u32 ..< 5'u32:
      st.remove(8'u64, i)
    let stats = st.compact()
    check stats.items == 5
    st.close()

    var st2 = openStore(dir, durability = durStrong)
    check st2.count() == 5
    check not st2.contains(8'u64, 0'u32)
    check st2.items[(8'u64, 9'u32)].payload == "v9"
    st2.close()
    removeDir(dir)

  test "backup/restore は compact 済み WAL として別 dir に復元できる":
    let dir = createTempDir("kouten-store", "backup-src")
    let backupDir = createTempDir("kouten-store", "backup")
    let restoredDir = createTempDir("kouten-store", "restore")
    var st = openStore(dir)
    st.setGalaxy("backup-galaxy")
    st.putRingName(3'u64, "docs/ai")
    st.putRingMeta(3'u64, 90.0, 0.75)
    st.upsert Particle(parent: 3'u64, seq: 0'u32, period: 90.0, head: 0.75,
                       tWrite: 1.0, payload: "dead",
                       vec: @[0.0'f32, 1.0'f32])
    st.upsert Particle(parent: 3'u64, seq: 1'u32, period: 90.0, head: 0.75,
                       tWrite: 2.0, payload: "live",
                       vec: @[1.0'f32, 0.0'f32])
    st.remove(3'u64, 0'u32)
    let backupStats = st.backup(backupDir)
    check backupStats.items == 1
    st.upsert Particle(parent: 3'u64, seq: 2'u32, period: 90.0, head: 0.75,
                       tWrite: 3.0, payload: "second-live")
    let backupStats2 = st.backup(backupDir)
    check backupStats2.items == 2
    check not fileExists(backupDir / "kouten.log.tmp")
    let verifyStats = verifyBackup(backupDir)
    check verifyStats.items == 2
    st.close()

    removeDir(restoredDir)
    let restoreStats = restoreBackup(backupDir, restoredDir,
                                     durability = durStrong)
    check restoreStats.items == 2
    check not fileExists(restoredDir / "kouten.log.restore")
    var restored = openStore(restoredDir, durability = durStrong)
    check restored.galaxy == "backup-galaxy"
    check restored.ringNames[3'u64] == "docs/ai"
    check restored.ringMeta[3'u64].period == 90.0
    check not restored.contains(3'u64, 0'u32)
    check restored.items[(3'u64, 1'u32)].payload == "live"
    check restored.items[(3'u64, 1'u32)].vec == @[1.0'f32, 0.0'f32]
    check restored.items[(3'u64, 2'u32)].payload == "second-live"
    restored.close()
    expect IOError:
      discard restoreBackup(backupDir, restoredDir)
    discard restoreBackup(backupDir, restoredDir, overwrite = true,
                          durability = durStrong)
    check not fileExists(restoredDir / "kouten.log.restore")
    removeDir(dir)
    removeDir(backupDir)
    removeDir(restoredDir)

  test "壊れた plain backup は restore 前に拒否され target を壊さない":
    let srcDir = createTempDir("kouten-store", "backup-corrupt-src")
    let backupDir = createTempDir("kouten-store", "backup-corrupt")
    let targetDir = createTempDir("kouten-store", "backup-corrupt-target")

    var src = openStore(srcDir)
    src.upsert Particle(parent: 10'u64, seq: 0'u32, period: 60.0, head: 0.0,
                        tWrite: 1.0, payload: "source")
    discard src.backup(backupDir)
    src.close()

    createDir(targetDir)
    writeFile(targetDir / "kouten.log",
              "P 9 0 60.0 0.0 1.0 6 0\nstable\n")
    writeFile(backupDir / "kouten.log",
              readFile(backupDir / "kouten.log") &
              "P 10 1 60.0 0.0 2.0 7 0\npartial")

    expect IOError:
      discard verifyBackup(backupDir)
    expect IOError:
      discard restoreBackup(backupDir, targetDir, overwrite = true)

    var target = openStore(targetDir)
    check target.count() == 1
    check target.items[(9'u64, 0'u32)].payload == "stable"
    check not target.contains(10'u64, 0'u32)
    target.close()

    removeDir(srcDir)
    removeDir(backupDir)
    removeDir(targetDir)

  test "encrypted backup/restore は passphrase が一致すると復元できる":
    let dir = createTempDir("kouten-store", "enc-backup-src")
    let backupDir = createTempDir("kouten-store", "enc-backup")
    let restoredDir = createTempDir("kouten-store", "enc-restore")
    var st = openStore(dir)
    st.setGalaxy("encrypted-galaxy")
    st.upsert Particle(parent: 4'u64, seq: 0'u32, period: 60.0, head: 0.1,
                       tWrite: 1.0, payload: "secret",
                       vec: @[1.0'f32, 0.0'f32])
    let backupStats = st.backupEncrypted(backupDir, "correct-passphrase")
    check backupStats.items == 1
    let verifyStats = verifyEncryptedBackup(backupDir, "correct-passphrase")
    check verifyStats.items == 1
    check fileExists(backupDir / "kouten.backup")
    check not fileExists(backupDir / "kouten.verify.tmp")
    check not fileExists(backupDir / "kouten.log.tmp")
    let encryptedBlob = readFile(backupDir / "kouten.backup")
    check encryptedBlob.startsWith("KOUTENDB-BACKUP-ARGON2ID-V2\n")
    check not encryptedBlob.contains("secret")
    st.close()

    removeDir(restoredDir)
    expect CatchableError:
      discard restoreEncryptedBackup(backupDir, restoredDir, "wrong-passphrase")
    let restoreStats = restoreEncryptedBackup(backupDir, restoredDir,
                                              "correct-passphrase",
                                              durability = durStrong)
    check restoreStats.items == 1
    check not fileExists(restoredDir / "kouten.log.restore")
    var restored = openStore(restoredDir, durability = durStrong)
    check restored.galaxy == "encrypted-galaxy"
    check restored.items[(4'u64, 0'u32)].payload == "secret"
    check restored.items[(4'u64, 0'u32)].vec == @[1.0'f32, 0.0'f32]
    restored.close()
    removeDir(dir)
    removeDir(backupDir)
    removeDir(restoredDir)

  test "壊れた encrypted backup は restore 前に拒否され target を壊さない":
    let backupDir = createTempDir("kouten-store", "enc-corrupt-backup")
    let targetDir = createTempDir("kouten-store", "enc-corrupt-target")

    writeFile(backupDir / "kouten.backup", "not-a-koutendb-encrypted-backup")
    createDir(targetDir)
    writeFile(targetDir / "kouten.log",
              "P 11 0 60.0 0.0 1.0 6 0\nstable\n")

    expect IOError:
      discard verifyEncryptedBackup(backupDir, "passphrase")
    expect IOError:
      discard restoreEncryptedBackup(backupDir, targetDir, "passphrase",
                                     overwrite = true)

    var target = openStore(targetDir)
    check target.count() == 1
    check target.items[(11'u64, 0'u32)].payload == "stable"
    target.close()

    removeDir(backupDir)
    removeDir(targetDir)

  test "legacy encrypted backup remains readable after Argon2id migration":
    let sourceDir = createTempDir("kouten-store", "legacy-enc-source")
    let plainDir = createTempDir("kouten-store", "legacy-enc-plain")
    let backupDir = createTempDir("kouten-store", "legacy-enc-backup")
    let targetDir = createTempDir("kouten-store", "legacy-enc-target")
    var source = openStore(sourceDir, durability = durStrong)
    source.upsert Particle(parent: 15'u64, seq: 0'u32, period: 60.0,
                           head: 0.1, tWrite: 1.0,
                           payload: "legacy-secret")
    discard source.backup(plainDir)
    source.close()

    writeFile(backupDir / "kouten.backup",
      legacyEncryptedBackup(readFile(plainDir / "kouten.log"),
                            "legacy-passphrase"))
    check verifyEncryptedBackup(backupDir, "legacy-passphrase").items == 1
    discard restoreEncryptedBackup(backupDir, targetDir, "legacy-passphrase")
    var restored = openStore(targetDir)
    check restored.getParticle(15'u64, 0'u32).payload == "legacy-secret"
    restored.close()

    removeDir(sourceDir)
    removeDir(plainDir)
    removeDir(backupDir)
    removeDir(targetDir)

  test "galaxy は data dir に固定され、違う galaxy では開けない":
    let dir = createTempDir("kouten-store", "galaxy")
    var st = openStore(dir)
    st.setGalaxy("andromeda")
    st.close()

    var st2 = openStore(dir)
    st2.setGalaxy("andromeda")
    expect ValueError:
      st2.setGalaxy("milky-way")
    st2.close()
    removeDir(dir)
