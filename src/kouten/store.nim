## kouten/store — 粒子ストア（設計書 §16 永続化）
##
## メモリ上の Table ＋ 追記専用ログ（WAL 兼データファイル）。
## - 追記専用は環の WORM 性（概念書 6.3④）とそのまま噛み合う。
## - flush はバッチ（128件 or 1ms）: プロセスクラッシュには安全、
##   OS クラッシュでは直近バッチを失い得る（歯止め: §16）。durStrong は
##   write boundary で fsync する。
## - compact は生存レコードだけで WAL を再構築する。backup/restore は
##   compact 済み WAL を別ディレクトリへ退避・復元する。
## - checkpoint は WAL と ring segment/index の完全な一世代を checksum
##   manifest で固定し、directory rename で公開・復元する。
##
## 現行 WAL は `!KOUTENDB-WAL 2` の magic/version 行から始まり、各論理
## レコードを `@ <len> <crc32>\n<body>` で包む。body は下記の長さ接頭辞
## つきテキスト形式で、payload はバイナリ安全。旧形式 WAL は v1.0 前の
## 移行互換として読み取りのみ残す。
##
## body レコード形式:
##   G <len>\n<galaxy>\n                                      銀河系ID
##   GD <len>\n<description>\n                              銀河系説明
##   N <ringKey> <len>\n<name>\n                               環名
##   RD <ringKey> <len>\n<description>\n                     環説明
##   R <ringKey> <period> <head>\n                             環メタ
##   RP <ringKey> <len>\n<json>\n                              環payload profile
##   TO <ringKey> <len>\n<json>\n                              ring time-orbit profile
##   SM <len>\n<json>\n                                    stellar coordinate map
##   P <parent> <seq> <period> <head> <tWrite> <len> <dim> <codec>
##     <physicalMicros> <logical> <origin>\n<payload><vec>\n
##                                                               粒子 upsert
##   E <parent> <seq> <dim>\n<dim×float32>\n                    埋め込み
##   F <oldParent> <oldSeq> <newParent> <newSeq> <newTWrite> <expiresAt>\n フォワーダ
##   D <parent> <seq>\n                                        物理退去
##   L <parent> <seq> <period> <head> <tWrite>
##     <physicalMicros> <logical> <origin> <ackedNodes> <reclaimAfter>\n
##                                                               論理削除 tombstone
##   LG <parent> <seq>\n                                      tombstone 安全回収
##   T <txid>\n / XP|XD|XF|XUJ|XUD <txid> ... / C <txid>\n atomic transaction
##   CT <txid>\n / CP <txid> ... / CC <txid>\n                cluster tx intent
##   CA <txid>\n                                          cluster tx applied
##   WJ <jobId> <len>\n<json>\n                         warp belt job snapshot
##   WD <jobId>\n                                      warp belt job delete tombstone
##   UJ <eventId> <len>\n<json>\n                    universe sync event snapshot
##   UD <eventId>\n                                    universe sync event delete tombstone
##   UA <len>\n<eventKey>\n                         universe sync event applied marker
##   UQ <nextEventId>\n                             次の universe sync event id
##   Q <nextTxId>\n                                      次の transaction id
##   S <ringKey> <nextSeq>\n                            次の ring-local seq
##   M <maxTWrite>\n                                    最大 write timestamp

import std/[algorithm, tables, sets, locks, os, streams, strutils, monotimes,
            times, posix, json, tempfiles, math, sequtils]
import nimsodium
import ./[payload, mutation]

export payload
export mutation

type
  StoreDurability* = enum
    durBuffered    ## batched flush: fast, may lose the last batch on OS crash
    durStrong      ## flush + fsync every write boundary

  SegmentPackStats* = object
    records*: int
    rings*: int
    bytes*: int64
    indexBytes*: int64
    removedFiles*: int

  SegmentPackLimitKind* = enum
    splBytes
    splElapsed

  SegmentPackLimitError* = object of CatchableError
    ## A bounded pack stopped before publishing a new generation. The old
    ## complete generation remains active.
    limitKind*: SegmentPackLimitKind

  StoreSegmentRingReport* = object
    ring*: uint64
    generation*: uint64
    liveRecords*: int
    coveredRecords*: int
    segmentRecords*: int
    staleRecords*: int
    staleRatio*: float
    segmentBytes*: int64
    indexBytes*: int64
    packRecommended*: bool

  StoreSegmentFallbackReason* = enum
    ssfrPointRead
    ssfrRingScan
    ssfrWindowRead

  StoreSegmentReport* = object
    diskBacked*: bool
    segmentHits*: uint64
    walFallbacks*: uint64
    walFallbackReasons*: array[StoreSegmentFallbackReason, uint64]
    rings*: seq[StoreSegmentRingReport]
    recommendedRings*: int
    totalSegmentBytes*: int64
    totalIndexBytes*: int64
    maxGeneration*: uint64

  StoreSegmentMetrics* = object
    hits*: uint64
    walFallbacks*: uint64
    walFallbackReasons*: array[StoreSegmentFallbackReason, uint64]
    segmentBytes*: int64
    indexBytes*: int64
    activeGenerations*: int
    staleRecords*: int
    recommendedRings*: int

  Particle* = object
    parent*: uint64
    seq*: uint32
    period*: float
    head*: float
    tWrite*: float
    payload*: string
    codec*: PayloadCodec
    vec*: seq[float32]
    version*: MutationVersion
    # serving 状態（永続化しない）
    sentAhead*: bool
    lastHere*: float

  Tombstone* = object
    parent*: uint64
    seq*: uint32
    period*: float
    head*: float
    tWrite*: float
    version*: MutationVersion
    acknowledgedNodes*: seq[uint16]
    reclaimAfter*: float
    # serving 状態（永続化しない）
    sentAhead*: bool
    lastHere*: float

  Forwarder* = object
    newParent*: uint64
    newSeq*: uint32
    newTWrite*: float
    expiresAt*: float

  TxOpKind = enum
    txRingMeta, txRingName, txUpsert, txRemove, txForwarder,
    txUniverseSyncEvent, txUniverseSyncDelete

  TxOp = object
    case kind: TxOpKind
    of txRingMeta:
      ringKey: uint64
      ringPeriod: float
      ringHead: float
    of txRingName:
      ringNameKey: uint64
      ringName: string
    of txUpsert:
      p: Particle
      walOffset: int64
      segmentOffset: int64
      segmentBody: string
    of txRemove:
      tombstone: Tombstone
    of txForwarder:
      oldParent: uint64
      oldSeq: uint32
      f: Forwarder
    of txUniverseSyncEvent:
      universeEventId: uint64
      universeEventBlob: string
    of txUniverseSyncDelete:
      universeDeleteEventId: uint64

  StoreTxn* = ref object
    store: Store
    id: uint64
    ops: seq[TxOp]
    closed: bool
    committed: bool

  ClusterTxOpKind* = enum
    ctxPut, ctxDelete

  ClusterTxOp* = object
    kind*: ClusterTxOpKind
    parent*: uint64
    seq*: uint32
    period*: float
    head*: float
    tWrite*: float
    payload*: string
    codec*: PayloadCodec
    vec*: seq[float32]
    version*: MutationVersion

  ClusterTxIntent* = object
    id*: uint64
    ops*: seq[ClusterTxOp]
    committed*: bool
    applied*: bool

  StoreCompactStats* = object
    beforeBytes*: BiggestInt
    afterBytes*: BiggestInt
    items*: int
    tombstones*: int
    forwarders*: int
    ringMeta*: int
    ringNames*: int
    clusterTx*: int
    appliedClusterTx*: int
    warpJobs*: int
    universeSyncEvents*: int

  StoreLocalityReport* = object
    ## Physical WAL locality measured from particle record order.
    ## ringRuns is the number of contiguous live particle runs by ring.
    ## Lower ringRuns/ringCount means related records are physically grouped.
    persistent*: bool
    walBytes*: BiggestInt
    totalParticleRecords*: int
    liveParticleRecords*: int
    deadParticleRecords*: int
    ringCount*: int
    ringRuns*: int
    fragmentedRings*: int
    avgRunRecords*: float
    maxRunRecords*: int
    localityScore*: float

  StoreBackupStats* = object
    bytes*: BiggestInt
    items*: int
    tombstones*: int
    forwarders*: int
    ringMeta*: int
    ringNames*: int
    clusterTx*: int
    appliedClusterTx*: int
    warpJobs*: int
    universeSyncEvents*: int
    source*: string
    destination*: string

  StoreCheckpointFile* = object
    path*: string
    kind*: string
    bytes*: int64
    checksum*: string
    ring*: uint64
    generation*: uint64

  StoreCheckpointStatus* = object
    format*: string
    id*: string
    path*: string
    createdAt*: float
    sourceWalHighWater*: int64
    snapshotWalBytes*: int64
    complete*: bool
    verified*: bool
    reasonCode*: string
    reason*: string
    items*: int
    tombstones*: int
    rings*: int
    files*: seq[StoreCheckpointFile]

  StoreCheckpointCleanupStats* = object
    root*: string
    kept*: int
    removed*: seq[string]
    invalid*: seq[string]

  MutationState* = object
    found*: bool
    deleted*: bool
    version*: MutationVersion

  DataDirLock = object
    fd: cint
    guardFd: cint
    identity: string
    held: bool

  Store* = ref object
    items*: Table[(uint64, uint32), Particle]
    itemVersions*: Table[(uint64, uint32), MutationVersion]
    tombstones*: Table[(uint64, uint32), Tombstone]
    itemsByRing*: Table[uint64, seq[(uint64, uint32)]]
    itemOffsets*: Table[(uint64, uint32), int64]
    itemSegmentOffsets*: Table[(uint64, uint32), int64]
    itemHasVector*: Table[(uint64, uint32), bool]
    vectorCount*: int
    vectorCountByRing*: Table[uint64, int]
    forwarders*: Table[(uint64, uint32), Forwarder]
    seqs*: Table[uint64, uint32]                    # ring → 次の seq
    ringMeta*: Table[uint64, tuple[period, head: float]]
    ringNames*: Table[uint64, string]
    ringDescriptions*: Table[uint64, string]
    ringPayloadProfiles*: Table[uint64, RingPayloadProfile]
    ringTimeOrbitProfiles*: Table[uint64, TimeOrbitProfile]
    stellarMaps*: Table[string, string]
    galaxy*: string
    galaxyDescription*: string
    placementEpoch*: uint32
    placementNodes*: uint16
    placementVirtualArcs*: int
    maintenanceDrained*: bool
    clusterTx*: Table[uint64, ClusterTxIntent]
    appliedClusterTx*: Table[uint64, bool]
    warpJobs*: Table[uint64, string]
    universeSyncEvents*: Table[uint64, string]
    appliedUniverseSyncEvents*: Table[string, bool]
    appliedUniverseSyncOrder*: seq[string]
    nextUniverseSyncId*: uint64
    writeFailed*: bool
    writeError*: string
    maxTWrite*: float
    mutationClockPhysical: int64
    mutationClockLogical: uint32
    mutationOrigin: uint32
    nextTxId: uint64
    logFile: File
    logPath: string
    segmentDir: string
    segmentGenerations: Table[uint64, uint64]
    segmentRecordCounts: Table[uint64, int]
    segmentFiles: Table[uint64, File]
    segmentIndexFiles: Table[uint64, File]
    segmentReadStreams: Table[uint64, FileStream]
    segmentReadHits: uint64
    segmentWalFallbacks: uint64
    segmentWalFallbackReasons: array[StoreSegmentFallbackReason, uint64]
    when defined(koutenTestFailpoints):
      segmentPackFailAfterSegmentReplace: bool
      segmentPackFailBeforeManifest: bool
      segmentPackDelayMs: int
    dataDirLock: DataDirLock
    persistent: bool
    diskBacked*: bool
    durability*: StoreDurability
    dirty: int
    lastFlush: MonoTime

const
  FlushEvery = 128
  FlushNs = 1_000_000   # 1ms
  MaxStoreRecordBytes = 64 * 1024 * 1024
  MaxStoreVectorDim = MaxStoreRecordBytes div sizeof(float32)
  WalMagicLine = "!KOUTENDB-WAL 2"
  WalRecordTag = "@"
  EncryptedBackupMagic = "KOUTENDB-BACKUP-SECRETBOX-V1\n"
  CheckpointFormat = "koutendb-checkpoint-v1"
  CheckpointManifestName = "checkpoint.json"
  CheckpointCompleteName = "checkpoint.complete"
  CheckpointChecksumAlgorithm = "blake2b-chain-v1"
  CheckpointChecksumChunkBytes = 1024 * 1024
  AppliedUniverseSyncRetention =
    when defined(koutenTestSmallLimits): 3
    else: 100_000

when defined(koutenTestFailpoints):
  var checkpointRestoreFailAfterExchange = false
  var checkpointRestoreFailAfterPublish = false

  proc failCheckpointRestoreAfterExchangeForTest*(enabled: bool) =
    checkpointRestoreFailAfterExchange = enabled

  proc failCheckpointRestoreAfterPublishForTest*(enabled: bool) =
    checkpointRestoreFailAfterPublish = enabled

when defined(koutenTestCrashPoints):
  proc processCrashPoint(name: string) =
    ## Test-only process boundary. The smoke runner waits for the marker and
    ## sends SIGKILL, so recovery observes real process termination rather
    ## than an exception unwinding open files and cleanup handlers.
    if getEnv("KOUTEN_TEST_CRASH_POINT") != name:
      return
    let readyPath = getEnv("KOUTEN_TEST_CRASH_READY")
    if readyPath.len == 0:
      raise newException(IOError,
        "KOUTEN_TEST_CRASH_READY is required for crash-point tests")
    writeFile(readyPath, name & "\n")
    while true:
      sleep(1000)

var dataDirRegistryLock: Lock
var openDataDirs = initHashSet[string]()
initLock(dataDirRegistryLock)

type
  WalCorruptionError = object of CatchableError

proc key(parent: uint64, seq: uint32): (uint64, uint32) = (parent, seq)

proc getParticle*(s: Store, parent: uint64, seq: uint32): Particle

proc observeMutationVersion(s: Store, version: MutationVersion) =
  if version.physicalMicros > s.mutationClockPhysical:
    s.mutationClockPhysical = version.physicalMicros
    s.mutationClockLogical = version.logical
  elif version.physicalMicros == s.mutationClockPhysical:
    s.mutationClockLogical = max(s.mutationClockLogical, version.logical)

proc nextMutationVersion*(s: Store, origin = 0'u32): MutationVersion =
  let effectiveOrigin = if origin == 0: s.mutationOrigin else: origin
  let wallMicros = max(1'i64, int64(floor(epochTime() * 1_000_000.0)))
  if wallMicros > s.mutationClockPhysical:
    s.mutationClockPhysical = wallMicros
    s.mutationClockLogical = 0
  else:
    if s.mutationClockLogical == uint32.high:
      if s.mutationClockPhysical == int64.high:
        raise newException(IOError, "mutation clock exhausted")
      inc s.mutationClockPhysical
      s.mutationClockLogical = 0
    else:
      inc s.mutationClockLogical
  MutationVersion(physicalMicros: s.mutationClockPhysical,
                  logical: s.mutationClockLogical,
                  origin: effectiveOrigin)

proc normalizeMutationVersion(s: Store, version: MutationVersion,
                              tWrite: float): MutationVersion =
  result = if version.isZero: legacyMutationVersion(tWrite) else: version
  result.validateMutationVersion()
  s.observeMutationVersion(result)

func buildCrc32Tables(): array[8, array[256, uint32]] =
  for i in 0 ..< result[0].len:
    var crc = i.uint32
    for _ in 0 ..< 8:
      if (crc and 1'u32) != 0'u32:
        crc = (crc shr 1) xor 0xEDB88320'u32
      else:
        crc = crc shr 1
    result[0][i] = crc
  for table in 1 ..< result.len:
    for i in 0 ..< result[table].len:
      let previous = result[table - 1][i]
      result[table][i] =
        (previous shr 8) xor result[0][int(previous and 0xFF'u32)]

const Crc32Tables = buildCrc32Tables()

func crc32(data: string): uint32 =
  var crc = 0xFFFFFFFF'u32
  var i = 0
  while i + 8 <= data.len:
    let firstWord =
      uint32(ord(data[i])) or
      (uint32(ord(data[i + 1])) shl 8) or
      (uint32(ord(data[i + 2])) shl 16) or
      (uint32(ord(data[i + 3])) shl 24)
    let first = crc xor firstWord
    let second =
      uint32(ord(data[i + 4])) or
      (uint32(ord(data[i + 5])) shl 8) or
      (uint32(ord(data[i + 6])) shl 16) or
      (uint32(ord(data[i + 7])) shl 24)
    crc = Crc32Tables[7][int(first and 0xFF'u32)] xor
          Crc32Tables[6][int((first shr 8) and 0xFF'u32)] xor
          Crc32Tables[5][int((first shr 16) and 0xFF'u32)] xor
          Crc32Tables[4][int(first shr 24)] xor
          Crc32Tables[3][int(second and 0xFF'u32)] xor
          Crc32Tables[2][int((second shr 8) and 0xFF'u32)] xor
          Crc32Tables[1][int((second shr 16) and 0xFF'u32)] xor
          Crc32Tables[0][int(second shr 24)]
    inc i, 8
  while i < data.len:
    let idx = int((crc xor uint32(ord(data[i]))) and 0xFF'u32)
    crc = (crc shr 8) xor Crc32Tables[0][idx]
    inc i
  result = not crc

static:
  doAssert crc32("123456789") == 0xCBF43926'u32

proc walRecord(body: string): string =
  WalRecordTag & " " & $body.len & " " & $crc32(body) & "\n" & body

proc writeWalRecord(file: File, body: string) =
  file.write(walRecord(body))

proc lineRecord(line: string): string =
  line & "\n"

proc writeWalLine(file: File, line: string) =
  file.writeWalRecord(lineRecord(line))

proc vecBytes(vec: seq[float32]): string =
  result = newStringOfCap(vec.len * sizeof(float32))
  for x in vec:
    var y = x
    let base = cast[ptr UncheckedArray[char]](addr y)
    for i in 0 ..< sizeof(float32):
      result.add base[i]

proc checkedStoreLen(n: int, label: string): int =
  if n < 0:
    raise newException(ValueError, label & " must be non-negative")
  if n > MaxStoreRecordBytes:
    raise newException(ValueError, label & " exceeds max store record bytes")
  n

proc checkedStoreVecDim(n: int): int =
  if n < 0:
    raise newException(ValueError, "vecDim must be non-negative")
  if n > MaxStoreVectorDim:
    raise newException(ValueError, "vecDim exceeds max store vector dimensions")
  n

proc readVec(fs: Stream, dim: int): seq[float32] =
  let dim = checkedStoreVecDim(dim)
  result = newSeq[float32](dim)
  for i in 0 ..< dim:
    if fs.readData(addr result[i], sizeof(float32)) != sizeof(float32):
      raise newException(IOError, "埋め込みレコードが途中で終わった")

proc readExactStr(fs: Stream, len: int): string =
  let len = checkedStoreLen(len, "payloadLen")
  result = fs.readStr(len)
  if result.len != len:
    raise newException(IOError, "WAL レコードが途中で終わった")

proc readRecordSep(fs: Stream) =
  if fs.atEnd:
    raise newException(IOError, "WAL レコード末尾の改行がない")
  discard fs.readChar()

proc validateStellarMapBlob(stellar, raw: string, allowDeleted = false): JsonNode =
  ## Validate the Store-owned stellar map snapshot before it reaches WAL.
  ## KoutenDB owns coordinate normalization; Store only enforces replayable shape.
  if stellar.len == 0:
    raise newException(ValueError, "stellar coordinate is empty")
  if raw.len == 0:
    raise newException(ValueError, "stellar map blob is empty")
  result = parseJson(raw)
  if result.kind != JObject:
    raise newException(ValueError, "stellar map must be a JSON object")
  if not result.hasKey("stellar") or result["stellar"].kind != JString:
    raise newException(ValueError, "stellar map requires string stellar")
  if result["stellar"].getStr() != stellar:
    raise newException(ValueError, "stellar map coordinate mismatch")
  if result.hasKey("deleted"):
    if not allowDeleted:
      raise newException(ValueError, "stellar map delete tombstone is internal")
    if result["deleted"].kind != JBool:
      raise newException(ValueError, "stellar map deleted must be boolean")
    if result["deleted"].getBool(false):
      return
  if not result.hasKey("members") or result["members"].kind != JArray:
    raise newException(ValueError, "stellar map requires members array")
  for member in result["members"]:
    if member.kind != JString:
      raise newException(ValueError, "stellar map members must be strings")

proc validateTimeOrbitProfile(profile: TimeOrbitProfile) =
  if profile.bits <= 0 or profile.bits > 60:
    raise newException(ValueError, "time orbit bits must be 1..60")
  if profile.bucketMs <= 0:
    raise newException(ValueError, "time orbit bucketMs must be > 0")
  let maxPosition =
    if profile.bits == 64: uint64.high else: (1'u64 shl profile.bits) - 1'u64
  if profile.phase > maxPosition:
    raise newException(ValueError, "time orbit phase exceeds coordinate space")

proc timeOrbitProfileJson(profile: TimeOrbitProfile): string =
  validateTimeOrbitProfile(profile)
  $(%*{
    "bits": profile.bits,
    "bucketMs": profile.bucketMs,
    "phase": $profile.phase,
    "salt": profile.salt
  })

proc parseTimeOrbitProfile(raw: string): TimeOrbitProfile =
  let node = parseJson(raw)
  if node.kind != JObject:
    raise newException(ValueError, "time orbit profile must be a JSON object")
  result = TimeOrbitProfile(
    bits: node{"bits"}.getInt(60),
    bucketMs: node{"bucketMs"}.getBiggestInt(60_000).int64,
    phase: parseBiggestUInt(node{"phase"}.getStr("0")).uint64,
    salt: node{"salt"}.getStr(""))
  validateTimeOrbitProfile(result)

proc evictState(s: Store, parent: uint64, seq: uint32) =
  let k = key(parent, seq)
  s.items.del k
  s.itemOffsets.del k
  s.itemSegmentOffsets.del k
  s.itemVersions.del k
  if s.itemHasVector.getOrDefault(k, false):
    s.vectorCount = max(0, s.vectorCount - 1)
    let n = max(0, s.vectorCountByRing.getOrDefault(parent, 0) - 1)
    if n == 0:
      s.vectorCountByRing.del parent
    else:
      s.vectorCountByRing[parent] = n
    s.itemHasVector.del k
  if parent in s.itemsByRing:
    var entries = s.itemsByRing[parent]
    for i in countdown(entries.len - 1, 0):
      if entries[i] == k:
        entries.delete(i)
        break
    if entries.len == 0:
      s.itemsByRing.del parent
    else:
      s.itemsByRing[parent] = entries
  s.forwarders.del k

proc insertItemKeyBySeq(s: Store, parent: uint64,
                        itemKey: (uint64, uint32)) =
  ## itemsByRing is the lightweight logical access path used by bounded ring
  ## reads. Keep it ordered independently from WAL/segment physical order so
  ## cursor pagination never needs to sort or scan payload records.
  var entries = s.itemsByRing.getOrDefault(parent, @[])
  var low = 0
  var high = entries.len
  while low < high:
    let middle = low + (high - low) div 2
    if entries[middle][1] < itemKey[1]:
      low = middle + 1
    else:
      high = middle
  if low < entries.len and entries[low] == itemKey:
    return
  entries.insert(itemKey, low)
  s.itemsByRing[parent] = entries

proc mergeTombstoneMetadata(current: var Tombstone,
                            incoming: Tombstone): bool =
  for node in incoming.acknowledgedNodes:
    if current.acknowledgedNodes.acknowledgeNode(node):
      result = true
  if incoming.reclaimAfter > current.reclaimAfter:
    current.reclaimAfter = incoming.reclaimAfter
    result = true

proc normalizeTombstoneMetadata(tombstone: var Tombstone) =
  tombstone.acknowledgedNodes =
    canonicalAcknowledgedNodes(tombstone.acknowledgedNodes)
  if tombstone.reclaimAfter < 0 or
      tombstone.reclaimAfter.classify in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError,
      "tombstone reclaimAfter must be finite and non-negative")

proc applyOp(s: Store, op: TxOp) =
  case op.kind
  of txRingMeta:
    s.ringMeta[op.ringKey] = (op.ringPeriod, op.ringHead)
  of txRingName:
    if op.ringName.len > 0:
      s.ringNames[op.ringNameKey] = op.ringName
  of txUpsert:
    var p = op.p
    p.version = s.normalizeMutationVersion(p.version, p.tWrite)
    let k = key(p.parent, p.seq)
    if k in s.tombstones and p.version <= s.tombstones[k].version:
      return
    if k in s.itemVersions and p.version <= s.itemVersions[k]:
      return
    s.maxTWrite = max(s.maxTWrite, p.tWrite)
    if p.seq >= s.seqs.getOrDefault(p.parent, 0'u32):
      s.seqs[p.parent] = p.seq + 1
    let oldHasVector = s.itemHasVector.getOrDefault(k, false)
    let newHasVector = p.vec.len > 0
    if k notin s.items and k notin s.itemOffsets:
      s.insertItemKeyBySeq(p.parent, k)
    if oldHasVector != newHasVector:
      if newHasVector:
        inc s.vectorCount
        s.vectorCountByRing[p.parent] = s.vectorCountByRing.getOrDefault(p.parent, 0) + 1
      else:
        s.vectorCount = max(0, s.vectorCount - 1)
        let n = max(0, s.vectorCountByRing.getOrDefault(p.parent, 0) - 1)
        if n == 0: s.vectorCountByRing.del p.parent else: s.vectorCountByRing[p.parent] = n
    s.itemHasVector[k] = newHasVector
    s.itemVersions[k] = p.version
    s.tombstones.del k
    if s.diskBacked:
      if op.walOffset >= 0:
        s.itemOffsets[k] = op.walOffset
        if op.segmentOffset < 0:
          s.itemSegmentOffsets.del k
      if op.segmentOffset >= 0:
        s.itemSegmentOffsets[k] = op.segmentOffset
      s.items.del k
    else:
      s.items[k] = p
  of txRemove:
    var tombstone = op.tombstone
    let k = key(tombstone.parent, tombstone.seq)
    if tombstone.version.isZero:
      if k notin s.itemVersions:
        return
      let current =
        if k in s.items: s.items[k]
        else: s.getParticle(tombstone.parent, tombstone.seq)
      tombstone.period = current.period
      tombstone.head = current.head
      tombstone.tWrite = current.tWrite
      tombstone.version = s.nextMutationVersion()
    tombstone.version =
      s.normalizeMutationVersion(tombstone.version, tombstone.tWrite)
    if k in s.tombstones:
      if tombstone.version < s.tombstones[k].version:
        return
      if tombstone.version == s.tombstones[k].version:
        discard s.tombstones[k].mergeTombstoneMetadata(tombstone)
        return
    if k in s.itemVersions and tombstone.version <= s.itemVersions[k]:
      return
    s.evictState(tombstone.parent, tombstone.seq)
    s.tombstones[k] = tombstone
  of txForwarder:
    s.forwarders[key(op.oldParent, op.oldSeq)] = op.f
  of txUniverseSyncEvent:
    if op.universeEventBlob.len == 0:
      raise newException(ValueError, "universe sync event blob is empty")
    s.universeSyncEvents[op.universeEventId] = op.universeEventBlob
    s.nextUniverseSyncId = max(s.nextUniverseSyncId, op.universeEventId)
  of txUniverseSyncDelete:
    s.universeSyncEvents.del op.universeDeleteEventId

proc applyOps(s: Store, ops: seq[TxOp]) =
  for op in ops:
    s.applyOp(op)

proc particleRecordBody(tag: string, txid: uint64, p: Particle): string =
  let prefix = if tag.len > 0: tag & " " & $txid & " " else: "P "
  result = prefix & $p.parent & " " & $p.seq & " " & $p.period & " " &
           $p.head & " " & $p.tWrite & " " & $p.payload.len & " " &
           $p.vec.len & " " & p.codec.payloadCodecName & " " &
           p.version.mutationVersionFields & "\n"
  result.add p.payload
  if p.vec.len > 0:
    result.add p.vec.vecBytes()
  result.add "\n"

proc writeParticleRecord(file: File, tag: string, txid: uint64, p: Particle) =
  file.writeWalRecord(particleRecordBody(tag, txid, p))

proc tombstoneRecordBody(tag: string, txid: uint64,
                         tombstone: Tombstone): string =
  let prefix = if tag.len > 0: tag & " " & $txid & " " else: "L "
  prefix & $tombstone.parent & " " & $tombstone.seq & " " &
    $tombstone.period & " " & $tombstone.head & " " & $tombstone.tWrite &
    " " & tombstone.version.mutationVersionFields & " " &
    tombstone.acknowledgedNodes.acknowledgedNodesField & " " &
    $tombstone.reclaimAfter

proc writeTombstoneRecord(file: File, tag: string, txid: uint64,
                          tombstone: Tombstone) =
  file.writeWalLine(tombstoneRecordBody(tag, txid, tombstone))

proc segmentFileName(ring, generation: uint64): string =
  let base = toHex(ring, 16)
  if generation == 0: base & ".seg" else: base & ".g" & $generation & ".seg"

proc segmentIndexFileName(ring, generation: uint64): string =
  let base = toHex(ring, 16)
  if generation == 0: base & ".idx" else: base & ".g" & $generation & ".idx"

proc segmentPath(s: Store, ring: uint64): string =
  s.segmentDir / segmentFileName(ring, s.segmentGenerations.getOrDefault(ring, 0))

proc segmentIndexPath(s: Store, ring: uint64): string =
  s.segmentDir / segmentIndexFileName(ring, s.segmentGenerations.getOrDefault(ring, 0))

proc segmentPath(s: Store, ring, generation: uint64): string =
  s.segmentDir / segmentFileName(ring, generation)

proc segmentIndexPath(s: Store, ring, generation: uint64): string =
  s.segmentDir / segmentIndexFileName(ring, generation)

proc segmentManifestPath(s: Store): string =
  s.segmentDir / "manifest"

proc syncDir(path: string)
proc replaceFileAtomic(src, dst: string)
proc syncFile(file: File)

proc loadSegmentManifest(s: Store): bool =
  ## No manifest denotes the legacy generation-0 layout.  A malformed
  ## manifest is not trusted and causes a cache rebuild from the WAL.
  s.segmentGenerations.clear()
  let path = s.segmentManifestPath()
  if not fileExists(path):
    return true
  try:
    let rows = readFile(path).splitLines()
    if rows.len == 0 or rows[0] != "!KOUTENDB-SEGMENTS 1":
      return false
    for i in 1 ..< rows.len:
      let line = rows[i].strip()
      if line.len == 0:
        continue
      let parts = line.splitWhitespace()
      if parts.len != 2:
        return false
      let ring = parseBiggestUInt(parts[0]).uint64
      let generation = parseBiggestUInt(parts[1]).uint64
      if generation == 0:
        return false
      s.segmentGenerations[ring] = generation
    result = true
  except CatchableError:
    s.segmentGenerations.clear()
    result = false

proc writeSegmentManifest(s: Store) =
  if s.segmentDir.len == 0:
    raise newException(IOError, "ring segment directory is not configured")
  createDir(s.segmentDir)
  let path = s.segmentManifestPath()
  let tmp = path & ".tmp"
  var rings: seq[uint64] = @[]
  for ring in s.segmentGenerations.keys:
    if s.segmentGenerations[ring] > 0:
      rings.add ring
  rings.sort()
  var file = open(tmp, fmWrite)
  try:
    file.write("!KOUTENDB-SEGMENTS 1\n")
    for ring in rings:
      file.write($ring & " " & $s.segmentGenerations[ring] & "\n")
    file.syncFile()
  finally:
    file.close()
  replaceFileAtomic(tmp, path)
  syncDir(s.segmentDir)

proc segmentFileForAppend(s: Store, ring: uint64): File =
  if s.segmentDir.len == 0:
    raise newException(IOError, "ring segment directory is not configured")
  createDir(s.segmentDir)
  if ring notin s.segmentFiles:
    s.segmentFiles[ring] = open(s.segmentPath(ring), fmAppend)
  s.segmentFiles[ring]

proc segmentIndexFileForAppend(s: Store, ring: uint64): File =
  if s.segmentDir.len == 0:
    raise newException(IOError, "ring segment directory is not configured")
  createDir(s.segmentDir)
  if ring notin s.segmentIndexFiles:
    s.segmentIndexFiles[ring] = open(s.segmentIndexPath(ring), fmAppend)
  s.segmentIndexFiles[ring]

proc closeSegmentFiles(s: Store) =
  for _, file in s.segmentFiles.mpairs:
    file.flushFile()
    file.close()
  s.segmentFiles.clear()

proc closeSegmentIndexFiles(s: Store) =
  for _, file in s.segmentIndexFiles.mpairs:
    file.flushFile()
    file.close()
  s.segmentIndexFiles.clear()

proc closeSegmentReadStreams(s: Store) =
  for _, stream in s.segmentReadStreams.mpairs:
    if stream != nil:
      stream.close()
  s.segmentReadStreams.clear()

proc flushSegmentFiles(s: Store) =
  for _, file in s.segmentFiles.mpairs:
    file.flushFile()

proc flushSegmentIndexFiles(s: Store) =
  for _, file in s.segmentIndexFiles.mpairs:
    file.flushFile()

proc writeSegmentBody(s: Store, ring: uint64, body: string): int64 =
  if not s.diskBacked or not s.persistent:
    return -1'i64
  var file = s.segmentFileForAppend(ring)
  result = file.getFilePos()
  file.write(walRecord(body))
  s.segmentFiles[ring] = file

proc appendSegmentIndex(s: Store, p: Particle, walOffset, segmentOffset: int64) =
  ## The index is a rebuildable cache.  WAL remains authoritative, therefore a
  ## partial or missing index entry only falls back to WAL on the next open.
  var file = s.segmentIndexFileForAppend(p.parent)
  file.write("P " & $p.parent & " " & $p.seq & " " & $walOffset & " " &
             $segmentOffset & "\n")
  s.segmentIndexFiles[p.parent] = file
  s.segmentRecordCounts[p.parent] =
    s.segmentRecordCounts.getOrDefault(p.parent, 0) + 1

proc cacheParticleInSegment(s: Store, p: Particle, walOffset: int64,
                            body: string) =
  ## Segment persistence is deliberately best-effort: the WAL write has
  ## already committed the logical mutation.  If this cache update fails, the
  ## next read and restart use the WAL rather than reporting a false failure.
  if not s.diskBacked or not s.persistent or s.segmentDir.len == 0 or
      walOffset < 0:
    return
  let k = key(p.parent, p.seq)
  try:
    let segmentOffset = s.writeSegmentBody(p.parent, body)
    s.appendSegmentIndex(p, walOffset, segmentOffset)
    s.itemSegmentOffsets[k] = segmentOffset
  except CatchableError:
    s.itemSegmentOffsets.del k

proc clusterTxOpBody(txid: uint64, op: ClusterTxOp): string =
  let kind = if op.kind == ctxDelete: "D" else: "P"
  result = "CP " & $txid & " " & kind & " " & $op.parent & " " & $op.seq & " " &
           $op.period & " " & $op.head & " " & $op.tWrite & " " &
           $op.payload.len & " " & $op.vec.len & " " &
           op.codec.payloadCodecName & " " &
           op.version.mutationVersionFields & "\n"
  result.add op.payload
  if op.vec.len > 0:
    result.add op.vec.vecBytes()
  result.add "\n"

proc writeClusterTxOp(file: File, txid: uint64, op: ClusterTxOp) =
  file.writeWalRecord(clusterTxOpBody(txid, op))

proc checkedWalBody(fs: Stream, parts: seq[string]): string

proc readParticleRecord(fs: Stream, parts: seq[string], firstData: int): Particle =
  result = Particle(parent: parseBiggestUInt(parts[firstData]).uint64,
                    seq: parseUInt(parts[firstData + 1]).uint32,
                    period: parseFloat(parts[firstData + 2]),
                    head: parseFloat(parts[firstData + 3]),
                    tWrite: parseFloat(parts[firstData + 4]))
  let len = parseInt(parts[firstData + 5])
  let dim = if parts.len > firstData + 6: parseInt(parts[firstData + 6]) else: 0
  result.codec = if parts.len > firstData + 7:
                   parsePayloadCodec(parts[firstData + 7])
                 else:
                   pcRaw
  result.version = parseMutationVersion(parts, firstData + 8, result.tWrite)
  result.payload = fs.readExactStr(len)
  result.vec = fs.readVec(dim)
  fs.readRecordSep()

proc readTombstoneRecord(parts: seq[string], firstData: int,
                         fallback: Tombstone = Tombstone()): Tombstone =
  result = fallback
  result.parent = parseBiggestUInt(parts[firstData]).uint64
  result.seq = parseUInt(parts[firstData + 1]).uint32
  if parts.len >= firstData + 8:
    result.period = parseFloat(parts[firstData + 2])
    result.head = parseFloat(parts[firstData + 3])
    result.tWrite = parseFloat(parts[firstData + 4])
    result.version = parseMutationVersion(parts, firstData + 5, result.tWrite)
    if parts.len > firstData + 8:
      result.acknowledgedNodes =
        parseAcknowledgedNodes(parts[firstData + 8])
    if parts.len > firstData + 9:
      result.reclaimAfter = parseFloat(parts[firstData + 9])
      if result.reclaimAfter < 0 or
          result.reclaimAfter.classify in {fcNan, fcInf, fcNegInf}:
        raise newException(ValueError,
          "tombstone reclaimAfter must be finite and non-negative")
  elif result.version.isZero:
    result.version = legacyMutationVersion(result.tWrite)

proc readParticleAtStream(fs: Stream, offset: int64): Particle =
  if fs.getPosition() != offset:
    fs.setPosition(offset)
  var line = ""
  if not fs.readLine(line):
    raise newException(IOError, "missing WAL record at offset " & $offset)
  var parts = line.split(' ')
  var recordStream: Stream = fs
  var bodyStream: StringStream = nil
  if parts[0] == WalRecordTag:
    let body = checkedWalBody(fs, parts)
    bodyStream = newStringStream(body)
    if not bodyStream.readLine(line):
      raise newException(WalCorruptionError, "empty WAL record body")
    parts = line.split(' ')
    recordStream = bodyStream
  case parts[0]
  of "P":
    result = recordStream.readParticleRecord(parts, 1)
  of "XP":
    result = recordStream.readParticleRecord(parts, 2)
  else:
    raise newException(IOError, "WAL offset does not point to a particle record")

proc readParticleBodyAtStream(fs: Stream, offset: int64): string =
  if fs.getPosition() != offset:
    fs.setPosition(offset)
  var line = ""
  if not fs.readLine(line):
    raise newException(IOError, "missing WAL record at offset " & $offset)
  var parts = line.split(' ')
  if parts[0] == WalRecordTag:
    result = checkedWalBody(fs, parts)
  else:
    case parts[0]
    of "P":
      let p = fs.readParticleRecord(parts, 1)
      result = particleRecordBody("", 0, p)
    of "XP":
      let p = fs.readParticleRecord(parts, 2)
      result = particleRecordBody("XP", 0, p)
    else:
      raise newException(IOError, "WAL offset does not point to a particle record")

const
  SegmentPackFlushBytes = 4 * 1024 * 1024

type
  SegmentPackWriter = object
    file: File
    pos: int64
    buffer: string

proc flushPackWriter(writer: var SegmentPackWriter) =
  if writer.buffer.len > 0:
    writer.file.write(writer.buffer)
    writer.pos += writer.buffer.len.int64
    writer.buffer.setLen(0)

proc appendPackRecord(s: Store,
                      writers: var seq[SegmentPackWriter],
                      writerIndexes: var Table[uint64, int],
                      ring: uint64,
                      record: string): int64 =
  if ring notin writerIndexes:
    writerIndexes[ring] = writers.len
    writers.add SegmentPackWriter(file: open(s.segmentPath(ring), fmWrite),
                                  pos: 0,
                                  buffer: "")
  let idx = writerIndexes[ring]
  result = writers[idx].pos + writers[idx].buffer.len.int64
  writers[idx].buffer.add(record)
  if writers[idx].buffer.len >= SegmentPackFlushBytes:
    writers[idx].flushPackWriter()

proc closePackWriters(writers: var seq[SegmentPackWriter]) =
  for writer in writers.mitems:
    writer.flushPackWriter()
    writer.file.flushFile()
    writer.file.close()
  writers.setLen(0)

proc flushDiskBackedLog(s: Store) =
  if s.logFile != nil:
    s.logFile.flushFile()

proc openWalReadStream(s: Store): FileStream =
  if not s.persistent or s.logPath.len == 0:
    raise newException(IOError, "disk-backed particle read requires persistent WAL")
  s.flushDiskBackedLog()
  result = newFileStream(s.logPath, fmRead)
  if result.isNil:
    raise newException(IOError, "cannot open WAL for particle read")

proc readParticleAt*(s: Store, offset: int64): Particle =
  let fs = s.openWalReadStream()
  try:
    result = fs.readParticleAtStream(offset)
  finally:
    fs.close()

proc openSegmentReadStream(s: Store, ring: uint64): FileStream

proc loadRingSegmentIndexes(s: Store): bool =
  ## Restore the rebuildable segment cache without replaying every live WAL
  ## payload into new segment files.  Index entries are accepted only when
  ## their WAL offset still identifies the current live revision.
  if s.segmentDir.len == 0 or not dirExists(s.segmentDir):
    return false
  var loaded = initTable[(uint64, uint32), tuple[walOffset, segmentOffset: int64]]()
  var sawIndex = false
  s.segmentRecordCounts.clear()
  try:
    for path in walkFiles(s.segmentDir / "*.idx"):
      sawIndex = true
      for rawLine in lines(path):
        let line = rawLine.strip()
        if line.len == 0:
          continue
        let parts = line.splitWhitespace()
        if parts.len == 3 and parts[0] == "D":
          let parent = parseBiggestUInt(parts[1]).uint64
          if path == s.segmentIndexPath(parent):
            loaded.del key(parent, parseUInt(parts[2]).uint32)
        elif parts.len == 5 and parts[0] == "P":
          let parent = parseBiggestUInt(parts[1]).uint64
          let seq = parseUInt(parts[2]).uint32
          let walOffset = parseBiggestInt(parts[3]).int64
          let segmentOffset = parseBiggestInt(parts[4]).int64
          if walOffset < 0 or segmentOffset < 0:
            return false
          if path == s.segmentIndexPath(parent):
            s.segmentRecordCounts[parent] =
              s.segmentRecordCounts.getOrDefault(parent, 0) + 1
            loaded[key(parent, seq)] = (walOffset, segmentOffset)
        else:
          return false
    if not sawIndex:
      return false
    for k, entry in loaded:
      if s.itemOffsets.getOrDefault(k, -1'i64) != entry.walOffset:
        continue
      if not fileExists(s.segmentPath(k[0])) or
          entry.segmentOffset >= getFileSize(s.segmentPath(k[0])):
        return false
      s.itemSegmentOffsets[k] = entry.segmentOffset
    result = true
  except CatchableError:
    s.itemSegmentOffsets.clear()
    s.segmentRecordCounts.clear()
    result = false

proc segmentParticleOrWal(s: Store, parent: uint64, seq: uint32,
                          segmentOffset, walOffset: int64): Particle =
  ## A segment is an optimization only.  A damaged or interrupted cache write
  ## must never make the durable WAL record unreadable.
  try:
    let fs = s.openSegmentReadStream(parent)
    try:
      let p = fs.readParticleAtStream(segmentOffset)
      let k = key(parent, seq)
      if p.parent != parent or p.seq != seq or
          p.version != s.itemVersions.getOrDefault(k):
        raise newException(IOError, "ring segment index does not match live revision")
      inc s.segmentReadHits
      return p
    finally:
      fs.close()
  except CatchableError:
    s.itemSegmentOffsets.del key(parent, seq)
    inc s.segmentWalFallbacks
    inc s.segmentWalFallbackReasons[ssfrPointRead]
    return s.readParticleAt(walOffset)

proc openSegmentReadStream(s: Store, ring: uint64): FileStream =
  if s.segmentDir.len == 0:
    raise newException(IOError, "ring segment directory is not configured")
  s.flushSegmentFiles()
  result = newFileStream(s.segmentPath(ring), fmRead)
  if result.isNil:
    raise newException(IOError, "cannot open ring segment for read")

proc readParticleRecordAtCurrent(fs: Stream, line: string): Particle =
  var parts = line.split(' ')
  var recordStream: Stream = fs
  var bodyStream: StringStream = nil
  if parts[0] == WalRecordTag:
    let body = checkedWalBody(fs, parts)
    bodyStream = newStringStream(body)
    var bodyLine = ""
    if not bodyStream.readLine(bodyLine):
      raise newException(WalCorruptionError, "empty segment record body")
    parts = bodyLine.split(' ')
    recordStream = bodyStream
  case parts[0]
  of "P":
    result = recordStream.readParticleRecord(parts, 1)
  of "XP":
    result = recordStream.readParticleRecord(parts, 2)
  else:
    raise newException(IOError, "segment record is not a particle")

iterator particlesByRing*(s: Store, ring: uint64): Particle =
  if s.diskBacked:
    var fromSegment: seq[Particle] = @[]
    var segmentUsable = false
    if s.segmentDir.len > 0 and fileExists(s.segmentPath(ring)):
      let segmentStream = s.openSegmentReadStream(ring)
      try:
        var line = ""
        while segmentStream.readLine(line):
          let recordStart = segmentStream.getPosition() - line.len - 1
          let p = segmentStream.readParticleRecordAtCurrent(line)
          let k = key(p.parent, p.seq)
          if p.parent == ring and k in s.itemSegmentOffsets and
              s.itemSegmentOffsets[k] == recordStart and
              p.version == s.itemVersions.getOrDefault(k):
            fromSegment.add p
        segmentUsable = true
      except CatchableError:
        # Discard partial cache output.  The WAL remains the only source used
        # for this read if a segment cannot be fully verified.
        fromSegment.setLen(0)
        inc s.segmentWalFallbacks
        inc s.segmentWalFallbackReasons[ssfrRingScan]
      finally:
        segmentStream.close()
    if segmentUsable:
      s.segmentReadHits += fromSegment.len.uint64
      for p in fromSegment:
        yield p
    for k in s.itemsByRing.getOrDefault(ring, @[]):
      if k in s.itemOffsets and (not segmentUsable or k notin s.itemSegmentOffsets):
        yield s.readParticleAt(s.itemOffsets[k])
  else:
    for k in s.itemsByRing.getOrDefault(ring, @[]):
      if k in s.items:
        yield s.items[k]

proc particlesByRingWindow*(s: Store, ring: uint64, limit: int,
                            reverse = false): seq[Particle] =
  ## Read a bounded ring-local window without scanning the whole ring.
  ## This is used by read paths such as latest-N subring bundle reads.
  if limit <= 0:
    return
  let keys = s.itemsByRing.getOrDefault(ring, @[])
  if keys.len == 0:
    return
  var selected: seq[(uint64, uint32)] = @[]
  if reverse:
    var i = keys.high
    while i >= 0 and selected.len < limit:
      let k = keys[i]
      if s.diskBacked:
        if k in s.items or k in s.itemSegmentOffsets or k in s.itemOffsets:
          selected.add k
      elif k in s.items:
        selected.add k
      dec i
  else:
    for k in keys:
      if selected.len >= limit:
        break
      if s.diskBacked:
        if k in s.items or k in s.itemSegmentOffsets or k in s.itemOffsets:
          selected.add k
      elif k in s.items:
        selected.add k
  if selected.len == 0:
    return
  if s.diskBacked:
    var segmentStream: FileStream = nil
    var walStream: FileStream = nil
    try:
      for k in selected:
        if k in s.items:
          result.add s.items[k]
        elif k in s.itemSegmentOffsets:
          try:
            if segmentStream == nil:
              segmentStream = s.openSegmentReadStream(ring)
            let p = segmentStream.readParticleAtStream(s.itemSegmentOffsets[k])
            if p.parent != k[0] or p.seq != k[1] or
                p.version != s.itemVersions.getOrDefault(k):
              raise newException(IOError,
                "ring segment index does not match live revision")
            result.add p
            inc s.segmentReadHits
          except CatchableError:
            # A derived segment failure is isolated to this record. Continue
            # the bounded read from the authoritative WAL without reopening a
            # stream for every item.
            s.itemSegmentOffsets.del k
            inc s.segmentWalFallbacks
            inc s.segmentWalFallbackReasons[ssfrWindowRead]
            if k notin s.itemOffsets:
              raise
            if walStream == nil:
              walStream = s.openWalReadStream()
            result.add walStream.readParticleAtStream(s.itemOffsets[k])
        elif k in s.itemOffsets:
          if walStream == nil:
            walStream = s.openWalReadStream()
          result.add walStream.readParticleAtStream(s.itemOffsets[k])
    finally:
      if segmentStream != nil:
        segmentStream.close()
      if walStream != nil:
        walStream.close()
  else:
    for k in selected:
      if k in s.items:
        result.add s.items[k]

proc ringLiveCount*(s: Store, ring: uint64): int =
  ## itemsByRing is updated together with live state on upsert/delete replay,
  ## so this does not touch payload files.
  s.itemsByRing.getOrDefault(ring, @[]).len

proc itemKeysByRingPage*(s: Store, ring: uint64, afterSeq: int64,
                         limit: int): tuple[
                           items: seq[(uint64, uint32)], hasMore: bool] =
  ## Select a logical cursor page from seq-ordered metadata. Segment/WAL
  ## physical order is intentionally irrelevant, and no payload is read while
  ## locating the page boundary.
  if limit <= 0:
    return
  let keys = s.itemsByRing.getOrDefault(ring, @[])
  var low = 0
  var high = keys.len
  while low < high:
    let middle = low + (high - low) div 2
    if keys[middle][1].int64 <= afterSeq:
      low = middle + 1
    else:
      high = middle
  var index = low
  while index < keys.len and result.items.len < limit:
    let itemKey = keys[index]
    inc index
    if itemKey in s.items or itemKey in s.itemOffsets:
      result.items.add itemKey
  while index < keys.len:
    let itemKey = keys[index]
    inc index
    if itemKey in s.items or itemKey in s.itemOffsets:
      result.hasMore = true
      break

iterator allParticles*(s: Store): Particle =
  for ring in s.itemsByRing.keys:
    for p in s.particlesByRing(ring):
      yield p

proc getParticle*(s: Store, parent: uint64, seq: uint32): Particle =
  let k = key(parent, seq)
  if k in s.items:
    return s.items[k]
  if k in s.itemSegmentOffsets:
    return s.segmentParticleOrWal(parent, seq, s.itemSegmentOffsets[k],
                                   s.itemOffsets.getOrDefault(k, -1'i64))
  if k in s.itemOffsets:
    return s.readParticleAt(s.itemOffsets[k])
  raise newException(KeyError, "particle not found")

proc rebuildRingSegmentsFromOffsets(s: Store, wal: FileStream): SegmentPackStats =
  type SegmentSource = tuple[offset: int64, k: (uint64, uint32)]
  var live: seq[SegmentSource] = @[]
  var packedRings = initTable[uint64, bool]()
  var writers: seq[SegmentPackWriter] = @[]
  var writerIndexes = initTable[uint64, int]()
  for k, offset in s.itemOffsets:
    live.add (offset: offset, k: k)
  live.sort do (a, b: SegmentSource) -> int:
    cmp(a.offset, b.offset)
  try:
    for entry in live:
      let body = wal.readParticleBodyAtStream(entry.offset)
      let framed = walRecord(body)
      let k = entry.k
      s.itemSegmentOffsets[k] =
        s.appendPackRecord(writers, writerIndexes, k[0], framed)
      inc result.records
      result.bytes += framed.len.int64
      packedRings[k[0]] = true
  finally:
    writers.closePackWriters()
  result.rings = packedRings.len

proc rebuildSegmentIndexes(s: Store) =
  ## Rewrite the cache index only after every replacement segment is closed.
  ## A missing index is safe: openStore rebuilds it from the durable WAL.
  var files = initTable[uint64, File]()
  try:
    for k, segmentOffset in s.itemSegmentOffsets:
      if k notin s.itemOffsets:
        continue
      if k[0] notin files:
        files[k[0]] = open(s.segmentIndexPath(k[0]), fmWrite)
      var file = files[k[0]]
      file.write("P " & $k[0] & " " & $k[1] & " " & $s.itemOffsets[k] &
                 " " & $segmentOffset & "\n")
      files[k[0]] = file
  finally:
    for _, file in files.mpairs:
      file.flushFile()
      file.close()

proc rebuildRingSegments*(s: Store): SegmentPackStats {.discardable.} =
  if not s.diskBacked or not s.persistent or s.segmentDir.len == 0:
    return
  s.flushDiskBackedLog()
  s.closeSegmentFiles()
  s.closeSegmentIndexFiles()
  s.closeSegmentReadStreams()
  if dirExists(s.segmentDir):
    removeDir(s.segmentDir)
  createDir(s.segmentDir)
  s.segmentGenerations.clear()
  s.segmentRecordCounts.clear()
  s.itemSegmentOffsets.clear()
  let wal = newFileStream(s.logPath, fmRead)
  if wal.isNil:
    raise newException(IOError, "cannot open WAL for segment rebuild")
  try:
    result = s.rebuildRingSegmentsFromOffsets(wal)
    for ring, keys in s.itemsByRing:
      var live = 0
      for k in keys:
        if k in s.itemSegmentOffsets:
          inc live
      if live > 0:
        s.segmentRecordCounts[ring] = live
    s.rebuildSegmentIndexes()
  finally:
    wal.close()

proc closeRingSegmentHandles(s: Store, ring: uint64) =
  if ring in s.segmentFiles:
    s.segmentFiles[ring].flushFile()
    s.segmentFiles[ring].close()
    s.segmentFiles.del ring
  if ring in s.segmentIndexFiles:
    s.segmentIndexFiles[ring].flushFile()
    s.segmentIndexFiles[ring].close()
    s.segmentIndexFiles.del ring
  if ring in s.segmentReadStreams:
    if s.segmentReadStreams[ring] != nil:
      s.segmentReadStreams[ring].close()
    s.segmentReadStreams.del ring

proc packRingSegment*(s: Store, ring: uint64; maxBytes = 0'i64;
                      maxElapsedMs = 0'i64): SegmentPackStats {.discardable.} =
  ## Merge only one ring into a new complete segment generation.  The
  ## manifest is switched last, making an interrupted pack select either the
  ## old complete generation or the new complete generation, never a mix.
  if not s.diskBacked or not s.persistent or s.segmentDir.len == 0:
    return
  if maxBytes < 0:
    raise newException(ValueError, "maxBytes must be >= 0")
  if maxElapsedMs < 0:
    raise newException(ValueError, "maxElapsedMs must be >= 0")
  let startedAt = getMonoTime()

  template checkElapsedLimit() =
    if maxElapsedMs > 0 and
        (getMonoTime() - startedAt).inMilliseconds >= maxElapsedMs:
      var err = newException(SegmentPackLimitError,
        "segment pack elapsed-time budget exhausted")
      err.limitKind = splElapsed
      raise err

  s.flushDiskBackedLog()
  let oldGeneration = s.segmentGenerations.getOrDefault(ring, 0'u64)
  if oldGeneration == uint64.high:
    raise newException(IOError, "segment generation exhausted")
  let newGeneration = oldGeneration + 1
  let newSegment = s.segmentPath(ring, newGeneration)
  let newIndex = s.segmentIndexPath(ring, newGeneration)
  let tmpSegment = newSegment & ".tmp"
  let tmpIndex = newIndex & ".tmp"
  var keys = s.itemsByRing.getOrDefault(ring, @[])
  keys.sort(proc(a, b: (uint64, uint32)): int = cmp(a[1], b[1]))
  var offsets = initTable[(uint64, uint32), int64]()
  var segment = open(tmpSegment, fmWrite)
  var index = open(tmpIndex, fmWrite)
  var wal: FileStream = nil
  try:
    if keys.len > 0:
      wal = s.openWalReadStream()
    for k in keys:
      checkElapsedLimit()
      when defined(koutenTestFailpoints):
        if s.segmentPackDelayMs > 0:
          sleep(s.segmentPackDelayMs)
      if k notin s.itemOffsets:
        continue
      let body = wal.readParticleBodyAtStream(s.itemOffsets[k])
      let framed = walRecord(body)
      let indexLine = "P " & $k[0] & " " & $k[1] & " " &
                      $s.itemOffsets[k] & " " & $segment.getFilePos() & "\n"
      checkElapsedLimit()
      if maxBytes > 0 and
          result.bytes + result.indexBytes + framed.len.int64 +
            indexLine.len.int64 > maxBytes:
        var err = newException(SegmentPackLimitError,
          "segment pack byte budget exhausted")
        err.limitKind = splBytes
        raise err
      let segmentOffset = segment.getFilePos()
      segment.write(framed)
      index.write(indexLine)
      when defined(koutenTestCrashPoints):
        processCrashPoint("segment-output")
      offsets[k] = segmentOffset
      inc result.records
      result.bytes += framed.len.int64
      result.indexBytes += indexLine.len.int64
    segment.syncFile()
    index.syncFile()
    checkElapsedLimit()
  except CatchableError:
    segment.close()
    index.close()
    if wal != nil: wal.close()
    if fileExists(tmpSegment): removeFile(tmpSegment)
    if fileExists(tmpIndex): removeFile(tmpIndex)
    raise
  segment.close()
  index.close()
  if wal != nil: wal.close()
  replaceFileAtomic(tmpSegment, newSegment)
  when defined(koutenTestCrashPoints):
    processCrashPoint("segment-after-data-publish")
  when defined(koutenTestFailpoints):
    if s.segmentPackFailAfterSegmentReplace:
      raise newException(IOError,
        "test segment pack failure after segment replacement")
  replaceFileAtomic(tmpIndex, newIndex)
  when defined(koutenTestCrashPoints):
    processCrashPoint("segment-before-manifest")
  when defined(koutenTestFailpoints):
    if s.segmentPackFailBeforeManifest:
      raise newException(IOError, "test segment pack failure before manifest")
  s.closeRingSegmentHandles(ring)
  s.segmentGenerations[ring] = newGeneration
  try:
    s.writeSegmentManifest()
    when defined(koutenTestCrashPoints):
      processCrashPoint("segment-after-manifest")
  except CatchableError:
    s.segmentGenerations[ring] = oldGeneration
    raise
  for k in s.itemsByRing.getOrDefault(ring, @[]):
    s.itemSegmentOffsets.del k
  for k, offset in offsets:
    s.itemSegmentOffsets[k] = offset
  s.segmentRecordCounts[ring] = result.records
  result.rings = 1
  let activeSegment = s.segmentPath(ring, newGeneration)
  let activeIndex = s.segmentIndexPath(ring, newGeneration)
  let ringPrefix = toHex(ring, 16)
  for path in walkFiles(s.segmentDir / (ringPrefix & "*")):
    if path != activeSegment and path != activeIndex and
        (path.endsWith(".seg") or path.endsWith(".idx") or
         path.endsWith(".tmp")):
      removeFile(path)
      inc result.removedFiles
      when defined(koutenTestCrashPoints):
        processCrashPoint("segment-cleanup")
  syncDir(s.segmentDir)

when defined(koutenTestFailpoints):
  proc failSegmentPackAfterSegmentReplaceForTest*(s: Store; enabled: bool) =
    s.segmentPackFailAfterSegmentReplace = enabled

  proc failSegmentPackBeforeManifestForTest*(s: Store; enabled: bool) =
    s.segmentPackFailBeforeManifest = enabled

  proc delaySegmentPackForTest*(s: Store; milliseconds: int) =
    if milliseconds < 0:
      raise newException(ValueError, "segment pack test delay must be >= 0")
    s.segmentPackDelayMs = milliseconds

proc segmentReport*(s: Store; staleRatioThreshold = 0.25;
                    minStaleRecords = 256): StoreSegmentReport =
  ## Report the derived ring-local read layout. Recommendations are diagnostic
  ## only; KoutenDB never starts background packing from this function.
  if staleRatioThreshold < 0 or staleRatioThreshold > 1:
    raise newException(ValueError, "staleRatioThreshold must be between 0 and 1")
  if minStaleRecords < 0:
    raise newException(ValueError, "minStaleRecords must be >= 0")
  result.diskBacked = s.diskBacked
  result.segmentHits = s.segmentReadHits
  result.walFallbacks = s.segmentWalFallbacks
  result.walFallbackReasons = s.segmentWalFallbackReasons
  var rings: seq[uint64] = @[]
  var seen = initTable[uint64, bool]()
  for ring in s.itemsByRing.keys:
    if not seen.getOrDefault(ring, false):
      rings.add ring
      seen[ring] = true
  for ring in s.segmentRecordCounts.keys:
    if not seen.getOrDefault(ring, false):
      rings.add ring
      seen[ring] = true
  for ring in s.segmentGenerations.keys:
    if not seen.getOrDefault(ring, false):
      rings.add ring
      seen[ring] = true
  rings.sort()
  for ring in rings:
    let live = s.ringLiveCount(ring)
    var covered = 0
    for k in s.itemsByRing.getOrDefault(ring, @[]):
      if k in s.itemSegmentOffsets:
        inc covered
    let records = s.segmentRecordCounts.getOrDefault(ring, covered)
    let stale = max(0, records - live)
    let ratio = if records == 0: 0.0 else: float(stale) / float(records)
    let segmentPath = s.segmentPath(ring)
    let indexPath = s.segmentIndexPath(ring)
    let segmentBytes = if fileExists(segmentPath): getFileSize(segmentPath) else: 0'i64
    let indexBytes = if fileExists(indexPath): getFileSize(indexPath) else: 0'i64
    let recommended = stale >= minStaleRecords and ratio >= staleRatioThreshold
    let generation = s.segmentGenerations.getOrDefault(ring, 0'u64)
    result.rings.add StoreSegmentRingReport(
      ring: ring, generation: generation, liveRecords: live,
      coveredRecords: covered, segmentRecords: records,
      staleRecords: stale, staleRatio: ratio,
      segmentBytes: segmentBytes, indexBytes: indexBytes,
      packRecommended: recommended)
    if recommended:
      inc result.recommendedRings
    result.totalSegmentBytes += segmentBytes
    result.totalIndexBytes += indexBytes
    result.maxGeneration = max(result.maxGeneration, generation)

proc segmentMetrics*(s: Store; staleRatioThreshold = 0.25;
                     minStaleRecords = 256): StoreSegmentMetrics =
  ## Low-cost aggregate metrics. This intentionally avoids walking every live
  ## record so a monitoring scrape cannot become a full data scan.
  if staleRatioThreshold < 0 or staleRatioThreshold > 1:
    raise newException(ValueError, "staleRatioThreshold must be between 0 and 1")
  if minStaleRecords < 0:
    raise newException(ValueError, "minStaleRecords must be >= 0")
  result.hits = s.segmentReadHits
  result.walFallbacks = s.segmentWalFallbacks
  result.walFallbackReasons = s.segmentWalFallbackReasons
  if not s.diskBacked or s.segmentDir.len == 0:
    return
  var rings = initHashSet[uint64]()
  for ring in s.itemsByRing.keys: rings.incl ring
  for ring in s.segmentRecordCounts.keys: rings.incl ring
  for ring in s.segmentGenerations.keys: rings.incl ring
  for ring in rings:
    let generation = s.segmentGenerations.getOrDefault(ring, 0'u64)
    if generation > 0:
      inc result.activeGenerations
    let records = s.segmentRecordCounts.getOrDefault(ring, 0)
    let stale = max(0, records - s.ringLiveCount(ring))
    let ratio = if records == 0: 0.0 else: float(stale) / float(records)
    result.staleRecords += stale
    if stale >= minStaleRecords and ratio >= staleRatioThreshold:
      inc result.recommendedRings
    let segmentPath = s.segmentPath(ring)
    let indexPath = s.segmentIndexPath(ring)
    if fileExists(segmentPath): result.segmentBytes += getFileSize(segmentPath)
    if fileExists(indexPath): result.indexBytes += getFileSize(indexPath)

proc readClusterTxOp(fs: Stream, parts: seq[string], firstData: int): ClusterTxOp =
  var data = firstData
  result.kind = ctxPut
  if parts.len > firstData and (parts[firstData] == "P" or parts[firstData] == "D"):
    result.kind = if parts[firstData] == "D": ctxDelete else: ctxPut
    inc data
  result.parent = parseBiggestUInt(parts[data]).uint64
  result.seq = parseUInt(parts[data + 1]).uint32
  result.period = parseFloat(parts[data + 2])
  result.head = parseFloat(parts[data + 3])
  result.tWrite = parseFloat(parts[data + 4])
  let len = parseInt(parts[data + 5])
  let dim = if parts.len > data + 6: parseInt(parts[data + 6]) else: 0
  result.codec = if parts.len > data + 7:
                   parsePayloadCodec(parts[data + 7])
                 else:
                   pcRaw
  result.version = parseMutationVersion(parts, data + 8, result.tWrite)
  result.payload = fs.readExactStr(len)
  result.vec = fs.readVec(dim)
  fs.readRecordSep()

proc truncateLog(path: string, size: int64) =
  if posix.truncate(path.cstring, posix.Off(size)) != 0:
    raiseOSError(osLastError())

proc syncFile(file: File) =
  file.flushFile()
  when not defined(windows):
    if posix.fsync(cint(file.getFileHandle())) != 0:
      raiseOSError(osLastError())

proc syncDir(path: string) =
  when not defined(windows):
    let dirPath = if path.len == 0: "." else: path
    let fd = posix.open(dirPath.cstring, posix.O_RDONLY)
    if fd < 0:
      raiseOSError(osLastError())
    try:
      if posix.fsync(fd) != 0:
        raiseOSError(osLastError())
    finally:
      discard posix.close(fd)

when not defined(windows):
  proc cRename(oldname, newname: cstring): cint {.importc: "rename",
      header: "<stdio.h>".}

proc replaceFileAtomic(src, dst: string) =
  when defined(windows):
    if fileExists(dst):
      removeFile(dst)
    moveFile(src, dst)
  else:
    if cRename(src.cstring, dst.cstring) != 0:
      raiseOSError(osLastError())

proc writeFileDurable(path, data: string) =
  var file = open(path, fmWrite)
  try:
    file.write(data)
    file.syncFile()
  finally:
    file.close()

proc segmentMaintenanceStatusPath*(s: Store): string =
  if not s.persistent or s.logPath.len == 0:
    return ""
  s.logPath.parentDir / "segment-maintenance.json"

proc writeSegmentMaintenanceStatus*(s: Store, data: string) =
  ## Publish scheduler state atomically. A crash can leave the temporary file,
  ## but readers only observe the previous or next complete status document.
  let path = s.segmentMaintenanceStatusPath()
  if path.len == 0:
    return
  let tmp = path & ".tmp"
  writeFileDurable(tmp, data)
  replaceFileAtomic(tmp, path)
  syncDir(path.parentDir)

proc readSegmentMaintenanceStatus*(s: Store): string =
  let path = s.segmentMaintenanceStatusPath()
  if path.len > 0 and fileExists(path):
    readFile(path)
  else:
    ""

proc unregisterDataDir(identity: string) =
  acquire(dataDirRegistryLock)
  try:
    openDataDirs.excl identity
  finally:
    release(dataDirRegistryLock)

proc dataDirGuardPath(identity: string): string =
  ## Unlike the legacy lock inside the data directory, this path does not move
  ## when checkpoint restore atomically replaces the directory.
  identity & ".kouten-dir.lock"

when not defined(windows):
  proc acquireFileLock(path, dir: string): cint =
    result = posix.open(path.cstring, posix.O_RDWR or posix.O_CREAT, 0o600)
    if result < 0:
      raise newException(IOError, "cannot open data directory lock: " & path)
    var fl = posix.Tflock(l_type: posix.F_WRLCK.cshort,
                          l_whence: posix.SEEK_SET.cshort,
                          l_start: 0,
                          l_len: 0)
    if posix.fcntl(result, posix.F_SETLK, addr fl) != 0:
      discard posix.close(result)
      result = -1
      raise newException(IOError, "data directory is already open: " & dir)

  proc releaseFileLock(fd: var cint) =
    if fd < 0:
      return
    var fl = posix.Tflock(l_type: posix.F_UNLCK.cshort,
                          l_whence: posix.SEEK_SET.cshort,
                          l_start: 0,
                          l_len: 0)
    discard posix.fcntl(fd, posix.F_SETLK, addr fl)
    discard posix.close(fd)
    fd = -1

proc acquireDataDirLock(dir: string): DataDirLock =
  ## POSIX record locks are process-scoped, so they do not reject a second
  ## Store handle in the same process. Reserve the canonical directory in a
  ## process-local registry as well as taking the cross-process file lock.
  let identity = expandFilename(dir)
  acquire(dataDirRegistryLock)
  try:
    if identity in openDataDirs:
      raise newException(IOError, "data directory is already open: " & dir)
    openDataDirs.incl identity
  finally:
    release(dataDirRegistryLock)

  result = DataDirLock(fd: -1, guardFd: -1, identity: identity, held: true)
  try:
    when not defined(windows):
      result.guardFd = acquireFileLock(dataDirGuardPath(identity), dir)
      result.fd = acquireFileLock(dir / ".kouten.lock", dir)
  except CatchableError:
    when not defined(windows):
      releaseFileLock(result.fd)
      releaseFileLock(result.guardFd)
    unregisterDataDir(identity)
    result.held = false
    raise

proc releaseDataDirLock(dataDirLock: var DataDirLock) =
  if not dataDirLock.held:
    return
  when not defined(windows):
    releaseFileLock(dataDirLock.fd)
    releaseFileLock(dataDirLock.guardFd)
  unregisterDataDir(dataDirLock.identity)
  dataDirLock = DataDirLock(fd: -1, guardFd: -1)

proc backupKey(passphrase: string): SecretBoxKey =
  if passphrase.len == 0:
    raise newException(ValueError, "backup passphrase is empty")
  secretBoxKeyFromBytes(genericHash("koutendb-backup-v1\0" & passphrase,
                                    SecretBoxKeyBytes))

proc endsWithNewline(path: string): bool =
  if not fileExists(path) or getFileSize(path) == 0:
    return true
  var f = open(path, fmRead)
  try:
    f.setFilePos(getFileSize(path) - 1)
    var buf: array[1, char]
    result = f.readChars(buf) == 1 and buf[0] == '\n'
  finally:
    f.close()

proc truncateMissingFinalNewline(path: string) =
  if endsWithNewline(path):
    return
  var f = open(path, fmRead)
  try:
    var pos = getFileSize(path) - 1
    var buf: array[1, char]
    while pos >= 0:
      f.setFilePos(pos)
      if f.readChars(buf) == 1 and buf[0] == '\n':
        truncateLog(path, pos + 1)
        return
      dec pos
    truncateLog(path, 0)
  finally:
    f.close()

proc isVersionedWalFile(path: string): bool =
  if not fileExists(path) or getFileSize(path) == 0:
    return false
  var f = open(path, fmRead)
  try:
    var line = ""
    result = f.readLine(line) and line == WalMagicLine
  finally:
    f.close()

proc checkedWalBody(fs: Stream, parts: seq[string]): string =
  if parts.len != 3:
    raise newException(WalCorruptionError, "invalid WAL wrapper header")
  let len = checkedStoreLen(parseInt(parts[1]), "walRecordLen")
  let expected = parseBiggestUInt(parts[2]).uint32
  result = fs.readExactStr(len)
  let actual = crc32(result)
  if actual != expected:
    raise newException(WalCorruptionError,
      "WAL checksum mismatch: expected " & $expected & ", got " & $actual)


proc replay(s: Store, path: string, repair = true) =
  let versionedWal = isVersionedWalFile(path)
  if repair and not versionedWal:
    truncateMissingFinalNewline(path)
  elif not repair and not endsWithNewline(path):
    raise newException(IOError, "WAL snapshot is missing final newline")
  let fs = newFileStream(path, fmRead)
  if fs.isNil: return
  let fileBytes = getFileSize(path)
  var line = ""
  var pending = initTable[uint64, seq[TxOp]]()
  var pendingCluster = initTable[uint64, ClusterTxIntent]()
  var lastGood = fs.getPosition()
  var repairTo = -1
  var strictWal = false
  var seenRecord = false
  while true:
    let recordStart = fs.getPosition()
    if not fs.readLine(line):
      break
    if line.len == 0: continue
    if line == WalMagicLine:
      if seenRecord:
        fs.close()
        raise newException(IOError, "WAL magic appears after records")
      strictWal = true
      lastGood = fs.getPosition()
      continue
    seenRecord = true
    var parts = line.split(' ')
    var recordStream: Stream = fs
    var bodyStream: StringStream = nil
    try:
      if parts[0] == WalRecordTag:
        let body = checkedWalBody(fs, parts)
        bodyStream = newStringStream(body)
        if not bodyStream.readLine(line):
          raise newException(WalCorruptionError, "empty WAL record body")
        parts = line.split(' ')
        recordStream = bodyStream
      elif strictWal:
        raise newException(WalCorruptionError, "unwrapped WAL record in versioned log")
      case parts[0]
      of "G":
        let len = parseInt(parts[1])
        s.galaxy = recordStream.readExactStr(len)
        recordStream.readRecordSep()
      of "GD":
        let len = parseInt(parts[1])
        s.galaxyDescription = recordStream.readExactStr(len)
        recordStream.readRecordSep()
      of "R":
        s.ringMeta[parseBiggestUInt(parts[1]).uint64] =
          (parseFloat(parts[2]), parseFloat(parts[3]))
      of "N":
        let ringKey = parseBiggestUInt(parts[1]).uint64
        let len = parseInt(parts[2])
        s.ringNames[ringKey] = recordStream.readExactStr(len)
        recordStream.readRecordSep()
      of "RD":
        let ringKey = parseBiggestUInt(parts[1]).uint64
        let len = parseInt(parts[2])
        let desc = recordStream.readExactStr(len)
        if desc.len == 0:
          s.ringDescriptions.del ringKey
        else:
          s.ringDescriptions[ringKey] = desc
        recordStream.readRecordSep()
      of "RP":
        let ringKey = parseBiggestUInt(parts[1]).uint64
        let len = parseInt(parts[2])
        let profile = parseJson(recordStream.readExactStr(len))
        s.ringPayloadProfiles[ringKey] = RingPayloadProfile(
          defaultCodec: parsePayloadCodec(profile{"defaultCodec"}.getStr("raw")),
          charset: profile{"charset"}.getStr(""),
          formatVersion: profile{"formatVersion"}.getStr(""))
        recordStream.readRecordSep()
      of "TO":
        let ringKey = parseBiggestUInt(parts[1]).uint64
        let len = parseInt(parts[2])
        let profile = parseTimeOrbitProfile(recordStream.readExactStr(len))
        s.ringTimeOrbitProfiles[ringKey] = profile
        recordStream.readRecordSep()
      of "SM":
        let len = parseInt(parts[1])
        let raw = recordStream.readExactStr(len)
        let node = parseJson(raw)
        let stellar = node{"stellar"}.getStr("")
        discard validateStellarMapBlob(stellar, raw, allowDeleted = true)
        if node{"deleted"}.getBool(false):
          s.stellarMaps.del stellar
        else:
          s.stellarMaps[stellar] = raw
        recordStream.readRecordSep()
      of "PM":
        if parts.len != 4:
          raise newException(WalCorruptionError,
            "invalid placement metadata record")
        let epoch = parseUInt(parts[1])
        let nodes = parseUInt(parts[2])
        let virtualArcs = parseInt(parts[3])
        if epoch == 0 or epoch > uint32.high.uint64 or
            nodes == 0 or nodes > uint16.high.uint64 or virtualArcs <= 0:
          raise newException(WalCorruptionError,
            "invalid placement metadata values")
        s.placementEpoch = uint32(epoch)
        s.placementNodes = uint16(nodes)
        s.placementVirtualArcs = virtualArcs
      of "MD":
        if parts.len != 2 or parts[1] notin ["0", "1"]:
          raise newException(WalCorruptionError,
            "invalid maintenance drain record")
        s.maintenanceDrained = parts[1] == "1"
      of "P":
        let p = recordStream.readParticleRecord(parts, 1)
        s.applyOp(TxOp(kind: txUpsert, p: p, walOffset: recordStart,
                       segmentOffset: -1'i64, segmentBody: ""))
      of "E":
        let parent = parseBiggestUInt(parts[1]).uint64
        let seq = parseUInt(parts[2]).uint32
        let dim = parseInt(parts[3])
        let v = recordStream.readVec(dim)
        recordStream.readRecordSep()
        let k = key(parent, seq)
        if k in s.items:
          s.items[k].vec = v
      of "F":
        let oldParent = parseBiggestUInt(parts[1]).uint64
        let oldSeq = parseUInt(parts[2]).uint32
        s.forwarders[key(oldParent, oldSeq)] =
          Forwarder(newParent: parseBiggestUInt(parts[3]).uint64,
                    newSeq: parseUInt(parts[4]).uint32,
                    newTWrite: parseFloat(parts[5]),
                    expiresAt: parseFloat(parts[6]))
      of "D":
        # Legacy/physical handoff eviction. Logical deletes use L and retain
        # ordering metadata so delayed transfers cannot resurrect data.
        s.evictState(parseBiggestUInt(parts[1]).uint64,
                     parseUInt(parts[2]).uint32)
      of "L":
        s.applyOp(TxOp(kind: txRemove,
                       tombstone: readTombstoneRecord(parts, 1)))
      of "LG":
        s.tombstones.del key(parseBiggestUInt(parts[1]).uint64,
                             parseUInt(parts[2]).uint32)
      of "T":
        let txid = parseBiggestUInt(parts[1]).uint64
        pending[txid] = @[]
        s.nextTxId = max(s.nextTxId, txid + 1)
      of "XR":
        let txid = parseBiggestUInt(parts[1]).uint64
        pending.mgetOrPut(txid, @[]).add TxOp(kind: txRingMeta,
                                              ringKey: parseBiggestUInt(parts[2]).uint64,
                                              ringPeriod: parseFloat(parts[3]),
                                              ringHead: parseFloat(parts[4]))
        s.nextTxId = max(s.nextTxId, txid + 1)
      of "XN":
        let txid = parseBiggestUInt(parts[1]).uint64
        let ringKey = parseBiggestUInt(parts[2]).uint64
        let len = parseInt(parts[3])
        pending.mgetOrPut(txid, @[]).add TxOp(kind: txRingName,
                                              ringNameKey: ringKey,
                                              ringName: recordStream.readExactStr(len))
        recordStream.readRecordSep()
        s.nextTxId = max(s.nextTxId, txid + 1)
      of "XP":
        let txid = parseBiggestUInt(parts[1]).uint64
        let p = recordStream.readParticleRecord(parts, 2)
        pending.mgetOrPut(txid, @[]).add TxOp(kind: txUpsert, p: p,
                                              walOffset: recordStart,
                                              segmentOffset: -1'i64,
                                              segmentBody: "")
        s.nextTxId = max(s.nextTxId, txid + 1)
      of "XD":
        let txid = parseBiggestUInt(parts[1]).uint64
        pending.mgetOrPut(txid, @[]).add TxOp(kind: txRemove,
          tombstone: Tombstone(
            parent: parseBiggestUInt(parts[2]).uint64,
            seq: parseUInt(parts[3]).uint32))
        s.nextTxId = max(s.nextTxId, txid + 1)
      of "XL":
        let txid = parseBiggestUInt(parts[1]).uint64
        pending.mgetOrPut(txid, @[]).add TxOp(
          kind: txRemove,
          tombstone: readTombstoneRecord(parts, 2))
        s.nextTxId = max(s.nextTxId, txid + 1)
      of "XF":
        let txid = parseBiggestUInt(parts[1]).uint64
        pending.mgetOrPut(txid, @[]).add TxOp(kind: txForwarder,
                                              oldParent: parseBiggestUInt(parts[2]).uint64,
                                              oldSeq: parseUInt(parts[3]).uint32,
                                              f: Forwarder(newParent: parseBiggestUInt(parts[4]).uint64,
                                                           newSeq: parseUInt(parts[5]).uint32,
                                                           newTWrite: parseFloat(parts[6]),
                                                           expiresAt: parseFloat(parts[7])))
        s.nextTxId = max(s.nextTxId, txid + 1)
      of "XUJ":
        let txid = parseBiggestUInt(parts[1]).uint64
        let eventId = parseBiggestUInt(parts[2]).uint64
        let len = parseInt(parts[3])
        pending.mgetOrPut(txid, @[]).add TxOp(kind: txUniverseSyncEvent,
                                              universeEventId: eventId,
                                              universeEventBlob: recordStream.readExactStr(len))
        recordStream.readRecordSep()
        s.nextTxId = max(s.nextTxId, txid + 1)
        s.nextUniverseSyncId = max(s.nextUniverseSyncId, eventId)
      of "XUD":
        let txid = parseBiggestUInt(parts[1]).uint64
        pending.mgetOrPut(txid, @[]).add TxOp(kind: txUniverseSyncDelete,
                                              universeDeleteEventId: parseBiggestUInt(parts[2]).uint64)
        s.nextTxId = max(s.nextTxId, txid + 1)
      of "C":
        let txid = parseBiggestUInt(parts[1]).uint64
        if txid in pending:
          s.applyOps(pending[txid])
          pending.del txid
        s.nextTxId = max(s.nextTxId, txid + 1)
      of "CT":
        let txid = parseBiggestUInt(parts[1]).uint64
        pendingCluster[txid] = ClusterTxIntent(id: txid)
        s.nextTxId = max(s.nextTxId, txid + 1)
      of "CP":
        let txid = parseBiggestUInt(parts[1]).uint64
        let op = recordStream.readClusterTxOp(parts, 2)
        pendingCluster.mgetOrPut(txid, ClusterTxIntent(id: txid)).ops.add op
        s.nextTxId = max(s.nextTxId, txid + 1)
      of "CC":
        let txid = parseBiggestUInt(parts[1]).uint64
        var intent = pendingCluster.getOrDefault(txid, ClusterTxIntent(id: txid))
        intent.committed = true
        intent.applied = s.appliedClusterTx.getOrDefault(txid, false)
        s.clusterTx[txid] = intent
        pendingCluster.del txid
        s.nextTxId = max(s.nextTxId, txid + 1)
      of "CA":
        let txid = parseBiggestUInt(parts[1]).uint64
        s.appliedClusterTx[txid] = true
        if txid in s.clusterTx:
          s.clusterTx[txid].applied = true
        s.nextTxId = max(s.nextTxId, txid + 1)
      of "WJ":
        let jobId = parseBiggestUInt(parts[1]).uint64
        let len = parseInt(parts[2])
        s.warpJobs[jobId] = recordStream.readExactStr(len)
        recordStream.readRecordSep()
      of "WD":
        s.warpJobs.del parseBiggestUInt(parts[1]).uint64
      of "UJ":
        let eventId = parseBiggestUInt(parts[1]).uint64
        let len = parseInt(parts[2])
        s.universeSyncEvents[eventId] = recordStream.readExactStr(len)
        recordStream.readRecordSep()
        s.nextUniverseSyncId = max(s.nextUniverseSyncId, eventId)
      of "UD":
        s.universeSyncEvents.del parseBiggestUInt(parts[1]).uint64
      of "UA":
        let len = parseInt(parts[1])
        let eventKey = recordStream.readExactStr(len)
        if not s.appliedUniverseSyncEvents.getOrDefault(eventKey, false):
          s.appliedUniverseSyncOrder.add eventKey
        s.appliedUniverseSyncEvents[eventKey] = true
        recordStream.readRecordSep()
      of "UX":
        let len = parseInt(parts[1])
        let eventKey = recordStream.readExactStr(len)
        s.appliedUniverseSyncEvents.del eventKey
        for i in countdown(s.appliedUniverseSyncOrder.len - 1, 0):
          if s.appliedUniverseSyncOrder[i] == eventKey:
            s.appliedUniverseSyncOrder.delete(i)
        recordStream.readRecordSep()
      of "UQ":
        s.nextUniverseSyncId = max(s.nextUniverseSyncId,
                                  parseBiggestUInt(parts[1]).uint64)
      of "Q":
        s.nextTxId = max(s.nextTxId, parseBiggestUInt(parts[1]).uint64)
      of "S":
        let ringKey = parseBiggestUInt(parts[1]).uint64
        let nextSeq = parseUInt(parts[2]).uint32
        s.seqs[ringKey] = max(s.seqs.getOrDefault(ringKey, 0'u32), nextSeq)
      of "M":
        s.maxTWrite = max(s.maxTWrite, parseFloat(parts[1]))
      else:
        if strictWal:
          raise newException(WalCorruptionError, "unknown WAL record tag: " & parts[0])
        discard   # legacy WAL keeps best-effort forward compatibility
      if not bodyStream.isNil and not bodyStream.atEnd:
        raise newException(WalCorruptionError, "WAL record body has trailing bytes")
      lastGood = fs.getPosition()
    except CatchableError:
      if getCurrentException() of WalCorruptionError:
        fs.close()
        raise newException(IOError, "invalid versioned WAL record near byte " &
          $lastGood & ": " & getCurrentExceptionMsg())
      if repair:
        if fs.getPosition() < fileBytes:
          fs.close()
          raise newException(IOError, "invalid WAL record before end of file near byte " &
            $lastGood & ": " & getCurrentExceptionMsg())
        repairTo = lastGood
        break
      fs.close()
      raise newException(IOError, "invalid WAL snapshot near byte " &
        $lastGood & ": " & getCurrentExceptionMsg())
  fs.close()
  if repairTo >= 0:
    truncateLog(path, repairTo.int64)

proc recoverCompaction(path: string) =
  let tmp = path & ".compact"
  let bak = path & ".bak"
  if not fileExists(path):
    if fileExists(tmp):
      moveFile(tmp, path)
    elif fileExists(bak):
      moveFile(bak, path)
  elif fileExists(tmp):
    removeFile(tmp)
  if fileExists(path) and fileExists(bak):
    removeFile(bak)

proc clearReplayState(s: Store) =
  ## WAL compaction changes record offsets.  Keep runtime configuration and
  ## file handles, but discard every value reconstructed from the WAL before
  ## replaying the new compacted generation.
  s.items.clear()
  s.itemVersions.clear()
  s.tombstones.clear()
  s.itemsByRing.clear()
  s.itemOffsets.clear()
  s.itemSegmentOffsets.clear()
  s.itemHasVector.clear()
  s.vectorCount = 0
  s.vectorCountByRing.clear()
  s.forwarders.clear()
  s.seqs.clear()
  s.ringMeta.clear()
  s.ringNames.clear()
  s.ringDescriptions.clear()
  s.ringPayloadProfiles.clear()
  s.ringTimeOrbitProfiles.clear()
  s.stellarMaps.clear()
  s.galaxy = ""
  s.galaxyDescription = ""
  s.placementEpoch = 0
  s.placementNodes = 0
  s.placementVirtualArcs = 0
  s.maintenanceDrained = false
  s.clusterTx.clear()
  s.appliedClusterTx.clear()
  s.warpJobs.clear()
  s.universeSyncEvents.clear()
  s.appliedUniverseSyncEvents.clear()
  s.appliedUniverseSyncOrder.setLen(0)
  s.nextUniverseSyncId = 0
  s.maxTWrite = 0
  s.mutationClockPhysical = 0
  s.mutationClockLogical = 0
  s.nextTxId = 1

proc flushMaybe(s: Store, force = false)

proc markWriteFailed(s: Store, message: string) =
  if s.persistent:
    s.writeFailed = true
    s.writeError = message

proc ensureWritable(s: Store) =
  if s.writeFailed:
    let suffix = if s.writeError.len > 0: ": " & s.writeError else: ""
    raise newException(IOError, "store write path is poisoned" & suffix)

when defined(koutenTestFailpoints):
  proc poisonWritesForTest*(s: Store, message = "test write failure") =
    s.markWriteFailed(message)

proc openStore*(dir: string, durability: StoreDurability = durBuffered,
                diskBacked = false, mutationOrigin = 1'u32): Store =
  ## dir == "" ならメモリのみ。指定時は dir/kouten.log に追記・起動時に再生。
  result = Store(lastFlush: getMonoTime(), nextTxId: 1,
                 durability: durability,
                 diskBacked: diskBacked,
                 mutationOrigin: mutationOrigin)
  if dir.len > 0:
    createDir(dir)
    result.dataDirLock = acquireDataDirLock(dir)
    let path = dir / "kouten.log"
    if diskBacked:
      result.segmentDir = dir / "segments"
    try:
      recoverCompaction(path)
      let newLog = not fileExists(path) or getFileSize(path) == 0
      result.replay(path)
      result.logPath = path
      result.persistent = true
      if diskBacked and not newLog:
        if dirExists(result.segmentDir):
          # Empty generations are meaningful after every record in a ring is
          # deleted, so restore the manifest even when the WAL has no live
          # item offsets.
          if not result.loadSegmentManifest() or
              not result.loadRingSegmentIndexes():
            result.rebuildRingSegments()
        elif result.itemOffsets.len > 0:
          # Existing v0.10 stores have no sidecar index, so they take one
          # migration rebuild. Subsequent opens reuse validated ring segments.
          result.rebuildRingSegments()
      result.logFile = open(path, fmAppend)
      if newLog:
        result.logFile.write(WalMagicLine & "\n")
        result.flushMaybe(force = true)
      if durability == durStrong:
        syncDir(dir)
    except CatchableError:
      releaseDataDirLock(result.dataDirLock)
      raise

proc setGalaxy*(s: Store, galaxy: string) =
  if galaxy.len == 0:
    return
  s.ensureWritable()
  if s.galaxy.len > 0:
    if s.galaxy != galaxy:
      raise newException(ValueError,
        "data dir belongs to galaxy '" & s.galaxy & "', not '" & galaxy & "'")
    return
  s.galaxy = galaxy
  if s.persistent:
    s.logFile.writeWalRecord("G " & $galaxy.len & "\n" & galaxy & "\n")
    s.flushMaybe(force = true)

proc clusterTxPending*(s: Store): int

proc configurePlacement*(s: Store, epoch: uint32, nodes: uint16,
                         virtualArcs: int) =
  ## Persist and fence the physical placement topology. Changing membership or
  ## virtual-arc density requires an explicit epoch increase; rollback is
  ## rejected because it could silently reintroduce stale ownership.
  if epoch == 0:
    raise newException(ValueError, "placement epoch must be positive")
  if nodes == 0:
    raise newException(ValueError, "placement nodes must be positive")
  if virtualArcs <= 0:
    raise newException(ValueError, "placement virtual arcs must be positive")
  s.ensureWritable()
  if s.placementEpoch > epoch:
    raise newException(ValueError,
      "placement epoch rollback is not allowed (stored=" &
      $s.placementEpoch & ", requested=" & $epoch & ")")
  if s.placementEpoch != 0 and nodes < s.placementNodes:
    raise newException(ValueError,
      "placement node removal requires an explicit drain/export workflow; " &
      "automatic scale-in is not supported")
  if s.placementEpoch == epoch and s.placementEpoch != 0:
    if s.placementNodes != nodes or s.placementVirtualArcs != virtualArcs:
      raise newException(ValueError,
        "placement topology changed without increasing placement epoch")
    return
  if s.placementEpoch != 0 and not s.maintenanceDrained:
    raise newException(ValueError,
      "placement topology changes require persistent maintenance drain")
  if s.placementEpoch != 0 and s.clusterTxPending > 0:
    raise newException(ValueError,
      "placement topology changes require zero pending cluster transactions")
  if s.placementEpoch != 0 and s.warpJobs.len > 0:
    raise newException(ValueError,
      "placement topology changes require zero pending warp jobs")
  if s.placementEpoch != 0 and s.universeSyncEvents.len > 0:
    raise newException(ValueError,
      "placement topology changes require zero pending Universe sync events")
  s.placementEpoch = epoch
  s.placementNodes = nodes
  s.placementVirtualArcs = virtualArcs
  if s.persistent:
    s.logFile.writeWalLine("PM " & $epoch & " " & $nodes & " " & $virtualArcs)
    s.flushMaybe(force = true)

proc setMaintenanceDrained*(s: Store, drained: bool) =
  ## Persist the operator-controlled quiet point used by backup and explicit
  ## topology migration. A restart must not silently resume writes.
  if s.maintenanceDrained == drained:
    if s.persistent:
      s.flushMaybe(force = true)
    return
  s.ensureWritable()
  if s.persistent:
    s.logFile.writeWalLine("MD " & $(if drained: 1 else: 0))
    s.flushMaybe(force = true)
  s.maintenanceDrained = drained

proc mutationState*(s: Store, parent: uint64, seq: uint32): MutationState =
  let k = key(parent, seq)
  if k in s.tombstones:
    return MutationState(found: true, deleted: true,
                         version: s.tombstones[k].version)
  if k in s.itemVersions:
    return MutationState(found: true, deleted: false,
                         version: s.itemVersions[k])

proc flushMaybe(s: Store, force: bool) =
  if not s.persistent: return
  s.ensureWritable()
  inc s.dirty
  let nowM = getMonoTime()
  if force or s.durability == durStrong or s.dirty >= FlushEvery or
      (nowM - s.lastFlush).inNanoseconds > FlushNs:
    try:
      if s.durability == durStrong:
        s.logFile.syncFile()
      else:
        s.logFile.flushFile()
      s.dirty = 0
      s.lastFlush = nowM
    except CatchableError:
      s.markWriteFailed(getCurrentExceptionMsg())
      raise

proc sync*(s: Store) =
  if s.persistent:
    s.flushMaybe(force = true)
    s.flushSegmentFiles()
    s.flushSegmentIndexFiles()

proc logSize*(s: Store): BiggestInt =
  if s.persistent and s.logPath.len > 0 and fileExists(s.logPath):
    getFileSize(s.logPath)
  else:
    0

proc isPersistent*(s: Store): bool =
  s.persistent

proc close*(s: Store) =
  s.closeSegmentFiles()
  s.closeSegmentIndexFiles()
  s.closeSegmentReadStreams()
  if s.persistent:
    if not s.writeFailed:
      try:
        if s.durability == durStrong:
          s.logFile.syncFile()
        else:
          s.logFile.flushFile()
      except CatchableError:
        s.markWriteFailed(getCurrentExceptionMsg())
        raise
    s.logFile.close()
    s.persistent = false
  releaseDataDirLock(s.dataDirLock)

proc writeSnapshotFile(s: Store, path: string) =
  var file = open(path, fmWrite)
  try:
    file.write(WalMagicLine & "\n")
    if s.galaxy.len > 0:
      file.writeWalRecord("G " & $s.galaxy.len & "\n" & s.galaxy & "\n")
    if s.galaxyDescription.len > 0:
      file.writeWalRecord("GD " & $s.galaxyDescription.len & "\n" &
                          s.galaxyDescription & "\n")
    if s.placementEpoch > 0:
      file.writeWalLine("PM " & $s.placementEpoch & " " &
                        $s.placementNodes & " " & $s.placementVirtualArcs)
    if s.maintenanceDrained:
      file.writeWalLine("MD 1")
    file.writeWalLine("Q " & $s.nextTxId)
    file.writeWalLine("UQ " & $s.nextUniverseSyncId)
    file.writeWalLine("M " & $s.maxTWrite)
    var seqKeys: seq[uint64] = @[]
    for ringKey in s.seqs.keys:
      seqKeys.add ringKey
    seqKeys.sort()
    for ringKey in seqKeys:
      file.writeWalLine("S " & $ringKey & " " & $s.seqs[ringKey])
    var ringNameKeys: seq[uint64] = @[]
    for ringKey in s.ringNames.keys:
      ringNameKeys.add ringKey
    ringNameKeys.sort()
    for ringKey in ringNameKeys:
      let name = s.ringNames[ringKey]
      file.writeWalRecord("N " & $ringKey & " " & $name.len & "\n" & name & "\n")
    var ringDescKeys: seq[uint64] = @[]
    for ringKey in s.ringDescriptions.keys:
      ringDescKeys.add ringKey
    ringDescKeys.sort()
    for ringKey in ringDescKeys:
      let desc = s.ringDescriptions[ringKey]
      if desc.len > 0:
        file.writeWalRecord("RD " & $ringKey & " " & $desc.len & "\n" & desc & "\n")
    var profileKeys: seq[uint64] = @[]
    for ringKey in s.ringPayloadProfiles.keys:
      profileKeys.add ringKey
    profileKeys.sort()
    for ringKey in profileKeys:
      let profile = s.ringPayloadProfiles[ringKey]
      let raw = $(%*{
        "defaultCodec": profile.defaultCodec.payloadCodecName,
        "charset": profile.charset,
        "formatVersion": profile.formatVersion
      })
      file.writeWalRecord("RP " & $ringKey & " " & $raw.len & "\n" & raw & "\n")
    var timeOrbitKeys: seq[uint64] = @[]
    for ringKey in s.ringTimeOrbitProfiles.keys:
      timeOrbitKeys.add ringKey
    timeOrbitKeys.sort()
    for ringKey in timeOrbitKeys:
      let raw = timeOrbitProfileJson(s.ringTimeOrbitProfiles[ringKey])
      file.writeWalRecord("TO " & $ringKey & " " & $raw.len & "\n" & raw & "\n")
    var stellarKeys: seq[string] = @[]
    for stellar in s.stellarMaps.keys:
      stellarKeys.add stellar
    stellarKeys.sort()
    for stellar in stellarKeys:
      let raw = s.stellarMaps[stellar]
      file.writeWalRecord("SM " & $raw.len & "\n" & raw & "\n")
    var metaKeys: seq[uint64] = @[]
    for ringKey in s.ringMeta.keys:
      metaKeys.add ringKey
    metaKeys.sort()
    for ringKey in metaKeys:
      let meta = s.ringMeta[ringKey]
      file.writeWalLine("R " & $ringKey & " " & $meta.period & " " & $meta.head)
    var itemKeys: seq[(uint64, uint32)] = @[]
    for k in s.items.keys:
      itemKeys.add k
    # Disk-backed stores keep live particles in WAL/segments rather than the
    # in-memory item table.  A snapshot must therefore include both sources.
    for k in s.itemOffsets.keys:
      if k notin s.items:
        itemKeys.add k
    itemKeys.sort(proc(a, b: (uint64, uint32)): int =
      result = cmp(a[0], b[0])
      if result == 0:
        result = cmp(a[1], b[1]))
    for k in itemKeys:
      let p = if k in s.items: s.items[k] else: s.getParticle(k[0], k[1])
      file.writeParticleRecord("", 0, p)
    var tombstoneKeys: seq[(uint64, uint32)] = @[]
    for k in s.tombstones.keys:
      tombstoneKeys.add k
    tombstoneKeys.sort(proc(a, b: (uint64, uint32)): int =
      result = cmp(a[0], b[0])
      if result == 0:
        result = cmp(a[1], b[1]))
    for k in tombstoneKeys:
      file.writeTombstoneRecord("", 0, s.tombstones[k])
    var forwarderKeys: seq[(uint64, uint32)] = @[]
    for k in s.forwarders.keys:
      forwarderKeys.add k
    forwarderKeys.sort(proc(a, b: (uint64, uint32)): int =
      result = cmp(a[0], b[0])
      if result == 0:
        result = cmp(a[1], b[1]))
    for old in forwarderKeys:
      let f = s.forwarders[old]
      file.writeWalLine("F " & $old[0] & " " & $old[1] & " " & $f.newParent & " " &
                        $f.newSeq & " " & $f.newTWrite & " " & $f.expiresAt)
    var clusterKeys: seq[uint64] = @[]
    for txid in s.clusterTx.keys:
      clusterKeys.add txid
    clusterKeys.sort()
    for txid in clusterKeys:
      let intent = s.clusterTx[txid]
      file.writeWalLine("CT " & $intent.id)
      for op in intent.ops:
        file.writeClusterTxOp(intent.id, op)
      if intent.committed:
        file.writeWalLine("CC " & $intent.id)
      if intent.applied:
        file.writeWalLine("CA " & $intent.id)
    var appliedClusterKeys: seq[uint64] = @[]
    for txid in s.appliedClusterTx.keys:
      appliedClusterKeys.add txid
    appliedClusterKeys.sort()
    for txid in appliedClusterKeys:
      let applied = s.appliedClusterTx[txid]
      if applied and txid notin s.clusterTx:
        file.writeWalLine("CA " & $txid)
    var warpKeys: seq[uint64] = @[]
    for jobId in s.warpJobs.keys:
      warpKeys.add jobId
    warpKeys.sort()
    for jobId in warpKeys:
      let blob = s.warpJobs[jobId]
      file.writeWalRecord("WJ " & $jobId & " " & $blob.len & "\n" & blob & "\n")
    var universeKeys: seq[uint64] = @[]
    for eventId in s.universeSyncEvents.keys:
      universeKeys.add eventId
    universeKeys.sort()
    for eventId in universeKeys:
      let blob = s.universeSyncEvents[eventId]
      file.writeWalRecord("UJ " & $eventId & " " & $blob.len & "\n" & blob & "\n")
    var appliedUniverseKeys: seq[string] = @[]
    for eventKey in s.appliedUniverseSyncEvents.keys:
      appliedUniverseKeys.add eventKey
    appliedUniverseKeys.sort()
    for eventKey in appliedUniverseKeys:
      let applied = s.appliedUniverseSyncEvents[eventKey]
      if applied:
        file.writeWalRecord("UA " & $eventKey.len & "\n" & eventKey & "\n")
    file.syncFile()
  finally:
    file.close()

proc snapshotStats(s: Store, path: string, source = ""): StoreBackupStats =
  StoreBackupStats(bytes: (if fileExists(path): getFileSize(path) else: 0),
                   items: (if s.diskBacked: s.itemOffsets.len else: s.items.len),
                   tombstones: s.tombstones.len,
                   forwarders: s.forwarders.len,
                   ringMeta: s.ringMeta.len,
                   ringNames: s.ringNames.len,
                   clusterTx: s.clusterTx.len,
                   appliedClusterTx: s.appliedClusterTx.len,
                   warpJobs: s.warpJobs.len,
                   universeSyncEvents: s.universeSyncEvents.len,
                   source: source,
                   destination: path)

proc snapshotStatsFromFile(path, source: string): StoreBackupStats =
  var s = Store(lastFlush: getMonoTime(), nextTxId: 1)
  s.replay(path, repair = false)
  result = s.snapshotStats(path, source)

proc checkpointChecksum(path: string): string =
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
  CheckpointChecksumAlgorithm & ":" &
    genericHashHex("KOUTENDB-CHECKPOINT-FINAL-V1\0" & state & "\0" &
                   $chunkIndex & "\0" & $total)

proc checkpointIdValid(id: string): bool =
  if id.len == 0 or id.len > 128 or id == "." or id == ".." or
      id.startsWith(".tmp-"):
    return false
  for c in id:
    if not (c in {'a'..'z'} or c in {'A'..'Z'} or c in {'0'..'9'} or
            c in {'-', '_', '.'}):
      return false
  true

proc newCheckpointId(): string =
  let millis = int64(floor(epochTime() * 1000.0))
  "cp-" & $millis & "-" &
    strutils.toHex(randomBytes(6)).toLowerAscii()

proc checkpointRelativePathValid(path: string): bool =
  if path.len == 0 or path.isAbsolute or '\\' in path:
    return false
  let parts = path.split('/')
  if parts.anyIt(it.len == 0 or it == "." or it == ".."):
    return false
  path == "kouten.log" or path == "segments/manifest" or
    (parts.len == 2 and parts[0] == "segments" and
     (parts[1].endsWith(".seg") or parts[1].endsWith(".idx")))

proc normalizedAbsolute(path: string): string =
  let absolute = absolutePath(path).normalizedPath()
  var existing = absolute
  var suffix: seq[string] = @[]
  while not fileExists(existing) and not dirExists(existing) and
      not symlinkExists(existing):
    let parent = existing.parentDir
    if parent == existing:
      break
    suffix.insert(existing.extractFilename, 0)
    existing = parent
  result =
    if fileExists(existing) or dirExists(existing) or symlinkExists(existing):
      expandFilename(existing)
    else:
      existing
  for component in suffix:
    result = result / component
  result.normalizePath()

proc pathContains(parent, child: string): bool =
  let normalizedParent = normalizedAbsolute(parent)
  let normalizedChild = normalizedAbsolute(child)
  normalizedChild == normalizedParent or
    normalizedChild.startsWith(normalizedParent & DirSep)

proc pathsOverlap(a, b: string): bool =
  pathContains(a, b) or pathContains(b, a)

proc syncPath(path: string) =
  var file = open(path, fmAppend)
  try:
    file.syncFile()
  finally:
    file.close()

proc copyFileDurable(src, dst: string) =
  createDir(dst.parentDir)
  copyFile(src, dst)
  syncPath(dst)

proc moveDirAtomic(src, dst: string) =
  when defined(windows):
    moveDir(src, dst)
  else:
    if cRename(src.cstring, dst.cstring) != 0:
      raiseOSError(osLastError())

when defined(linux):
  {.emit: """
#include <fcntl.h>
#include <sys/syscall.h>
#include <unistd.h>
#ifndef RENAME_EXCHANGE
#define RENAME_EXCHANGE (1 << 1)
#endif
static int kouten_rename_exchange(const char *left, const char *right) {
  return (int)syscall(SYS_renameat2, AT_FDCWD, left,
                      AT_FDCWD, right, RENAME_EXCHANGE);
}
""".}
  proc cRenameExchange(left, right: cstring): cint
    {.importc: "kouten_rename_exchange", nodecl.}

proc exchangeDirsAtomic(left, right: string) =
  ## Existing-directory restore requires one indivisible namespace change.
  ## A two-rename fallback can leave the target path absent after a crash, so
  ## unsupported platforms fail closed and can restore into a fresh path.
  when defined(linux):
    if cRenameExchange(left.cstring, right.cstring) != 0:
      raiseOSError(osLastError())
  else:
    raise newException(IOError,
      "atomic checkpoint overwrite is not supported on this platform; " &
      "restore into a new data directory")

proc sealCheckpointSegments(s: Store) =
  ## A freshly rebuilt checkpoint starts with legacy generation-zero files.
  ## Promote all complete files together and publish one manifest last, so the
  ## checkpoint never relies on the implicit legacy layout.
  if not s.diskBacked or s.segmentDir.len == 0 or
      not dirExists(s.segmentDir):
    return
  s.closeSegmentFiles()
  s.closeSegmentIndexFiles()
  s.closeSegmentReadStreams()
  var rings: seq[uint64] = @[]
  for ring in s.segmentRecordCounts.keys:
    rings.add ring
  rings.sort()
  for ring in rings:
    let oldSegment = s.segmentPath(ring, 0)
    let oldIndex = s.segmentIndexPath(ring, 0)
    if not fileExists(oldSegment) or not fileExists(oldIndex):
      raise newException(IOError,
        "checkpoint segment generation is incomplete for ring " & $ring)
    oldSegment.syncPath()
    oldIndex.syncPath()
    let newSegment = s.segmentPath(ring, 1)
    let newIndex = s.segmentIndexPath(ring, 1)
    replaceFileAtomic(oldSegment, newSegment)
    replaceFileAtomic(oldIndex, newIndex)
    s.segmentGenerations[ring] = 1
  if rings.len > 0:
    s.writeSegmentManifest()
  syncDir(s.segmentDir)

proc checkpointFileNode(file: StoreCheckpointFile): JsonNode =
  result = %*{
    "path": file.path,
    "kind": file.kind,
    "bytes": $file.bytes,
    "checksum": file.checksum
  }
  if file.ring != 0 or file.kind in ["segment", "segment-index"]:
    result["ring"] = %($file.ring)
    result["generation"] = %($file.generation)

proc checkpointFiles(checkpointDir: string): seq[StoreCheckpointFile] =
  let wal = checkpointDir / "kouten.log"
  if not fileExists(wal):
    raise newException(IOError, "checkpoint WAL is missing")
  result.add StoreCheckpointFile(
    path: "kouten.log", kind: "wal", bytes: getFileSize(wal),
    checksum: checkpointChecksum(wal))
  let segmentDir = checkpointDir / "segments"
  let manifest = segmentDir / "manifest"
  if not fileExists(manifest):
    if dirExists(segmentDir):
      for kind, path in walkDir(segmentDir):
        if kind in {pcFile, pcLinkToFile}:
          raise newException(IOError,
            "checkpoint segment files exist without a manifest: " & path)
    return
  result.add StoreCheckpointFile(
    path: "segments/manifest", kind: "segment-manifest",
    bytes: getFileSize(manifest), checksum: checkpointChecksum(manifest))
  let rows = readFile(manifest).splitLines()
  if rows.len == 0 or rows[0] != "!KOUTENDB-SEGMENTS 1":
    raise newException(IOError, "invalid checkpoint segment manifest")
  var seen = initTable[uint64, bool]()
  for i in 1 ..< rows.len:
    let line = rows[i].strip()
    if line.len == 0:
      continue
    let parts = line.splitWhitespace()
    if parts.len != 2:
      raise newException(IOError, "invalid checkpoint segment manifest row")
    let ring = parseBiggestUInt(parts[0]).uint64
    let generation = parseBiggestUInt(parts[1]).uint64
    if generation == 0 or seen.getOrDefault(ring, false):
      raise newException(IOError, "invalid checkpoint segment generation")
    seen[ring] = true
    let segmentName = segmentFileName(ring, generation)
    let indexName = segmentIndexFileName(ring, generation)
    let segment = segmentDir / segmentName
    let index = segmentDir / indexName
    if not fileExists(segment) or not fileExists(index):
      raise newException(IOError,
        "checkpoint segment generation is incomplete for ring " & $ring)
    result.add StoreCheckpointFile(
      path: "segments/" & segmentName, kind: "segment",
      bytes: getFileSize(segment), checksum: checkpointChecksum(segment),
      ring: ring, generation: generation)
    result.add StoreCheckpointFile(
      path: "segments/" & indexName, kind: "segment-index",
      bytes: getFileSize(index), checksum: checkpointChecksum(index),
      ring: ring, generation: generation)

proc checkpointManifest(status: StoreCheckpointStatus): string =
  var files = newJArray()
  for file in status.files:
    files.add checkpointFileNode(file)
  $(%*{
    "format": CheckpointFormat,
    "id": status.id,
    "complete": true,
    "createdAt": status.createdAt,
    "sourceWalHighWater": $status.sourceWalHighWater,
    "snapshotWalBytes": $status.snapshotWalBytes,
    "stats": {
      "items": status.items,
      "tombstones": status.tombstones,
      "rings": status.rings
    },
    "files": files
  })

proc parseCheckpointManifest(checkpointDir: string): StoreCheckpointStatus =
  result.path = checkpointDir
  let manifestPath = checkpointDir / CheckpointManifestName
  let completePath = checkpointDir / CheckpointCompleteName
  if symlinkExists(checkpointDir) or symlinkExists(manifestPath) or
      symlinkExists(completePath):
    raise newException(IOError, "checkpoint symlinks are not allowed")
  if not fileExists(manifestPath):
    raise newException(IOError, "checkpoint manifest is missing")
  if not fileExists(completePath):
    raise newException(IOError, "checkpoint completion marker is missing")
  if readFile(completePath).strip() != checkpointChecksum(manifestPath):
    raise newException(IOError, "checkpoint manifest checksum mismatch")
  let node = parseJson(readFile(manifestPath))
  if node.isNil or node.kind != JObject or not node.hasKey("format") or
      node["format"].kind != JString or
      node["format"].getStr() != CheckpointFormat:
    raise newException(IOError, "unsupported checkpoint manifest format")
  result.format = node["format"].getStr()
  if not node.hasKey("id") or node["id"].kind != JString:
    raise newException(IOError, "invalid checkpoint identity")
  result.id = node["id"].getStr()
  if not checkpointIdValid(result.id):
    raise newException(IOError, "invalid checkpoint identity")
  if not node.hasKey("complete") or node["complete"].kind != JBool:
    raise newException(IOError, "checkpoint completion state is missing")
  result.complete = node["complete"].getBool()
  if not result.complete:
    raise newException(IOError, "checkpoint is not complete")
  if not node.hasKey("createdAt") or
      node["createdAt"].kind notin {JFloat, JInt}:
    raise newException(IOError, "invalid checkpoint creation time")
  result.createdAt =
    if node["createdAt"].kind == JFloat: node["createdAt"].getFloat()
    else: node["createdAt"].getInt().float
  if result.createdAt < 0 or
      result.createdAt.classify in {fcNan, fcInf, fcNegInf}:
    raise newException(IOError, "invalid checkpoint creation time")
  if not node.hasKey("sourceWalHighWater") or
      node["sourceWalHighWater"].kind != JString or
      not node.hasKey("snapshotWalBytes") or
      node["snapshotWalBytes"].kind != JString:
    raise newException(IOError, "invalid checkpoint WAL bounds")
  try:
    result.sourceWalHighWater =
      parseBiggestInt(node["sourceWalHighWater"].getStr()).int64
    result.snapshotWalBytes =
      parseBiggestInt(node["snapshotWalBytes"].getStr()).int64
  except CatchableError:
    raise newException(IOError, "invalid checkpoint WAL bounds")
  if result.sourceWalHighWater < 0 or result.snapshotWalBytes < 0:
    raise newException(IOError, "invalid checkpoint WAL bounds")
  if not node.hasKey("stats") or node["stats"].kind != JObject:
    raise newException(IOError, "checkpoint stats are missing")
  let stats = node["stats"]
  for field in ["items", "tombstones", "rings"]:
    if not stats.hasKey(field) or stats[field].kind != JInt:
      raise newException(IOError, "invalid checkpoint stats")
  result.items = stats["items"].getInt()
  result.tombstones = stats["tombstones"].getInt()
  result.rings = stats["rings"].getInt()
  if result.items < 0 or result.tombstones < 0 or result.rings < 0:
    raise newException(IOError, "invalid checkpoint stats")
  if not node.hasKey("files") or node["files"].kind != JArray or
      node["files"].len == 0:
    raise newException(IOError, "checkpoint file inventory is missing")
  let files = node["files"]
  var seen = initTable[string, bool]()
  for entry in files:
    if entry.kind != JObject:
      raise newException(IOError, "invalid checkpoint file entry")
    for field in ["path", "kind", "bytes", "checksum"]:
      if not entry.hasKey(field) or entry[field].kind != JString:
        raise newException(IOError, "invalid checkpoint file entry")
    let relative = entry["path"].getStr()
    if not checkpointRelativePathValid(relative) or
        seen.getOrDefault(relative, false):
      raise newException(IOError, "invalid checkpoint file path: " & relative)
    seen[relative] = true
    var file = StoreCheckpointFile(
      path: relative,
      kind: entry["kind"].getStr(),
      checksum: entry["checksum"].getStr())
    try:
      file.bytes = parseBiggestInt(entry["bytes"].getStr()).int64
      if entry.hasKey("ring"):
        if entry["ring"].kind != JString or
            not entry.hasKey("generation") or
            entry["generation"].kind != JString:
          raise newException(ValueError, "invalid ring generation")
        file.ring = parseBiggestUInt(entry["ring"].getStr()).uint64
        file.generation =
          parseBiggestUInt(entry["generation"].getStr()).uint64
      elif entry.hasKey("generation"):
        raise newException(ValueError, "generation without ring")
    except CatchableError:
      raise newException(IOError,
        "invalid checkpoint file metadata: " & relative)
    if file.bytes < 0 or
        not file.checksum.startsWith(CheckpointChecksumAlgorithm & ":"):
      raise newException(IOError,
        "invalid checkpoint file metadata: " & relative)
    case relative
    of "kouten.log":
      if file.kind != "wal":
        raise newException(IOError, "checkpoint WAL kind is invalid")
    of "segments/manifest":
      if file.kind != "segment-manifest":
        raise newException(IOError,
          "checkpoint segment manifest kind is invalid")
    else:
      if file.generation == 0:
        raise newException(IOError,
          "checkpoint segment generation must be positive")
      let expectedKind =
        if relative.endsWith(".seg"): "segment" else: "segment-index"
      let expectedName =
        if expectedKind == "segment":
          segmentFileName(file.ring, file.generation)
        else:
          segmentIndexFileName(file.ring, file.generation)
      if file.kind != expectedKind or
          relative != "segments/" & expectedName:
        raise newException(IOError,
          "checkpoint segment metadata does not match its path: " & relative)
    result.files.add file

proc validateCheckpointContents(checkpointDir: string): StoreCheckpointStatus =
  result = parseCheckpointManifest(checkpointDir)
  var inventory = initTable[string, StoreCheckpointFile]()
  for file in result.files:
    let path = checkpointDir / file.path
    if symlinkExists(path):
      raise newException(IOError,
        "checkpoint file symlinks are not allowed: " & file.path)
    if not fileExists(path):
      raise newException(IOError, "checkpoint file is missing: " & file.path)
    if getFileSize(path) != file.bytes:
      raise newException(IOError, "checkpoint file size mismatch: " & file.path)
    if checkpointChecksum(path) != file.checksum:
      raise newException(IOError, "checkpoint checksum mismatch: " & file.path)
    inventory[file.path] = file
  if "kouten.log" notin inventory or inventory["kouten.log"].kind != "wal":
    raise newException(IOError, "checkpoint WAL inventory is missing")
  let wal = checkpointDir / "kouten.log"
  if getFileSize(wal) != result.snapshotWalBytes:
    raise newException(IOError, "checkpoint snapshot WAL size mismatch")
  let stats = snapshotStatsFromFile(wal, checkpointDir)
  if stats.items != result.items or stats.tombstones != result.tombstones or
      stats.ringMeta != result.rings:
    raise newException(IOError, "checkpoint logical statistics mismatch")

  let segmentDir = checkpointDir / "segments"
  if symlinkExists(segmentDir):
    raise newException(IOError,
      "checkpoint segment directory symlinks are not allowed")
  if "segments/manifest" in inventory:
    var verifier = Store(lastFlush: getMonoTime(), nextTxId: 1,
                         diskBacked: true, persistent: true,
                         logPath: wal, segmentDir: segmentDir)
    verifier.replay(wal, repair = false)
    if not verifier.loadSegmentManifest() or
        not verifier.loadRingSegmentIndexes():
      raise newException(IOError, "checkpoint segment index validation failed")
    if verifier.itemSegmentOffsets.len != verifier.itemOffsets.len:
      raise newException(IOError, "checkpoint segment coverage is incomplete")
    for k, offset in verifier.itemSegmentOffsets:
      let stream = newFileStream(verifier.segmentPath(k[0]), fmRead)
      if stream.isNil:
        raise newException(IOError, "cannot open checkpoint segment")
      try:
        let particle = stream.readParticleAtStream(offset)
        if particle.parent != k[0] or particle.seq != k[1] or
            particle.version != verifier.itemVersions.getOrDefault(k):
          raise newException(IOError,
            "checkpoint segment does not match WAL revision")
      finally:
        stream.close()
    verifier.closeSegmentReadStreams()
    for kind, path in walkDir(segmentDir):
      if kind in {pcFile, pcLinkToFile}:
        let relative = "segments/" & path.extractFilename
        if relative notin inventory:
          raise newException(IOError,
            "checkpoint contains an unreferenced segment file: " & relative)
  elif dirExists(segmentDir):
    for kind, path in walkDir(segmentDir):
      if kind in {pcFile, pcLinkToFile}:
        raise newException(IOError,
          "checkpoint contains segments without an inventory: " & path)
  result.verified = true
  result.reasonCode = "verified"
  result.reason = "verified"

proc checkpointReasonCode*(reason: string): string =
  ## Bounded machine-readable classification for checkpoint diagnostics.
  ## Human-readable error details remain in `reason`.
  let value = reason.toLowerAscii()
  if value == "verified": "verified"
  elif value.startsWith("restored"): "restored"
  elif "symlink" in value: "symlink-rejected"
  elif "manifest is missing" in value: "manifest-missing"
  elif "completion marker is missing" in value: "completion-marker-missing"
  elif "manifest checksum mismatch" in value: "manifest-checksum-mismatch"
  elif "unsupported checkpoint manifest format" in value: "unsupported-format"
  elif "checkpoint identity" in value: "invalid-identity"
  elif "creation time" in value: "invalid-created-at"
  elif "wal bounds" in value: "invalid-wal-bounds"
  elif "checkpoint stats" in value or "logical statistics" in value:
    "logical-stats-invalid"
  elif "file inventory" in value or "wal inventory" in value:
    "inventory-missing"
  elif "file entry" in value or "file metadata" in value or
      "file path" in value or "kind is invalid" in value or
      "generation" in value:
    "inventory-invalid"
  elif "file is missing" in value: "file-missing"
  elif "size mismatch" in value: "file-size-mismatch"
  elif "checksum mismatch" in value: "file-checksum-mismatch"
  elif "segment index validation failed" in value:
    "segment-index-invalid"
  elif "segment coverage is incomplete" in value:
    "segment-coverage-incomplete"
  elif "segment does not match wal revision" in value:
    "segment-revision-mismatch"
  elif "unreferenced segment file" in value or
      "segments without an inventory" in value:
    "unreferenced-file"
  elif "not complete" in value or "completion state" in value:
    "incomplete"
  else: "verification-failed"

proc checkpointStatus*(checkpointDir: string): StoreCheckpointStatus =
  ## Inspect one immutable checkpoint without mutating or repairing it.
  result.path = checkpointDir
  try:
    result = validateCheckpointContents(checkpointDir)
  except CatchableError:
    result.verified = false
    result.complete = false
    result.reason = getCurrentExceptionMsg()
    result.reasonCode = checkpointReasonCode(result.reason)

proc verifyCheckpoint*(checkpointDir: string): StoreCheckpointStatus =
  result = checkpointStatus(checkpointDir)
  if not result.verified:
    raise newException(IOError, result.reason)

proc createCheckpoint*(s: Store; root = ""; id = ""):
    StoreCheckpointStatus =
  ## Build a self-contained compact WAL and its matching ring-local sidecars,
  ## then publish the checksum manifest and directory last.
  if not s.persistent or s.logPath.len == 0:
    raise newException(ValueError, "checkpoint requires a persistent store")
  let checkpointId = if id.len > 0: id else: newCheckpointId()
  if not checkpointIdValid(checkpointId):
    raise newException(ValueError, "invalid checkpoint identity")
  let sourceDir = s.logPath.parentDir
  let checkpointRoot = if root.len > 0: root else: sourceDir & ".checkpoints"
  if pathsOverlap(sourceDir, checkpointRoot):
    raise newException(ValueError,
      "checkpoint root must be outside the source data directory")
  createDir(checkpointRoot)
  let finalDir = checkpointRoot / checkpointId
  let stageDir = checkpointRoot / (".tmp-" & checkpointId)
  if dirExists(finalDir) or fileExists(finalDir) or symlinkExists(finalDir):
    raise newException(IOError, "checkpoint already exists: " & checkpointId)
  if dirExists(stageDir) or fileExists(stageDir) or symlinkExists(stageDir):
    raise newException(IOError,
      "checkpoint staging directory already exists: " & stageDir)
  s.sync()
  let sourceHighWater = s.logSize().int64
  createDir(stageDir)
  let stageGuardPath = dataDirGuardPath(expandFilename(stageDir))
  try:
    s.writeSnapshotFile(stageDir / "kouten.log")
    var staged = openStore(stageDir, durability = durStrong, diskBacked = true)
    try:
      staged.sealCheckpointSegments()
    finally:
      staged.close()
    let lockPath = stageDir / ".kouten.lock"
    if fileExists(lockPath):
      removeFile(lockPath)
    if fileExists(stageGuardPath):
      removeFile(stageGuardPath)
    let stats = snapshotStatsFromFile(stageDir / "kouten.log", stageDir)
    var status = StoreCheckpointStatus(
      format: CheckpointFormat,
      id: checkpointId,
      path: stageDir,
      createdAt: epochTime(),
      sourceWalHighWater: sourceHighWater,
      snapshotWalBytes: getFileSize(stageDir / "kouten.log"),
      complete: true,
      items: stats.items,
      tombstones: stats.tombstones,
      rings: stats.ringMeta,
      files: checkpointFiles(stageDir))
    writeFileDurable(stageDir / CheckpointManifestName,
                     checkpointManifest(status))
    writeFileDurable(stageDir / CheckpointCompleteName,
      checkpointChecksum(stageDir / CheckpointManifestName) & "\n")
    discard validateCheckpointContents(stageDir)
    syncDir(stageDir)
    when defined(koutenTestCrashPoints):
      processCrashPoint("checkpoint-before-publish")
    moveDirAtomic(stageDir, finalDir)
    when defined(koutenTestCrashPoints):
      processCrashPoint("checkpoint-after-publish")
    syncDir(checkpointRoot)
    result = verifyCheckpoint(finalDir)
  except CatchableError:
    if dirExists(stageDir):
      removeDir(stageDir)
    if fileExists(stageGuardPath):
      try:
        removeFile(stageGuardPath)
      except CatchableError:
        discard
    raise

proc listCheckpoints*(root: string): seq[StoreCheckpointStatus] =
  if root.len == 0 or not dirExists(root):
    return
  var paths: seq[string] = @[]
  for kind, path in walkDir(root):
    if kind in {pcDir, pcLinkToDir} and
        not path.extractFilename.startsWith(".tmp-"):
      paths.add path
  paths.sort()
  for path in paths:
    result.add checkpointStatus(path)
  result.sort(proc(a, b: StoreCheckpointStatus): int =
    result = cmp(b.createdAt, a.createdAt)
    if result == 0:
      result = cmp(b.id, a.id))

proc cleanupCheckpoints*(root: string; keep = 2):
    StoreCheckpointCleanupStats =
  ## Corrupt checkpoints are retained for diagnosis. At least one verified
  ## checkpoint is always retained, regardless of caller input.
  if root.len == 0:
    raise newException(ValueError, "checkpoint root is required")
  if keep < 1:
    raise newException(ValueError,
      "checkpoint cleanup must retain at least one verified generation")
  result.root = root
  let statuses = listCheckpoints(root)
  var verified: seq[StoreCheckpointStatus] = @[]
  for status in statuses:
    if status.verified:
      verified.add status
    else:
      result.invalid.add status.path.extractFilename
  result.kept = min(keep, verified.len)
  for i in keep ..< verified.len:
    removeDir(verified[i].path)
    result.removed.add verified[i].id
  if result.removed.len > 0:
    syncDir(root)

proc restoreCheckpoint*(checkpointDir, targetDir: string;
                        overwrite = false): StoreCheckpointStatus =
  ## Verify first, stage every referenced file, verify the staged copy, then
  ## atomically exchange the whole data directory. No partial target is served.
  if checkpointDir.len == 0 or targetDir.len == 0:
    raise newException(ValueError,
      "checkpoint and target directories are required")
  let sourceStatus = verifyCheckpoint(checkpointDir)
  if pathsOverlap(checkpointDir, targetDir):
    raise newException(ValueError,
      "checkpoint and target data directories must not overlap")
  if symlinkExists(targetDir):
    raise newException(IOError,
      "checkpoint restore target must not be a symlink")
  createDir(targetDir.parentDir)
  let nonce = strutils.toHex(randomBytes(5)).toLowerAscii()
  let stageDir = targetDir & ".checkpoint-stage-" & nonce
  let previousDir = targetDir & ".checkpoint-previous-" & nonce
  var targetLock: DataDirLock
  var removePlaceholder = false
  var targetExisted = false
  if dirExists(targetDir):
    if not overwrite:
      raise newException(IOError, "target data directory already exists: " & targetDir)
    targetExisted = true
    targetLock = acquireDataDirLock(targetDir)
  elif fileExists(targetDir):
    raise newException(IOError, "target path is not a directory: " & targetDir)
  else:
    # Materialize the identity long enough to take both the stable sibling
    # guard and the legacy in-directory lock. The empty placeholder is then
    # removed while the stable guard remains held across publication.
    createDir(targetDir)
    targetLock = acquireDataDirLock(targetDir)
    removePlaceholder = true
  var previousPublished = false
  var targetPublished = false
  try:
    if removePlaceholder:
      removeDir(targetDir)
    if dirExists(stageDir) or fileExists(stageDir) or
        symlinkExists(stageDir) or dirExists(previousDir) or
        fileExists(previousDir) or symlinkExists(previousDir):
      raise newException(IOError, "checkpoint restore staging collision")
    createDir(stageDir)
    for file in sourceStatus.files:
      copyFileDurable(checkpointDir / file.path, stageDir / file.path)
    copyFileDurable(checkpointDir / CheckpointManifestName,
                    stageDir / CheckpointManifestName)
    copyFileDurable(checkpointDir / CheckpointCompleteName,
                    stageDir / CheckpointCompleteName)
    discard validateCheckpointContents(stageDir)
    if targetExisted:
      exchangeDirsAtomic(stageDir, targetDir)
      targetPublished = true
      when defined(koutenTestFailpoints):
        if checkpointRestoreFailAfterExchange:
          raise newException(IOError,
            "test checkpoint restore failure after atomic exchange")
      moveDirAtomic(stageDir, previousDir)
      previousPublished = true
    else:
      moveDirAtomic(stageDir, targetDir)
      targetPublished = true
    syncDir(targetDir.parentDir)
    when defined(koutenTestFailpoints):
      if checkpointRestoreFailAfterPublish:
        raise newException(IOError,
          "test checkpoint restore failure after publication")
    let restoredStatus = validateCheckpointContents(targetDir)
    if restoredStatus.items != sourceStatus.items or
        restoredStatus.tombstones != sourceStatus.tombstones or
        restoredStatus.rings != sourceStatus.rings:
      raise newException(IOError,
        "restored checkpoint logical statistics mismatch")
    removeFile(targetDir / CheckpointManifestName)
    removeFile(targetDir / CheckpointCompleteName)
    syncDir(targetDir)
    result = sourceStatus
    result.path = targetDir
    result.reasonCode = "restored"
    result.reason = "restored"
    if dirExists(previousDir):
      try:
        removeDir(previousDir)
        syncDir(targetDir.parentDir)
        previousPublished = false
      except CatchableError:
        result.reasonCode = "restored-cleanup-pending"
        result.reason = "restored; previous target cleanup pending at " &
                        previousDir
  except CatchableError:
    if targetPublished and targetExisted:
      let previousPath =
        if previousPublished: previousDir
        else: stageDir
      if dirExists(targetDir) and dirExists(previousPath):
        exchangeDirsAtomic(targetDir, previousPath)
        syncDir(targetDir.parentDir)
    elif targetPublished and dirExists(targetDir):
      removeDir(targetDir)
      syncDir(targetDir.parentDir)
    if dirExists(stageDir):
      removeDir(stageDir)
    if dirExists(previousDir):
      removeDir(previousDir)
    raise
  finally:
    releaseDataDirLock(targetLock)

proc sameParticleRevision(current, candidate: Particle): bool =
  current.parent == candidate.parent and
    current.seq == candidate.seq and
    current.version == candidate.version and
    abs(current.tWrite - candidate.tWrite) < 1e-9

proc isLiveParticle(s: Store, p: Particle, walOffset: int64): bool =
  let k = key(p.parent, p.seq)
  if s.diskBacked:
    if k in s.itemOffsets:
      # The offset is the exact current WAL record identity. Checking its HLC
      # version also catches divergence without reopening every live payload.
      return s.itemOffsets[k] == walOffset and
        k in s.itemVersions and s.itemVersions[k] == p.version
    if k notin s.itemSegmentOffsets:
      return false
    return s.getParticle(p.parent, p.seq).sameParticleRevision(p)
  if k notin s.items:
    return false
  s.items[k].sameParticleRevision(p)

proc localityReport*(s: Store): StoreLocalityReport =
  ## Inspect the physical WAL particle order and report ring locality.
  result.persistent = s.persistent
  result.walBytes = s.logSize()
  if not s.persistent or s.logPath.len == 0 or not fileExists(s.logPath):
    result.liveParticleRecords = s.items.len
    result.ringCount = s.itemsByRing.len
    result.ringRuns = result.ringCount
    result.avgRunRecords = if result.ringRuns == 0: 0.0
                           else: float(result.liveParticleRecords) / float(result.ringRuns)
    result.maxRunRecords = result.liveParticleRecords
    result.localityScore = 1.0
    return

  if s.persistent:
    s.flushMaybe(force = true)

  let fs = newFileStream(s.logPath, fmRead)
  if fs.isNil:
    return
  defer: fs.close()

  var line = ""
  var lastRing = 0'u64
  var haveLast = false
  var currentRun = 0
  var runCounts = initTable[uint64, int]()
  var rings = initTable[uint64, bool]()

  while true:
    let recordStart = fs.getPosition()
    if not fs.readLine(line):
      break
    if line.len == 0:
      continue
    if line == WalMagicLine:
      continue
    var parts = line.split(' ')
    var recordStream: Stream = fs
    var bodyStream: StringStream = nil
    try:
      if parts[0] == WalRecordTag:
        let body = checkedWalBody(fs, parts)
        bodyStream = newStringStream(body)
        if not bodyStream.readLine(line):
          continue
        parts = line.split(' ')
        recordStream = bodyStream
      case parts[0]
      of "P":
        inc result.totalParticleRecords
        let p = recordStream.readParticleRecord(parts, 1)
        if s.isLiveParticle(p, recordStart):
          inc result.liveParticleRecords
          rings[p.parent] = true
          if not haveLast or p.parent != lastRing:
            if haveLast and currentRun > 0:
              result.maxRunRecords = max(result.maxRunRecords, currentRun)
            inc result.ringRuns
            runCounts[p.parent] = runCounts.getOrDefault(p.parent, 0) + 1
            lastRing = p.parent
            haveLast = true
            currentRun = 1
          else:
            inc currentRun
        else:
          inc result.deadParticleRecords
      of "XP":
        inc result.totalParticleRecords
        let p = recordStream.readParticleRecord(parts, 2)
        if s.isLiveParticle(p, recordStart):
          inc result.liveParticleRecords
          rings[p.parent] = true
          if not haveLast or p.parent != lastRing:
            if haveLast and currentRun > 0:
              result.maxRunRecords = max(result.maxRunRecords, currentRun)
            inc result.ringRuns
            runCounts[p.parent] = runCounts.getOrDefault(p.parent, 0) + 1
            lastRing = p.parent
            haveLast = true
            currentRun = 1
          else:
            inc currentRun
        else:
          inc result.deadParticleRecords
      else:
        discard
    except CatchableError:
      raise newException(IOError, "cannot inspect WAL locality near byte " &
        $recordStart & ": " & getCurrentExceptionMsg())
  if haveLast and currentRun > 0:
    result.maxRunRecords = max(result.maxRunRecords, currentRun)

  result.ringCount = rings.len
  for _, runs in runCounts:
    if runs > 1:
      inc result.fragmentedRings
  result.avgRunRecords = if result.ringRuns == 0: 0.0
                         else: float(result.liveParticleRecords) / float(result.ringRuns)
  result.localityScore =
    if result.totalParticleRecords == 0: 1.0
    elif result.liveParticleRecords == 0 or result.ringRuns == 0: 0.0
    else: float(result.ringCount) / float(result.ringRuns)

proc compact*(s: Store): StoreCompactStats =
  ## 生存レコードだけで WAL を再構築する。
  ## append-only の読みやすさを保ちながら、削除済み/上書き済みログの肥大化を抑える。
  result.items = s.items.len
  result.tombstones = s.tombstones.len
  result.forwarders = s.forwarders.len
  result.ringMeta = s.ringMeta.len
  result.ringNames = s.ringNames.len
  result.clusterTx = s.clusterTx.len
  result.appliedClusterTx = s.appliedClusterTx.len
  result.warpJobs = s.warpJobs.len
  result.universeSyncEvents = s.universeSyncEvents.len
  if not s.persistent or s.logPath.len == 0:
    return

  let path = s.logPath
  let tmp = path & ".compact"
  let bak = path & ".bak"
  s.flushMaybe(force = true)
  result.beforeBytes = getFileSize(path)
  s.logFile.close()
  s.writeSnapshotFile(tmp)
  if fileExists(bak):
    removeFile(bak)
  if fileExists(path):
    replaceFileAtomic(path, bak)
  replaceFileAtomic(tmp, path)
  result.afterBytes = getFileSize(path)
  syncDir(parentDir(path))
  s.logFile = open(path, fmAppend)
  s.persistent = true
  s.dirty = 0
  s.lastFlush = getMonoTime()
  # The compacted WAL has new byte offsets, so rebuild the in-memory offset
  # table and its derived ring-local read cache before serving another read.
  s.clearReplayState()
  s.replay(path)
  if s.diskBacked:
    discard s.rebuildRingSegments()
  if fileExists(bak):
    removeFile(bak)
    syncDir(parentDir(path))

proc backup*(s: Store, dstDir: string): StoreBackupStats =
  ## 現在の Store 状態を compact 済み WAL として dstDir/kouten.log に退避する。
  ## 元の WAL は書き換えないため、通常運用中の backup に使える。
  if dstDir.len == 0:
    raise newException(ValueError, "backup destination is empty")
  createDir(dstDir)
  let dst = dstDir / "kouten.log"
  let tmp = dst & ".tmp"
  if s.persistent:
    s.flushMaybe(force = true)
  s.writeSnapshotFile(tmp)
  when defined(koutenTestCrashPoints):
    processCrashPoint("backup-before-publish")
  replaceFileAtomic(tmp, dst)
  when defined(koutenTestCrashPoints):
    processCrashPoint("backup-after-publish")
  syncDir(dstDir)
  result = s.snapshotStats(dst, s.logPath)

proc backupEncrypted*(s: Store, dstDir, passphrase: string): StoreBackupStats =
  ## 現在の Store 状態を secretbox で暗号化した snapshot として dstDir/kouten.backup に退避する。
  if dstDir.len == 0:
    raise newException(ValueError, "backup destination is empty")
  createDir(dstDir)
  let dst = dstDir / "kouten.backup"
  let tmpPlain = dstDir / "kouten.log.tmp"
  let tmpEnc = dst & ".tmp"
  if s.persistent:
    s.flushMaybe(force = true)
  s.writeSnapshotFile(tmpPlain)
  try:
    let plaintext = readFile(tmpPlain)
    writeFileDurable(tmpEnc, EncryptedBackupMagic &
      encryptSecretBox(plaintext, backupKey(passphrase)))
    replaceFileAtomic(tmpEnc, dst)
    syncDir(dstDir)
    result = s.snapshotStats(dst, s.logPath)
  finally:
    if fileExists(tmpPlain):
      removeFile(tmpPlain)
    if fileExists(tmpEnc):
      removeFile(tmpEnc)

proc verifyBackup*(backupDir: string): StoreBackupStats =
  ## backupDir/kouten.log を復元前に strict 検証する。通常 openStore の
  ## tail repair とは違い、backup 検証では壊れた snapshot を拒否する。
  if backupDir.len == 0:
    raise newException(ValueError, "backup directory is required")
  let src = backupDir / "kouten.log"
  if not fileExists(src):
    raise newException(IOError, "backup kouten.log not found: " & src)
  result = snapshotStatsFromFile(src, src)

proc verifyEncryptedBackup*(backupDir, passphrase: string): StoreBackupStats =
  ## backupDir/kouten.backup を復号し、復元前に strict 検証する。
  if backupDir.len == 0:
    raise newException(ValueError, "backup directory is required")
  let src = backupDir / "kouten.backup"
  if not fileExists(src):
    raise newException(IOError, "encrypted backup not found: " & src)
  let blob = readFile(src)
  if not blob.startsWith(EncryptedBackupMagic):
    raise newException(IOError, "invalid encrypted backup header")
  let plaintext = decryptSecretBox(blob[EncryptedBackupMagic.len .. ^1],
                                   backupKey(passphrase))
  let validateDir = createTempDir("kouten-verify", "")
  let validateTmp = validateDir / "kouten.log"
  writeFile(validateTmp, plaintext)
  try:
    result = snapshotStatsFromFile(validateTmp, src)
    result.bytes = getFileSize(src)
    result.destination = src
  finally:
    if dirExists(validateDir):
      removeDir(validateDir)

proc restoreBackup*(backupDir, targetDir: string, overwrite = false,
                    durability: StoreDurability = durBuffered): StoreBackupStats =
  ## backupDir/kouten.log を targetDir/kouten.log として復元する。
  ## 既存 target は overwrite=true のときだけ置き換える。
  if backupDir.len == 0 or targetDir.len == 0:
    raise newException(ValueError, "backup and target directories are required")
  let src = backupDir / "kouten.log"
  if not fileExists(src):
    raise newException(IOError, "backup kouten.log not found: " & src)
  discard verifyBackup(backupDir)
  createDir(targetDir)
  let dst = targetDir / "kouten.log"
  if fileExists(dst) and not overwrite:
    raise newException(IOError, "target kouten.log already exists: " & dst)
  let tmp = dst & ".restore"
  try:
    copyFile(src, tmp)
    var file = open(tmp, fmAppend)
    try:
      file.syncFile()
    finally:
      file.close()
    replaceFileAtomic(tmp, dst)
    syncDir(targetDir)
    var restored = openStore(targetDir, durability = durability)
    try:
      result = restored.snapshotStats(dst, src)
    finally:
      restored.close()
  finally:
    if fileExists(tmp):
      removeFile(tmp)

proc restoreEncryptedBackup*(backupDir, targetDir, passphrase: string,
                             overwrite = false,
                             durability: StoreDurability = durBuffered): StoreBackupStats =
  ## backupDir/kouten.backup を復号し、targetDir/kouten.log として復元する。
  if backupDir.len == 0 or targetDir.len == 0:
    raise newException(ValueError, "backup and target directories are required")
  let src = backupDir / "kouten.backup"
  if not fileExists(src):
    raise newException(IOError, "encrypted backup not found: " & src)
  let blob = readFile(src)
  if not blob.startsWith(EncryptedBackupMagic):
    raise newException(IOError, "invalid encrypted backup header")
  let plaintext = decryptSecretBox(blob[EncryptedBackupMagic.len .. ^1],
                                   backupKey(passphrase))
  discard verifyEncryptedBackup(backupDir, passphrase)
  createDir(targetDir)
  let dst = targetDir / "kouten.log"
  if fileExists(dst) and not overwrite:
    raise newException(IOError, "target kouten.log already exists: " & dst)
  let tmp = dst & ".restore"
  try:
    writeFileDurable(tmp, plaintext)
    replaceFileAtomic(tmp, dst)
    syncDir(targetDir)
    var restored = openStore(targetDir, durability = durability)
    try:
      result = restored.snapshotStats(dst, src)
    finally:
      restored.close()
  finally:
    if fileExists(tmp):
      removeFile(tmp)

proc putRingMeta*(s: Store, ringKey: uint64, period, head: float) =
  if ringKey in s.ringMeta and
      s.ringMeta[ringKey] == (period: period, head: head):
    return
  s.ensureWritable()
  s.applyOp(TxOp(kind: txRingMeta, ringKey: ringKey,
                 ringPeriod: period, ringHead: head))
  if s.persistent:
    s.logFile.writeWalLine("R " & $ringKey & " " & $period & " " & $head)
    s.flushMaybe()

proc putRingName*(s: Store, ringKey: uint64, name: string) =
  if name.len == 0:
    return
  s.ensureWritable()
  if s.ringNames.getOrDefault(ringKey, "") == name:
    return
  s.ringNames[ringKey] = name
  if s.persistent:
    s.logFile.writeWalRecord("N " & $ringKey & " " & $name.len & "\n" & name & "\n")
    s.flushMaybe()

proc putGalaxyDescription*(s: Store, description: string) =
  if s.galaxyDescription == description:
    return
  s.ensureWritable()
  s.galaxyDescription = description
  if s.persistent:
    s.logFile.writeWalRecord("GD " & $description.len & "\n" & description & "\n")
    s.flushMaybe(force = true)

proc putRingDescription*(s: Store, ringKey: uint64, description: string) =
  if s.ringDescriptions.getOrDefault(ringKey, "") == description:
    return
  s.ensureWritable()
  if description.len == 0:
    s.ringDescriptions.del ringKey
  else:
    s.ringDescriptions[ringKey] = description
  if s.persistent:
    s.logFile.writeWalRecord("RD " & $ringKey & " " & $description.len & "\n" &
                             description & "\n")
    s.flushMaybe(force = true)

proc putRingPayloadProfile*(s: Store, ringKey: uint64,
                            profile: RingPayloadProfile) =
  if ringKey in s.ringPayloadProfiles and
      s.ringPayloadProfiles[ringKey] == profile:
    return
  s.ensureWritable()
  s.ringPayloadProfiles[ringKey] = profile
  if s.persistent:
    let raw = $(%*{
      "defaultCodec": profile.defaultCodec.payloadCodecName,
      "charset": profile.charset,
      "formatVersion": profile.formatVersion
    })
    s.logFile.writeWalRecord("RP " & $ringKey & " " & $raw.len & "\n" & raw & "\n")
    s.flushMaybe(force = true)

proc putTimeOrbitProfile*(s: Store, ringKey: uint64,
                          profile: TimeOrbitProfile) =
  if ringKey in s.ringTimeOrbitProfiles and
      s.ringTimeOrbitProfiles[ringKey] == profile:
    return
  s.ensureWritable()
  validateTimeOrbitProfile(profile)
  s.ringTimeOrbitProfiles[ringKey] = profile
  if s.persistent:
    let raw = timeOrbitProfileJson(profile)
    s.logFile.writeWalRecord("TO " & $ringKey & " " & $raw.len & "\n" & raw & "\n")
    s.flushMaybe(force = true)

proc putStellarMap*(s: Store, stellar, blob: string) =
  if stellar.len == 0:
    raise newException(ValueError, "stellar coordinate is empty")
  s.ensureWritable()
  if blob.len > 0 and s.stellarMaps.getOrDefault(stellar, "") == blob:
    return
  if blob.len == 0:
    s.stellarMaps.del stellar
    if s.persistent:
      let raw = $(%*{"stellar": stellar, "deleted": true})
      s.logFile.writeWalRecord("SM " & $raw.len & "\n" & raw & "\n")
      s.flushMaybe(force = true)
    return
  discard validateStellarMapBlob(stellar, blob)
  s.stellarMaps[stellar] = blob
  if s.persistent:
    s.logFile.writeWalRecord("SM " & $blob.len & "\n" & blob & "\n")
    s.flushMaybe(force = true)

proc putWarpJob*(s: Store, jobId: uint64, blob: string) =
  ## KoutenDB layer が解釈する warp job snapshot を保存する。
  ## Store は WAL/compact/backup/restore だけを担当し、scheduler policy は持たない。
  if blob.len == 0:
    raise newException(ValueError, "warp job blob is empty")
  s.ensureWritable()
  s.warpJobs[jobId] = blob
  if s.persistent:
    s.logFile.writeWalRecord("WJ " & $jobId & " " & $blob.len & "\n" & blob & "\n")
    s.flushMaybe(force = true)

proc deleteWarpJob*(s: Store, jobId: uint64) =
  s.ensureWritable()
  s.warpJobs.del jobId
  if s.persistent:
    s.logFile.writeWalLine("WD " & $jobId)
    s.flushMaybe(force = true)

proc putUniverseSyncEvent*(s: Store, eventId: uint64, blob: string) =
  ## KoutenDB layer が解釈する universe sync event snapshot を保存する。
  ## Store は durable queue / compact / backup / restore だけを担当する。
  if blob.len == 0:
    raise newException(ValueError, "universe sync event blob is empty")
  s.ensureWritable()
  s.universeSyncEvents[eventId] = blob
  s.nextUniverseSyncId = max(s.nextUniverseSyncId, eventId)
  if s.persistent:
    s.logFile.writeWalRecord("UJ " & $eventId & " " & $blob.len & "\n" & blob & "\n")
    s.flushMaybe(force = true)

proc setNextUniverseSyncId*(s: Store, nextId: uint64) =
  ## Persist the source outbox sequence independent of currently live events.
  ## This prevents id reuse after every acknowledged event has been pruned.
  if nextId <= s.nextUniverseSyncId:
    return
  s.ensureWritable()
  s.nextUniverseSyncId = nextId
  if s.persistent:
    s.logFile.writeWalLine("UQ " & $nextId)
    s.flushMaybe(force = true)

proc deleteUniverseSyncEvent*(s: Store, eventId: uint64) =
  s.ensureWritable()
  s.universeSyncEvents.del eventId
  if s.persistent:
    s.logFile.writeWalLine("UD " & $eventId)
    s.flushMaybe(force = true)

proc pruneAppliedUniverseSyncEvents*(s: Store, maxKeep: int): int =
  ## Bound the target-side idempotency set. Choose maxKeep large enough for the
  ## longest expected delayed retry window.
  if maxKeep < 0:
    raise newException(ValueError, "maxKeep must be >= 0")
  s.ensureWritable()
  var compactedOrder: seq[string]
  for eventKey in s.appliedUniverseSyncOrder:
    if s.appliedUniverseSyncEvents.getOrDefault(eventKey, false):
      compactedOrder.add eventKey
  s.appliedUniverseSyncOrder = compactedOrder
  while s.appliedUniverseSyncOrder.len > maxKeep:
    let eventKey = s.appliedUniverseSyncOrder[0]
    s.appliedUniverseSyncOrder.delete(0)
    if s.appliedUniverseSyncEvents.getOrDefault(eventKey, false):
      s.appliedUniverseSyncEvents.del eventKey
      inc result
      if s.persistent:
        s.logFile.writeWalRecord("UX " & $eventKey.len & "\n" & eventKey & "\n")
  if result > 0 and s.persistent:
    s.flushMaybe(force = true)

proc markUniverseSyncEventApplied*(s: Store, eventKey: string) =
  if eventKey.len == 0:
    raise newException(ValueError, "universe sync event key is empty")
  if s.appliedUniverseSyncEvents.getOrDefault(eventKey, false):
    return
  s.ensureWritable()
  s.appliedUniverseSyncEvents[eventKey] = true
  s.appliedUniverseSyncOrder.add eventKey
  if s.persistent:
    s.logFile.writeWalRecord("UA " & $eventKey.len & "\n" & eventKey & "\n")
    s.flushMaybe(force = true)
  discard s.pruneAppliedUniverseSyncEvents(AppliedUniverseSyncRetention)

proc isUniverseSyncEventApplied*(s: Store, eventKey: string): bool =
  s.appliedUniverseSyncEvents.getOrDefault(eventKey, false)

proc nextSeq*(s: Store, ring: uint64): uint32 =
  result = s.seqs.getOrDefault(ring, 0'u32)
  s.seqs[ring] = result + 1

proc upsert*(s: Store, p: Particle, origin = 0'u32,
             preserveVersion = false): bool {.discardable.} =
  s.ensureWritable()
  var effective = p
  effective.version =
    if preserveVersion and not p.version.isZero:
      s.normalizeMutationVersion(p.version, p.tWrite)
    else:
      s.nextMutationVersion(origin)
  let k = key(effective.parent, effective.seq)
  if k in s.tombstones and effective.version <= s.tombstones[k].version:
    return false
  if k in s.itemVersions and effective.version <= s.itemVersions[k]:
    return false
  var walOffset = -1'i64
  if s.persistent:
    walOffset = s.logFile.getFilePos()
    s.logFile.writeParticleRecord("", 0, effective)
    s.flushMaybe()
  s.applyOp(TxOp(kind: txUpsert, p: effective, walOffset: walOffset,
                 segmentOffset: -1'i64, segmentBody: ""))
  if s.diskBacked and s.persistent:
    s.cacheParticleInSegment(effective, walOffset,
      particleRecordBody("", 0, effective))
  true

proc putForwarder*(s: Store, oldParent: uint64, oldSeq: uint32, f: Forwarder) =
  s.ensureWritable()
  let forwarderKey = key(oldParent, oldSeq)
  if forwarderKey in s.forwarders and s.forwarders[forwarderKey] == f:
    return
  s.forwarders[forwarderKey] = f
  if s.persistent:
    s.logFile.writeWalLine("F " & $oldParent & " " & $oldSeq & " " & $f.newParent & " " &
                           $f.newSeq & " " & $f.newTWrite & " " & $f.expiresAt)
    s.flushMaybe()

proc remove*(s: Store, parent: uint64, seq: uint32,
             origin = 0'u32): bool {.discardable.} =
  s.ensureWritable()
  let k = key(parent, seq)
  var tombstone =
    if k in s.items or k in s.itemOffsets or k in s.itemSegmentOffsets:
      let p = s.getParticle(parent, seq)
      let version = s.nextMutationVersion(origin)
      Tombstone(parent: parent, seq: seq, period: p.period, head: p.head,
                tWrite: p.tWrite, version: version,
                acknowledgedNodes:
                  (if version.origin > 0 and
                      version.origin <= uint32(uint16.high):
                     @[uint16(version.origin - 1)]
                   else:
                     @[]))
    elif k in s.tombstones:
      s.tombstones[k]
    else:
      return false
  if k in s.tombstones and tombstone.version <= s.tombstones[k].version:
    return false
  if s.persistent:
    s.logFile.writeTombstoneRecord("", 0, tombstone)
    s.flushMaybe()
  s.applyOp(TxOp(kind: txRemove, tombstone: tombstone))
  true

proc applyTombstone*(s: Store, tombstone: Tombstone): bool {.discardable.} =
  ## Apply a transferred/replayed logical delete using its original version.
  s.ensureWritable()
  var effective = tombstone
  effective.normalizeTombstoneMetadata()
  effective.version =
    s.normalizeMutationVersion(effective.version, effective.tWrite)
  let k = key(effective.parent, effective.seq)
  if k in s.tombstones:
    if effective.version < s.tombstones[k].version:
      return false
    if effective.version == s.tombstones[k].version:
      var merged = s.tombstones[k]
      if not merged.mergeTombstoneMetadata(effective):
        return false
      if s.persistent:
        s.logFile.writeTombstoneRecord("", 0, merged)
        s.flushMaybe()
      s.tombstones[k] = merged
      return true
  if k in s.itemVersions and effective.version <= s.itemVersions[k]:
    return false
  if s.persistent:
    s.logFile.writeTombstoneRecord("", 0, effective)
    s.flushMaybe()
  s.applyOp(TxOp(kind: txRemove, tombstone: effective))
  true

proc evict*(s: Store, parent: uint64, seq: uint32) =
  ## Remove a transferred source copy without creating a logical delete.
  s.ensureWritable()
  s.evictState(parent, seq)
  if s.persistent:
    s.logFile.writeWalLine("D " & $parent & " " & $seq)
    s.flushMaybe()

proc reclaimTombstone*(s: Store, parent: uint64, seq: uint32): bool
    {.discardable.} =
  ## Remove the final logical-delete marker only after cluster-wide
  ## acknowledgement and the server's stale-transfer drain grace.
  s.ensureWritable()
  let k = key(parent, seq)
  if k notin s.tombstones:
    return false
  s.tombstones.del k
  if s.persistent:
    s.logFile.writeWalLine("LG " & $parent & " " & $seq)
    s.flushMaybe()
  true
proc contains*(s: Store, parent: uint64, seq: uint32): bool =
  let k = key(parent, seq)
  k in s.items or k in s.itemOffsets

proc count*(s: Store): int =
  if s.diskBacked:
    s.itemOffsets.len
  else:
    s.items.len

proc clusterTxPending*(s: Store): int =
  for _, intent in s.clusterTx:
    if intent.committed and not intent.applied:
      inc result

proc clusterTxCommitted*(s: Store): int = s.clusterTx.len

proc clusterTxApplied*(s: Store): int =
  for _, intent in s.clusterTx:
    if intent.applied:
      inc result

proc isClusterTxApplied*(s: Store, txid: uint64): bool =
  s.appliedClusterTx.getOrDefault(txid, false) or
    (txid in s.clusterTx and s.clusterTx[txid].applied)

proc hasClusterTxIntent*(s: Store, txid: uint64): bool =
  txid in s.clusterTx

proc beginTxn*(s: Store): StoreTxn =
  result = StoreTxn(store: s, id: s.nextTxId)
  inc s.nextTxId

proc reserveTxId*(s: Store): uint64 =
  result = s.nextTxId
  inc s.nextTxId

proc upsert*(tx: StoreTxn, p: Particle) =
  doAssert not tx.closed, "transaction is closed"
  var effective = p
  effective.version = tx.store.nextMutationVersion()
  tx.ops.add TxOp(kind: txUpsert, p: effective, walOffset: -1'i64,
                  segmentOffset: -1'i64, segmentBody: "")

proc remove*(tx: StoreTxn, parent: uint64, seq: uint32) =
  doAssert not tx.closed, "transaction is closed"
  let s = tx.store
  let k = key(parent, seq)
  var source = Particle()
  var found = false
  if tx.ops.len > 0:
    for i in countdown(tx.ops.len - 1, 0):
      let op = tx.ops[i]
      case op.kind
      of txUpsert:
        if key(op.p.parent, op.p.seq) == k:
          source = op.p
          found = true
          break
      of txRemove:
        if key(op.tombstone.parent, op.tombstone.seq) == k:
          return
      else:
        discard
  if not found and
      (k in s.items or k in s.itemOffsets or k in s.itemSegmentOffsets):
    source = s.getParticle(parent, seq)
    found = true
  if not found:
    return
  let tombstone = Tombstone(
    parent: parent, seq: seq,
    period: source.period, head: source.head, tWrite: source.tWrite,
    version: s.nextMutationVersion(),
    acknowledgedNodes:
      (if s.mutationOrigin > 0 and
          s.mutationOrigin <= uint32(uint16.high):
         @[uint16(s.mutationOrigin - 1)]
       else:
         @[]))
  tx.ops.add TxOp(kind: txRemove, tombstone: tombstone)

proc putForwarder*(tx: StoreTxn, oldParent: uint64, oldSeq: uint32, f: Forwarder) =
  doAssert not tx.closed, "transaction is closed"
  tx.ops.add TxOp(kind: txForwarder, oldParent: oldParent, oldSeq: oldSeq, f: f)

proc putUniverseSyncEvent*(tx: StoreTxn, eventId: uint64, blob: string) =
  doAssert not tx.closed, "transaction is closed"
  if blob.len == 0:
    raise newException(ValueError, "universe sync event blob is empty")
  tx.ops.add TxOp(kind: txUniverseSyncEvent, universeEventId: eventId,
                  universeEventBlob: blob)

proc deleteUniverseSyncEvent*(tx: StoreTxn, eventId: uint64) =
  doAssert not tx.closed, "transaction is closed"
  tx.ops.add TxOp(kind: txUniverseSyncDelete, universeDeleteEventId: eventId)

proc putRingMeta*(tx: StoreTxn, ringKey: uint64, period, head: float) =
  doAssert not tx.closed, "transaction is closed"
  tx.ops.add TxOp(kind: txRingMeta, ringKey: ringKey,
                  ringPeriod: period, ringHead: head)

proc putRingName*(tx: StoreTxn, ringKey: uint64, name: string) =
  doAssert not tx.closed, "transaction is closed"
  if name.len > 0:
    tx.ops.add TxOp(kind: txRingName, ringNameKey: ringKey, ringName: name)

proc rollback*(tx: StoreTxn) =
  tx.ops.setLen(0)
  tx.closed = true

proc packCommittedSegments*(tx: StoreTxn)

proc commit*(tx: StoreTxn) =
  doAssert not tx.closed, "transaction is closed"
  let s = tx.store
  s.ensureWritable()
  if s.persistent:
    s.logFile.writeWalLine("T " & $tx.id)
    for i in 0 ..< tx.ops.len:
      var op = tx.ops[i]
      case op.kind
      of txRingMeta:
        s.logFile.writeWalLine("XR " & $tx.id & " " & $op.ringKey & " " &
                               $op.ringPeriod & " " & $op.ringHead)
      of txRingName:
        s.logFile.writeWalRecord("XN " & $tx.id & " " & $op.ringNameKey & " " &
                                 $op.ringName.len & "\n" & op.ringName & "\n")
      of txUpsert:
        op.walOffset = s.logFile.getFilePos()
        op.segmentBody = particleRecordBody("XP", tx.id, op.p)
        s.logFile.writeWalRecord(op.segmentBody)
        tx.ops[i] = op
      of txRemove:
        s.logFile.writeTombstoneRecord("XL", tx.id, op.tombstone)
      of txForwarder:
        s.logFile.writeWalLine("XF " & $tx.id & " " & $op.oldParent & " " &
                               $op.oldSeq & " " & $op.f.newParent & " " &
                               $op.f.newSeq & " " & $op.f.newTWrite & " " &
                               $op.f.expiresAt)
      of txUniverseSyncEvent:
        s.logFile.writeWalRecord("XUJ " & $tx.id & " " & $op.universeEventId &
                                 " " & $op.universeEventBlob.len & "\n" &
                                 op.universeEventBlob & "\n")
      of txUniverseSyncDelete:
        s.logFile.writeWalLine("XUD " & $tx.id & " " & $op.universeDeleteEventId)
    s.logFile.writeWalLine("C " & $tx.id)
    s.flushMaybe(force = true)
  s.applyOps(tx.ops)
  tx.committed = true
  tx.closed = true
  tx.packCommittedSegments()

proc packCommittedSegments*(tx: StoreTxn) =
  ## Add committed transaction payloads to ring-local segment files.
  ## WAL remains the source of truth; segment entries are rebuildable.
  doAssert tx.committed, "transaction must be committed before segment packing"
  let s = tx.store
  if not s.diskBacked or not s.persistent or s.segmentDir.len == 0:
    return
  for op in tx.ops:
    if op.kind == txUpsert:
      let p = op.p
      let body =
        if op.segmentBody.len > 0: op.segmentBody
        else: particleRecordBody("", 0, p)
      s.cacheParticleInSegment(p, op.walOffset, body)

proc putClusterTxIntent*(s: Store, intent: ClusterTxIntent) =
  s.ensureWritable()
  var effective = intent
  for op in effective.ops.mitems:
    op.version =
      if op.version.isZero: s.nextMutationVersion()
      else: s.normalizeMutationVersion(op.version, op.tWrite)
  s.clusterTx[effective.id] = effective
  if s.persistent:
    s.logFile.writeWalLine("CT " & $effective.id)
    for op in effective.ops:
      s.logFile.writeClusterTxOp(effective.id, op)
    s.logFile.writeWalLine("CC " & $effective.id)
    s.flushMaybe(force = true)

proc markClusterTxApplied*(s: Store, txid: uint64) =
  s.ensureWritable()
  s.appliedClusterTx[txid] = true
  if txid in s.clusterTx:
    s.clusterTx[txid].applied = true
  if s.persistent:
    s.logFile.writeWalLine("CA " & $txid)
    s.flushMaybe()
