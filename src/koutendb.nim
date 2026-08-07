## KoutenDB — 公開 API（設計書 §13–§16）
##
## 学習コスト最小の表面。まずこの3語だけで使い始められる:
##
## ```nim
## var db = koutendb.open()          # 組み込み（単一プロセス）
## let id = db.put("hello")
## echo db.get(id)
## ```
##
## そのままの API でスケールアウトできる（サーバは koutend を並べるだけ）:
##
## ```nim
## var db = connect("10.0.0.1:7301,10.0.0.2:7301,10.0.0.3:7301")
## let id = db.put(%*{"title": "..", "author": {"name": ".."}}, ring = "docs")
## echo db.query(id, "{ title author { name } }")   # 必要な形だけ取得（サーバ側で射影）
## echo db.locate(id)                # 今どのノードか — どのモードでも問い合わせゼロ
## echo db.locate(id, at = 120.0)    # 未来の所在も計算できる（ephemeris）
## ```
##
## 永続化は open/サーバ起動時にディレクトリを渡すだけ:
## `koutendb.open(dataDir = "/var/lib/kouten")` / `koutend --data=DIR`

import std/[algorithm, tables, hashes, json, times, monotimes, strutils, os, net]
import kouten/[core, store, select, wire, field, vector_backend,
              planner_backend, payload, metrics_format]

export vector_backend
export planner_backend
export payload
export select
export metrics_format

type
  KoutenDurability* = StoreDurability

  KoutenValidationError* = object of ValueError
    ## Invalid user input that can be fixed before retrying.

  KoutenGuardrailError* = object of ValueError
    ## An opt-in production guardrail rejected an otherwise valid operation.

  KoutenConflictError* = object of IOError
    ## A retryable conflict, such as a busy cooperative coordinate lock.

  KoutenOperationError* = object of IOError
    ## Operational failure from remote cluster, durability, backup, or sync paths.

  KoutenNotFoundError* = object of KeyError
    ## Requested record or maintenance job does not exist.

  KoutenId* = object
    ## 不透明ID。put が返し、get/query/locate に渡す。中身に触る必要はない。
    ## （内部的には自己記述の軌道要素 = 設計書 §2.2。この ID だけで所在計算が閉じる）
    parent: uint64
    epoch: uint32
    seq: uint32
    tWrite: float

  RingInfo = object
    period: float
    headAngle: float

  Mode = enum
    mEmbedded, mCluster

  KoutenLockScope* = enum
    rlsRing
    rlsStellar

  KoutenLockToken* = object
    ## Cooperative lock token for high-integrity application workflows.
    ## Normal put/get paths do not check these locks; use them around
    ## transaction/bulk workflows that need retry safety.
    scope*: KoutenLockScope
    coordinate*: string
    token*: string
    fence*: uint64
    expiresAt*: float
    keys*: seq[string]

  KoutenLockState = object
    scope: KoutenLockScope
    coordinate: string
    token: string
    expiresAt: float

  RetrievalTuning* = object
    ## 内部 tuning knob。通常は SearchProfile を使う。
    budget*: int
    focus*: int
    topRings*: int
    branchBudget*: int
    maxDepth*: int
    includeChildren*: bool
    note*: string

  SearchScope* = enum
    ssTight        ## 指定 ring 中心。短く速い
    ssNear         ## 近い周辺 ring まで
    ssWide         ## 広めに関連 ring を見る
    ssAll          ## recall 優先でかなり広く見る

  SearchDepth* = enum
    sdShallow      ## 子階層へ降りない
    sdNormal       ## 標準。現状は shallow と同じ
    sdDeep         ## 子 ring も辿る
    sdVeryDeep     ## 深い階層まで辿る

  ResultAmount* = enum
    raFew          ## 少数だけ返す
    raNormal       ## 標準量
    raMany         ## 多めに返す
    raAllUseful    ## 有用そうなものを多めに残す

  WriteAckMode* = enum
    wamAccepted     ## durable landing / intake が完了したら返す
    wamApplied      ## owner への apply 完了まで待ってから返す

  RingApplyMode* = enum
    ramLatestOnly       ## 新しい timestamp / sequence を最新状態として採用する
    ramAppendOnly       ## eventId 重複だけ避け、追加データとして保存する
    ramBoundedHistory   ## timestamp 順の履歴を bounded に保持するための足場
    ramDelayedTimestamp ## delay window 後に timestamp 順で apply するための足場

  RingApplyPolicy* = object
    ## Universe sync / delayed apply 用の ring-local policy。
    mode*: RingApplyMode
    historyKeep*: int
    delayMs*: int

  KoutenGuardrails* = object
    ## Opt-in write-path guardrails for production trials.
    ## A zero value means "disabled" so existing workloads keep their behavior.
    maxPayloadBytes*: int
    maxVectorDim*: int
    maxRingCount*: int
    maxRecordsPerRing*: int

  KoutenGuardrailReason = enum
    kgrPayloadBytes
    kgrVectorDimension
    kgrRingCount
    kgrRecordsPerRing

  SearchProfile* = object
    ## 人間向けの retrieval tuning profile。
    ## RDB の optimizer hint を、KoutenDB では自然な語彙で表す。
    amount*: ResultAmount
    scope*: SearchScope
    depth*: SearchDepth
    note*: string

  WarpStatus* = enum
    wsPending       ## 登録済み。まだ処理されていない
    wsRunning       ## step 処理中または途中まで処理済み
    wsDone          ## 指定 ring をすべて処理済み
    wsFailed        ## 処理中に失敗した。retryAt 以降に再試行できる
    wsDeadLetter    ## retry budget を使い切った

  WarpJob* = object
    ## ring-scoped delayed batch update。
    ## JOIN ではなく、指定 ring 群を登録順に少しずつ走査して条件一致 document に patch を落とす。
    id*: uint64
    rings*: seq[string]
    whereField*: string
    equals*: JsonNode
    patch*: JsonNode
    status*: WarpStatus
    ringIndex*: int
    cursor*: string
    scanned*: int
    matched*: int
    updated*: int
    attempts*: int
    maxAttempts*: int
    retryAt*: float
    acknowledged*: bool
    error*: string

  UniverseSyncEvent* = object
    ## Universe 間の durable eventual convergence 用イベント。
    ## 即時グローバル commit ではなく、別 universe の同名 galaxy に後で配送・適用する。
    id*: uint64
    eventKey*: string
    sourceUniverse*: string
    sourceGalaxy*: string
    ring*: string
    op*: string
    logicalKey*: string
    payload*: string
    codec*: PayloadCodec
    vec*: seq[float32]
    timestamp*: float
    applyAfter*: float
    originSeq*: uint64
    attempts*: int
    maxAttempts*: int
    retryAt*: float
    deadLetter*: bool
    acknowledged*: bool
    error*: string

  KoutenDb* = ref object
    ## DB ハンドル。所有は木構造（循環なし）— ARC 制約（設計書 §13.3）。
    mode: Mode
    tbl: ArcTable
    rings: Table[uint64, RingInfo]
    ringNames: Table[string, uint64]
    ringKeyNames: Table[uint64, string]
    ringDescriptions: Table[uint64, string]
    ringPayloadProfiles: Table[uint64, RingPayloadProfile]
    timeOrbitProfiles: Table[uint64, TimeOrbitProfile]
    ringWriteAckModes: Table[uint64, WriteAckMode]
    ringApplyPolicies: Table[uint64, RingApplyPolicy]
    guardrails: KoutenGuardrails
    guardrailDenials: array[KoutenGuardrailReason, uint64]
    ringChildren: Table[uint64, seq[uint64]]
    stellarMembers: Table[string, seq[string]]
    stellarByMember: Table[string, seq[string]]
    activeLocks: Table[string, KoutenLockState]
    lockFence: uint64
    retrievalTunings: Table[string, RetrievalTuning]
    searchProfiles: Table[string, SearchProfile]
    lastRingName: string        # 1エントリキャッシュ（putのホットパス最適化, §16.2）
    lastRingKey: uint64
    # embedded
    clock: float
    dataDir: string
    st: Store
    vectorBackend: VectorBackend
    plannerBackend: PlannerBackend
    defaultWriteAckMode: WriteAckMode
    # cluster
    client: ClusterClient
    galaxy: string
    galaxyDescription: string
    pendingLandingReads: Table[(uint64, uint32), bool]
    # delayed maintenance jobs
    nextWarpId: uint64
    warpJobs: seq[WarpJob]
    nextUniverseSyncId: uint64
    universeSyncEvents: seq[UniverseSyncEvent]

  GalaxyRouter* = ref object
    galaxies: Table[string, KoutenDb]

  KoutenTx* = ref object
    ## embedded は単一 Store atomic transaction。
    ## cluster は node0 landing zone への atomic intent commit。
    db: KoutenDb
    tx: StoreTxn
    stagedRingWrites: Table[uint64, int]
    clusterTxId: uint64
    clusterOps: seq[TxWireOp]
    closed: bool

  KoutenHit* = object
    ## retrieve の候補。score は cosine similarity（高いほど近い）。
    id*: KoutenId
    score*: float
    payload*: string
    codec*: PayloadCodec

  KoutenRecord* = object
    ## ORM / driver が listByRing で扱う薄い record。
    id*: KoutenId
    payload*: string
    codec*: PayloadCodec

  WarpStepResult* = object
    job*: WarpJob
    scanned*: int
    matched*: int
    updated*: int

  KoutenListPage* = object
    ## cursor pagination の結果。nextCursor が空なら次ページなし。
    items*: seq[KoutenRecord]
    nextCursor*: string

  KoutenReadSortDirection* = enum
    rsAsc
    rsDesc

  KoutenPaginationMode* = enum
    rpOff
    rpOn

  KoutenReadOptions* = object
    ## Ring read options shared by the public API and CLI.
    ## Cursor reads are the efficient default. Page reads are human-facing and
    ## may need to skip earlier filtered matches.
    filter*: JsonNode
    selection*: string
    limit*: int
    cursor*: string
    pagination*: KoutenPaginationMode
    page*: int
    pageLimit*: int
    sortField*: string
    sortDirection*: KoutenReadSortDirection

  KoutenFilterBuilder* = object
    ## Typed helper for constructing read filters without string-concatenated
    ## JSON. The stored representation remains a JSON object so existing CLI,
    ## wire, C ABI, and driver paths stay compatible.
    node: JsonNode

  KoutenReadPage* = object
    ring*: string
    count*: int
    items*: seq[KoutenRecord]
    nextCursor*: string
    pagination*: KoutenPaginationMode
    page*: int
    pageLimit*: int
    sortField*: string
    sortDirection*: KoutenReadSortDirection

  KoutenTimeReadPage* = object
    ring*: string
    fromMs*: int64
    toMs*: int64
    bucketsVisited*: int
    count*: int
    items*: seq[KoutenRecord]
    rings*: seq[string]

  KoutenStellarOptions* = object
    ## Read a coordinate-local stellar neighborhood.
    ## A root ring behaves like a telescope target: nearby child rings are in
    ## the same field of view unless subrings narrow the view. Distant rings
    ## are not forced into the read path.
    filter*: JsonNode
    selection*: string
    limitPerRing*: int
    subringLimits*: Table[string, int]
    subringSortFields*: Table[string, string]
    subringSortDirections*: Table[string, KoutenReadSortDirection]
    maxDepth*: int
    branchBudget*: int
    subrings*: seq[string]
    includeRoot*: bool
    sortField*: string
    sortDirection*: KoutenReadSortDirection

  KoutenStellarRingPage* = object
    ring*: string
    count*: int
    items*: seq[KoutenRecord]

  KoutenStellarPage* = object
    root*: string
    maxDepth*: int
    branchBudget*: int
    ringsVisited*: int
    count*: int
    rings*: seq[KoutenStellarRingPage]

  RetrieveStats* = object
    totalVectors*: int
    scanned*: int
    skippedVectors*: int
    returned*: int
    ringsTouched*: int
    payloadBytes*: int
    estimatedTokens*: int
    fanoutNodes*: int
    candidateReduction*: float

  RetrievalPlan* = object
    ## SQL の実行計画に相当する retrieval tuning surface。
    ## 物理配置は変えず、この計画だけを変えて消費量/recall を調整する。
    strategy*: string
    profile*: string
    baseRing*: string
    amount*: string
    scope*: string
    depth*: string
    ringScoped*: bool
    budget*: int
    focus*: int
    topRings*: int
    effectiveTopRings*: int
    branchBudget*: int
    maxDepth*: int
    includeChildren*: bool
    reason*: string
    selectedRings*: seq[string]
    prunedRings*: seq[string]
    ringFeatures*: seq[RingPlanCandidate]

  RingMetric* = object
    ringKey*: uint64
    count*: int
    coherence*: float

  KoutenRingSummary* = object
    ringKey*: uint64
    count*: int
    centroid*: seq[float32]
    score*: float
    coherence*: float
    massG*: float

  RetrievalEnvelopeOptions* = object
    ## RAG / MCP adapter に渡す retrieval envelope の補助メタデータ。
    provider*: string
    galaxy*: string
    ring*: string
    backend*: string
    mode*: string
    requestId*: string
    correlationId*: string
    sourceType*: string
    resourceKind*: string
    resourceScope*: string
    retentionClass*: string
    contextReusable*: bool
    dataLabel*: string
    plan*: RetrievalPlan

  CompactStats* = StoreCompactStats
  BackupStats* = StoreBackupStats
  LocalityReport* = StoreLocalityReport
  CheckpointFile* = StoreCheckpointFile
  CheckpointStatus* = StoreCheckpointStatus
  CheckpointCleanupStats* = StoreCheckpointCleanupStats

  KoutenSegmentRingStatus* = object
    ring*: string
    ringKey*: uint64
    generation*: uint64
    liveRecords*: int
    coveredRecords*: int
    segmentRecords*: int
    staleRecords*: int
    staleRatio*: float
    segmentBytes*: int64
    indexBytes*: int64
    packRecommended*: bool

  KoutenSegmentStatus* = object
    diskBacked*: bool
    segmentHits*: uint64
    walFallbacks*: uint64
    walFallbackPointReads*: uint64
    walFallbackRingScans*: uint64
    walFallbackWindowReads*: uint64
    rings*: seq[KoutenSegmentRingStatus]
    recommendedRings*: int
    totalSegmentBytes*: int64
    totalIndexBytes*: int64
    maxGeneration*: uint64

  KoutenSegmentMaintenancePolicy* = object
    ## Zero means unlimited for each budget. Callers that schedule maintenance
    ## should set at least one limit explicitly.
    staleRatioThreshold*: float
    minStaleRecords*: int
    maxRings*: int
    maxBytes*: int64
    maxElapsedMs*: int64

  KoutenSegmentMaintenanceDecision* = object
    ring*: string
    ringKey*: uint64
    recommended*: bool
    selected*: bool
    reason*: string
    staleRecords*: int
    staleRatio*: float
    estimatedBytes*: int64
    recordsRewritten*: int
    bytesRewritten*: int64
    filesRemoved*: int
    error*: string

  KoutenSegmentMaintenanceResult* = object
    dryRun*: bool
    outcome*: string
    startedAt*: float
    finishedAt*: float
    elapsedMs*: int64
    recommendedRings*: int
    selectedRings*: int
    packedRings*: int
    recordsRewritten*: int
    bytesRewritten*: int64
    filesRemoved*: int
    stopReason*: string
    decisions*: seq[KoutenSegmentMaintenanceDecision]

  KoutenOperationalCheck* = object
    name*: string
    ok*: bool
    message*: string

  KoutenOperationalVerifyReport* = object
    ok*: bool
    dataDir*: string
    persistent*: bool
    diskBacked*: bool
    walPath*: string
    walExists*: bool
    walBytes*: int64
    items*: int
    rings*: int
    ringNames*: int
    vectors*: int
    galaxy*: string
    segmentDir*: string
    segmentDirExists*: bool
    segmentFiles*: int
    segmentPackRecords*: int
    segmentStatus*: KoutenSegmentStatus
    locality*: LocalityReport
    checks*: seq[KoutenOperationalCheck]

  DumpStats* = object
    bytes*: BiggestInt
    records*: int
    rings*: int
    documents*: int
    destination*: string

  ImportStats* = object
    read*: int
    imported*: int
    skipped*: int
    errors*: int
    rings*: int
    batches*: int
    batchSize*: int
    source*: string
    defaultRing*: string

  UniverseSyncStats* = object
    read*: int
    applied*: int
    skipped*: int
    acked*: int
    pruned*: int
    errors*: int
    deadLetter*: int

const
  durBuffered* = store.durBuffered
  durStrong* = store.durStrong
  DefaultPeriod = 60.0
  RetrievalEnvelopeSchema* = "koutendb.retrieval.v1"
  RetrievalEnvelopeVersion* = 1
  AtlasSchema* = "koutendb.atlas.v1"
  AtlasVersion* = 1

proc parentRingName(name: string): string
proc addRingChild(db: KoutenDb, parent, child: uint64)
proc ringNameOf(db: KoutenDb, key: uint64): string
proc ringKey(db: KoutenDb, name: string, persist = true): uint64
proc ringKeyForRead(db: KoutenDb, ring: string): uint64
proc descendantRingKeys(db: KoutenDb, root: uint64, maxDepth, branchBudget: int): seq[uint64]
proc addUniqueRingKey(keys: var seq[uint64], key: uint64)
proc stellarNeighborKeys(db: KoutenDb, root: uint64, maxDepth, branchBudget: int): seq[uint64]
proc put*(db: KoutenDb, encoded: EncodedPayload, ring: string = "default",
          vec: seq[float32] = @[]): KoutenId
proc put*(db: KoutenDb, payload: string, ring: string = "default",
          vec: seq[float32] = @[]): KoutenId
proc enqueueUniverseSyncEvent*(db: KoutenDb, sourceUniverse, sourceGalaxy,
                               ring, payload: string,
                               vec: seq[float32] = @[],
                               codec = pcRaw,
                               op = "put", logicalKey = "",
                               timestamp = -1.0,
                               eventKey = ""): uint64
proc stageUniverseSyncEvent(db: KoutenDb, tx: StoreTxn, sourceUniverse,
                            sourceGalaxy, ring, payload: string,
                            vec: seq[float32] = @[], codec = pcRaw,
                            op = "put", logicalKey = "",
                            timestamp = -1.0,
                            eventKey = ""): tuple[event: UniverseSyncEvent,
                                                   removed: seq[int]]

proc defaultRetrievalTuning*(): RetrievalTuning =
  RetrievalTuning(budget: 8, focus: 0, topRings: 0, branchBudget: 0,
                  maxDepth: 0, includeChildren: false, note: "default")

proc defaultSearchProfile*(): SearchProfile =
  SearchProfile(amount: raNormal, scope: ssTight, depth: sdNormal,
                note: "default")

proc defaultRingApplyPolicy*(): RingApplyPolicy =
  RingApplyPolicy(mode: ramLatestOnly, historyKeep: 1, delayMs: 0)

proc defaultGuardrails*(): KoutenGuardrails =
  KoutenGuardrails(maxPayloadBytes: 0, maxVectorDim: 0, maxRingCount: 0,
                   maxRecordsPerRing: 0)

proc appendAudit(dataDir, event: string; ok = true; ring = ""; id = "";
                 message = ""; extra: JsonNode = nil) =
  if dataDir.len == 0:
    return
  var node = %*{
    "timestamp": epochTime(),
    "event": event,
    "ok": ok,
    "ring": ring,
    "id": id,
    "message": message
  }
  if not extra.isNil:
    node["extra"] = extra
  let path = dataDir / "kouten.audit.jsonl"
  var f = open(path, fmAppend)
  try:
    f.writeLine($node)
  finally:
    f.close()

proc auditLogPath*(dataDir: string): string =
  if dataDir.len == 0:
    return ""
  dataDir / "kouten.audit.jsonl"

proc audit(db: KoutenDb, event: string; ok = true; ring = ""; id = "";
           message = ""; extra: JsonNode = nil) =
  if db.mode == mEmbedded:
    appendAudit(db.dataDir, event, ok = ok, ring = ring, id = id,
                message = message, extra = extra)

proc auditLogPath*(db: KoutenDb): string =
  if db.mode == mEmbedded:
    auditLogPath(db.dataDir)
  else:
    ""

proc tuningFromSearchProfile*(profile: SearchProfile): RetrievalTuning =
  case profile.amount
  of raFew:
    result.budget = 3
  of raNormal:
    result.budget = 8
  of raMany:
    result.budget = 16
  of raAllUseful:
    result.budget = 32

  case profile.scope
  of ssTight:
    result.focus = 0
    result.topRings = 0
  of ssNear:
    result.focus = 15
    result.topRings = 0
  of ssWide:
    result.focus = 45
    result.topRings = 0
  of ssAll:
    result.focus = 90
    result.topRings = 0

  case profile.depth
  of sdShallow:
    result.includeChildren = false
    result.maxDepth = 0
    result.branchBudget = 0
  of sdNormal:
    result.includeChildren = false
    result.maxDepth = 0
    result.branchBudget = 0
  of sdDeep:
    result.includeChildren = true
    result.maxDepth = 2
    result.branchBudget = 4
  of sdVeryDeep:
    result.includeChildren = true
    result.maxDepth = 4
    result.branchBudget = 8
  result.note = profile.note

proc normalizedCoordinate(name: string): string =
  name.strip(chars = {' ', '\t', '\r', '\n', '/'})

proc addUniqueString(items: var seq[string], value: string) =
  if value.len > 0 and value notin items:
    items.add value

proc removeString(items: var seq[string], value: string) =
  var next: seq[string] = @[]
  for item in items:
    if item != value:
      next.add item
  items = next

proc rebuildStellarMembership(db: KoutenDb) =
  db.stellarByMember.clear()
  for stellar, members in db.stellarMembers:
    for member in members:
      var stellars = db.stellarByMember.getOrDefault(member, @[])
      stellars.addUniqueString stellar
      db.stellarByMember[member] = stellars

proc loadStellarMap(db: KoutenDb, raw: string) =
  if raw.len == 0:
    return
  let node = parseJson(raw)
  let stellar = normalizedCoordinate(node{"stellar"}.getStr(""))
  if stellar.len == 0:
    return
  var members: seq[string] = @[]
  if node.hasKey("members") and node["members"].kind == JArray:
    for item in node["members"]:
      members.addUniqueString normalizedCoordinate(item.getStr())
  db.stellarMembers[stellar] = members

proc stellarMapBlob(stellar: string, members: seq[string]): string =
  var arr = newJArray()
  for member in members:
    arr.add %member
  $(%*{"stellar": stellar, "members": arr})

proc lockKey(scope: KoutenLockScope, coordinate: string): string =
  case scope
  of rlsRing: "ring:" & normalizedCoordinate(coordinate)
  of rlsStellar: "stellar:" & normalizedCoordinate(coordinate)

proc purgeExpiredLocks(db: KoutenDb, now = epochTime()) =
  var expired: seq[string] = @[]
  for key, state in db.activeLocks:
    if state.expiresAt <= now:
      expired.add key
  for key in expired:
    db.activeLocks.del key

proc newLockToken(db: KoutenDb, keys: seq[string]): tuple[token: string, fence: uint64] =
  ## Cooperative lock token. This is not an auth secret; it prevents accidental
  ## unlock by callers that do not own the lock.
  inc db.lockFence
  result.fence = db.lockFence
  result.token = $result.fence & ":" & $epochTime() & ":" & $keys.len & ":" &
    $hash(keys.join("|"))

proc acquireLockKeys(db: KoutenDb, scope: KoutenLockScope, coordinate: string,
                     keys: seq[string], ttlSeconds = 30.0,
                     waitMs = 0): KoutenLockToken =
  doAssert db.mode == mEmbedded, "coordinate locks are embedded mode only in this release"
  if ttlSeconds <= 0:
    raise newException(KoutenValidationError, "ttlSeconds must be positive")
  let deadline = epochTime() + float(max(waitMs, 0)) / 1000.0
  var uniqueKeys: seq[string] = @[]
  for key in keys:
    if key.len > 0 and key notin uniqueKeys:
      uniqueKeys.add key
  if uniqueKeys.len == 0:
    raise newException(KoutenValidationError, "lock key set is empty")

  while true:
    let now = epochTime()
    db.purgeExpiredLocks(now)
    var busy = ""
    for key in uniqueKeys:
      if key in db.activeLocks:
        busy = key
        break
    if busy.len == 0:
      let generated = db.newLockToken(uniqueKeys)
      let expiresAt = now + ttlSeconds
      for key in uniqueKeys:
        db.activeLocks[key] = KoutenLockState(scope: scope,
                                             coordinate: coordinate,
                                             token: generated.token,
                                             expiresAt: expiresAt)
      return KoutenLockToken(scope: scope, coordinate: coordinate,
                            token: generated.token, fence: generated.fence,
                            expiresAt: expiresAt,
                            keys: uniqueKeys)
    if waitMs <= 0 or epochTime() >= deadline:
      raise newException(KoutenConflictError, "coordinate lock is busy: " & busy)
    sleep(10)

proc acquireRingLock*(db: KoutenDb, ring: string, ttlSeconds = 30.0,
                      waitMs = 0): KoutenLockToken =
  ## Acquire an opt-in cooperative lock for one ring coordinate.
  let coord = normalizedCoordinate(ring)
  if coord.len == 0:
    raise newException(KoutenValidationError, "ring is required")
  db.acquireLockKeys(rlsRing, coord, @[lockKey(rlsRing, coord)],
                     ttlSeconds, waitMs)

proc acquireStellarLock*(db: KoutenDb, stellar: string, ttlSeconds = 30.0,
                         waitMs = 0): KoutenLockToken =
  ## Acquire a cooperative lock for a stellar lens and its current member rings.
  ## The member set is captured at acquisition time.
  let coord = normalizedCoordinate(stellar)
  if coord.len == 0:
    raise newException(KoutenValidationError, "stellar is required")
  var keys = @[lockKey(rlsStellar, coord), lockKey(rlsRing, coord)]
  for member in db.stellarMembers.getOrDefault(coord, @[]):
    keys.add lockKey(rlsRing, member)
  db.acquireLockKeys(rlsStellar, coord, keys, ttlSeconds, waitMs)

proc releaseLock*(db: KoutenDb, token: KoutenLockToken) =
  ## Release a cooperative lock. A mismatched token is ignored so callers cannot
  ## accidentally release another workflow's lock after TTL expiry/reacquire.
  for key in token.keys:
    if key in db.activeLocks and db.activeLocks[key].token == token.token:
      db.activeLocks.del key

proc lockActive*(db: KoutenDb, token: KoutenLockToken): bool =
  ## Return true when every key in the token is still owned by the same token.
  db.purgeExpiredLocks()
  if token.keys.len == 0:
    return false
  for key in token.keys:
    if key notin db.activeLocks:
      return false
    if db.activeLocks[key].token != token.token:
      return false
  true

proc withRingLock*(db: KoutenDb, ring: string, body: proc(),
                   ttlSeconds = 30.0, waitMs = 0) =
  let token = db.acquireRingLock(ring, ttlSeconds, waitMs)
  try:
    body()
  finally:
    db.releaseLock(token)

proc withStellarLock*(db: KoutenDb, stellar: string, body: proc(),
                      ttlSeconds = 30.0, waitMs = 0) =
  let token = db.acquireStellarLock(stellar, ttlSeconds, waitMs)
  try:
    body()
  finally:
    db.releaseLock(token)

# ---------------------------------------------------------------- 開閉と時計

proc open*(nodes: int = 8, dataDir: string = "",
           durability: KoutenDurability = durBuffered,
           diskBacked = false): KoutenDb =
  ## 組み込みモードで開く。dataDir を渡すと追記ログに永続化され、
  ## 再オープン時に中身と時計が復元される。
  if nodes <= 0 or nodes > int(high(uint16)):
    raise newException(ValueError, "nodes must be in 1.." & $int(high(uint16)))
  let tbl = equalArcTable(1, uint16(nodes))
  result = KoutenDb(mode: mEmbedded,
                   tbl: tbl,
                   dataDir: dataDir,
                   st: openStore(dataDir, durability = durability,
                                 diskBacked = diskBacked),
                   vectorBackend: newExactVectorBackend(),
                   plannerBackend: newHeuristicPlannerBackend())
  result.clock = result.st.maxTWrite   # 再開時: 時計を巻き戻さない
  for key, meta in result.st.ringMeta:
    result.rings[key] = RingInfo(period: meta.period, headAngle: meta.head)
  for key, name in result.st.ringNames:
    result.ringNames[name] = key
    result.ringKeyNames[key] = name
  for key, desc in result.st.ringDescriptions:
    result.ringDescriptions[key] = desc
  for key, profile in result.st.ringPayloadProfiles:
    result.ringPayloadProfiles[key] = profile
  for key, profile in result.st.ringTimeOrbitProfiles:
    result.timeOrbitProfiles[key] = profile
  for _, blob in result.st.stellarMaps:
    result.loadStellarMap(blob)
  result.rebuildStellarMembership()
  result.galaxyDescription = result.st.galaxyDescription
  for _, blob in result.st.warpJobs:
    let raw = parseJson(blob)
    var rings: seq[string] = @[]
    for item in raw["rings"]:
      rings.add item.getStr()
    let status =
      case raw{"status"}.getStr("wsPending")
      of "wsPending": wsPending
      of "wsRunning": wsRunning
      of "wsDone": wsDone
      of "wsFailed": wsFailed
      of "wsDeadLetter": wsDeadLetter
      else: wsPending
    let job = WarpJob(
      id: raw["id"].getInt().uint64,
      rings: rings,
      whereField: raw["whereField"].getStr(),
      equals: raw["equals"],
      patch: raw["patch"],
      status: status,
      ringIndex: raw{"ringIndex"}.getInt(),
      cursor: raw{"cursor"}.getStr(),
      scanned: raw{"scanned"}.getInt(),
      matched: raw{"matched"}.getInt(),
      updated: raw{"updated"}.getInt(),
      attempts: raw{"attempts"}.getInt(),
      maxAttempts: raw{"maxAttempts"}.getInt(8),
      retryAt: raw{"retryAt"}.getFloat(),
      acknowledged: raw{"acknowledged"}.getBool(),
      error: raw{"error"}.getStr())
    result.warpJobs.add job
    result.nextWarpId = max(result.nextWarpId, job.id)
  for _, blob in result.st.universeSyncEvents:
    let raw = parseJson(blob)
    var vec: seq[float32] = @[]
    if raw.hasKey("vec") and raw["vec"].kind == JArray:
      for item in raw["vec"]:
        case item.kind
        of JInt:
          vec.add float32(item.getInt())
        of JFloat:
          vec.add float32(item.getFloat())
        else:
          discard
    let event = UniverseSyncEvent(
      id: raw["id"].getInt().uint64,
      eventKey: raw["eventKey"].getStr(),
      sourceUniverse: raw{"sourceUniverse"}.getStr(),
      sourceGalaxy: raw{"sourceGalaxy"}.getStr(),
      ring: raw["ring"].getStr(),
      op: raw{"op"}.getStr("put"),
      logicalKey: raw{"logicalKey"}.getStr(),
      payload: raw{"payload"}.getStr(),
      codec: parsePayloadCodec(raw{"codec"}.getStr("raw")),
      vec: vec,
      timestamp: raw{"timestamp"}.getFloat(),
      applyAfter: raw{"applyAfter"}.getFloat(),
      originSeq: raw{"originSeq"}.getBiggestInt().uint64,
      attempts: raw{"attempts"}.getInt(),
      maxAttempts: raw{"maxAttempts"}.getInt(8),
      retryAt: raw{"retryAt"}.getFloat(),
      deadLetter: raw{"deadLetter"}.getBool(),
      acknowledged: raw{"acknowledged"}.getBool(),
      error: raw{"error"}.getStr())
    result.universeSyncEvents.add event
    result.nextUniverseSyncId = max(result.nextUniverseSyncId, event.id)
  result.nextUniverseSyncId = max(result.nextUniverseSyncId,
                                  result.st.nextUniverseSyncId)
  for key, name in result.st.ringNames:
    let parentName = parentRingName(name)
    if parentName.len > 0 and parentName in result.ringNames:
      result.addRingChild(result.ringNames[parentName], key)
  if not result.st.diskBacked:
    for _, p in result.st.items:
      result.vectorBackend.upsert p

proc connect*(peers: string, username: string = "", password: string = "",
              authToken: string = "", secretKey: string = "",
              galaxy: string = "", tls: bool = false,
              tlsCaFile: string = "", tlsServerName: string = "",
              tlsInsecureSkipVerify: bool = false): KoutenDb =
  ## クラスタモードで開く。peers = "host:port,host:port,..."（koutend の並び順）。
  ## 時計は wall clock。API は open() と同じに使える。
  let ps = parsePeers(peers)
  let client = newClusterClient(ps, username = username,
                                password = password,
                                authToken = authToken,
                                secretKey = secretKey,
                                galaxy = galaxy,
                                tls = tls,
                                tlsCaFile = tlsCaFile,
                                tlsServerName = tlsServerName,
                                tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  var tbl: ArcTable
  try:
    tbl = client.topologyReq(0)
    if int(tbl.nNodes) != ps.len:
      raise newException(IOError,
        "server topology node count does not match configured peers")
  except CatchableError:
    client.close()
    raise
  KoutenDb(mode: mCluster, tbl: tbl, client: client,
           plannerBackend: newHeuristicPlannerBackend(), galaxy: galaxy)

proc openGalaxyRouter*(): GalaxyRouter =
  GalaxyRouter()

proc close*(db: KoutenDb)

proc addGalaxy*(r: GalaxyRouter, name, peers: string,
                username: string = "", password: string = "",
                authToken: string = "", secretKey: string = "",
                tls: bool = false, tlsCaFile: string = "",
                tlsServerName: string = "",
                tlsInsecureSkipVerify: bool = false) =
  r.galaxies[name] = connect(peers, username = username, password = password,
                             authToken = authToken, secretKey = secretKey,
                             galaxy = name, tls = tls,
                             tlsCaFile = tlsCaFile,
                             tlsServerName = tlsServerName,
                             tlsInsecureSkipVerify = tlsInsecureSkipVerify)

proc galaxy*(r: GalaxyRouter, name: string): KoutenDb =
  r.galaxies[name]

proc close*(r: GalaxyRouter) =
  for _, db in r.galaxies:
    db.close()
  r.galaxies.clear()

proc close*(db: KoutenDb) =
  ## 後始末（永続化のフラッシュ・接続クローズ）。
  case db.mode
  of mEmbedded: db.st.close()
  of mCluster: db.client.close()

proc setGalaxyDescription*(db: KoutenDb, description: string) =
  ## Atlas に出す galaxy の説明。payload 本文ではなく探索前の案内文として使う。
  db.galaxyDescription = description
  if db.mode == mEmbedded:
    db.st.putGalaxyDescription(description)

proc getGalaxyDescription*(db: KoutenDb): string =
  db.galaxyDescription

proc setRingDescription*(db: KoutenDb, ring, description: string) =
  ## Atlas に出す ring の説明。ring が未作成なら軽いメタデータとして作成する。
  let key = db.ringKey(ring)
  if description.len == 0:
    db.ringDescriptions.del key
  else:
    db.ringDescriptions[key] = description
  if db.mode == mEmbedded:
    db.st.putRingDescription(key, description)

proc getRingDescription*(db: KoutenDb, ring: string): string =
  let key = db.ringKeyForRead(ring)
  if key == 0'u64:
    ""
  else:
    db.ringDescriptions.getOrDefault(key, "")

proc configureRingPayloadProfile*(db: KoutenDb, ring: string,
                                  profile: RingPayloadProfile) =
  ## A declaration for applications and tools. It never changes the codec of
  ## existing records, whose explicit metadata remains authoritative.
  let key = db.ringKey(ring)
  db.ringPayloadProfiles[key] = profile
  if db.mode == mEmbedded:
    db.st.putRingPayloadProfile(key, profile)

proc ringPayloadProfile*(db: KoutenDb, ring: string): RingPayloadProfile =
  let key = db.ringKeyForRead(ring)
  if key == 0'u64:
    defaultRingPayloadProfile()
  else:
    db.ringPayloadProfiles.getOrDefault(key, defaultRingPayloadProfile())

proc stableHash64(value: string): uint64 =
  ## Stable FNV-1a hash for persistent coordinate derivation.
  result = 14695981039346656037'u64
  for ch in value:
    result = result xor uint64(ord(ch))
    result = result * 1099511628211'u64

proc timeOrbitMask(bits: int): uint64 =
  if bits <= 0 or bits > 60:
    raise newException(ValueError, "time orbit bits must be 1..60")
  (1'u64 shl bits) - 1'u64

proc normalizedTimeOrbitProfile(ring: string;
                                profile: TimeOrbitProfile): TimeOrbitProfile =
  result = profile
  if result.bits == 0:
    result.bits = 60
  if result.bucketMs == 0:
    result.bucketMs = 60_000
  if result.bucketMs < 0:
    raise newException(ValueError, "time orbit bucketMs must be > 0")
  let mask = timeOrbitMask(result.bits)
  if result.phase == 0'u64:
    let salt =
      if result.salt.len > 0: result.salt
      else: ring
    result.phase = stableHash64(ring & "\0" & salt) and mask
  elif result.phase > mask:
    raise newException(ValueError, "time orbit phase exceeds coordinate space")

proc configureTimeOrbitProfile*(db: KoutenDb, ring: string,
                                profile: TimeOrbitProfile) =
  ## Configure a ring-local time orbit. It does not move existing records.
  let key = db.ringKey(ring)
  let normalized = normalizedTimeOrbitProfile(ring, profile)
  db.timeOrbitProfiles[key] = normalized
  if db.mode == mEmbedded:
    db.st.putTimeOrbitProfile(key, normalized)

proc timeOrbitProfile*(db: KoutenDb, ring: string): TimeOrbitProfile =
  let key = db.ringKeyForRead(ring)
  if key == 0'u64:
    normalizedTimeOrbitProfile(ring, defaultTimeOrbitProfile())
  else:
    db.timeOrbitProfiles.getOrDefault(
      key, normalizedTimeOrbitProfile(ring, defaultTimeOrbitProfile()))

proc timeOrbitBucket*(profile: TimeOrbitProfile, timestampMs: int64): uint64 =
  if timestampMs < 0:
    raise newException(ValueError, "timestampMs must be >= 0")
  let normalized = normalizedTimeOrbitProfile("", profile)
  uint64(timestampMs div normalized.bucketMs)

proc timeOrbitCoordinate*(profile: TimeOrbitProfile, timestampMs: int64): uint64 =
  let normalized = normalizedTimeOrbitProfile("", profile)
  let mask = timeOrbitMask(normalized.bits)
  (normalized.phase + timeOrbitBucket(normalized, timestampMs)) and mask

proc timeOrbitRing*(baseRing: string, profile: TimeOrbitProfile,
                    timestampMs: int64): string =
  let base = normalizedCoordinate(baseRing)
  if base.len == 0:
    raise newException(ValueError, "time orbit base ring must not be empty")
  let coord = timeOrbitCoordinate(profile, timestampMs)
  base & "/@time/" & $coord

proc compact*(db: KoutenDb): CompactStats =
  ## 組み込み永続 Store の WAL を生存レコードだけに再構築する。
  ## cluster 接続では各 koutend 側の管理操作として実行する。
  if db.mode != mEmbedded:
    raise newException(ValueError, "cluster connection cannot compact remote stores")
  result = db.st.compact()
  db.audit("compact", extra = %*{
    "beforeBytes": result.beforeBytes,
    "afterBytes": result.afterBytes,
    "items": result.items,
    "rings": result.ringMeta,
    "ringNames": result.ringNames
  })

proc localityReport*(db: KoutenDb): LocalityReport =
  ## 組み込み Store の WAL 物理配置を調べる。
  ## ringRuns が ringCount に近いほど、同じ ring の live record が物理的にもまとまっている。
  if db.mode != mEmbedded:
    raise newException(ValueError, "cluster connection cannot inspect local WAL locality")
  db.st.localityReport()

proc segmentStatus*(db: KoutenDb; staleRatioThreshold = 0.25;
                    minStaleRecords = 256): KoutenSegmentStatus =
  ## Inspect the ring-local derived read layout without modifying it.
  if db.mode != mEmbedded:
    raise newException(ValueError,
      "cluster connection cannot inspect local segment layout")
  let report = db.st.segmentReport(staleRatioThreshold, minStaleRecords)
  result.diskBacked = report.diskBacked
  result.segmentHits = report.segmentHits
  result.walFallbacks = report.walFallbacks
  result.walFallbackPointReads = report.walFallbackReasons[ssfrPointRead]
  result.walFallbackRingScans = report.walFallbackReasons[ssfrRingScan]
  result.walFallbackWindowReads = report.walFallbackReasons[ssfrWindowRead]
  result.recommendedRings = report.recommendedRings
  result.totalSegmentBytes = report.totalSegmentBytes
  result.totalIndexBytes = report.totalIndexBytes
  result.maxGeneration = report.maxGeneration
  for ring in report.rings:
    result.rings.add KoutenSegmentRingStatus(
      ring: db.ringNameOf(ring.ring), ringKey: ring.ring,
      generation: ring.generation, liveRecords: ring.liveRecords,
      coveredRecords: ring.coveredRecords,
      segmentRecords: ring.segmentRecords, staleRecords: ring.staleRecords,
      staleRatio: ring.staleRatio, segmentBytes: ring.segmentBytes,
      indexBytes: ring.indexBytes, packRecommended: ring.packRecommended)

proc segmentStatusJson*(status: KoutenSegmentStatus): JsonNode =
  ## Stable JSON boundary shared by the CLI and additive C ABI calls.
  var rings = newJArray()
  for ring in status.rings:
    rings.add %*{
      "ring": ring.ring,
      "ringKey": $ring.ringKey,
      "generation": $ring.generation,
      "liveRecords": ring.liveRecords,
      "coveredRecords": ring.coveredRecords,
      "segmentRecords": ring.segmentRecords,
      "staleRecords": ring.staleRecords,
      "staleRatio": ring.staleRatio,
      "segmentBytes": ring.segmentBytes,
      "indexBytes": ring.indexBytes,
      "packRecommended": ring.packRecommended
    }
  %*{
    "diskBacked": status.diskBacked,
    "recommendedRings": status.recommendedRings,
    "totalSegmentBytes": status.totalSegmentBytes,
    "totalIndexBytes": status.totalIndexBytes,
    "maxGeneration": $status.maxGeneration,
    "segmentHits": $status.segmentHits,
    "walFallbacks": $status.walFallbacks,
    "walFallbackReasons": {
      "point-read-failed": $status.walFallbackPointReads,
      "ring-scan-failed": $status.walFallbackRingScans,
      "window-read-failed": $status.walFallbackWindowReads
    },
    "rings": rings
  }

proc defaultSegmentMaintenancePolicy*(): KoutenSegmentMaintenancePolicy =
  ## Conservative defaults for one bounded maintenance pass. Automatic
  ## scheduling remains disabled unless the server is configured for it.
  KoutenSegmentMaintenancePolicy(
    staleRatioThreshold: 0.25,
    minStaleRecords: 256,
    maxRings: 1,
    maxBytes: 64'i64 * 1024 * 1024,
    maxElapsedMs: 1000)

proc validateSegmentMaintenancePolicy*(policy: KoutenSegmentMaintenancePolicy) =
  if policy.staleRatioThreshold < 0 or policy.staleRatioThreshold > 1:
    raise newException(KoutenValidationError,
      "staleRatioThreshold must be between 0 and 1")
  if policy.minStaleRecords < 0:
    raise newException(KoutenValidationError, "minStaleRecords must be >= 0")
  if policy.maxRings < 0:
    raise newException(KoutenValidationError, "maxRings must be >= 0")
  if policy.maxBytes < 0:
    raise newException(KoutenValidationError, "maxBytes must be >= 0")
  if policy.maxElapsedMs < 0:
    raise newException(KoutenValidationError, "maxElapsedMs must be >= 0")

proc planSegmentMaintenance*(st: Store;
    policy = defaultSegmentMaintenancePolicy()):
    KoutenSegmentMaintenanceResult =
  ## Produce the exact count/byte-budget selection used by execution. Elapsed
  ## time is enforced dynamically because it cannot be predicted by a dry run.
  validateSegmentMaintenancePolicy(policy)
  if not st.isPersistent or not st.diskBacked:
    raise newException(KoutenValidationError,
      "segment maintenance requires a persistent disk-backed store")
  let report = st.segmentReport(policy.staleRatioThreshold,
                                policy.minStaleRecords)
  result.dryRun = true
  result.outcome = "dry-run"
  result.recommendedRings = report.recommendedRings
  var selectedBytes = 0'i64
  for ring in report.rings:
    let estimatedBytes = ring.segmentBytes + ring.indexBytes
    var decision = KoutenSegmentMaintenanceDecision(
      ring: st.ringNames.getOrDefault(ring.ring, $ring.ring),
      ringKey: ring.ring,
      recommended: ring.packRecommended,
      staleRecords: ring.staleRecords,
      staleRatio: ring.staleRatio,
      estimatedBytes: estimatedBytes)
    if not ring.packRecommended:
      if ring.staleRecords < policy.minStaleRecords:
        decision.reason = "stale-records-below-minimum"
      else:
        decision.reason = "stale-ratio-below-threshold"
    elif policy.maxRings > 0 and result.selectedRings >= policy.maxRings:
      decision.reason = "ring-budget-exhausted"
    elif policy.maxBytes > 0 and
        estimatedBytes > policy.maxBytes - selectedBytes:
      decision.reason = "byte-budget-exhausted"
    else:
      decision.selected = true
      decision.reason = "selected"
      inc result.selectedRings
      selectedBytes += estimatedBytes
    result.decisions.add decision
  if result.selectedRings == 0:
    result.outcome = "no-work"

proc planSegmentMaintenance*(db: KoutenDb;
    policy = defaultSegmentMaintenancePolicy()):
    KoutenSegmentMaintenanceResult =
  if db.mode != mEmbedded:
    raise newException(KoutenValidationError,
      "cluster connection cannot maintain local segment layout")
  db.st.planSegmentMaintenance(policy)

proc segmentMaintenanceJson*(maintenance: KoutenSegmentMaintenanceResult;
    policy: KoutenSegmentMaintenancePolicy): JsonNode =
  var decisions = newJArray()
  for decision in maintenance.decisions:
    decisions.add %*{
      "ring": decision.ring,
      "ringKey": $decision.ringKey,
      "recommended": decision.recommended,
      "selected": decision.selected,
      "reasonCode": decision.reason,
      "reason": decision.reason,
      "cleanupReasonCode":
        (if decision.reason == "packed" and decision.filesRemoved > 0:
           "inactive-generations-removed"
         elif decision.reason == "packed": "no-inactive-generations"
         else: "not-run"),
      "staleRecords": decision.staleRecords,
      "staleRatio": decision.staleRatio,
      "estimatedBytes": decision.estimatedBytes,
      "recordsRewritten": decision.recordsRewritten,
      "bytesRewritten": decision.bytesRewritten,
      "filesRemoved": decision.filesRemoved,
      "error": decision.error
    }
  %*{
    "schema": "koutendb.segment-maintenance.v1",
    "outcome": maintenance.outcome,
    "dryRun": maintenance.dryRun,
    "startedAt": maintenance.startedAt,
    "finishedAt": maintenance.finishedAt,
    "elapsedMs": maintenance.elapsedMs,
    "recommendedRings": maintenance.recommendedRings,
    "selectedRings": maintenance.selectedRings,
    "packedRings": maintenance.packedRings,
    "recordsRewritten": maintenance.recordsRewritten,
    "bytesRewritten": maintenance.bytesRewritten,
    "filesRemoved": maintenance.filesRemoved,
    "stopReasonCode": maintenance.stopReason,
    "stopReason": maintenance.stopReason,
    "policy": {
      "staleRatioThreshold": policy.staleRatioThreshold,
      "minStaleRecords": policy.minStaleRecords,
      "maxRings": policy.maxRings,
      "maxBytes": policy.maxBytes,
      "maxElapsedMs": policy.maxElapsedMs
    },
    "decisions": decisions
  }

proc segmentMaintenanceStatus*(st: Store): JsonNode =
  let raw = st.readSegmentMaintenanceStatus()
  if raw.len == 0:
    return newJNull()
  try:
    result = parseJson(raw)
  except JsonParsingError as exc:
    raise newException(KoutenOperationError,
      "segment maintenance status is invalid: " & exc.msg)
  if result.kind != JObject or
      not result.hasKey("schema") or result["schema"].kind != JString or
      result["schema"].getStr() != "koutendb.segment-maintenance.v1" or
      not result.hasKey("outcome") or result["outcome"].kind != JString or
      result["outcome"].getStr() notin
        ["running", "completed", "partial", "interrupted", "failed", "no-work"]:
    raise newException(KoutenOperationError,
      "segment maintenance status has an unsupported schema or outcome")

proc segmentMaintenanceStatus*(db: KoutenDb): JsonNode =
  if db.mode != mEmbedded:
    raise newException(KoutenValidationError,
      "cluster connection cannot inspect local maintenance status")
  db.st.segmentMaintenanceStatus()

proc recoverInterruptedSegmentMaintenance*(st: Store): bool =
  ## Convert a durable running marker left by process termination into a
  ## stable interrupted outcome. Segment generation recovery remains handled
  ## by the manifest-last pack protocol.
  let status = st.segmentMaintenanceStatus()
  if status.kind != JObject or status{"outcome"}.getStr() != "running":
    return false
  status["outcome"] = %"interrupted"
  status["stopReason"] = %"process-terminated"
  status["finishedAt"] = %epochTime()
  st.writeSegmentMaintenanceStatus(pretty(status))
  true

proc recoverInterruptedSegmentMaintenance*(db: KoutenDb): bool =
  if db.mode != mEmbedded:
    raise newException(KoutenValidationError,
      "cluster connection cannot recover local maintenance status")
  db.st.recoverInterruptedSegmentMaintenance()

proc runSegmentMaintenance*(st: Store;
    policy = defaultSegmentMaintenancePolicy(); dryRun = false):
    KoutenSegmentMaintenanceResult {.discardable.} =
  ## Run one bounded maintenance pass. A byte/time interruption happens before
  ## manifest publication, so the previously complete generation remains
  ## active. Other selected rings are not attempted after an interruption or
  ## failure.
  result = st.planSegmentMaintenance(policy)
  result.startedAt = epochTime()
  if dryRun:
    result.dryRun = true
    result.finishedAt = epochTime()
    return

  if result.selectedRings == 0:
    result.dryRun = false
    result.finishedAt = epochTime()
    st.writeSegmentMaintenanceStatus(
      pretty(segmentMaintenanceJson(result, policy)))
    return

  result.dryRun = false
  result.outcome = "completed"
  var running = result
  running.outcome = "running"
  st.writeSegmentMaintenanceStatus(
    pretty(segmentMaintenanceJson(running, policy)))
  let startedMono = getMonoTime()
  var stopped = false
  for i in 0 ..< result.decisions.len:
    if not result.decisions[i].selected:
      continue
    if stopped:
      result.decisions[i].selected = false
      result.decisions[i].reason = "not-run-after-stop"
      continue
    let elapsed = (getMonoTime() - startedMono).inMilliseconds
    if policy.maxElapsedMs > 0 and elapsed >= policy.maxElapsedMs:
      result.decisions[i].selected = false
      result.decisions[i].reason = "elapsed-budget-exhausted"
      result.stopReason = result.decisions[i].reason
      result.outcome = if result.packedRings > 0: "partial" else: "interrupted"
      stopped = true
      continue
    let remainingBytes =
      if policy.maxBytes > 0: policy.maxBytes - result.bytesRewritten
      else: 0'i64
    let remainingMs =
      if policy.maxElapsedMs > 0: policy.maxElapsedMs - elapsed
      else: 0'i64
    try:
      let stats = st.packRingSegment(result.decisions[i].ringKey,
                                     remainingBytes, remainingMs)
      let rewritten = stats.bytes + stats.indexBytes
      result.decisions[i].reason = "packed"
      result.decisions[i].recordsRewritten = stats.records
      result.decisions[i].bytesRewritten = rewritten
      result.decisions[i].filesRemoved = stats.removedFiles
      result.recordsRewritten += stats.records
      result.bytesRewritten += rewritten
      result.filesRemoved += stats.removedFiles
      inc result.packedRings
    except SegmentPackLimitError as exc:
      result.decisions[i].reason =
        if exc.limitKind == splBytes: "interrupted-byte-budget"
        else: "interrupted-elapsed-budget"
      result.decisions[i].error = exc.msg
      result.stopReason = result.decisions[i].reason
      result.outcome = if result.packedRings > 0: "partial" else: "interrupted"
      stopped = true
    except CatchableError as exc:
      result.decisions[i].reason = "pack-failed"
      result.decisions[i].error = exc.msg
      result.stopReason = "pack-failed"
      result.outcome = "failed"
      stopped = true
  result.elapsedMs = (getMonoTime() - startedMono).inMilliseconds
  result.finishedAt = epochTime()
  st.writeSegmentMaintenanceStatus(
    pretty(segmentMaintenanceJson(result, policy)))

proc runSegmentMaintenance*(db: KoutenDb;
    policy = defaultSegmentMaintenancePolicy(); dryRun = false):
    KoutenSegmentMaintenanceResult {.discardable.} =
  if db.mode != mEmbedded:
    raise newException(KoutenValidationError,
      "cluster connection cannot maintain local segment layout")
  result = db.st.runSegmentMaintenance(policy, dryRun)
  if dryRun:
    return
  db.audit("segment-maintenance", ok = result.outcome != "failed",
           message = result.outcome, extra = %*{
    "selectedRings": result.selectedRings,
    "packedRings": result.packedRings,
    "recordsRewritten": result.recordsRewritten,
    "bytesRewritten": result.bytesRewritten,
    "elapsedMs": result.elapsedMs,
    "stopReason": result.stopReason
  })

proc checkpointStatusJson*(status: CheckpointStatus): JsonNode =
  var files = newJArray()
  for file in status.files:
    var entry = %*{
      "path": file.path,
      "kind": file.kind,
      "bytes": file.bytes,
      "checksum": file.checksum
    }
    if file.kind in ["segment", "segment-index"]:
      entry["ringKey"] = %($file.ring)
      entry["generation"] = %($file.generation)
    files.add entry
  %*{
    "schema": "koutendb.checkpoint-status.v1",
    "format": status.format,
    "id": status.id,
    "path": status.path,
    "createdAt": status.createdAt,
    "sourceWalHighWater": $status.sourceWalHighWater,
    "snapshotWalBytes": $status.snapshotWalBytes,
    "complete": status.complete,
    "verified": status.verified,
    "reasonCode": status.reasonCode,
    "reason": status.reason,
    "items": status.items,
    "tombstones": status.tombstones,
    "rings": status.rings,
    "files": files
  }

proc checkpointListJson*(root: string;
                         statuses: openArray[CheckpointStatus]): JsonNode =
  var entries = newJArray()
  for status in statuses:
    entries.add checkpointStatusJson(status)
  %*{
    "schema": "koutendb.checkpoint-list.v1",
    "root": root,
    "count": statuses.len,
    "checkpoints": entries
  }

proc checkpointCleanupJson*(stats: CheckpointCleanupStats): JsonNode =
  %*{
    "schema": "koutendb.checkpoint-cleanup.v1",
    "reasonCode": "cleanup-completed",
    "root": stats.root,
    "kept": stats.kept,
    "removed": stats.removed,
    "invalid": stats.invalid
  }

proc checkpointMetrics*(root: string): seq[string] =
  ## Aggregate checkpoint health without checkpoint-ID labels. The bounded
  ## shape is safe for regular Prometheus/OpenMetrics scrapes.
  let statuses = listCheckpoints(root)
  var verified = 0
  var invalid = 0
  var newestCreatedAt = 0.0
  var newestVerified = 0
  for status in statuses:
    if status.verified: inc verified else: inc invalid
    if status.createdAt >= newestCreatedAt:
      newestCreatedAt = status.createdAt
      newestVerified = if status.verified: 1 else: 0
  # A damaged manifest may hide its creation time. In that case KoutenDB
  # cannot prove that the newest generation is healthy, so report unhealthy.
  if invalid > 0:
    newestVerified = 0
  let newestAge =
    if newestCreatedAt > 0: max(0.0, epochTime() - newestCreatedAt)
    else: 0.0
  result.add "node 0 checkpointGenerations " & $statuses.len &
             " checkpointVerifiedGenerations " & $verified &
             " checkpointInvalidGenerations " & $invalid &
             " checkpointNewestCreatedAtSec " & $newestCreatedAt &
             " checkpointNewestAgeSec " & $newestAge &
             " checkpointNewestVerified " & $newestVerified

proc checkpointMetricsText*(root: string;
                            format = kmfPrometheus): string =
  formatMetricLines(checkpointMetrics(root), format)

proc createCheckpoint*(db: KoutenDb; root = ""; id = ""):
    CheckpointStatus =
  if db.mode != mEmbedded:
    raise newException(KoutenValidationError,
      "cluster connection cannot checkpoint remote stores")
  result = db.st.createCheckpoint(root, id)
  db.audit("checkpoint-create", extra = %*{
    "checkpointId": result.id,
    "path": result.path,
    "sourceWalHighWater": $result.sourceWalHighWater,
    "snapshotWalBytes": $result.snapshotWalBytes,
    "items": result.items,
    "rings": result.rings
  })

proc checkpointStatus*(checkpointDir: string): CheckpointStatus =
  store.checkpointStatus(checkpointDir)

proc verifyCheckpoint*(checkpointDir: string): CheckpointStatus =
  store.verifyCheckpoint(checkpointDir)

proc listCheckpoints*(root: string): seq[CheckpointStatus] =
  store.listCheckpoints(root)

proc cleanupCheckpoints*(root: string; keep = 2): CheckpointCleanupStats =
  store.cleanupCheckpoints(root, keep)

proc restoreCheckpoint*(checkpointDir, dataDir: string;
                        overwrite = false): CheckpointStatus =
  result = store.restoreCheckpoint(checkpointDir, dataDir, overwrite)
  appendAudit(dataDir, "checkpoint-restore", extra = %*{
    "checkpointId": result.id,
    "source": checkpointDir,
    "snapshotWalBytes": $result.snapshotWalBytes,
    "items": result.items,
    "rings": result.rings
  })

proc backup*(db: KoutenDb, dstDir: string): BackupStats =
  ## 現在の embedded Store 状態を compact 済み WAL として dstDir に退避する。
  if db.mode != mEmbedded:
    raise newException(ValueError, "cluster connection cannot backup remote stores")
  result = db.st.backup(dstDir)
  db.audit("backup", extra = %*{
    "destination": dstDir,
    "bytes": result.bytes,
    "items": result.items,
    "rings": result.ringMeta,
    "ringNames": result.ringNames
  })

proc backupEncrypted*(db: KoutenDb, dstDir, passphrase: string): BackupStats =
  ## 現在の embedded Store 状態を encrypted compact snapshot として dstDir に退避する。
  if db.mode != mEmbedded:
    raise newException(ValueError, "cluster connection cannot backup remote stores")
  result = db.st.backupEncrypted(dstDir, passphrase)
  db.audit("backup-encrypted", extra = %*{
    "destination": dstDir,
    "bytes": result.bytes,
    "items": result.items,
    "rings": result.ringMeta,
    "ringNames": result.ringNames
  })

proc verifyBackup*(backupDir: string): BackupStats =
  ## backupDir の WAL snapshot を復元前に strict 検証する。
  store.verifyBackup(backupDir)

proc verifyEncryptedBackup*(backupDir, passphrase: string): BackupStats =
  ## backupDir の encrypted backup を復号し、復元前に strict 検証する。
  store.verifyEncryptedBackup(backupDir, passphrase)

proc addOperationalCheck(report: var KoutenOperationalVerifyReport;
                         name: string; ok: bool; message: string) =
  report.checks.add KoutenOperationalCheck(name: name, ok: ok,
                                           message: message)
  if not ok:
    report.ok = false

proc operationalVerify*(dataDir: string; diskBacked = true;
                        verifySegments = false;
                        maxWalBytes: int64 = -1;
                        maxSegmentFiles = -1;
                        maxItems = -1;
                        maxRings = -1;
                        maxSegmentBytes: int64 = -1;
                        maxDeadRecords = -1;
                        maxDeadRatio = -1.0;
                        maxSegmentGeneration: int64 = -1;
                        staleRatioThreshold = 0.25;
                        minStaleRecords = 256): KoutenOperationalVerifyReport =
  ## Open and inspect a persistent embedded data directory for operational
  ## readiness checks. Opening the store exercises WAL replay, recovery gates,
  ## and the data-directory lock. Segment verification can rebuild the
  ## rebuildable read layout; the WAL remains the source of truth.
  if dataDir.len == 0:
    raise newException(ValueError, "operationalVerify requires dataDir")

  result.ok = true
  result.dataDir = dataDir
  result.walPath = dataDir / "kouten.log"
  result.walExists = fileExists(result.walPath)
  if result.walExists:
    result.walBytes = getFileSize(result.walPath)
  result.addOperationalCheck("data-dir", dirExists(dataDir), dataDir)
  result.addOperationalCheck("wal-file", result.walExists, result.walPath)
  if maxWalBytes >= 0:
    result.addOperationalCheck("wal-bytes-limit",
      result.walBytes <= maxWalBytes,
      "bytes=" & $result.walBytes & " max=" & $maxWalBytes)

  var db = open(dataDir = dataDir, diskBacked = diskBacked)
  try:
    result.persistent = true
    result.diskBacked = db.st.diskBacked
    result.items =
      if db.st.diskBacked: db.st.itemOffsets.len
      else: db.st.items.len
    result.rings = db.st.ringMeta.len
    result.ringNames = db.st.ringNames.len
    result.vectors = db.st.vectorCount
    result.galaxy = db.st.galaxy
    result.segmentDir = dataDir / "segments"
    result.segmentDirExists = dirExists(result.segmentDir)
    if result.segmentDirExists:
      for kind, path in walkDir(result.segmentDir):
        if kind == pcFile and path.endsWith(".seg"):
          inc result.segmentFiles
    result.locality = db.localityReport()
    result.addOperationalCheck("open-replay-lock", true, "opened and replayed WAL")
    result.addOperationalCheck("metadata", true,
      "items=" & $result.items & " rings=" & $result.rings &
      " ringNames=" & $result.ringNames)
    if maxItems >= 0:
      result.addOperationalCheck("items-limit",
        result.items <= maxItems,
        "items=" & $result.items & " max=" & $maxItems)
    if maxRings >= 0:
      result.addOperationalCheck("rings-limit",
        result.rings <= maxRings,
        "rings=" & $result.rings & " max=" & $maxRings)
    result.addOperationalCheck("locality-report", true,
      "ringRuns=" & $result.locality.ringRuns &
      " localityScore=" & $result.locality.localityScore)
    if verifySegments:
      let packStats = db.st.rebuildRingSegments()
      result.segmentPackRecords = packStats.records
      result.segmentDirExists = dirExists(result.segmentDir)
      result.segmentFiles = 0
      if result.segmentDirExists:
        for kind, path in walkDir(result.segmentDir):
          if kind == pcFile and path.endsWith(".seg"):
            inc result.segmentFiles
      result.addOperationalCheck("segments", true,
        "rebuiltRecords=" & $packStats.records &
        " files=" & $result.segmentFiles)
    elif result.diskBacked:
      result.addOperationalCheck("segments", result.segmentDirExists,
        if result.segmentDirExists: "present files=" & $result.segmentFiles
        else: "missing; run verify --segments to rebuild")
    result.segmentStatus = db.segmentStatus(staleRatioThreshold,
                                            minStaleRecords)
    if maxSegmentFiles >= 0:
      result.addOperationalCheck("segment-files-limit",
        result.segmentFiles <= maxSegmentFiles,
        "files=" & $result.segmentFiles & " max=" & $maxSegmentFiles)
    if maxSegmentBytes >= 0:
      let totalBytes = result.segmentStatus.totalSegmentBytes +
                       result.segmentStatus.totalIndexBytes
      result.addOperationalCheck("segment-bytes-limit",
        totalBytes <= maxSegmentBytes,
        "bytes=" & $totalBytes & " max=" & $maxSegmentBytes)
    if maxDeadRecords >= 0:
      result.addOperationalCheck("dead-records-limit",
        result.locality.deadParticleRecords <= maxDeadRecords,
        "records=" & $result.locality.deadParticleRecords &
        " max=" & $maxDeadRecords)
    if maxDeadRatio >= 0:
      if maxDeadRatio > 1:
        raise newException(ValueError, "maxDeadRatio must be between 0 and 1")
      let deadRatio =
        if result.locality.totalParticleRecords == 0: 0.0
        else: float(result.locality.deadParticleRecords) /
              float(result.locality.totalParticleRecords)
      result.addOperationalCheck("dead-record-ratio-limit",
        deadRatio <= maxDeadRatio,
        "ratio=" & $deadRatio & " max=" & $maxDeadRatio)
    if maxSegmentGeneration >= 0:
      result.addOperationalCheck("segment-generation-limit",
        result.segmentStatus.maxGeneration <= maxSegmentGeneration.uint64,
        "generation=" & $result.segmentStatus.maxGeneration &
        " max=" & $maxSegmentGeneration)
  finally:
    db.close()

proc restoreBackup*(backupDir, dataDir: string, overwrite = false,
                    durability: KoutenDurability = durBuffered): BackupStats =
  ## backupDir の WAL を dataDir へ復元する。dataDir が既存の場合は overwrite が必要。
  result = store.restoreBackup(backupDir, dataDir, overwrite = overwrite,
                               durability = durability)
  appendAudit(dataDir, "restore", extra = %*{
    "source": backupDir,
    "bytes": result.bytes,
    "items": result.items,
    "rings": result.ringMeta,
    "ringNames": result.ringNames
  })

proc restoreEncryptedBackup*(backupDir, dataDir, passphrase: string,
                             overwrite = false,
                             durability: KoutenDurability = durBuffered): BackupStats =
  ## backupDir の encrypted backup を dataDir へ復元する。
  result = store.restoreEncryptedBackup(backupDir, dataDir, passphrase,
                                        overwrite = overwrite,
                                        durability = durability)
  appendAudit(dataDir, "restore-encrypted", extra = %*{
    "source": backupDir,
    "bytes": result.bytes,
    "items": result.items,
    "rings": result.ringMeta,
    "ringNames": result.ringNames
  })

proc writeDumpLine(outFile: File, node: JsonNode): BiggestInt =
  let line = $node
  outFile.write(line)
  outFile.write("\n")
  line.len + 1

proc dump*(db: KoutenDb, path: string = "", includeVectors = true): DumpStats =
  ## embedded DB を JSON Lines として dump する。
  ## backup/restore は復旧用、dump は監査・移行・デバッグ用の可読 export。
  if db.mode != mEmbedded:
    raise newException(ValueError, "cluster connection cannot dump remote stores")

  var outFile: File
  let toStdout = path.len == 0 or path == "-"
  if toStdout:
    outFile = stdout
    result.destination = "stdout"
  else:
    let parent = parentDir(path)
    if parent.len > 0:
      createDir(parent)
    outFile = open(path, fmWrite)
    result.destination = path

  try:
    result.bytes += writeDumpLine(outFile, %*{
      "type": "meta",
      "format": "koutendb.dump.v1",
      "galaxy": db.st.galaxy,
      "epoch": db.tbl.epoch,
      "nodes": db.tbl.nNodes,
      "documents": db.st.count(),
      "rings": db.rings.len
    })
    inc result.records
    for ringKey, info in db.rings:
      result.bytes += writeDumpLine(outFile, %*{
        "type": "ring",
        "key": $ringKey,
        "name": db.ringNameOf(ringKey),
        "period": info.period,
        "head": info.headAngle
      })
      inc result.records
      inc result.rings
    for p in db.st.allParticles():
      var doc = %*{
        "type": "document",
        "id": $(KoutenId(parent: p.parent, epoch: db.tbl.epoch,
                       seq: p.seq, tWrite: p.tWrite)),
        "parent": $p.parent,
        "seq": p.seq,
        "epoch": db.tbl.epoch,
        "tWrite": p.tWrite,
        "ring": db.ringNameOf(p.parent),
        "period": p.period,
        "head": p.head,
        "payload": p.payload,
        "codec": payloadCodecName(p.codec)
      }
      if includeVectors:
        doc["vec"] = %p.vec
      result.bytes += writeDumpLine(outFile, doc)
      inc result.records
      inc result.documents
  finally:
    if not toStdout:
      outFile.close()

proc jsonPath(node: JsonNode, path: string): JsonNode =
  if path.len == 0:
    return node
  result = node
  for part in path.split('.'):
    if result.isNil or result.kind != JObject or not result.hasKey(part):
      return nil
    result = result[part]

proc pathString(node: JsonNode, path: string): string =
  let v = jsonPath(node, path)
  if v.isNil:
    return ""
  case v.kind
  of JString:
    v.getStr()
  of JInt:
    $v.getInt()
  of JFloat:
    $v.getFloat()
  of JBool:
    $v.getBool()
  else:
    ""

proc pathPayload(node: JsonNode, path: string): string =
  let v = jsonPath(node, path)
  if v.isNil:
    return ""
  if v.kind == JString: v.getStr() else: $v

proc pathVector(node: JsonNode, path: string): seq[float32] =
  if path.len == 0:
    return @[]
  let v = jsonPath(node, path)
  if v.isNil or v.kind != JArray:
    return @[]
  for item in v:
    case item.kind
    of JInt:
      result.add float32(item.getInt())
    of JFloat:
      result.add float32(item.getFloat())
    else:
      return @[]

proc importJsonl*(db: KoutenDb, path: string, defaultRing = "imported",
                  ringField = "", ringPrefix = "", payloadField = "",
                  vecField = "", maxRecords = 0,
                  batchSize = 1000,
                  packSegments = false): ImportStats =
  ## JSON Lines を読み込み、ringField の値で ring に割り振りながら保存する。
  ## MongoDB export のような 1 行 1 JSON ドキュメントの移行入口。
  if db.mode != mEmbedded:
    raise newException(ValueError, "cluster connection cannot import JSONL directly")
  if path.len == 0:
    raise newException(ValueError, "import path is empty")
  if batchSize < 0:
    raise newException(ValueError, "batchSize must be >= 0")
  result.source = path
  result.defaultRing = defaultRing
  result.batchSize = batchSize
  var seenRings = initTable[string, bool]()
  var koutenDumpMode = false
  var batchCount = 0
  var stagedRingNames = initTable[uint64, bool]()
  var stagedRingMeta = initTable[uint64, bool]()
  let effectiveBatchSize =
    if batchSize <= 0: 1
    else: batchSize
  var tx = db.st.beginTxn()
  var staged: seq[Particle]

  proc commitBatch() =
    if staged.len == 0:
      tx.rollback()
      tx = db.st.beginTxn()
      return
    tx.commit()
    # Disk-backed transactions update the ring-local segment cache during
    # commit.  The retained option is accepted for source compatibility.
    discard packSegments
    if not db.st.diskBacked:
      for p in staged:
        db.vectorBackend.upsert p
    staged.setLen(0)
    stagedRingNames.clear()
    stagedRingMeta.clear()
    inc batchCount
    tx = db.st.beginTxn()

  proc stagePut(encoded: EncodedPayload, ring: string, vec: seq[float32]) =
    let key = db.ringKey(ring, persist = false)
    let ri = db.rings[key]
    if not stagedRingNames.getOrDefault(key, false) and
        db.st.ringNames.getOrDefault(key, "") != ring:
      tx.putRingName(key, ring)
      stagedRingNames[key] = true
    if not stagedRingMeta.getOrDefault(key, false) and
        key notin db.st.ringMeta:
      tx.putRingMeta(key, ri.period, ri.headAngle)
      stagedRingMeta[key] = true
    let seq = db.st.nextSeq(key)
    let p = Particle(parent: key, seq: seq, period: ri.period,
                     head: ri.headAngle, tWrite: db.clock,
                     payload: encoded.data, codec: encoded.codec,
                     vec: vec.normalize())
    tx.upsert p
    staged.add p
    if staged.len >= effectiveBatchSize:
      commitBatch()

  try:
    for line in lines(path):
      if maxRecords > 0 and result.read >= maxRecords:
        break
      inc result.read
      let trimmed = line.strip()
      if trimmed.len == 0:
        inc result.skipped
        continue
      try:
        let node = parseJson(trimmed)
        let nodeType =
          if node.kind == JObject and node.hasKey("type"): node["type"].getStr()
          else: ""
        if nodeType == "meta" and
            node{"format"}.getStr("") == "koutendb.dump.v1":
          koutenDumpMode = true
          inc result.skipped
          continue
        if nodeType == "ring" and
            (koutenDumpMode or
             (node.hasKey("key") and node.hasKey("name") and
              node.hasKey("period") and node.hasKey("head"))):
          inc result.skipped
          continue
        if nodeType == "document" and node.hasKey("ring") and node.hasKey("payload"):
          let ring = node["ring"].getStr(defaultRing)
          let codec =
            if node.hasKey("codec"): parsePayloadCodec(node["codec"].getStr("raw"))
            else: pcRaw
          stagePut(encodedPayload(node["payload"].getStr(), codec),
                   ring,
                   pathVector(node, "vec"))
          seenRings[ring] = true
          inc result.imported
          continue
        var ring =
          if ringField.len > 0: pathString(node, ringField) else: ""
        if ring.len == 0:
          ring = defaultRing
        if ringPrefix.len > 0:
          ring = ringPrefix & ring
        let payload = pathPayload(node, payloadField)
        if payload.len == 0:
          inc result.skipped
          continue
        stagePut(encodedPayload(payload),
                 ring,
                 pathVector(node, vecField))
        seenRings[ring] = true
        inc result.imported
      except CatchableError:
        inc result.errors
    commitBatch()
  except CatchableError:
    tx.rollback()
    raise
  result.rings = seenRings.len
  result.batches = batchCount

proc clampTopRings*(topRings: int): int

proc packDiskBackedSegments*(db: KoutenDb): SegmentPackStats {.discardable.} =
  ## Build ring-local physical segment files for disk-backed embedded reads.
  ## WAL remains the source of truth; segments are rebuildable read layout.
  doAssert db.mode == mEmbedded, "packDiskBackedSegments は組み込みモード専用"
  if db.st.diskBacked:
    result = db.st.rebuildRingSegments()

proc packDiskBackedRing*(db: KoutenDb, ring: string): SegmentPackStats {.discardable.} =
  ## Merge one ring into a new complete segment generation without rewriting
  ## unrelated rings.
  doAssert db.mode == mEmbedded, "packDiskBackedRing は組み込みモード専用"
  if db.st.diskBacked:
    result = db.st.packRingSegment(db.ringKey(ring, persist = false))

proc packRecommendedDiskBackedRings*(db: KoutenDb;
                                     staleRatioThreshold = 0.25;
                                     minStaleRecords = 256;
                                     maxRings = 0): SegmentPackStats {.discardable.} =
  ## Pack only rings selected by the current segment diagnostic. maxRings=0
  ## means no count limit. Invocation is explicit so applications can schedule
  ## the I/O during their own maintenance window.
  if db.mode != mEmbedded:
    raise newException(ValueError,
      "cluster connection cannot pack local segment layout")
  if not db.st.diskBacked:
    return
  if maxRings < 0:
    raise newException(ValueError, "maxRings must be >= 0")
  let report = db.st.segmentReport(staleRatioThreshold, minStaleRecords)
  var packed = 0
  for ring in report.rings:
    if not ring.packRecommended:
      continue
    if maxRings > 0 and packed >= maxRings:
      break
    let stats = db.st.packRingSegment(ring.ring)
    result.records += stats.records
    result.rings += stats.rings
    result.bytes += stats.bytes
    result.indexBytes += stats.indexBytes
    result.removedFiles += stats.removedFiles
    inc packed

proc configurePlannerBackend*(db: KoutenDb, kind: PlannerBackendKind) =
  ## retrieval planner backend を選ぶ。
  ## KoutenDB core は deterministic heuristic planner を使う。
  case kind
  of pbHeuristic:
    db.plannerBackend = newHeuristicPlannerBackend()

proc sanitizeRetrievalTuning(t: RetrievalTuning): RetrievalTuning =
  result = t
  result.budget = max(1, t.budget)
  result.focus = max(0, min(100, t.focus))
  result.topRings = clampTopRings(t.topRings)
  result.branchBudget = max(0, t.branchBudget)
  result.maxDepth = max(0, t.maxDepth)

proc configureRetrievalTuning*(db: KoutenDb, profile: string,
                               tuning: RetrievalTuning) =
  ## SQL tuning profile のように retrieval 既定値を名前付きで登録する。
  ## 例: "latency", "recall", "rag-low-token"。
  if profile.len == 0:
    raise newException(ValueError, "retrieval tuning profile name is empty")
  db.retrievalTunings[profile] = sanitizeRetrievalTuning(tuning)

proc configureSearchProfile*(db: KoutenDb, name: string,
                             profile: SearchProfile) =
  ## 人間向けの検索 profile を登録する。
  ## 例: amount=raFew, scope=ssTight, depth=sdShallow。
  if name.len == 0:
    raise newException(ValueError, "search profile name is empty")
  db.searchProfiles[name] = profile
  db.configureRetrievalTuning(name, profile.tuningFromSearchProfile())

proc retrievalTuning*(db: KoutenDb, profile = "default"): RetrievalTuning =
  if profile in db.retrievalTunings:
    db.retrievalTunings[profile]
  else:
    defaultRetrievalTuning()

proc nowT(db: KoutenDb): float {.inline.} =
  case db.mode
  of mEmbedded: db.clock
  of mCluster: epochTime()

proc now*(db: KoutenDb): float =
  ## DB 時計の現在時刻 [s]。組み込み=手動クロック、クラスタ=実時間。
  db.nowT

proc advance*(db: KoutenDb, dt: float) =
  ## 時計を dt 秒進める（組み込みモード専用。クラスタは実時間で回る）。
  doAssert db.mode == mEmbedded, "advance は組み込みモード専用（クラスタは実時間）"
  db.clock += dt

# ---------------------------------------------------------------- 内部

proc parentRingName(name: string): string =
  let pos = name.rfind('/')
  if pos <= 0: "" else: name[0 ..< pos]

proc addRingChild(db: KoutenDb, parent, child: uint64) =
  var children = db.ringChildren.getOrDefault(parent, @[])
  if child notin children:
    children.add child
    db.ringChildren[parent] = children

proc ringKey(db: KoutenDb, name: string, persist = true): uint64 =
  if name == "halo":
    result = HaloKey
    if result notin db.rings:
      db.rings[result] = RingInfo(period: HaloPeriod, headAngle: 0.0)
    if persist and db.mode == mEmbedded and result notin db.st.ringMeta:
      db.st.putRingMeta(result, db.rings[result].period, db.rings[result].headAngle)
    if persist and db.mode == mEmbedded:
      db.st.putRingName(result, name)
    db.ringNames[name] = result
    db.ringKeyNames[result] = name
    db.lastRingName = name
    db.lastRingKey = result
    return
  if name == db.lastRingName:
    result = db.lastRingKey
    if persist and db.mode == mEmbedded and result in db.rings and
        result notin db.st.ringMeta:
      db.st.putRingMeta(result, db.rings[result].period, db.rings[result].headAngle)
    return
  if name in db.ringNames:
    result = db.ringNames[name]
  else:
    result = uint64(hash(name)) or 1'u64   # 0 を避ける
    db.ringNames[name] = result
    db.ringKeyNames[result] = name
    if db.mode == mEmbedded and persist:
      db.st.putRingName(result, name)
    if result notin db.rings:
      # ヘッド角は名前から決定論的に散らす（環ごとに書き込み先ノードが分散する）
      let info = RingInfo(period: DefaultPeriod,
                          headAngle: float(result mod 628) / 100.0)
      db.rings[result] = info
      if db.mode == mEmbedded and persist:
        db.st.putRingMeta(result, info.period, info.headAngle)
    elif persist and db.mode == mEmbedded and result notin db.st.ringMeta:
      db.st.putRingMeta(result, db.rings[result].period, db.rings[result].headAngle)
  let parentName = parentRingName(name)
  if parentName.len > 0:
    let parentKey = db.ringKey(parentName, persist)
    db.addRingChild(parentKey, result)
  db.lastRingName = name
  db.lastRingKey = result

proc orbitOf(db: KoutenDb, id: KoutenId): Orbit =
  let ri = db.rings[id.parent]
  OrbitalId(parent: id.parent, epoch: id.epoch, tWrite: id.tWrite, seq: id.seq)
    .ringOrbit(ri.period, ri.headAngle)

# ---------------------------------------------------------------- 設定と書き込み

proc configureRing*(db: KoutenDb, ring: string, period: float) =
  ## 環の公転周期を設定（省略時 60s）。JOIN したい2環は 1:2 等の整数比にすると
  ## 会合が規則化される（設計書 §8）。put より先に呼ぶこと（周期は ID の意味を変える）。
  let key = db.ringKey(ring)
  db.rings[key].period = period
  if db.mode == mEmbedded:
    db.st.putRingMeta(key, period, db.rings[key].headAngle)

proc configureWriteAckMode*(db: KoutenDb, mode: WriteAckMode) =
  ## cluster transaction / update / delete の既定応答タイミング。
  ## wamAccepted は landing intent 受付で返し、wamApplied は owner apply まで待つ。
  db.defaultWriteAckMode = mode

proc configureRingWriteAckMode*(db: KoutenDb, ring: string,
                                mode: WriteAckMode) =
  ## ring ごとに応答タイミングを上書きする。
  ## 厳密に read-visible になってから返したい ring だけ wamApplied にできる。
  let key = db.ringKey(ring)
  db.ringWriteAckModes[key] = mode

proc configureRingApplyPolicy*(db: KoutenDb, ring: string,
                               policy: RingApplyPolicy) =
  ## universe sync / delayed apply の ring-local policy を設定する。
  ## データ構造は縛らず、同期・履歴・適用順の扱いだけを ring ごとに変える。
  if policy.historyKeep < 0:
    raise newException(KoutenValidationError, "historyKeep must be >= 0")
  if policy.delayMs < 0:
    raise newException(KoutenValidationError, "delayMs must be >= 0")
  let key = db.ringKey(ring)
  db.ringApplyPolicies[key] = policy

proc ringApplyPolicy*(db: KoutenDb, ring: string): RingApplyPolicy =
  let key = db.ringKeyForRead(ring)
  db.ringApplyPolicies.getOrDefault(key, defaultRingApplyPolicy())

proc configureGuardrails*(db: KoutenDb, guardrails: KoutenGuardrails) =
  ## Configure opt-in write-path limits. Zero fields are disabled.
  if guardrails.maxPayloadBytes < 0:
    raise newException(KoutenValidationError, "maxPayloadBytes must be >= 0")
  if guardrails.maxVectorDim < 0:
    raise newException(KoutenValidationError, "maxVectorDim must be >= 0")
  if guardrails.maxRingCount < 0:
    raise newException(KoutenValidationError, "maxRingCount must be >= 0")
  if guardrails.maxRecordsPerRing < 0:
    raise newException(KoutenValidationError, "maxRecordsPerRing must be >= 0")
  db.guardrails = guardrails

proc guardrails*(db: KoutenDb): KoutenGuardrails =
  db.guardrails

proc writeAckModeForRing(db: KoutenDb, ringKey: uint64): WriteAckMode =
  db.ringWriteAckModes.getOrDefault(ringKey, db.defaultWriteAckMode)

proc writeAckModeForOps(db: KoutenDb, ops: seq[TxWireOp]): WriteAckMode =
  if ops.len == 0:
    return db.defaultWriteAckMode
  result = wamAccepted
  for op in ops:
    if db.writeAckModeForRing(op.parent) == wamApplied:
      return wamApplied

proc markPendingLandingReads(db: KoutenDb, ops: seq[TxWireOp]) =
  if db.mode != mCluster:
    return
  for op in ops:
    db.pendingLandingReads[(op.parent, op.seq)] = true

proc clearPendingLandingRead(db: KoutenDb, id: KoutenId) =
  if db.mode == mCluster:
    db.pendingLandingReads.del((id.parent, id.seq))

proc hasPendingLandingRead(db: KoutenDb, id: KoutenId): bool =
  db.mode == mCluster and db.pendingLandingReads.getOrDefault((id.parent, id.seq), false)

proc waitClusterTxApplied*(db: KoutenDb, txid: uint64, timeoutMs = 10_000,
                           pollMs = 20): bool =
  ## cluster landing intent が owner に apply されるまで待つ。
  ## timeout 時は false。呼び出し側は accepted 済みとして後で status / get を再試行できる。
  doAssert db.mode == mCluster, "waitClusterTxApplied は cluster mode 専用"
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while epochTime() <= deadline:
    let status = db.client.txStatusReq(0, txid)
    if status == "APPLIED":
      return true
    if status == "UNKNOWN":
      return false
    sleep(max(1, pollMs))
  false

proc liveRecordsInEmbeddedRing(db: KoutenDb, ringKey: uint64): int =
  if db.mode != mEmbedded:
    return 0
  for itemKey in db.st.itemsByRing.getOrDefault(ringKey, @[]):
    if db.st.contains(itemKey[0], itemKey[1]):
      inc result

proc checkPayloadGuardrails(db: KoutenDb, encoded: EncodedPayload,
                            vecLen: int) =
  let g = db.guardrails
  if g.maxPayloadBytes > 0 and encoded.data.len > g.maxPayloadBytes:
    inc db.guardrailDenials[kgrPayloadBytes]
    db.audit("guardrail-denied", ok = false,
             message = "payload exceeds maxPayloadBytes",
             extra = %*{"maxPayloadBytes": g.maxPayloadBytes,
                        "payloadBytes": encoded.data.len})
    raise newException(KoutenGuardrailError,
      "payload exceeds maxPayloadBytes " & $g.maxPayloadBytes)
  if g.maxVectorDim > 0 and vecLen > g.maxVectorDim:
    inc db.guardrailDenials[kgrVectorDimension]
    db.audit("guardrail-denied", ok = false,
             message = "vector dimension exceeds maxVectorDim",
             extra = %*{"maxVectorDim": g.maxVectorDim,
                        "vectorDim": vecLen})
    raise newException(KoutenGuardrailError,
      "vector dimension exceeds maxVectorDim " & $g.maxVectorDim)

proc checkWriteGuardrails(db: KoutenDb, encoded: EncodedPayload,
                          ring: string, vecLen: int) =
  db.checkPayloadGuardrails(encoded, vecLen)
  let g = db.guardrails
  if g.maxRingCount > 0 and ring notin db.ringNames and
      db.ringNames.len >= g.maxRingCount:
    inc db.guardrailDenials[kgrRingCount]
    db.audit("guardrail-denied", ok = false, ring = ring,
             message = "ring count exceeds maxRingCount",
             extra = %*{"maxRingCount": g.maxRingCount,
                        "ringCount": db.ringNames.len})
    raise newException(KoutenGuardrailError,
      "ring count exceeds maxRingCount " & $g.maxRingCount)
  if g.maxRecordsPerRing > 0 and db.mode == mEmbedded and ring in db.ringNames:
    let key = db.ringNames[ring]
    if db.liveRecordsInEmbeddedRing(key) >= g.maxRecordsPerRing:
      inc db.guardrailDenials[kgrRecordsPerRing]
      db.audit("guardrail-denied", ok = false, ring = ring,
               message = "ring records exceed maxRecordsPerRing",
               extra = %*{"maxRecordsPerRing": g.maxRecordsPerRing,
                          "records": db.liveRecordsInEmbeddedRing(key)})
      raise newException(KoutenGuardrailError,
        "ring records exceed maxRecordsPerRing " & $g.maxRecordsPerRing)

proc put*(db: KoutenDb, encoded: EncodedPayload, ring: string = "default",
          vec: seq[float32] = @[]): KoutenId =
  ## 書き込み。環は初回利用時に自動作成。
  ## 返る ID を持っていれば、所在は誰にも問い合わせずいつでも計算できる。
  db.checkWriteGuardrails(encoded, ring, vec.len)
  let key = db.ringKey(ring)
  let ri = db.rings[key]
  let normVec = vec.normalize()
  case db.mode
  of mEmbedded:
    let seq = db.st.nextSeq(key)
    result = KoutenId(parent: key, epoch: db.tbl.epoch, seq: seq, tWrite: db.clock)
    let p = Particle(parent: key, seq: seq, period: ri.period,
                     head: ri.headAngle, tWrite: db.clock, payload: encoded.data,
                     codec: encoded.codec,
                     vec: normVec)
    db.st.upsert p
    if not db.st.diskBacked:
      db.vectorBackend.upsert p
    db.audit("put", ring = ring, id = $result,
             extra = %*{"payloadBytes": encoded.data.len,
                        "vectorDim": vec.len,
                        "codec": $encoded.codec})
  of mCluster:
    # Stable physical ring owner. Logical orbit timing is independent.
    let node = int(db.tbl.placementOwner(key))
    let (seq, tWrite) = db.client.putReq(node, key, ri.period, ri.headAngle,
                                         encoded.data, normVec, encoded.codec)
    result = KoutenId(parent: key, epoch: db.tbl.epoch, seq: seq, tWrite: tWrite)

proc put*(db: KoutenDb, payload: string, ring: string = "default",
          vec: seq[float32] = @[]): KoutenId =
  db.put(encodedPayload(payload), ring, vec)

proc putUsingRingProfile*(db: KoutenDb, payload: string,
                          ring: string = "default",
                          vec: seq[float32] = @[]): KoutenId =
  ## Uses the ring's declared default codec. The ordinary string overload
  ## remains raw for backwards compatibility.
  db.put(encodedPayload(payload, db.ringPayloadProfile(ring).defaultCodec),
         ring, vec)

proc timeJsonPayload(payload: string, timestampMs: int64): EncodedPayload =
  ## Time writes keep JSON queryable by adding event/ingest timestamps when the
  ## payload is a JSON object. Non-JSON payloads stay raw and are bucket-local.
  try:
    var node = parseJson(payload)
    if node.kind == JObject:
      if not node.hasKey("eventTimeMs"):
        node["eventTimeMs"] = %timestampMs
      if not node.hasKey("ingestTimeMs"):
        node["ingestTimeMs"] = %(int64(epochTime() * 1000.0))
      return encodedPayload($node, pcJson)
  except JsonParsingError:
    discard
  encodedPayload(payload, pcRaw)

proc putTime*(db: KoutenDb, payload: string, ring: string,
              timestampMs: int64, vec: seq[float32] = @[]): KoutenId =
  ## Store a log/event payload into the ring's calculated time-orbit coordinate.
  let profile = db.timeOrbitProfile(ring)
  db.put(timeJsonPayload(payload, timestampMs),
         ring = timeOrbitRing(ring, profile, timestampMs),
         vec = vec)

proc putTime*(db: KoutenDb, doc: JsonNode, ring: string,
              timestampMs: int64, vec: seq[float32] = @[]): KoutenId =
  db.putTime($doc, ring, timestampMs, vec)

proc put*(db: KoutenDb, doc: JsonNode, ring: string = "default",
          vec: seq[float32] = @[]): KoutenId =
  ## 構造化ドキュメントの書き込み。query（選択取得）の対象になる。
  db.put(encodedPayload($doc, pcJson), ring, vec)

proc putSynced*(db: KoutenDb, encoded: EncodedPayload,
                sourceUniverse, sourceGalaxy: string,
                ring: string = "default", vec: seq[float32] = @[],
                logicalKey = ""): KoutenId =
  ## embedded put と universe outbox 登録を同時に行う。
  ## 既存 put の意味は変えず、Universe 同期したい write path だけで使う。
  doAssert db.mode == mEmbedded, "putSynced は embedded mode 専用"
  db.checkWriteGuardrails(encoded, ring, vec.len)
  let key = db.ringKey(ring, persist = false)
  let ri = db.rings[key]
  let normVec = vec.normalize()
  let tx = db.st.beginTxn()
  var committed = false
  try:
    if db.st.ringNames.getOrDefault(key, "") != ring:
      tx.putRingName(key, ring)
    if key notin db.st.ringMeta:
      tx.putRingMeta(key, ri.period, ri.headAngle)
    let seq = db.st.nextSeq(key)
    result = KoutenId(parent: key, epoch: db.tbl.epoch, seq: seq,
                     tWrite: db.clock)
    tx.upsert Particle(parent: key, seq: seq, period: ri.period,
                       head: ri.headAngle, tWrite: db.clock,
                       payload: encoded.data, codec: encoded.codec,
                       vec: normVec)
    let staged = db.stageUniverseSyncEvent(tx,
      sourceUniverse = sourceUniverse,
      sourceGalaxy = sourceGalaxy,
      ring = ring,
      payload = encoded.data,
      vec = vec,
      codec = encoded.codec,
      logicalKey = logicalKey,
      timestamp = epochTime())
    tx.commit()
    committed = true
    for idx in staged.removed:
      db.universeSyncEvents.delete(idx)
    db.universeSyncEvents.add staged.event
    db.audit("put-synced", ring = ring, id = $result,
             extra = %*{"payloadBytes": encoded.data.len,
                        "vectorDim": vec.len,
                        "codec": $encoded.codec,
                        "sourceUniverse": sourceUniverse,
                        "sourceGalaxy": sourceGalaxy})
  except CatchableError:
    if not committed:
      tx.rollback()
    raise

proc putSynced*(db: KoutenDb, payload: string, sourceUniverse, sourceGalaxy: string,
                ring: string = "default", vec: seq[float32] = @[],
                logicalKey = ""): KoutenId =
  db.putSynced(encodedPayload(payload), sourceUniverse, sourceGalaxy,
               ring, vec, logicalKey)

proc putSynced*(db: KoutenDb, doc: JsonNode, sourceUniverse, sourceGalaxy: string,
                ring: string = "default", vec: seq[float32] = @[],
                logicalKey = ""): KoutenId =
  db.putSynced(encodedPayload($doc, pcJson), sourceUniverse = sourceUniverse,
               sourceGalaxy = sourceGalaxy, ring = ring, vec = vec,
               logicalKey = logicalKey)

# ---------------------------------------------------------------- トランザクション

proc beginTransaction*(db: KoutenDb): KoutenTx =
  ## transaction を開始する。
  ## embedded: 単一 Store atomic transaction。
  ## cluster: node0 landing zone に commit intent を置き、各 owner へ非同期 apply。
  case db.mode
  of mEmbedded:
    KoutenTx(db: db, tx: db.st.beginTxn())
  of mCluster:
    KoutenTx(db: db, clusterTxId: db.client.txBeginReq(0))

proc put*(tx: KoutenTx, encoded: EncodedPayload, ring: string = "default",
          vec: seq[float32] = @[]): KoutenId =
  ## transaction 内の書き込み。commit まで DB 本体には見えない。
  doAssert not tx.closed, "transaction is closed"
  tx.db.checkWriteGuardrails(encoded, ring, vec.len)
  let key = tx.db.ringKey(ring, persist = false)
  let ri = tx.db.rings[key]
  let normVec = vec.normalize()
  case tx.db.mode
  of mEmbedded:
    let g = tx.db.guardrails
    if g.maxRecordsPerRing > 0:
      let staged = tx.stagedRingWrites.getOrDefault(key, 0)
      if tx.db.liveRecordsInEmbeddedRing(key) + staged >= g.maxRecordsPerRing:
        inc tx.db.guardrailDenials[kgrRecordsPerRing]
        tx.db.audit("guardrail-denied", ok = false, ring = ring,
                    message = "ring records exceed maxRecordsPerRing",
                    extra = %*{"maxRecordsPerRing": g.maxRecordsPerRing,
                               "records": tx.db.liveRecordsInEmbeddedRing(key),
                               "stagedRecords": staged})
        raise newException(KoutenGuardrailError,
          "ring records exceed maxRecordsPerRing " & $g.maxRecordsPerRing)
    if tx.db.st.ringNames.getOrDefault(key, "") != ring:
      tx.tx.putRingName(key, ring)
    if key notin tx.db.st.ringMeta:
      tx.tx.putRingMeta(key, ri.period, ri.headAngle)
    let seq = tx.db.st.nextSeq(key)
    result = KoutenId(parent: key, epoch: tx.db.tbl.epoch, seq: seq, tWrite: tx.db.clock)
    tx.tx.upsert Particle(parent: key, seq: seq, period: ri.period,
                          head: ri.headAngle, tWrite: tx.db.clock,
                          payload: encoded.data, codec: encoded.codec, vec: normVec)
    tx.stagedRingWrites[key] = tx.stagedRingWrites.getOrDefault(key, 0) + 1
  of mCluster:
    let (seq, tWrite) = tx.db.client.txReserveReq(0, tx.clusterTxId, key,
                                                  ri.period, ri.headAngle)
    result = KoutenId(parent: key, epoch: tx.db.tbl.epoch, seq: seq, tWrite: tWrite)
    tx.clusterOps.add TxWireOp(parent: key, seq: seq, period: ri.period,
                               head: ri.headAngle, tWrite: tWrite,
                               payload: encoded.data, codec: encoded.codec, vec: normVec)

proc put*(tx: KoutenTx, payload: string, ring: string = "default",
          vec: seq[float32] = @[]): KoutenId =
  tx.put(encodedPayload(payload), ring, vec)

proc put*(tx: KoutenTx, doc: JsonNode, ring: string = "default",
          vec: seq[float32] = @[]): KoutenId =
  tx.put(encodedPayload($doc, pcJson), ring, vec)

proc remove*(tx: KoutenTx, id: KoutenId) =
  ## transaction 内の削除。commit まで DB 本体には反映されない。
  doAssert not tx.closed, "transaction is closed"
  case tx.db.mode
  of mEmbedded:
    tx.tx.remove(id.parent, id.seq)
  of mCluster:
    let ri = tx.db.rings[id.parent]
    tx.clusterOps.add TxWireOp(delete: true, parent: id.parent, seq: id.seq,
                               period: ri.period, head: ri.headAngle,
                               tWrite: id.tWrite)

proc update*(tx: KoutenTx, id: KoutenId, encoded: EncodedPayload,
             vec: seq[float32] = @[]) =
  ## transaction 内の置換更新。commit まで DB 本体には反映されない。
  doAssert not tx.closed, "transaction is closed"
  tx.db.checkPayloadGuardrails(encoded, vec.len)
  let normVec = vec.normalize()
  case tx.db.mode
  of mEmbedded:
    let k = (id.parent, id.seq)
    if k notin tx.db.st.items:
      raise newException(KeyError, "id が見つからない")
    var p = tx.db.st.items[k]
    p.payload = encoded.data
    p.codec = encoded.codec
    p.tWrite = tx.db.clock
    if vec.len > 0:
      p.vec = normVec
    tx.tx.upsert p
  of mCluster:
    let ri = tx.db.rings[id.parent]
    tx.clusterOps.add TxWireOp(parent: id.parent, seq: id.seq,
                               period: ri.period, head: ri.headAngle,
                               tWrite: id.tWrite, payload: encoded.data,
                               codec: encoded.codec,
                               vec: normVec)

proc update*(tx: KoutenTx, id: KoutenId, payload: string,
             vec: seq[float32] = @[]) =
  tx.update(id, encodedPayload(payload), vec)

proc update*(tx: KoutenTx, id: KoutenId, doc: JsonNode,
             vec: seq[float32] = @[]) =
  tx.update(id, encodedPayload($doc, pcJson), vec)

proc commit*(tx: KoutenTx) =
  doAssert not tx.closed, "transaction is closed"
  case tx.db.mode
  of mEmbedded:
    tx.tx.commit()
    if not tx.db.st.diskBacked:
      tx.db.vectorBackend.clear()
      for _, p in tx.db.st.items:
        tx.db.vectorBackend.upsert p
  of mCluster:
    tx.db.client.txCommitReq(0, tx.clusterTxId, tx.clusterOps)
    if tx.db.writeAckModeForOps(tx.clusterOps) == wamApplied:
      if not tx.db.waitClusterTxApplied(tx.clusterTxId):
        raise newException(IOError, "cluster transaction apply timed out")
    else:
      tx.db.markPendingLandingReads(tx.clusterOps)
  tx.closed = true

proc commit*(tx: KoutenTx, ackMode: WriteAckMode) =
  ## この transaction だけ応答タイミングを上書きして commit する。
  doAssert not tx.closed, "transaction is closed"
  case tx.db.mode
  of mEmbedded:
    tx.commit()
  of mCluster:
    tx.db.client.txCommitReq(0, tx.clusterTxId, tx.clusterOps)
    if ackMode == wamApplied:
      if not tx.db.waitClusterTxApplied(tx.clusterTxId):
        raise newException(IOError, "cluster transaction apply timed out")
    else:
      tx.db.markPendingLandingReads(tx.clusterOps)
    tx.closed = true

proc rollback*(tx: KoutenTx) =
  if not tx.closed:
    if tx.db.mode == mEmbedded:
      tx.tx.rollback()
    tx.closed = true

proc transaction*(db: KoutenDb, body: proc(tx: KoutenTx)) =
  ## 例外が出なければ commit、出たら rollback して例外を再送出する。
  let tx = db.beginTransaction()
  try:
    body(tx)
    tx.commit()
  except CatchableError:
    tx.rollback()
    raise

proc batchPutAtomic*(db: KoutenDb, payloads: seq[string],
                     ring: string = "default",
                     vecs: seq[seq[float32]] = @[]): seq[KoutenId] =
  ## Embedded all-or-nothing bulk insert. If any staged write or commit fails,
  ## no partial payloads become visible.
  doAssert db.mode == mEmbedded, "batchPutAtomic is embedded mode only"
  let tx = db.beginTransaction()
  try:
    for i, payload in payloads:
      let vec = if i < vecs.len: vecs[i] else: @[]
      result.add tx.put(payload, ring = ring, vec = vec)
    tx.commit()
  except CatchableError:
    tx.rollback()
    result.setLen(0)
    raise

proc batchPutAtomic*(db: KoutenDb, docs: seq[JsonNode],
                     ring: string = "default",
                     vecs: seq[seq[float32]] = @[]): seq[KoutenId] =
  ## Embedded all-or-nothing bulk JSON insert.
  doAssert db.mode == mEmbedded, "batchPutAtomic is embedded mode only"
  let tx = db.beginTransaction()
  try:
    for i, doc in docs:
      let vec = if i < vecs.len: vecs[i] else: @[]
      result.add tx.put(doc, ring = ring, vec = vec)
    tx.commit()
  except CatchableError:
    tx.rollback()
    result.setLen(0)
    raise

proc batchUpdateAtomic*(db: KoutenDb, ids: seq[KoutenId],
                        payloads: seq[string],
                        vecs: seq[seq[float32]] = @[]) =
  ## Embedded all-or-nothing bulk replace. Every ID must exist before commit.
  doAssert db.mode == mEmbedded, "batchUpdateAtomic is embedded mode only"
  if ids.len != payloads.len:
    raise newException(KoutenValidationError, "ids and payloads length mismatch")
  let tx = db.beginTransaction()
  try:
    for i, id in ids:
      let vec = if i < vecs.len: vecs[i] else: @[]
      tx.update(id, payloads[i], vec = vec)
    tx.commit()
  except CatchableError:
    tx.rollback()
    raise

proc batchUpdateAtomic*(db: KoutenDb, ids: seq[KoutenId],
                        docs: seq[JsonNode],
                        vecs: seq[seq[float32]] = @[]) =
  ## Embedded all-or-nothing bulk JSON replace.
  doAssert db.mode == mEmbedded, "batchUpdateAtomic is embedded mode only"
  if ids.len != docs.len:
    raise newException(KoutenValidationError, "ids and docs length mismatch")
  let tx = db.beginTransaction()
  try:
    for i, id in ids:
      let vec = if i < vecs.len: vecs[i] else: @[]
      tx.update(id, docs[i], vec = vec)
    tx.commit()
  except CatchableError:
    tx.rollback()
    raise

proc batchDeleteAtomic*(db: KoutenDb, ids: seq[KoutenId]) =
  ## Embedded all-or-nothing bulk delete. Every remove is committed together.
  doAssert db.mode == mEmbedded, "batchDeleteAtomic is embedded mode only"
  let tx = db.beginTransaction()
  try:
    for id in ids:
      if not db.st.contains(id.parent, id.seq):
        raise newException(KoutenNotFoundError, "id not found")
      tx.remove(id)
    tx.commit()
  except CatchableError:
    tx.rollback()
    raise

# ---------------------------------------------------------------- 読み出し

proc fetchClusterPayload(db: KoutenDb, id: KoutenId, selection: string,
                         fwdDepth = 0, needCodec = true): EncodedPayload =
  ## 現在の所有ノードから取得。取りこぼしのフォールバック順:
  ##   primary → 1つ手前（尾流コピー, §6.1）→ もう一度 primary
  ## 最後の再試行は「手前を見ている間に粒子が前方へハンドオフされた」TOCTOU
  ## レースを閉じる（移動は常に前方向なので、primary 再訪で必ず追いつく）。
  let ri = db.rings[id.parent]
  let n = int(db.tbl.nNodes)
  let physicalPrimary = int(db.tbl.placementOwner(id.parent))
  # Keep point reads bounded and owner-routed. Mutation versions and durable
  # tombstones protect destination writes, but a tail copy is still not an
  # authoritative read source.
  var candidates = @[physicalPrimary]
  var redirectsLeft = 2
  proc addTarget(node, at: int) =
    if redirectsLeft > 0 and node >= 0 and node < n:
      candidates.insert(node, at)
      dec redirectsLeft
  proc landingRead(): tuple[hit: bool, deleted: bool, value: EncodedPayload] =
    let r = db.client.txGetIdReq(0, WireId(parent: id.parent, epoch: id.epoch,
      seq: id.seq, tWrite: id.tWrite, period: ri.period, head: ri.headAngle),
      selection)
    if r.found:
      return (true, false, encodedPayload(r.value, r.codec))
    if r.deleted:
      db.clearPendingLandingRead(id)
      return (false, true, EncodedPayload())
    (false, false, EncodedPayload())
  if db.hasPendingLandingRead(id):
    let pending = landingRead()
    if pending.deleted:
      raise newException(KeyError, "id は cluster tx landing intent で削除済み")
    if pending.hit:
      return pending.value
    db.clearPendingLandingRead(id)
  var candidateIndex = 0
  while candidateIndex < candidates.len:
    let node = candidates[candidateIndex]
    inc candidateIndex
    var r: tuple[found: bool, node: int, value: string, codec: PayloadCodec, forwarded: bool,
                 newParent: uint64, newSeq: uint32, newTWrite: float,
                 targetNode: int]
    try:
      if selection.len == 0 and not needCodec:
        let raw = db.client.getValueReq(node, id.parent, id.seq, ri.period,
                                        ri.headAngle, id.tWrite)
        r = (found: raw.found, node: raw.node, value: raw.value,
             codec: pcRaw, forwarded: raw.forwarded,
             newParent: raw.newParent, newSeq: raw.newSeq,
             newTWrite: raw.newTWrite, targetNode: raw.targetNode)
      else:
        r =
          if selection.len == 0:
            db.client.getReq(node, id.parent, id.seq, ri.period, ri.headAngle,
                             id.tWrite)
          else:
            db.client.queryReq(node, id.parent, id.seq, ri.period, ri.headAngle,
                               id.tWrite, selection)
    except IOError, OSError, TimeoutError:
      let pendingRetry = landingRead()
      if pendingRetry.deleted:
        raise newException(KeyError, "id は cluster tx landing intent で削除済み")
      if pendingRetry.hit:
        return pendingRetry.value
      continue
    if r.found:
      return encodedPayload(r.value, r.codec)
    if r.forwarded:
      if r.targetNode >= 0:
        # Ownership changed after the client calculated physicalPrimary. Follow
        # the server's current target without probing unrelated nodes.
        addTarget(r.targetNode, candidateIndex)
        continue
      if fwdDepth >= 1:
        raise newException(KeyError, "FWD chain が長すぎる")
      if r.newParent notin db.rings:
        raise newException(KeyError, "FWD 先の環メタがない（parent=" & $r.newParent & "）")
      return db.fetchClusterPayload(KoutenId(parent: r.newParent, epoch: id.epoch,
                                            seq: r.newSeq, tWrite: r.newTWrite),
                                    selection, fwdDepth + 1, needCodec)
    let pendingRetry = landingRead()
    if pendingRetry.deleted:
      raise newException(KeyError, "id は cluster tx landing intent で削除済み")
    if pendingRetry.hit:
      return pendingRetry.value
  raise newException(KeyError, "id が見つからない（parent=" & $id.parent &
                     " seq=" & $id.seq & "）")

proc get*(db: KoutenDb, id: KoutenId): string =
  ## 読み出し。クラスタでは所在を計算して当該ノードに直接取りに行く（1 RTT）。
  case db.mode
  of mEmbedded:
    db.st.getParticle(id.parent, id.seq).payload
  of mCluster:
    db.fetchClusterPayload(id, "", needCodec = false).data

proc getEncoded*(db: KoutenDb, id: KoutenId): EncodedPayload =
  ## Read payload bytes together with the persisted format identifier.
  case db.mode
  of mEmbedded:
    let p = db.st.getParticle(id.parent, id.seq)
    encodedPayload(p.payload, p.codec)
  of mCluster:
    db.fetchClusterPayload(id, "")

proc batchGet*(db: KoutenDb, ids: seq[KoutenId]): seq[string] =
  ## 複数 ID をまとめて取得する。cluster では同一 node 行きをまとめて 1 request にする。
  case db.mode
  of mEmbedded:
    for id in ids:
      result.add db.get(id)
  of mCluster:
    var byNode = initTable[int, seq[tuple[idx: int, id: KoutenId]]]()
    result = newSeq[string](ids.len)
    for i, id in ids:
      let node = int(db.tbl.placementOwner(id.parent))
      byNode.mgetOrPut(node, @[]).add (idx: i, id: id)
    for node, entries in byNode:
      var req: seq[tuple[parent: uint64, seq: uint32, period: float,
                         head: float, tWrite: float]] = @[]
      for e in entries:
        let ri = db.rings[e.id.parent]
        req.add (parent: e.id.parent, seq: e.id.seq, period: ri.period,
                 head: ri.headAngle, tWrite: e.id.tWrite)
      let values = db.client.batchGetReq(node, req)
      for i, value in values:
        let idx = entries[i].idx
        if value.len == 0:
          result[idx] = db.get(entries[i].id)
        else:
          result[idx] = value

proc exists*(db: KoutenDb, id: KoutenId): bool =
  ## ORM / driver 向けの存在確認。cluster では get による確認。
  case db.mode
  of mEmbedded:
    db.st.contains(id.parent, id.seq)
  of mCluster:
    try:
      discard db.get(id)
      true
    except KeyError, IOError, OSError:
      false

proc remove*(db: KoutenDb, id: KoutenId) =
  ## ID 指定削除。cluster では landing intent 経由で owner へ非同期 apply。
  case db.mode
  of mEmbedded:
    if not db.st.contains(id.parent, id.seq):
      raise newException(KeyError, "id が見つからない")
    db.st.remove(id.parent, id.seq)
    db.vectorBackend.remove(id.parent, id.seq)
    db.audit("delete", id = $id)
  of mCluster:
    let ri = db.rings[id.parent]
    let txid = db.client.txBeginReq(0)
    let ops = @[
      TxWireOp(delete: true, parent: id.parent, seq: id.seq,
               period: ri.period, head: ri.headAngle, tWrite: id.tWrite)
    ]
    db.client.txCommitReq(0, txid, ops)
    if db.writeAckModeForOps(ops) == wamApplied:
      if not db.waitClusterTxApplied(txid):
        raise newException(IOError, "cluster delete apply timed out")
    else:
      db.markPendingLandingReads(ops)

proc deleteById*(db: KoutenDb, id: KoutenId) =
  ## ORM で直感的に使うための alias。
  db.remove(id)

proc update*(db: KoutenDb, id: KoutenId, encoded: EncodedPayload,
             vec: seq[float32] = @[]) =
  ## payload を置換する。vec を省略した場合は既存 vec を保持する。
  db.checkPayloadGuardrails(encoded, vec.len)
  case db.mode
  of mEmbedded:
    if not db.st.contains(id.parent, id.seq):
      raise newException(KeyError, "id が見つからない")
    var p = db.st.getParticle(id.parent, id.seq)
    p.payload = encoded.data
    p.codec = encoded.codec
    p.tWrite = db.clock
    if vec.len > 0:
      p.vec = vec.normalize()
    db.st.upsert p
    if not db.st.diskBacked:
      db.vectorBackend.upsert p
    db.audit("update", id = $id,
             extra = %*{"payloadBytes": encoded.data.len,
                        "vectorDim": vec.len,
                        "codec": $encoded.codec})
  of mCluster:
    let ri = db.rings[id.parent]
    let txid = db.client.txBeginReq(0)
    let ops = @[
      TxWireOp(parent: id.parent, seq: id.seq, period: ri.period,
               head: ri.headAngle, tWrite: id.tWrite,
               payload: encoded.data, codec: encoded.codec, vec: vec.normalize())
    ]
    db.client.txCommitReq(0, txid, ops)
    if db.writeAckModeForOps(ops) == wamApplied:
      if not db.waitClusterTxApplied(txid):
        raise newException(IOError, "cluster update apply timed out")
    else:
      db.markPendingLandingReads(ops)

proc update*(db: KoutenDb, id: KoutenId, payload: string,
             vec: seq[float32] = @[]) =
  db.update(id, encodedPayload(payload), vec)

proc update*(db: KoutenDb, id: KoutenId, doc: JsonNode,
             vec: seq[float32] = @[]) =
  db.update(id, encodedPayload($doc, pcJson), vec)

proc mergePatch(dst: var JsonNode, patch: JsonNode) =
  if patch.kind != JObject or dst.kind != JObject:
    dst = patch
    return
  for key, value in patch:
    if value.kind == JNull:
      if dst.hasKey(key):
        dst.delete key
    elif dst.hasKey(key) and dst[key].kind == JObject and value.kind == JObject:
      var child = dst[key]
      child.mergePatch(value)
      dst[key] = child
    else:
      dst[key] = value

proc patch*(db: KoutenDb, id: KoutenId, patchDoc: JsonNode): JsonNode =
  ## JSON object の merge patch。payload は JSON document であること。
  var doc = parseJson(db.get(id))
  doc.mergePatch(patchDoc)
  db.update(id, doc)
  doc

proc countByRing*(db: KoutenDb, ring: string): int =
  ## ring 内の live record 数。cluster v1 は全ノード集計。
  if db.mode == mEmbedded and ring notin db.ringNames:
    return 0
  let key = db.ringKeyForRead(ring)
  case db.mode
  of mEmbedded:
    for itemKey in db.st.itemsByRing.getOrDefault(key, @[]):
      if db.st.contains(itemKey[0], itemKey[1]):
        inc result
  of mCluster:
    for node in 0 ..< db.client.peers.len:
      result += db.client.countRingReq(node, key)

proc listByRing*(db: KoutenDb, ring: string, limit = 100,
                 cursor = ""): KoutenListPage =
  ## ring 内を seq 昇順で cursor pagination する。cursor は前回の nextCursor。
  ## cluster v1 は全ノードから集めて merge する。
  if limit <= 0 or (db.mode == mEmbedded and ring notin db.ringNames):
    return
  let key = db.ringKeyForRead(ring)
  let afterSeq =
    if cursor.len == 0: -1'i64
    else: int64(parseBiggestInt(cursor))
  if db.mode == mCluster:
    var rows: seq[WireListItem] = @[]
    var remoteHasMore = false
    for node in 0 ..< db.client.peers.len:
      let part = db.client.listRingReq(node, key, limit, cursor)
      rows.add part.items
      remoteHasMore = remoteHasMore or part.nextCursor.len > 0
    rows.sort(proc(a, b: WireListItem): int = cmp(a.seq, b.seq))
    for row in rows:
      if row.seq.int64 <= afterSeq:
        continue
      if result.items.len >= limit:
        result.nextCursor = $(result.items[^1].id.seq)
        break
      result.items.add KoutenRecord(
        id: KoutenId(parent: row.parent, epoch: db.tbl.epoch, seq: row.seq,
                    tWrite: row.tWrite),
        payload: row.payload, codec: row.codec)
    if result.nextCursor.len == 0 and remoteHasMore and result.items.len > 0:
      result.nextCursor = $(result.items[^1].id.seq)
    return
  # Segment physical order is optimized independently from logical cursor
  # order. Use the seq-ordered metadata path so updates to old records cannot
  # regress the cursor or duplicate rows across pages.
  let page = db.st.itemKeysByRingPage(key, afterSeq, limit)
  for itemKey in page.items:
    let p = db.st.getParticle(itemKey[0], itemKey[1])
    result.items.add KoutenRecord(
      id: KoutenId(parent: p.parent, epoch: db.tbl.epoch, seq: p.seq,
                  tWrite: p.tWrite),
      payload: p.payload, codec: p.codec)
  if page.hasMore and result.items.len > 0:
    result.nextCursor = $(result.items[^1].id.seq)

proc defaultReadOptions*(): KoutenReadOptions =
  KoutenReadOptions(
    filter: newJObject(),
    selection: "",
    limit: 100,
    cursor: "",
    pagination: rpOff,
    page: 1,
    pageLimit: 20,
    sortField: "",
    sortDirection: rsDesc)

proc defaultStellarOptions*(): KoutenStellarOptions =
  KoutenStellarOptions(
    filter: newJObject(),
    selection: "",
    limitPerRing: 20,
    subringLimits: initTable[string, int](),
    subringSortFields: initTable[string, string](),
    subringSortDirections: initTable[string, KoutenReadSortDirection](),
    maxDepth: 1,
    branchBudget: 0,
    subrings: @[],
    includeRoot: true,
    sortField: "time",
    sortDirection: rsDesc)

proc koutenFilter*(): KoutenFilterBuilder =
  ## Start a safe read-filter builder.
  KoutenFilterBuilder(node: newJObject())

proc toJson*(builder: KoutenFilterBuilder): JsonNode =
  ## Return a defensive JSON object copy suitable for KoutenReadOptions.filter.
  if builder.node.isNil:
    return newJObject()
  if builder.node.kind != JObject:
    raise newException(ValueError, "Kouten filter builder must contain a JSON object")
  builder.node.copy()

proc withFilterValue(builder: KoutenFilterBuilder; key: string;
                     value: JsonNode): KoutenFilterBuilder =
  if key.len == 0:
    raise newException(ValueError, "filter key must not be empty")
  if value.isNil:
    raise newException(ValueError, "filter value must not be nil")
  result.node = builder.toJson()
  result.node[key] = value.copy()

proc eq*(builder: KoutenFilterBuilder; key: string;
         value: JsonNode): KoutenFilterBuilder =
  ## Add an equality match for a JSON value.
  builder.withFilterValue(key, value)

proc eq*(builder: KoutenFilterBuilder; key, value: string): KoutenFilterBuilder =
  ## Add an equality match for a string value.
  builder.withFilterValue(key, %value)

proc eq*(builder: KoutenFilterBuilder; key: string;
         value: SomeInteger): KoutenFilterBuilder =
  ## Add an equality match for an integer value.
  builder.withFilterValue(key, %value)

proc eq*(builder: KoutenFilterBuilder; key: string;
         value: SomeFloat): KoutenFilterBuilder =
  ## Add an equality match for a floating-point value.
  builder.withFilterValue(key, %value)

proc eq*(builder: KoutenFilterBuilder; key: string;
         value: bool): KoutenFilterBuilder =
  ## Add an equality match for a boolean value.
  builder.withFilterValue(key, %value)

proc id*(builder: KoutenFilterBuilder; rawId: string): KoutenFilterBuilder =
  ## Match a KoutenDB raw/string ID using the same `id` filter field accepted by
  ## readRing and CLI `--filter='{"id":"..."}'`.
  builder.eq("id", rawId)

proc withFilter*(options: KoutenReadOptions;
                 builder: KoutenFilterBuilder): KoutenReadOptions =
  ## Return read options with a builder-produced filter.
  result = options
  result.filter = builder.toJson()

proc withFilter*(options: KoutenStellarOptions;
                 builder: KoutenFilterBuilder): KoutenStellarOptions =
  ## Return stellar read options with a builder-produced filter.
  result = options
  result.filter = builder.toJson()

proc normalizedReadOptions(options: KoutenReadOptions): KoutenReadOptions =
  result = options
  if result.filter.isNil:
    result.filter = newJObject()
  if result.limit <= 0:
    result.limit = 100
  if result.page <= 0:
    result.page = 1
  if result.pageLimit <= 0:
    result.pageLimit = result.limit
  if result.sortField.len == 0:
    result.sortField = "time"
  if result.sortField == "write":
    result.sortField = "time"
  if result.sortField notin ["id", "time"]:
    raise newException(ValueError, "sort field must be id, time, or write")

proc recordMatchesReadFilter(item: KoutenRecord, filterNode: JsonNode): bool =
  if filterNode.isNil or filterNode.kind != JObject or filterNode.len == 0:
    return true
  let cliId = $item.id.parent & ":" & $item.id.epoch & ":" & $item.id.seq & ":" & $item.id.tWrite
  if filterNode.hasKey("id") and
      filterNode["id"].getStr() notin [$item.id, cliId]:
    return false
  for key, expected in filterNode:
    if key == "id":
      continue
    if not item.codec.supportsJsonProjection:
      return false
    try:
      let doc = parseJson(item.payload)
      if doc.kind != JObject or not doc.hasKey(key) or doc[key] != expected:
        return false
    except JsonParsingError:
      return false
  true

proc projectReadRecord(item: KoutenRecord; prepared: PreparedSelection;
                       hasSelection: bool): KoutenRecord =
  result = item
  if not hasSelection:
    return
  if not item.codec.supportsJsonProjection:
    raise newException(ValueError,
      "payload codec " & item.codec.payloadCodecName & " does not support JSON projection")
  result.payload = $applySelection(prepared, parseJson(item.payload))
  result.codec = pcJson

proc compareReadRecords(a, b: KoutenRecord, options: KoutenReadOptions): int =
  case options.sortField
  of "id":
    result = cmp($a.id, $b.id)
  of "time":
    result = cmp(a.id.tWrite, b.id.tWrite)
  else:
    result = 0
  if options.sortDirection == rsDesc:
    result = -result

proc canUseRingWindowFastPath(db: KoutenDb, ring: string,
                              opts: KoutenReadOptions): bool =
  db.mode == mEmbedded and ring in db.ringNames and
    (opts.filter.isNil or opts.filter.kind == JObject and opts.filter.len == 0) and
    opts.cursor.len == 0 and opts.pagination == rpOff and opts.limit > 0 and
    opts.sortField in ["id", "time"]

proc readRingPrepared(db: KoutenDb, ring: string, opts: KoutenReadOptions;
                      preparedSelection: PreparedSelection;
                      hasSelection: bool): KoutenReadPage =
  let requested =
    if opts.pagination == rpOn: opts.page * opts.pageLimit
    else: opts.limit
  let skip =
    if opts.pagination == rpOn: (opts.page - 1) * opts.pageLimit
    else: 0
  let take =
    if opts.pagination == rpOn: opts.pageLimit
    else: opts.limit

  result.ring = ring
  result.pagination = opts.pagination
  result.page = opts.page
  result.pageLimit = opts.pageLimit
  result.sortField = opts.sortField
  result.sortDirection = opts.sortDirection

  if requested <= 0:
    return

  if db.canUseRingWindowFastPath(ring, opts):
    let key = db.ringNames[ring]
    let reverse = opts.sortDirection == rsDesc
    var matched: seq[KoutenRecord] = @[]
    let liveCount = db.st.ringLiveCount(key)
    if take >= liveCount:
      # A complete ring read can consume the segment sequentially. This is the
      # physical-locality path made cheaper by an explicit ring pack.
      for p in db.st.particlesByRing(key):
        matched.add KoutenRecord(
          id: KoutenId(parent: p.parent, epoch: db.tbl.epoch, seq: p.seq,
                       tWrite: p.tWrite),
          payload: p.payload, codec: p.codec)
    else:
      # Bounded reads keep payload I/O bounded and reuse one segment stream.
      let particles = db.st.particlesByRingWindow(key, take, reverse)
      for p in particles:
        matched.add KoutenRecord(
          id: KoutenId(parent: p.parent, epoch: db.tbl.epoch, seq: p.seq,
                       tWrite: p.tWrite),
          payload: p.payload, codec: p.codec)
    matched.sort(proc(a, b: KoutenRecord): int = compareReadRecords(a, b, opts))
    if matched.len > take:
      matched.setLen(take)
    for item in matched:
      result.items.add projectReadRecord(item, preparedSelection, hasSelection)
    result.count = result.items.len
    return

  var matched: seq[KoutenRecord] = @[]
  var nextCursor = opts.cursor
  let pageSize = max(requested, 100)
  while matched.len < requested:
    let page = db.listByRing(ring, limit = pageSize, cursor = nextCursor)
    for item in page.items:
      if recordMatchesReadFilter(item, opts.filter):
        matched.add item
        if matched.len >= requested:
          break
    nextCursor = page.nextCursor
    if nextCursor.len == 0 or page.items.len == 0:
      break

  matched.sort(proc(a, b: KoutenRecord): int = compareReadRecords(a, b, opts))
  for i in skip ..< min(skip + take, matched.len):
    result.items.add projectReadRecord(matched[i], preparedSelection, hasSelection)
  result.count = result.items.len
  result.nextCursor = nextCursor

proc readRing*(db: KoutenDb, ring: string,
               options: KoutenReadOptions = defaultReadOptions()): KoutenReadPage =
  ## Read records from one ring with filter, projection, limit/cursor,
  ## page/pagelimit, and page-local sort controls.
  let opts = normalizedReadOptions(options)
  let hasSelection = opts.selection.len > 0
  let preparedSelection =
    if hasSelection: prepareSelection(opts.selection)
    else: PreparedSelection()
  db.readRingPrepared(ring, opts, preparedSelection, hasSelection)

proc eventTimeMsOf(item: KoutenRecord): tuple[ok: bool, value: int64] =
  if not item.codec.supportsJsonProjection:
    return (false, 0'i64)
  try:
    let node = parseJson(item.payload)
    if node.kind == JObject and node.hasKey("eventTimeMs"):
      case node["eventTimeMs"].kind
      of JInt:
        return (true, node["eventTimeMs"].getBiggestInt().int64)
      of JFloat:
        return (true, int64(node["eventTimeMs"].getFloat()))
      else:
        discard
  except JsonParsingError:
    discard
  (false, 0'i64)

proc compareTimeRecords(a, b: KoutenRecord): int =
  let ta = eventTimeMsOf(a)
  let tb = eventTimeMsOf(b)
  if ta.ok and tb.ok:
    result = cmp(ta.value, tb.value)
  elif ta.ok:
    result = -1
  elif tb.ok:
    result = 1
  else:
    result = cmp(a.id.tWrite, b.id.tWrite)
  if result == 0:
    result = cmp($a.id, $b.id)

proc readTime*(db: KoutenDb, ring: string, fromMs, toMs: int64,
               options: KoutenReadOptions = defaultReadOptions(),
               maxBuckets = 1024): KoutenTimeReadPage =
  ## Read a ring-local time-orbit range. This calculates affected bucket rings
  ## first, then uses normal readRing controls inside each bucket.
  if fromMs < 0 or toMs < 0:
    raise newException(ValueError, "time range must be >= 0")
  if toMs < fromMs:
    raise newException(ValueError, "toMs must be >= fromMs")
  if maxBuckets <= 0:
    raise newException(ValueError, "maxBuckets must be > 0")
  let profile = db.timeOrbitProfile(ring)
  let fromBucket = timeOrbitBucket(profile, fromMs)
  let toBucket = timeOrbitBucket(profile, toMs)
  if toBucket < fromBucket:
    raise newException(ValueError, "time range crosses orbit wrap")
  let bucketCount = int(toBucket - fromBucket + 1'u64)
  if bucketCount > maxBuckets:
    raise newException(ValueError, "time range exceeds maxBuckets")

  result.ring = ring
  result.fromMs = fromMs
  result.toMs = toMs
  result.bucketsVisited = bucketCount

  var readOpts = options
  if readOpts.limit <= 0:
    readOpts.limit = 100
  let perBucketLimit = readOpts.limit
  for bucket in fromBucket .. toBucket:
    let timestampMs = int64(bucket) * profile.bucketMs
    let bucketRing = timeOrbitRing(ring, profile, timestampMs)
    result.rings.add bucketRing
    readOpts.limit = perBucketLimit
    let page = db.readRing(bucketRing, readOpts)
    for item in page.items:
      let eventTime = eventTimeMsOf(item)
      if eventTime.ok and (eventTime.value < fromMs or eventTime.value > toMs):
        continue
      result.items.add item
  result.items.sort(compareTimeRecords)
  if options.limit > 0 and result.items.len > options.limit:
    result.items.setLen(options.limit)
  result.count = result.items.len

proc anchorRingName(db: KoutenDb, anchor: KoutenId): string =
  result = db.ringKeyNames.getOrDefault(anchor.parent, "")
  if result.len == 0:
    raise newException(ValueError,
      "anchor ring is unknown in this KoutenDB handle; configure or read the ring map first")

proc nearRing*(db: KoutenDb, anchor: KoutenId, relation: string): string =
  ## Resolve a temporary proximity hint into a normal ring coordinate.
  ## The relation is not persisted as metadata; only the resulting ring stores data.
  let root = db.anchorRingName(anchor)
  let clean = relation.strip(chars = {'/'})
  if clean.len == 0: root else: root & "/" & clean

proc nearRing*(baseRing, ring: string): string =
  ## Resolve a write-time coordinate hint into a concrete nearby ring name.
  ## Example: baseRing=users/123 and ring=orders becomes users/123/orders.
  let base = baseRing.strip(chars = {'/'})
  let child = ring.strip(chars = {'/'})
  if base.len == 0:
    child
  elif child.len == 0:
    base
  else:
    base & "/" & child

proc putNear*(db: KoutenDb, baseRing: string, encoded: EncodedPayload,
              ring: string, vec: seq[float32] = @[]): KoutenId =
  ## Store data under a nearby coordinate derived from baseRing + ring.
  ## Example: baseRing users/123 and ring orders stores into users/123/orders.
  ## The hint is write-time only; reads use the resulting ring coordinate.
  db.put(encoded, ring = nearRing(baseRing, ring), vec = vec)

proc putNear*(db: KoutenDb, baseRing, payload, ring: string,
              vec: seq[float32] = @[]): KoutenId =
  db.putNear(baseRing, encodedPayload(payload), ring = ring, vec = vec)

proc putNear*(db: KoutenDb, baseRing: string, doc: JsonNode, ring: string,
              vec: seq[float32] = @[]): KoutenId =
  db.putNear(baseRing, encodedPayload($doc, pcJson), ring = ring, vec = vec)

proc putNear*(db: KoutenDb, anchor: KoutenId, encoded: EncodedPayload,
              relation = "context", vec: seq[float32] = @[]): KoutenId =
  ## Store related data in the same stellar coordinate neighborhood as anchor.
  ## This converts the relation hint to a nearby ring, then uses normal put.
  db.put(encoded, ring = db.nearRing(anchor, relation), vec = vec)

proc putNear*(db: KoutenDb, anchor: KoutenId, payload: string,
              relation = "context", vec: seq[float32] = @[]): KoutenId =
  db.putNear(anchor, encodedPayload(payload), relation = relation, vec = vec)

proc putNear*(db: KoutenDb, anchor: KoutenId, doc: JsonNode,
              relation = "context", vec: seq[float32] = @[]): KoutenId =
  db.putNear(anchor, encodedPayload($doc, pcJson), relation = relation, vec = vec)

proc attachStellar*(db: KoutenDb, stellar, ring: string) =
  ## Attach a ring coordinate to a stellar coordinate's visible lens.
  ## This does not copy payloads or create a strict foreign-key constraint.
  let stellarCoord = normalizedCoordinate(stellar)
  let member = normalizedCoordinate(ring)
  if stellarCoord.len == 0:
    raise newException(ValueError, "stellar coordinate must not be empty")
  if member.len == 0:
    raise newException(ValueError, "stellar member ring must not be empty")
  discard db.ringKey(stellarCoord)
  discard db.ringKey(member)
  var members = db.stellarMembers.getOrDefault(stellarCoord, @[])
  members.addUniqueString member
  db.stellarMembers[stellarCoord] = members
  db.rebuildStellarMembership()
  if db.mode == mEmbedded:
    db.st.putStellarMap(stellarCoord, stellarMapBlob(stellarCoord, members))

proc detachStellar*(db: KoutenDb, stellar, ring: string) =
  ## Remove a ring coordinate from a stellar coordinate's visible lens.
  let stellarCoord = normalizedCoordinate(stellar)
  let member = normalizedCoordinate(ring)
  if stellarCoord.len == 0:
    raise newException(ValueError, "stellar coordinate must not be empty")
  if member.len == 0:
    raise newException(ValueError, "stellar member ring must not be empty")
  var members = db.stellarMembers.getOrDefault(stellarCoord, @[])
  members.removeString member
  if members.len == 0:
    db.stellarMembers.del stellarCoord
    if db.mode == mEmbedded:
      db.st.putStellarMap(stellarCoord, "")
  else:
    db.stellarMembers[stellarCoord] = members
    if db.mode == mEmbedded:
      db.st.putStellarMap(stellarCoord, stellarMapBlob(stellarCoord, members))
  db.rebuildStellarMembership()

proc stellarMembers*(db: KoutenDb, stellar: string): seq[string] =
  db.stellarMembers.getOrDefault(normalizedCoordinate(stellar), @[])

proc stellarCoordinatesFor*(db: KoutenDb, ring: string): seq[string] =
  db.stellarByMember.getOrDefault(normalizedCoordinate(ring), @[])

proc normalizedStellarOptions(options: KoutenStellarOptions): KoutenStellarOptions =
  result = options
  if result.filter.isNil:
    result.filter = newJObject()
  if result.limitPerRing <= 0:
    result.limitPerRing = 20
  var normalizedLimits = initTable[string, int]()
  for name, value in result.subringLimits:
    let clean = normalizedCoordinate(name)
    if clean.len == 0:
      continue
    if value <= 0:
      raise newException(ValueError, "subring limit must be positive")
    normalizedLimits[clean] = value
  result.subringLimits = normalizedLimits
  var normalizedSortFields = initTable[string, string]()
  for name, value in result.subringSortFields:
    let clean = normalizedCoordinate(name)
    if clean.len == 0:
      continue
    if value.len == 0:
      continue
    if value == "write":
      normalizedSortFields[clean] = "time"
    elif value in ["id", "time"]:
      normalizedSortFields[clean] = value
    else:
      raise newException(ValueError, "subring sort field must be id, time, or write")
  result.subringSortFields = normalizedSortFields
  var normalizedSortDirections = initTable[string, KoutenReadSortDirection]()
  for name, value in result.subringSortDirections:
    let clean = normalizedCoordinate(name)
    if clean.len == 0:
      continue
    normalizedSortDirections[clean] = value
  result.subringSortDirections = normalizedSortDirections
  if result.maxDepth < 0:
    result.maxDepth = 0
  if result.branchBudget < 0:
    result.branchBudget = 0
  for i, value in result.subrings:
    result.subrings[i] = value.strip(chars = {'/'})
  if result.sortField.len == 0:
    result.sortField = "time"
  if result.sortField == "write":
    result.sortField = "time"
  if result.sortField notin ["id", "time"]:
    raise newException(ValueError, "sort field must be id, time, or write")

proc subringMatches(root, ringName: string, subrings: seq[string]): bool =
  if subrings.len == 0:
    return true
  let rootClean = normalizedCoordinate(root)
  let ringClean = normalizedCoordinate(ringName)
  for subring in subrings:
    let sub = normalizedCoordinate(subring)
    if sub.len == 0:
      continue
    if ringClean == rootClean & "/" & sub:
      return true
    if ringClean == sub or ringClean.startsWith(sub & "/"):
      return true
    if ringClean.endsWith("/" & sub):
      return true
  false

proc subringNameMatches(root, ringName, subring: string): bool =
  let rootClean = normalizedCoordinate(root)
  let ringClean = normalizedCoordinate(ringName)
  let sub = normalizedCoordinate(subring)
  if sub.len == 0:
    return false
  if ringClean == rootClean & "/" & sub:
    return true
  if ringClean == sub or ringClean.startsWith(sub & "/"):
    return true
  if ringClean.endsWith("/" & sub):
    return true
  false

proc stellarLimitFor(root, ringName: string,
                     opts: KoutenStellarOptions): int =
  result = opts.limitPerRing
  if opts.subringLimits.len == 0:
    return
  let rootClean = normalizedCoordinate(root)
  if normalizedCoordinate(ringName) == rootClean:
    return
  var bestLen = -1
  for subring, limit in opts.subringLimits:
    let clean = normalizedCoordinate(subring)
    if clean.len > bestLen and subringNameMatches(root, ringName, clean):
      result = limit
      bestLen = clean.len

proc stellarSortFor(root, ringName: string,
                    opts: KoutenStellarOptions):
                    tuple[field: string, direction: KoutenReadSortDirection] =
  result = (opts.sortField, opts.sortDirection)
  if normalizedCoordinate(ringName) == normalizedCoordinate(root):
    return
  var bestFieldLen = -1
  for subring, field in opts.subringSortFields:
    let clean = normalizedCoordinate(subring)
    if clean.len > bestFieldLen and subringNameMatches(root, ringName, clean):
      result.field = field
      bestFieldLen = clean.len
  var bestDirectionLen = -1
  for subring, direction in opts.subringSortDirections:
    let clean = normalizedCoordinate(subring)
    if clean.len > bestDirectionLen and subringNameMatches(root, ringName, clean):
      result.direction = direction
      bestDirectionLen = clean.len

proc readStellar*(db: KoutenDb, root: string,
                  options: KoutenStellarOptions = defaultStellarOptions()): KoutenStellarPage =
  ## Read a stellar neighborhood: the root ring and nearby child coordinates.
  ## It is similar to pointing a telescope at a ring: nearby satellites are
  ## naturally visible, and subrings narrow the field when needed. It does not
  ## chase distant coordinates just to emulate a global join.
  let opts = normalizedStellarOptions(options)
  let hasSelection = opts.selection.len > 0
  let preparedSelection =
    if hasSelection: prepareSelection(opts.selection)
    else: PreparedSelection()
  result.root = root
  result.maxDepth = opts.maxDepth
  result.branchBudget = opts.branchBudget
  if root notin db.ringNames:
    return
  let rootKey = db.ringNames[root]
  var keys: seq[uint64] = @[]
  if opts.subrings.len > 0:
    if opts.includeRoot:
      keys.add rootKey
    for subring in opts.subrings:
      if subring.len == 0:
        continue
      let ringName = root.strip(chars = {'/'}) & "/" & subring
      if ringName in db.ringNames:
        keys.add db.ringNames[ringName]
  else:
    keys = db.stellarNeighborKeys(rootKey, opts.maxDepth, opts.branchBudget)
    if not opts.includeRoot and keys.len > 0 and keys[0] == rootKey:
      keys.delete(0)
  var visibleCoordinates = db.stellarMembers.getOrDefault(root, @[])
  for stellar in db.stellarByMember.getOrDefault(root, @[]):
    visibleCoordinates.addUniqueString stellar
    for member in db.stellarMembers.getOrDefault(stellar, @[]):
      visibleCoordinates.addUniqueString member
  for ringName in visibleCoordinates:
    if not subringMatches(root, ringName, opts.subrings):
      continue
    if ringName in db.ringNames:
      keys.addUniqueRingKey db.ringNames[ringName]
  for key in keys:
    let ringName = db.ringNameOf(key)
    let ringLimit = stellarLimitFor(root, ringName, opts)
    let ringSort = stellarSortFor(root, ringName, opts)
    let readOptions = normalizedReadOptions(KoutenReadOptions(
      filter: opts.filter,
      selection: opts.selection,
      limit: ringLimit,
      sortField: ringSort.field,
      sortDirection: ringSort.direction))
    let page = db.readRingPrepared(ringName, readOptions, preparedSelection,
                                   hasSelection)
    if page.items.len == 0:
      continue
    result.rings.add KoutenStellarRingPage(ring: ringName,
                                          count: page.count,
                                          items: page.items)
    result.count += page.count
  result.ringsVisited = keys.len

proc batchPut*(db: KoutenDb, payloads: seq[string], ring: string = "default",
               vecs: seq[seq[float32]] = @[]): seq[KoutenId] =
  ## 複数 payload を同じ ring に保存する。vecs が空なら vector なし。
  for i, payload in payloads:
    let vec = if i < vecs.len: vecs[i] else: @[]
    result.add db.put(payload, ring = ring, vec = vec)

proc batchPut*(db: KoutenDb, docs: seq[JsonNode], ring: string = "default",
               vecs: seq[seq[float32]] = @[]): seq[KoutenId] =
  for i, doc in docs:
    let vec = if i < vecs.len: vecs[i] else: @[]
    result.add db.put(doc, ring = ring, vec = vec)

proc findWarpJob(db: KoutenDb, jobId: uint64): int =
  for i, job in db.warpJobs:
    if job.id == jobId:
      return i
  -1

proc jsonField(doc: JsonNode, path: string): JsonNode =
  var cur = doc
  for part in path.split('.'):
    if part.len == 0 or cur.isNil or cur.kind != JObject or not cur.hasKey(part):
      return nil
    cur = cur[part]
  cur

proc warpRetryDelaySeconds(attempts: int): float =
  ## Core fallback only. FlowBrigade adapter can replace this policy.
  let capped = min(max(attempts, 1), 8)
  min(30.0, 0.2 * float(1 shl (capped - 1)))

proc warpJobJson(job: WarpJob): JsonNode =
  result = %*{
    "id": job.id,
    "rings": job.rings,
    "whereField": job.whereField,
    "equals": job.equals,
    "patch": job.patch,
    "status": $job.status,
    "ringIndex": job.ringIndex,
    "cursor": job.cursor,
    "scanned": job.scanned,
    "matched": job.matched,
    "updated": job.updated,
    "attempts": job.attempts,
    "maxAttempts": job.maxAttempts,
    "retryAt": job.retryAt,
    "acknowledged": job.acknowledged,
    "error": job.error
  }

proc persistWarpJob(db: KoutenDb, job: WarpJob) =
  if db.mode == mEmbedded and not db.st.isNil:
    db.st.putWarpJob(job.id, $job.warpJobJson())

proc universeSyncEventJson(event: UniverseSyncEvent): JsonNode =
  %*{
    "id": event.id,
    "eventKey": event.eventKey,
    "sourceUniverse": event.sourceUniverse,
    "sourceGalaxy": event.sourceGalaxy,
    "ring": event.ring,
    "op": event.op,
    "logicalKey": event.logicalKey,
    "payload": event.payload,
    "codec": event.codec.payloadCodecName,
    "vec": event.vec,
    "timestamp": event.timestamp,
    "applyAfter": event.applyAfter,
    "originSeq": event.originSeq,
    "attempts": event.attempts,
    "maxAttempts": event.maxAttempts,
    "retryAt": event.retryAt,
    "deadLetter": event.deadLetter,
    "acknowledged": event.acknowledged,
    "error": event.error
  }

proc persistUniverseSyncEvent(db: KoutenDb, event: UniverseSyncEvent) =
  if db.mode == mEmbedded and not db.st.isNil:
    db.st.putUniverseSyncEvent(event.id, $event.universeSyncEventJson())

proc makeUniverseEventKey(sourceUniverse, sourceGalaxy, ring, logicalKey: string,
                          originSeq: uint64, timestamp: float): string =
  sourceUniverse & "|" & sourceGalaxy & "|" & ring & "|" & logicalKey & "|" &
    $originSeq & "|" & $timestamp

proc sameUniverseLogicalStream(a: UniverseSyncEvent, sourceUniverse,
                               sourceGalaxy, ring, op, logicalKey: string): bool =
  a.sourceUniverse == sourceUniverse and
    a.sourceGalaxy == sourceGalaxy and
    a.ring == ring and
    a.op == op and
    a.logicalKey == logicalKey and
    logicalKey.len > 0

proc deleteUniverseSyncEventAt(db: KoutenDb, idx: int) =
  let eventId = db.universeSyncEvents[idx].id
  db.universeSyncEvents.delete(idx)
  if db.mode == mEmbedded and not db.st.isNil:
    db.st.deleteUniverseSyncEvent(eventId)

proc pendingUniverseSyncCoalesceIndexes(db: KoutenDb, sourceUniverse,
                                        sourceGalaxy, ring, op,
                                        logicalKey: string,
                                        policy: RingApplyPolicy): seq[int] =
  if logicalKey.len == 0:
    return
  case policy.mode
  of ramLatestOnly:
    for i in countdown(db.universeSyncEvents.len - 1, 0):
      let event = db.universeSyncEvents[i]
      if not event.acknowledged and
          event.sameUniverseLogicalStream(sourceUniverse, sourceGalaxy, ring,
                                          op, logicalKey):
        result.add i
  of ramBoundedHistory:
    let keep = max(1, policy.historyKeep)
    var matches: seq[tuple[idx: int, timestamp: float, originSeq: uint64]]
    for i, event in db.universeSyncEvents:
      if not event.acknowledged and
          event.sameUniverseLogicalStream(sourceUniverse, sourceGalaxy, ring,
                                          op, logicalKey):
        matches.add (idx: i, timestamp: event.timestamp,
                     originSeq: event.originSeq)
    if matches.len >= keep:
      matches.sort(proc(a, b: tuple[idx: int, timestamp: float,
                                    originSeq: uint64]): int =
        result = cmp(a.timestamp, b.timestamp)
        if result == 0:
          result = cmp(a.originSeq, b.originSeq))
      var removeIdx: seq[int]
      for j in 0 ..< matches.len - keep + 1:
        removeIdx.add matches[j].idx
      removeIdx.sort(SortOrder.Descending)
      for idx in removeIdx:
        result.add idx
  of ramAppendOnly, ramDelayedTimestamp:
    discard

proc coalescePendingUniverseSyncEvents(db: KoutenDb, sourceUniverse,
                                       sourceGalaxy, ring, op,
                                       logicalKey: string,
                                       policy: RingApplyPolicy) =
  for idx in db.pendingUniverseSyncCoalesceIndexes(sourceUniverse, sourceGalaxy,
                                                  ring, op, logicalKey, policy):
    db.deleteUniverseSyncEventAt(idx)

proc universeSyncEventReady(db: KoutenDb, event: UniverseSyncEvent): bool =
  if event.applyAfter > 0.0:
    return epochTime() >= event.applyAfter
  let policy = db.ringApplyPolicy(event.ring)
  if policy.mode != ramDelayedTimestamp or policy.delayMs <= 0:
    return true
  epochTime() >= event.timestamp + float(policy.delayMs) / 1000.0

proc universeSyncRetryDelaySeconds(attempts: int): float =
  let capped = min(max(attempts, 1), 8)
  min(300.0, float(1 shl (capped - 1)))

proc universeSyncDispatchable*(event: UniverseSyncEvent, now = epochTime()): bool =
  if event.acknowledged or event.deadLetter:
    return false
  if event.retryAt > 0.0 and event.retryAt > now:
    return false
  if event.applyAfter > 0.0 and event.applyAfter > now:
    return false
  true

proc markUniverseSyncDelayed*(db: KoutenDb, eventId: uint64, retryAt: float) =
  for i, event in db.universeSyncEvents:
    if event.id == eventId:
      var updated = event
      updated.retryAt = max(updated.retryAt, retryAt)
      db.universeSyncEvents[i] = updated
      db.persistUniverseSyncEvent(updated)
      return
  raise newException(KeyError, "universe sync event not found")

proc markUniverseSyncFailure*(db: KoutenDb, eventId: uint64,
                              message: string): UniverseSyncEvent =
  ## Record a failed delivery attempt. The event remains in the outbox until it
  ## is acknowledged or reaches its retry budget and becomes dead-lettered.
  for i, event in db.universeSyncEvents:
    if event.id == eventId:
      var updated = event
      inc updated.attempts
      updated.error = message
      if updated.maxAttempts <= 0:
        updated.maxAttempts = 8
      if updated.attempts >= updated.maxAttempts:
        updated.deadLetter = true
        updated.retryAt = 0.0
      else:
        updated.retryAt = epochTime() + universeSyncRetryDelaySeconds(updated.attempts)
      db.universeSyncEvents[i] = updated
      db.persistUniverseSyncEvent(updated)
      return updated
  raise newException(KeyError, "universe sync event not found")

proc enqueueUniverseSyncEvent*(db: KoutenDb, sourceUniverse, sourceGalaxy,
                               ring, payload: string,
                               vec: seq[float32] = @[],
                               codec = pcRaw,
                               op = "put", logicalKey = "",
                               timestamp = -1.0,
                               eventKey = ""): uint64 =
  ## Universe 間の durable eventual sync 用イベントを登録する。
  ## これは global commit ではなく、別 universe に後で配送するための WAL-backed outbox。
  doAssert db.mode == mEmbedded, "universe sync event queue は embedded mode 専用"
  if ring.len == 0:
    raise newException(ValueError, "universe sync event ring is empty")
  if op != "put":
    raise newException(ValueError, "only put universe sync events are supported")
  let policy = db.ringApplyPolicy(ring)
  db.coalescePendingUniverseSyncEvents(sourceUniverse, sourceGalaxy, ring,
                                       op, logicalKey, policy)
  inc db.nextUniverseSyncId
  if db.mode == mEmbedded and not db.st.isNil:
    db.st.setNextUniverseSyncId(db.nextUniverseSyncId)
  let ts = if timestamp >= 0.0: timestamp else: epochTime()
  let applyAfter =
    if policy.mode == ramDelayedTimestamp and policy.delayMs > 0:
      ts + float(policy.delayMs) / 1000.0
    else:
      0.0
  let key = if eventKey.len > 0: eventKey
            else: makeUniverseEventKey(sourceUniverse, sourceGalaxy, ring,
                                       logicalKey, db.nextUniverseSyncId, ts)
  let event = UniverseSyncEvent(id: db.nextUniverseSyncId,
                                eventKey: key,
                                sourceUniverse: sourceUniverse,
                                sourceGalaxy: sourceGalaxy,
                                ring: ring,
                                op: op,
                                logicalKey: logicalKey,
                                payload: payload,
                                codec: codec,
                                vec: vec.normalize(),
                                timestamp: ts,
                                applyAfter: applyAfter,
                                originSeq: db.nextUniverseSyncId,
                                maxAttempts: 8)
  db.universeSyncEvents.add event
  db.persistUniverseSyncEvent(event)
  event.id

proc stageUniverseSyncEvent(db: KoutenDb, tx: StoreTxn, sourceUniverse,
                            sourceGalaxy, ring, payload: string,
                            vec: seq[float32] = @[], codec = pcRaw,
                            op = "put", logicalKey = "",
                            timestamp = -1.0,
                            eventKey = ""): tuple[event: UniverseSyncEvent,
                                                   removed: seq[int]] =
  doAssert db.mode == mEmbedded, "universe sync event queue は embedded mode 専用"
  if ring.len == 0:
    raise newException(ValueError, "universe sync event ring is empty")
  if op != "put":
    raise newException(ValueError, "only put universe sync events are supported")
  let policy = db.ringApplyPolicy(ring)
  result.removed = db.pendingUniverseSyncCoalesceIndexes(sourceUniverse,
    sourceGalaxy, ring, op, logicalKey, policy)
  for idx in result.removed:
    tx.deleteUniverseSyncEvent(db.universeSyncEvents[idx].id)
  inc db.nextUniverseSyncId
  if not db.st.isNil:
    db.st.setNextUniverseSyncId(db.nextUniverseSyncId)
  let ts = if timestamp >= 0.0: timestamp else: epochTime()
  let applyAfter =
    if policy.mode == ramDelayedTimestamp and policy.delayMs > 0:
      ts + float(policy.delayMs) / 1000.0
    else:
      0.0
  let key = if eventKey.len > 0: eventKey
            else: makeUniverseEventKey(sourceUniverse, sourceGalaxy, ring,
                                       logicalKey, db.nextUniverseSyncId, ts)
  result.event = UniverseSyncEvent(id: db.nextUniverseSyncId,
                                   eventKey: key,
                                   sourceUniverse: sourceUniverse,
                                   sourceGalaxy: sourceGalaxy,
                                   ring: ring,
                                   op: op,
                                   logicalKey: logicalKey,
                                   payload: payload,
                                   codec: codec,
                                   vec: vec.normalize(),
                                   timestamp: ts,
                                   applyAfter: applyAfter,
                                   originSeq: db.nextUniverseSyncId,
                                   maxAttempts: 8)
  tx.putUniverseSyncEvent(result.event.id, $result.event.universeSyncEventJson())

proc universeSyncEvents*(db: KoutenDb,
                         includeAcknowledged = false,
                         includeDeadLetter = true): seq[UniverseSyncEvent] =
  ## 未配送/未ackの universe sync outbox を返す。配送先は core 外の scheduler/adapter が選ぶ。
  for event in db.universeSyncEvents:
    if (includeAcknowledged or not event.acknowledged) and
        (includeDeadLetter or not event.deadLetter):
      result.add event

proc applyUniverseSyncEvent*(db: KoutenDb, event: UniverseSyncEvent): bool =
  ## 別 universe から受け取った event を idempotent に適用する。
  ## true は今回適用、false は既に適用済み。
  doAssert db.mode == mEmbedded, "universe sync event apply は embedded mode 専用"
  if event.eventKey.len == 0:
    raise newException(ValueError, "universe sync event key is empty")
  if db.st.isUniverseSyncEventApplied(event.eventKey):
    return false
  let policy = db.ringApplyPolicy(event.ring)
  case policy.mode
  of ramLatestOnly, ramAppendOnly, ramBoundedHistory, ramDelayedTimestamp:
    discard db.put(encodedPayload(event.payload, event.codec),
                   ring = event.ring, vec = event.vec)
  db.st.markUniverseSyncEventApplied(event.eventKey)
  true

proc ackUniverseSyncEvent*(db: KoutenDb, eventId: uint64): UniverseSyncEvent =
  ## 配送先 universe で durable に受け取られたことを outbox 側で ack する。
  for i, event in db.universeSyncEvents:
    if event.id == eventId:
      var updated = event
      updated.acknowledged = true
      updated.retryAt = 0.0
      updated.error = ""
      db.universeSyncEvents[i] = updated
      db.persistUniverseSyncEvent(updated)
      return updated
  raise newException(KeyError, "universe sync event not found")

proc pruneAckedUniverseSyncEvents*(db: KoutenDb): int =
  ## ack 済み universe sync events を outbox から削除する。
  for i in countdown(db.universeSyncEvents.len - 1, 0):
    if db.universeSyncEvents[i].acknowledged:
      let eventId = db.universeSyncEvents[i].id
      db.universeSyncEvents.delete(i)
      if db.mode == mEmbedded and not db.st.isNil:
        db.st.deleteUniverseSyncEvent(eventId)
      inc result

proc syncUniverseOnce*(source, target: KoutenDb,
                       pruneAcked = false): UniverseSyncStats =
  ## source outbox から target store へ一度だけ event を配送する。
  ## Transport / scheduling は呼び出し側が担当し、core は durable event 境界だけを提供する。
  doAssert source.mode == mEmbedded, "source universe sync は embedded mode 専用"
  doAssert target.mode == mEmbedded, "target universe sync は embedded mode 専用"
  for event in source.universeSyncEvents(includeDeadLetter = false):
    inc result.read
    if not universeSyncDispatchable(event):
      inc result.skipped
      continue
    if not target.universeSyncEventReady(event):
      inc result.skipped
      continue
    try:
      if target.applyUniverseSyncEvent(event):
        inc result.applied
      else:
        inc result.skipped
      discard source.ackUniverseSyncEvent(event.id)
      inc result.acked
    except CatchableError:
      inc result.errors
      let updated = source.markUniverseSyncFailure(event.id, getCurrentExceptionMsg())
      if updated.deadLetter:
        inc result.deadLetter
  if pruneAcked:
    result.pruned = source.pruneAckedUniverseSyncEvents()

proc enqueueWarp*(db: KoutenDb, rings: seq[string], whereField: string,
                  equals: JsonNode, patchDoc: JsonNode,
                  maxAttempts = 8): uint64 =
  ## 非同期 warp を登録する。
  ## 指定 ring 群を登録順に走査し、whereField == equals の JSON document に patchDoc を落とす。
  if rings.len == 0:
    raise newException(ValueError, "warp rings must not be empty")
  if whereField.len == 0:
    raise newException(ValueError, "warp whereField must not be empty")
  if patchDoc.isNil or patchDoc.kind != JObject:
    raise newException(ValueError, "warp patch must be a JSON object")
  if maxAttempts <= 0:
    raise newException(ValueError, "warp maxAttempts must be positive")
  inc db.nextWarpId
  result = db.nextWarpId
  let job = WarpJob(id: result, rings: rings, whereField: whereField,
                    equals: equals, patch: patchDoc,
                    status: wsPending, maxAttempts: maxAttempts)
  db.warpJobs.add job
  db.persistWarpJob(job)

proc warpStatus*(db: KoutenDb, jobId: uint64): WarpJob =
  let idx = db.findWarpJob(jobId)
  if idx < 0:
    raise newException(KeyError, "warp job not found")
  db.warpJobs[idx]

proc ackWarp*(db: KoutenDb, jobId: uint64): WarpJob =
  ## 反映確認済みにする。将来の galaxy ack / queue compaction のための薄い境界。
  let idx = db.findWarpJob(jobId)
  if idx < 0:
    raise newException(KeyError, "warp job not found")
  var job = db.warpJobs[idx]
  if job.status != wsDone:
    raise newException(ValueError, "only done warp jobs can be acknowledged")
  job.acknowledged = true
  db.warpJobs[idx] = job
  db.persistWarpJob(job)
  job

proc pruneAckedWarpJobs*(db: KoutenDb): int =
  ## ack 済み warp job を queue から取り除く。永続 Store では WD tombstone を追記する。
  for i in countdown(db.warpJobs.len - 1, 0):
    if db.warpJobs[i].acknowledged:
      let jobId = db.warpJobs[i].id
      db.warpJobs.delete(i)
      if db.mode == mEmbedded and not db.st.isNil:
        db.st.deleteWarpJob(jobId)
      inc result

proc warpStep*(db: KoutenDb, jobId: uint64, maxRecords = 100,
               now = -1.0): WarpJob =
  ## warp job を少しだけ進める。1回で走査する上限は maxRecords。
  ## 大きな ring でも同期 JOIN のように全件を握らず、呼び出し側が刻んで進められる。
  if maxRecords <= 0:
    raise newException(ValueError, "maxRecords must be positive")
  let idx = db.findWarpJob(jobId)
  if idx < 0:
    raise newException(KeyError, "warp job not found")
  var job = db.warpJobs[idx]
  let current = if now >= 0.0: now else: epochTime()
  if job.status in {wsDone, wsDeadLetter}:
    return job
  if job.status == wsFailed and job.retryAt > current:
    return job

  job.status = wsRunning
  job.error = ""
  var remaining = maxRecords
  var updates: seq[tuple[id: KoutenId, doc: JsonNode]] = @[]
  try:
    while remaining > 0 and job.ringIndex < job.rings.len:
      let page = db.listByRing(job.rings[job.ringIndex], limit = remaining,
                               cursor = job.cursor)
      for rec in page.items:
        inc job.scanned
        dec remaining
        var doc: JsonNode
        try:
          doc = parseJson(rec.payload)
        except JsonParsingError:
          continue
        let found = doc.jsonField(job.whereField)
        if not found.isNil and found == job.equals:
          inc job.matched
          let before = $doc
          doc.mergePatch(job.patch)
          if $doc != before:
            updates.add (rec.id, doc)
      if page.nextCursor.len > 0:
        job.cursor = page.nextCursor
      else:
        inc job.ringIndex
        job.cursor = ""

    if updates.len > 0:
      db.transaction(proc(tx: KoutenTx) =
        for item in updates:
          tx.update(item.id, item.doc)
      )
      job.updated += updates.len
    if job.ringIndex >= job.rings.len:
      job.status = wsDone
  except CatchableError as e:
    inc job.attempts
    job.error = e.msg
    if job.attempts >= job.maxAttempts:
      job.status = wsDeadLetter
    else:
      job.status = wsFailed
      job.retryAt = current + warpRetryDelaySeconds(job.attempts)

  db.warpJobs[idx] = job
  db.persistWarpJob(job)
  job

proc warpDrain*(db: KoutenDb, jobId: uint64, maxSteps = 1000,
                maxRecordsPerStep = 100): WarpJob =
  ## テスト・バッチ用途。通常運用では scheduler が warpStep を刻んで呼ぶ。
  if maxSteps <= 0:
    raise newException(ValueError, "maxSteps must be positive")
  for _ in 0 ..< maxSteps:
    result = db.warpStep(jobId, maxRecords = maxRecordsPerStep)
    if result.status in {wsDone, wsDeadLetter}:
      return
    if result.status == wsFailed:
      return
  result = db.warpStatus(jobId)

proc batchRemove*(db: KoutenDb, ids: seq[KoutenId]) =
  ## 複数 ID を削除する。v1 は embedded 専用。
  doAssert db.mode == mEmbedded, "batchRemove は embedded mode 専用"
  for id in ids:
    db.remove(id)

proc batchDelete*(db: KoutenDb, ids: seq[KoutenId]) =
  db.batchRemove(ids)

proc query*(db: KoutenDb, id: KoutenId, prepared: PreparedSelection): JsonNode =
  ## 選択取得（GraphQL 風, 設計書 §15）。payload は JSON であること。
  ## prepareSelection validates and parses the projection once for reuse.
  ## クラスタではサーバ側で射影され、選択した分だけがネットワークを流れる。
  case db.mode
  of mEmbedded:
    let p = db.st.getParticle(id.parent, id.seq)
    if not p.codec.supportsJsonProjection:
      raise newException(ValueError,
        "payload codec " & p.codec.payloadCodecName & " does not support JSON projection")
    applySelection(prepared, parseJson(p.payload))
  of mCluster:
    parseJson(db.fetchClusterPayload(id, prepared.source).data)

proc query*(db: KoutenDb, id: KoutenId, selection: string): JsonNode =
  ## Convenience form. Reuse PreparedSelection on hot paths.
  db.query(id, prepareSelection(selection))

proc contains*(db: KoutenDb, id: KoutenId): bool =
  ## `id in db` と書ける（組み込みモード）。
  db.exists(id)

# ---------------------------------------------------------------- 局所探索 / RAG 候補取得

proc ringKeyForRead(db: KoutenDb, ring: string): uint64 =
  if ring == "halo":
    return HaloKey
  if ring in db.ringNames:
    return db.ringNames[ring]
  uint64(hash(ring)) or 1'u64

proc ringMetrics*(db: KoutenDb): seq[RingMetric]
proc ringSummaries*(db: KoutenDb, queryVec: seq[float32] = @[]): seq[KoutenRingSummary]

proc `$`*(id: KoutenId): string =
  $id.parent & ":" & $id.seq

proc id*(builder: KoutenFilterBuilder; koutenId: KoutenId): KoutenFilterBuilder =
  ## Match a KoutenDB ID without asking callers to manually stringify it.
  builder.id($koutenId.parent & ":" & $koutenId.epoch & ":" &
             $koutenId.seq & ":" & $koutenId.tWrite)

proc focusToTopRings*(focus: int): int =
  ## ユーザー向けの探索幅 1..100 を、内部 topRings 2..500 に写像する。
  ## 値が高いほど広く探す。1 ring にはしない（recall の歯止め）。
  let f = max(1, min(100, focus))
  max(2, min(500, 2 + ((f - 1) * 498 + 98) div 99))

proc clampTopRings*(topRings: int): int =
  ## 0 は ring 絞り込み無効。正数指定時は recall の歯止めとして 2..500 に収める。
  if topRings <= 0: 0 else: max(2, min(500, topRings))

proc ringNameOf(db: KoutenDb, key: uint64): string =
  db.ringKeyNames.getOrDefault(key, $key)

proc descendantRingKeys(db: KoutenDb, root: uint64, maxDepth, branchBudget: int): seq[uint64] =
  result.add root
  if maxDepth <= 0:
    return
  var queue: seq[tuple[key: uint64, depth: int]] = @[(key: root, depth: 0)]
  var idx = 0
  while idx < queue.len:
    let current = queue[idx]
    inc idx
    if current.depth >= maxDepth:
      continue
    var children = db.ringChildren.getOrDefault(current.key, @[])
    if branchBudget > 0 and children.len > branchBudget:
      children.setLen(branchBudget)
    for child in children:
      result.add child
      queue.add (key: child, depth: current.depth + 1)

proc parentRingKey(db: KoutenDb, key: uint64): uint64 =
  let name = db.ringNameOf(key)
  let parentName = parentRingName(name)
  if parentName.len > 0 and parentName in db.ringNames:
    db.ringNames[parentName]
  else:
    0'u64

proc stellarNeighborKeys(db: KoutenDb, root: uint64, maxDepth, branchBudget: int): seq[uint64] =
  ## Coordinate-near read set. It includes the target ring, its nearby
  ## descendants, and parent/sibling rings inside the configured field of view.
  result.add root
  if maxDepth <= 0:
    return

  for key in db.descendantRingKeys(root, maxDepth, branchBudget):
    result.addUniqueRingKey(key)

  var current = root
  for depth in 1 .. maxDepth:
    let parent = db.parentRingKey(current)
    if parent == 0'u64:
      break
    result.addUniqueRingKey(parent)
    var siblings = db.ringChildren.getOrDefault(parent, @[])
    if branchBudget > 0 and siblings.len > branchBudget:
      siblings.setLen(branchBudget)
    for sibling in siblings:
      result.addUniqueRingKey(sibling)
    current = parent

proc addUniqueRingKey(keys: var seq[uint64], key: uint64) =
  if key notin keys:
    keys.add key

proc siblingRingKeys(db: KoutenDb, root: uint64, siblingBudget: int): seq[uint64] =
  let name = db.ringNameOf(root)
  let parentName = parentRingName(name)
  if parentName.len == 0 or parentName notin db.ringNames:
    return @[]
  let parentKey = db.ringNames[parentName]
  var siblings = db.ringChildren.getOrDefault(parentKey, @[])
  for sibling in siblings:
    if sibling != root:
      result.add sibling
      if siblingBudget > 0 and result.len >= siblingBudget:
        break

proc scopeSiblingBudget(plan: RetrievalPlan): int =
  case plan.scope
  of "ssNear": 2
  of "ssWide": max(4, plan.branchBudget)
  of "ssAll": 0
  else: -1

proc ringSummaryTable(db: KoutenDb, queryVec: seq[float32],
                      ringKeys: seq[uint64]): Table[uint64, KoutenRingSummary] =
  let q = queryVec.normalize()
  case db.mode
  of mEmbedded:
    for ring in ringKeys:
      var centroid: seq[float32] = @[]
      var n = 0
      for k in db.st.itemsByRing.getOrDefault(ring, @[]):
        if k notin db.st.items:
          continue
        let p = db.st.items[k]
        if p.vec.len == 0:
          continue
        if centroid.len == 0:
          centroid = newSeq[float32](p.vec.len)
        if centroid.len != p.vec.len:
          continue
        for i in 0 ..< p.vec.len:
          centroid[i] = float32((float(centroid[i]) * float(n) +
                                 float(p.vec[i])) / float(n + 1))
        inc n
        centroid = centroid.normalize()
      let score = if q.len > 0 and q.len == centroid.len:
                    1.0 - cosineDistance(q, centroid)
                  else:
                    0.0
      var meanDist = 0.0
      var distN = 0
      if centroid.len > 0:
        for k in db.st.itemsByRing.getOrDefault(ring, @[]):
          if k notin db.st.items:
            continue
          let p = db.st.items[k]
          if p.vec.len != centroid.len:
            continue
          meanDist += cosineDistance(p.vec, centroid)
          inc distN
      if distN > 0:
        meanDist /= float(distN)
      let coherence = if distN > 0: max(0.0, min(1.0, 1.0 - meanDist)) else: 0.0
      result[ring] = KoutenRingSummary(ringKey: ring, count: n,
                                      centroid: centroid, score: score,
                                      coherence: coherence,
                                      massG: float(n) * coherence)
  of mCluster:
    let wanted = block:
      var t = initTable[uint64, bool]()
      for ring in ringKeys:
        t[ring] = true
      t
    for rs in db.ringSummaries(q):
      if rs.ringKey in wanted:
        result[rs.ringKey] = rs

proc expandPlan(db: KoutenDb, plan: RetrievalPlan,
                queryVec: seq[float32] = @[],
                computeFeatures = true): RetrievalPlan =
  result = plan
  if plan.baseRing.len == 0:
    return
  let root = db.ringKeyForRead(plan.baseRing)
  var keys =
    if plan.includeChildren:
      db.descendantRingKeys(root, plan.maxDepth, plan.branchBudget)
    else:
      @[root]
  let siblingBudget = plan.scopeSiblingBudget()
  if siblingBudget >= 0:
    for sibling in db.siblingRingKeys(root, siblingBudget):
      keys.addUniqueRingKey sibling
      if plan.includeChildren:
        for child in db.descendantRingKeys(sibling, plan.maxDepth, plan.branchBudget):
          keys.addUniqueRingKey child

  let summaryByRing =
    if computeFeatures:
      db.ringSummaryTable(queryVec, keys)
    else:
      initTable[uint64, KoutenRingSummary]()
  var candidates: seq[RingPlanCandidate] = @[]
  for key in keys:
    let summary = summaryByRing.getOrDefault(
      key,
      KoutenRingSummary(ringKey: key, count: 0, centroid: @[], score: 0.0))
    let utility = summary.coherence * (1.0 - 1.0 / float(summary.count + 1))
    candidates.add RingPlanCandidate(
      key: key,
      name: db.ringNameOf(key),
      score: summary.score,
      centroidScore: summary.score,
      ringCount: summary.count,
      utility: utility,
      isBase: key == root,
      isSibling: key != root and parentRingName(db.ringNameOf(key)) == parentRingName(plan.baseRing),
      isDescendant: key != root and db.ringNameOf(key).startsWith(plan.baseRing & "/"))

  let selection = db.plannerBackend.selectRings(candidates)
  result.ringFeatures = selection.selected & selection.pruned
  result.selectedRings = @[]
  result.prunedRings = @[]
  for c in selection.selected:
    result.selectedRings.add c.name
  for c in selection.pruned:
    result.prunedRings.add c.name

proc retrievalPlan*(ring: string = "", budget = 8, topRings = 0, focus = 0,
                    includeChildren = false, maxDepth = 0,
                    branchBudget = 0, profile = "",
                    amount = raNormal, scope = ssTight,
                    depth = sdNormal): RetrievalPlan =
  ## 物理配置を変えない retrieval 実行計画。SQL tuning の knob に相当する。
  result.profile = profile
  result.baseRing = ring
  result.amount = $amount
  result.scope = $scope
  result.depth = $depth
  result.ringScoped = ring.len > 0
  result.budget = max(0, budget)
  result.focus = max(0, min(100, focus))
  result.topRings = topRings
  result.effectiveTopRings =
    if focus > 0: focusToTopRings(focus) else: clampTopRings(topRings)
  result.includeChildren = includeChildren
  result.maxDepth = max(0, maxDepth)
  result.branchBudget = max(0, branchBudget)
  if ring.len > 0:
    result.strategy = if includeChildren: "hierarchical-ring" else: "ring-scoped"
    result.selectedRings = @[ring]
    result.reason = "explicit ring scope"
  elif result.effectiveTopRings > 0:
    result.strategy = "top-rings"
    result.reason = "focus/topRings selected"
  else:
    result.strategy = "global"
    result.reason = "no ring scope"

proc ringCandidateJson(c: RingPlanCandidate): JsonNode =
  %*{
    "ring": c.name,
    "key": $c.key,
    "score": c.score,
    "centroidScore": c.centroidScore,
    "ringCount": c.ringCount,
    "utility": c.utility,
    "isBase": c.isBase,
    "isSibling": c.isSibling,
    "isDescendant": c.isDescendant
  }

proc planJson*(plan: RetrievalPlan): JsonNode =
  var features = newJArray()
  for c in plan.ringFeatures:
    features.add c.ringCandidateJson()
  %*{
    "strategy": plan.strategy,
    "profile": plan.profile,
    "baseRing": plan.baseRing,
    "amount": plan.amount,
    "scope": plan.scope,
    "depth": plan.depth,
    "ringScoped": plan.ringScoped,
    "budget": plan.budget,
    "focus": plan.focus,
    "topRings": plan.topRings,
    "effectiveTopRings": plan.effectiveTopRings,
    "branchBudget": plan.branchBudget,
    "maxDepth": plan.maxDepth,
    "includeChildren": plan.includeChildren,
    "reason": plan.reason,
    "selectedRings": plan.selectedRings,
    "prunedRings": plan.prunedRings,
    "ringFeatures": features
  }

proc tunedRetrievalPlan*(db: KoutenDb, ring: string = "", profile = "default",
                         budget = 0, topRings = -1, focus = -1,
                         includeChildren = false, maxDepth = -1,
                         branchBudget = -1): RetrievalPlan =
  ## 登録済み tuning profile を使って実行計画を作る。
  ## 引数に正の値を渡した項目は profile より優先される。
  let t = db.retrievalTuning(profile)
  let sp = db.searchProfiles.getOrDefault(profile, defaultSearchProfile())
  db.expandPlan(retrievalPlan(
    ring = ring,
    budget = if budget > 0: budget else: t.budget,
    topRings = if topRings >= 0: topRings else: t.topRings,
    focus = if focus >= 0: focus else: t.focus,
    includeChildren = includeChildren or t.includeChildren,
    maxDepth = if maxDepth >= 0: maxDepth else: t.maxDepth,
    branchBudget = if branchBudget >= 0: branchBudget else: t.branchBudget,
    profile = profile,
    amount = sp.amount,
    scope = sp.scope,
    depth = sp.depth), computeFeatures = false)

proc searchPlan*(ring: string = "", amount = raNormal, scope = ssTight,
                 depth = sdNormal,
                 profile = ""): RetrievalPlan =
  ## 人間向け語彙から実行計画を作る。
  let tuning = tuningFromSearchProfile(SearchProfile(amount: amount,
                                                     scope: scope,
                                                     depth: depth))
  retrievalPlan(ring = ring, budget = tuning.budget,
                topRings = tuning.topRings, focus = tuning.focus,
                includeChildren = tuning.includeChildren,
                maxDepth = tuning.maxDepth,
                branchBudget = tuning.branchBudget,
                profile = profile, amount = amount, scope = scope,
                depth = depth)

proc ringSummaries*(db: KoutenDb, queryVec: seq[float32] = @[]): seq[KoutenRingSummary] =
  ## クラスタ/組み込みの環 summary。queryVec を渡すと近い順に score 付きで返す。
  let q = queryVec.normalize()
  case db.mode
  of mEmbedded:
    var merged = initTable[uint64, tuple[c: seq[float32], n: int]]()
    for _, p in db.st.items:
      if p.vec.len == 0:
        continue
      var e = merged.getOrDefault(p.parent, (c: newSeq[float32](p.vec.len), n: 0))
      if e.c.len != p.vec.len:
        continue
      for i in 0 ..< p.vec.len:
        e.c[i] = float32((float(e.c[i]) * float(e.n) + float(p.vec[i])) / float(e.n + 1))
      inc e.n
      e.c = e.c.normalize()
      merged[p.parent] = e
    for ring, e in merged:
      let score = if q.len > 0 and q.len == e.c.len: 1.0 - cosineDistance(q, e.c) else: 0.0
      var meanDist = 0.0
      var distN = 0
      for _, p in db.st.items:
        if p.parent == ring and p.vec.len == e.c.len:
          meanDist += cosineDistance(p.vec, e.c)
          inc distN
      if distN > 0:
        meanDist /= float(distN)
      let coherence = if distN > 0: max(0.0, min(1.0, 1.0 - meanDist)) else: 0.0
      result.add KoutenRingSummary(ringKey: ring, count: e.n,
                                  centroid: e.c, score: score,
                                  coherence: coherence,
                                  massG: float(e.n) * coherence)
  of mCluster:
    var merged = initTable[uint64, tuple[c: seq[float32], n: int]]()
    for node in 0 ..< db.client.peers.len:
      for rs in db.client.ringsReq(node):
        if rs.centroid.len == 0:
          continue
        var e = merged.getOrDefault(rs.ringKey,
                                    (c: newSeq[float32](rs.centroid.len), n: 0))
        if e.c.len != rs.centroid.len:
          continue
        for i in 0 ..< rs.centroid.len:
          e.c[i] = float32((float(e.c[i]) * float(e.n) +
                            float(rs.centroid[i]) * float(rs.count)) /
                           float(e.n + rs.count))
        e.n += rs.count
        e.c = e.c.normalize()
        merged[rs.ringKey] = e
    for ring, e in merged:
      let score = if q.len > 0 and q.len == e.c.len: 1.0 - cosineDistance(q, e.c) else: 0.0
      result.add KoutenRingSummary(ringKey: ring, count: e.n,
                                  centroid: e.c, score: score,
                                  coherence: 0.0,
                                  massG: 0.0)
  result.sort(proc(a, b: KoutenRingSummary): int =
    let byScore = cmp(b.score, a.score)
    if byScore != 0: byScore else: cmp(b.count, a.count))

proc ringDepth(name: string): int =
  if name.len == 0:
    return 0
  result = 1
  for ch in name:
    if ch == '/':
      inc result

proc centroidPreview(vec: seq[float32], maxDims: int): JsonNode =
  result = newJArray()
  let n = min(vec.len, max(0, maxDims))
  for i in 0 ..< n:
    result.add %vec[i]

proc atlas*(db: KoutenDb, queryVec: seq[float32] = @[],
            maxCentroidDims = 8): JsonNode =
  ## LLM / agent が最初に読む全体地図。
  ## payload 本文は返さず、galaxy・ring 階層・件数・coherence・massG・centroid の
  ## preview だけを返す。全体 corpus を読む前の orientation step に使う。
  var summaryByRing = initTable[uint64, KoutenRingSummary]()
  for rs in db.ringSummaries(queryVec):
    summaryByRing[rs.ringKey] = rs

  var docCounts = initTable[uint64, int]()
  if db.mode == mEmbedded:
    for _, p in db.st.items:
      docCounts[p.parent] = docCounts.getOrDefault(p.parent, 0) + 1

  var ringKeys: seq[uint64] = @[]
  for key in db.rings.keys:
    ringKeys.addUniqueRingKey(key)
  for key in db.ringKeyNames.keys:
    ringKeys.addUniqueRingKey(key)
  for key in summaryByRing.keys:
    ringKeys.addUniqueRingKey(key)
  ringKeys.sort(proc(a, b: uint64): int = cmp(db.ringNameOf(a), db.ringNameOf(b)))

  var rings = newJArray()
  var totalDocs = 0
  var vectorDocs = 0
  for key in ringKeys:
    let name = db.ringNameOf(key)
    let parentName = parentRingName(name)
    let parentKey =
      if parentName.len > 0 and parentName in db.ringNames:
        db.ringNames[parentName]
      else:
        0'u64
    let ri = db.rings.getOrDefault(key, RingInfo(period: DefaultPeriod,
                                                headAngle: 0.0))
    let rs = summaryByRing.getOrDefault(key, KoutenRingSummary(ringKey: key))
    let docs =
      if key in docCounts: docCounts[key]
      else: rs.count
    totalDocs += docs
    vectorDocs += rs.count

    var children = newJArray()
    for child in db.ringChildren.getOrDefault(key, @[]):
      children.add %db.ringNameOf(child)

    rings.add %*{
      "name": name,
      "key": $key,
      "description": db.ringDescriptions.getOrDefault(key, ""),
      "parent": parentName,
      "parentKey": (if parentKey == 0'u64: "" else: $parentKey),
      "children": children,
      "depth": ringDepth(name),
      "documents": docs,
      "vectorDocuments": rs.count,
      "coherence": rs.coherence,
      "massG": rs.massG,
      "score": rs.score,
      "period": ri.period,
      "head": ri.headAngle,
      "centroidDims": rs.centroid.len,
      "centroidPreview": centroidPreview(rs.centroid, maxCentroidDims)
    }

  result = %*{
    "schema": AtlasSchema,
    "version": AtlasVersion,
    "galaxyMap": {
      "galaxy": db.galaxy,
      "description": db.galaxyDescription,
      "mode": (case db.mode
               of mEmbedded: "embedded"
               of mCluster: "cluster"),
      "nodes": int(db.tbl.nNodes),
      "rings": ringKeys.len,
      "documents": totalDocs,
      "vectorDocuments": vectorDocs,
      "purpose": "orientation-before-retrieval"
    },
    "ringMap": rings,
    "usage": {
      "write": "put documents into human/app/import-rule rings",
      "read": "select rings from this atlas, then retrieve/query only the needed scope",
      "memory": "reduce scanned candidates before ANN/rerank/LLM stages"
    }
  }

proc fillReturnedPayloadStats(stats: var RetrieveStats; hits: seq[KoutenHit]) =
  stats.returned = hits.len
  stats.payloadBytes = 0
  for h in hits:
    stats.payloadBytes += h.payload.len
  stats.estimatedTokens = (stats.payloadBytes + 3) div 4

proc retrieveWithStats*(db: KoutenDb, queryVec: seq[float32], ring: string = "",
                        budget = 8, topRings = 0, focus = 0,
                        includeChildren = false, maxDepth = 0,
                        branchBudget = 0, profile = "",
                        amount = raNormal, scope = ssTight,
                        depth = sdNormal):
                        tuple[hits: seq[KoutenHit], stats: RetrieveStats,
                              plan: RetrievalPlan] =
  ## 埋め込み近傍と探索統計を一回の探索で返す。
  ## RAG/MCP 経路では retrieve + retrieveStats の二重探索を避けるためこれを使う。
  let q = queryVec.normalize()
  if q.len == 0 or budget <= 0:
    return
  let needsPlanFeatures = ring.len > 0 and (includeChildren or scope != ssTight)
  result.plan = db.expandPlan(retrievalPlan(ring = ring, budget = budget,
                                            topRings = topRings, focus = focus,
                                            includeChildren = includeChildren,
                                            maxDepth = maxDepth,
                                            branchBudget = branchBudget,
                                            profile = profile,
                                            amount = amount,
                                            scope = scope, depth = depth), q,
                              computeFeatures = needsPlanFeatures)
  let ringKeys =
    if ring.len > 0:
      var keys: seq[uint64] = @[]
      for name in result.plan.selectedRings:
        keys.add db.ringKeyForRead(name)
      keys
    else:
      @[]
  let ringFilter = if ringKeys.len == 1: ringKeys[0] else: 0'u64
  case db.mode
  of mEmbedded:
    let rr =
      if ringKeys.len > 1:
        db.vectorBackend.searchMany(db.st, q, ringKeys, budget)
      else:
        db.vectorBackend.search(db.st, q, ring.len > 0, ringFilter, budget)
    for h in rr.hits:
      result.hits.add KoutenHit(id: KoutenId(parent: h.parent, epoch: db.tbl.epoch,
                                           seq: h.seq, tWrite: h.tWrite),
                               score: h.score, payload: h.payload,
                               codec: h.codec)
    result.stats.totalVectors = rr.totalVectors
    result.stats.scanned = rr.scanned
    result.stats.skippedVectors = rr.skippedVectors
    result.stats.ringsTouched = rr.ringsTouched
    result.stats.fanoutNodes = 1
    result.stats.fillReturnedPayloadStats(result.hits)
  of mCluster:
    var countedNodes = initTable[int, bool]()
    var contactedNodes = initTable[int, bool]()
    template mergeRetrieve(node: int, rr: RetrieveWireResult) =
      contactedNodes[node] = true
      if node notin countedNodes:
        result.stats.totalVectors += rr.totalVectors
        countedNodes[node] = true
      result.stats.scanned += rr.scanned
      result.stats.ringsTouched += rr.ringsTouched
      for h in rr.hits:
        result.hits.add KoutenHit(
          id: KoutenId(parent: h.parent, epoch: db.tbl.epoch,
                       seq: h.seq, tWrite: h.tWrite),
          score: h.score, payload: h.payload, codec: h.codec)
    if ringKeys.len > 0:
      for ringKey in ringKeys:
        let node = int(db.tbl.placementOwner(ringKey))
        let rr = db.client.retrieveReq(node, true, ringKey, q, budget)
        mergeRetrieve(node, rr)
    elif result.plan.effectiveTopRings <= 0:
      for node in 0 ..< db.client.peers.len:
        let rr = db.client.retrieveReq(node, ring.len > 0, ringFilter, q, budget)
        mergeRetrieve(node, rr)
    else:
      var rings = db.ringSummaries(q)
      if rings.len > result.plan.effectiveTopRings:
        rings.setLen(result.plan.effectiveTopRings)
      for rs in rings:
        let node = int(db.tbl.placementOwner(rs.ringKey))
        let rr = db.client.retrieveReq(node, true, rs.ringKey, q, budget)
        mergeRetrieve(node, rr)
    result.stats.fanoutNodes = contactedNodes.len
  result.hits.sort(proc(a, b: KoutenHit): int = cmp(b.score, a.score))
  if result.hits.len > budget:
    result.hits.setLen(budget)
  result.stats.skippedVectors = max(0, result.stats.totalVectors - result.stats.scanned)
  result.stats.fillReturnedPayloadStats(result.hits)
  if result.stats.totalVectors > 0:
    result.stats.candidateReduction =
      1.0 - float(result.stats.scanned) / float(result.stats.totalVectors)

proc retrieve*(db: KoutenDb, queryVec: seq[float32], ring: string = "",
               budget = 8, topRings = 0, focus = 0): seq[KoutenHit] =
  ## 埋め込み近傍を取得する。ring を指定すると、その環だけを探索する。
  ## cluster は ring 所有ノードへ直接送り、global 探索だけ全ノードを使う。
  db.retrieveWithStats(queryVec, ring = ring, budget = budget,
                       topRings = topRings, focus = focus).hits

proc retrieveStats*(db: KoutenDb, queryVec: seq[float32], ring: string = "",
                    budget = 8, topRings = 0, focus = 0): RetrieveStats =
  ## retrieve の探索幅を測るための軽量 stats。
  db.retrieveWithStats(queryVec, ring = ring, budget = budget,
                       topRings = topRings, focus = focus).stats

proc retrieveTunedWithStats*(db: KoutenDb, queryVec: seq[float32],
                             ring: string = "", profile = "default"):
                             tuple[hits: seq[KoutenHit], stats: RetrieveStats,
                                   plan: RetrievalPlan] =
  ## tuning profile を使って retrieve する。
  ## RDB の optimizer profile / hint を切り替えるのに近い API。
  result.plan = db.tunedRetrievalPlan(ring = ring, profile = profile)
  let sp = db.searchProfiles.getOrDefault(profile, defaultSearchProfile())
  let rr = db.retrieveWithStats(queryVec, ring = ring,
                                budget = result.plan.budget,
                                topRings = result.plan.topRings,
                                focus = result.plan.focus,
                                includeChildren = result.plan.includeChildren,
                                maxDepth = result.plan.maxDepth,
                                branchBudget = result.plan.branchBudget,
                                profile = profile,
                                amount = sp.amount,
                                scope = sp.scope,
                                depth = sp.depth)
  result.hits = rr.hits
  result.stats = rr.stats
  result.plan = rr.plan

proc retrieveTuned*(db: KoutenDb, queryVec: seq[float32],
                    ring: string = "", profile = "default"): seq[KoutenHit] =
  db.retrieveTunedWithStats(queryVec, ring = ring, profile = profile).hits

proc defaultRetrievalEnvelopeOptions*(db: KoutenDb, ring = ""): RetrievalEnvelopeOptions =
  ## Shelfer などの外部 runtime が使う安定 envelope の既定値。
  result.provider = "koutendb"
  result.galaxy = db.galaxy
  result.ring = ring
  result.backend =
    case db.mode
    of mEmbedded: "exact"
    of mCluster: "cluster"
  result.mode = "vector"
  result.sourceType = "document"
  result.resourceKind = "rag"
  result.resourceScope = if ring.len > 0: "topic" else: "persistent"
  result.retentionClass = "normal"
  result.contextReusable = true
  result.dataLabel = ""
  result.plan = retrievalPlan(ring = ring)

proc retrievalEnvelope*(
    hits: seq[KoutenHit];
    stats: RetrieveStats;
    opts: RetrievalEnvelopeOptions;
    budget = 8;
    ringScoped = false): JsonNode =
  ## retrieve 結果を KoutenDB 依存の薄い JSON 契約に変換する。
  ## KoutenDB core は Shelfer に依存せず、Shelfer adapter はこの envelope を消費する。
  var chunks = newJArray()
  for h in hits:
    let payloadBytes = h.payload.len
    chunks.add %*{
      "id": $h.id,
      "payload": h.payload,
      "score": h.score,
      "estimatedTokens": (payloadBytes + 3) div 4,
      "ring": opts.ring,
      "sourceUri": "koutendb://" & opts.galaxy & "/" & opts.ring & "/" & $h.id
    }

  result = %*{
    "schema": RetrievalEnvelopeSchema,
    "version": RetrievalEnvelopeVersion,
    "source": {
      "provider": opts.provider,
      "galaxy": opts.galaxy,
      "ring": opts.ring,
      "backend": opts.backend,
      "sourceType": opts.sourceType
    },
    "query": {
      "mode": opts.mode,
      "budget": budget,
      "ringScoped": ringScoped
    },
    "plan": opts.plan.planJson(),
    "chunks": chunks,
    "stats": {
      "totalVectors": stats.totalVectors,
      "scanned": stats.scanned,
      "skippedVectors": stats.skippedVectors,
      "returned": stats.returned,
      "ringsTouched": stats.ringsTouched,
      "fanoutNodes": stats.fanoutNodes,
      "payloadBytes": stats.payloadBytes,
      "estimatedTokens": stats.estimatedTokens,
      "candidateReduction": stats.candidateReduction
    },
    "policyHints": {
      "resourceKind": opts.resourceKind,
      "resourceScope": opts.resourceScope,
      "retentionClass": opts.retentionClass,
      "contextReusable": opts.contextReusable,
      "dataLabel": opts.dataLabel
    }
  }
  if opts.requestId.len > 0 or opts.correlationId.len > 0:
    result["trace"] = %*{
      "requestId": opts.requestId,
      "correlationId": opts.correlationId
    }

proc retrievalEnvelope*(db: KoutenDb, queryVec: seq[float32], ring: string = "",
                        budget = 8, topRings = 0, focus = 0): JsonNode =
  ## 便利版。retrieve と retrieveStats をまとめて envelope 化する。
  let rr = db.retrieveWithStats(queryVec, ring = ring, budget = budget,
                                topRings = topRings, focus = focus)
  var opts = db.defaultRetrievalEnvelopeOptions(ring)
  opts.plan = db.expandPlan(rr.plan, queryVec.normalize(), computeFeatures = true)
  retrievalEnvelope(rr.hits, rr.stats, opts,
                    budget = budget, ringScoped = ring.len > 0)

proc retrievalEnvelopeTuned*(db: KoutenDb, queryVec: seq[float32],
                             ring: string = "", profile = "default"): JsonNode =
  ## tuning profile を使って retrieval envelope を作る。
  let rr = db.retrieveTunedWithStats(queryVec, ring = ring, profile = profile)
  var opts = db.defaultRetrievalEnvelopeOptions(ring)
  opts.plan = db.expandPlan(rr.plan, queryVec.normalize(), computeFeatures = true)
  retrievalEnvelope(rr.hits, rr.stats, opts,
                    budget = rr.plan.budget, ringScoped = ring.len > 0)

proc retrievalEnvelopeValidationErrors*(env: JsonNode): seq[string] =
  ## KoutenDB retrieval envelope v1 の互換性チェック。
  ## 外部 adapter はこの結果が空であることを受け入れ条件にできる。
  if env == nil or env.kind != JObject:
    return @["envelope must be a JSON object"]

  template requireObject(key: string) =
    if not env.hasKey(key) or env[key].kind != JObject:
      result.add key & " must be an object"

  template requireArray(key: string) =
    if not env.hasKey(key) or env[key].kind != JArray:
      result.add key & " must be an array"

  if env{"schema"}.getStr("") != RetrievalEnvelopeSchema:
    result.add "schema must be " & RetrievalEnvelopeSchema
  if env{"version"}.getInt(0) != RetrievalEnvelopeVersion:
    result.add "version must be " & $RetrievalEnvelopeVersion

  requireObject("source")
  requireObject("query")
  requireObject("plan")
  requireArray("chunks")
  requireObject("stats")
  requireObject("policyHints")

  if env.hasKey("source") and env["source"].kind == JObject:
    let source = env["source"]
    for key in ["provider", "backend", "sourceType"]:
      if source{key}.getStr("").len == 0:
        result.add "source." & key & " must be a non-empty string"

  if env.hasKey("query") and env["query"].kind == JObject:
    let query = env["query"]
    if query{"mode"}.getStr("").len == 0:
      result.add "query.mode must be a non-empty string"
    if query{"budget"}.getInt(-1) < 0:
      result.add "query.budget must be >= 0"
    if not query.hasKey("ringScoped") or query["ringScoped"].kind != JBool:
      result.add "query.ringScoped must be a boolean"

  if env.hasKey("plan") and env["plan"].kind == JObject:
    let plan = env["plan"]
    for key in ["strategy", "reason", "amount", "scope", "depth"]:
      if plan{key}.getStr("").len == 0:
        result.add "plan." & key & " must be a non-empty string"
    for key in ["budget", "focus", "effectiveTopRings", "branchBudget", "maxDepth"]:
      if plan{key}.getInt(-1) < 0:
        result.add "plan." & key & " must be >= 0"
    if not plan.hasKey("ringScoped") or plan["ringScoped"].kind != JBool:
      result.add "plan.ringScoped must be a boolean"
    if not plan.hasKey("includeChildren") or plan["includeChildren"].kind != JBool:
      result.add "plan.includeChildren must be a boolean"

  if env.hasKey("chunks") and env["chunks"].kind == JArray:
    var i = 0
    for chunk in env["chunks"].items:
      if chunk.kind != JObject:
        result.add "chunks[" & $i & "] must be an object"
        inc i
        continue
      for key in ["id", "payload", "ring", "sourceUri"]:
        if not chunk.hasKey(key) or chunk[key].kind != JString:
          result.add "chunks[" & $i & "]." & key & " must be a string"
      if not chunk.hasKey("score") or chunk["score"].kind notin {JInt, JFloat}:
        result.add "chunks[" & $i & "].score must be numeric"
      if chunk{"estimatedTokens"}.getInt(-1) < 0:
        result.add "chunks[" & $i & "].estimatedTokens must be >= 0"
      inc i

  if env.hasKey("stats") and env["stats"].kind == JObject:
    let stats = env["stats"]
    for key in ["totalVectors", "scanned", "skippedVectors", "returned",
                "ringsTouched", "fanoutNodes", "payloadBytes", "estimatedTokens"]:
      if stats{key}.getInt(-1) < 0:
        result.add "stats." & key & " must be >= 0"
    if not stats.hasKey("candidateReduction") or
        stats["candidateReduction"].kind notin {JInt, JFloat}:
      result.add "stats.candidateReduction must be numeric"

  if env.hasKey("policyHints") and env["policyHints"].kind == JObject:
    let hints = env["policyHints"]
    for key in ["resourceKind", "resourceScope", "retentionClass"]:
      if hints{key}.getStr("").len == 0:
        result.add "policyHints." & key & " must be a non-empty string"
    if not hints.hasKey("contextReusable") or hints["contextReusable"].kind != JBool:
      result.add "policyHints.contextReusable must be a boolean"

proc isValidRetrievalEnvelope*(env: JsonNode): bool =
  retrievalEnvelopeValidationErrors(env).len == 0

proc ringMetrics*(db: KoutenDb): seq[RingMetric] =
  ## 環ごとの意味的一貫性。coherence は 0..1 目安で、高いほど vec がまとまっている。
  doAssert db.mode == mEmbedded, "ringMetrics v1 は組み込みモード専用"
  var sums = initTable[uint64, tuple[c: seq[float32], n: int]]()
  for _, p in db.st.items:
    if p.vec.len == 0:
      continue
    var e = sums.getOrDefault(p.parent, (c: newSeq[float32](p.vec.len), n: 0))
    if e.c.len != p.vec.len:
      continue
    for i in 0 ..< p.vec.len:
      e.c[i] = float32((float(e.c[i]) * float(e.n) + float(p.vec[i])) / float(e.n + 1))
    inc e.n
    e.c = e.c.normalize()
    sums[p.parent] = e

  for ring, e in sums:
    if e.n == 0:
      continue
    var meanDist = 0.0
    for _, p in db.st.items:
      if p.parent == ring and p.vec.len == e.c.len:
        meanDist += cosineDistance(p.vec, e.c)
    meanDist /= float(e.n)
    result.add RingMetric(ringKey: ring, count: e.n,
                          coherence: max(0.0, min(1.0, 1.0 - meanDist)))
  result.sort(proc(a, b: RingMetric): int = cmp(b.count, a.count))

# ---------------------------------------------------------------- 所在（KoutenDB の核）

proc locate*(db: KoutenDb, id: KoutenId, at: float = -1.0): int =
  ## その ID が「どのノードにあるか」。at 省略で現在、未来時刻も渡せる。
  ## どちらのモードでも問い合わせゼロ・ローカル計算のみ（概念書 2章）。
  let t = if at < 0.0: db.nowT else: at
  int(db.tbl.node(db.orbitOf(id), t))

proc nextVisit*(db: KoutenDb, id: KoutenId, node: int): float =
  ## その ID が指定ノードに次に到着する時刻（プリフェッチ・バッチの予定表）。
  db.orbitOf(id).nextArrival(db.tbl.arcStart(NodeId(node)), db.nowT)

proc nextJoin*(db: KoutenDb, a, b: KoutenId): float =
  ## 2つの ID が次に同一ノードに同居する時刻（= ローカル JOIN できる瞬間）。
  ## 同周期で位相が合わない場合は -1（configureRing で 1:2 等の整数比に）。
  let oa = db.orbitOf(a)
  let ob = db.orbitOf(b)
  let t0 = db.nowT
  if oa.period == ob.period:
    return if db.tbl.node(oa, t0) == db.tbl.node(ob, t0): t0 else: -1.0
  let horizon = synodicPeriod(oa.period, ob.period) * 1.5
  for t in conjunctions(oa, ob, t0, horizon):
    if t >= t0: return t
  -1.0

# ---------------------------------------------------------------- 運用

proc stats*(db: KoutenDb): seq[tuple[node, count: int]] =
  ## ノードごとの保持件数（クラスタ運用の観察用）。
  case db.mode
  of mEmbedded:
    result.add (node: 0, count: db.st.count)
  of mCluster:
    for i in 0 ..< db.client.peers.len:
      result.add db.client.statsReq(i)

proc health*(db: KoutenDb): seq[string] =
  ## ノード health の簡易文字列表現。クラスタ readiness/liveness の土台。
  case db.mode
  of mEmbedded:
    result.add "node=0 items=" & $db.st.count & " pendingTx=" & $db.st.clusterTxPending
  of mCluster:
    for i in 0 ..< db.client.peers.len:
      result.add db.client.healthReq(i)

proc metrics*(db: KoutenDb): seq[string] =
  ## Backward-compatible key/value operational metrics.
  case db.mode
  of mEmbedded:
    let segment = db.st.segmentMetrics()
    result.add "node 0 items " & $db.st.count &
               " rings " & $db.st.ringMeta.len &
               " forwarders " & $db.st.forwarders.len &
               " walBytes " & $db.st.logSize &
               " persistent " & $(if db.st.isPersistent: 1 else: 0) &
               " durabilityStrong " &
                 $(if db.st.durability == durStrong: 1 else: 0) &
               " clusterTxCommitted " & $db.st.clusterTxCommitted &
               " clusterTxApplied " & $db.st.clusterTxApplied &
               " clusterTxPending " & $db.st.clusterTxPending &
               " universeSyncEvents " & $db.st.universeSyncEvents.len &
               " segmentHits " & $segment.hits &
               " segmentWalFallbacks " & $segment.walFallbacks &
               " segmentWalFallbackPointRead " &
                 $segment.walFallbackReasons[ssfrPointRead] &
               " segmentWalFallbackRingScan " &
                 $segment.walFallbackReasons[ssfrRingScan] &
               " segmentWalFallbackWindowRead " &
                 $segment.walFallbackReasons[ssfrWindowRead] &
               " segmentBytes " & $segment.segmentBytes &
               " segmentIndexBytes " & $segment.indexBytes &
               " segmentActiveGenerations " & $segment.activeGenerations &
               " segmentStaleRecords " & $segment.staleRecords &
               " segmentRecommendedRings " & $segment.recommendedRings &
               " guardrailDeniedPayloadBytes " &
                 $db.guardrailDenials[kgrPayloadBytes] &
               " guardrailDeniedVectorDim " &
                 $db.guardrailDenials[kgrVectorDimension] &
               " guardrailDeniedRingCount " &
                 $db.guardrailDenials[kgrRingCount] &
               " guardrailDeniedRecordsPerRing " &
                 $db.guardrailDenials[kgrRecordsPerRing]
  of mCluster:
    for i in 0 ..< db.client.peers.len:
      result.add db.client.metricsReq(i)

proc metricsText*(db: KoutenDb;
                  format = kmfPrometheus): string =
  ## Prometheus/OpenMetrics projection with bounded labels. Use `metrics()`
  ## when the legacy key/value contract is required.
  formatMetricLines(db.metrics(), format)

proc shutdownCluster*(db: KoutenDb): seq[string] =
  ## 運用・テスト用の graceful shutdown。認証導入までは信頼ネットワーク前提。
  doAssert db.mode == mCluster, "shutdownCluster はクラスタモード専用"
  for i in countdown(db.client.peers.high, 0):
    result.add db.client.shutdownReq(i)

proc drainCluster*(db: KoutenDb): seq[string] =
  ## Rolling maintenance / backup 用に全ノードを書き込み拒否状態へ移す。
  ## 読み取りは継続し、未読 payload はサーバ側で drain して wire 境界を守る。
  doAssert db.mode == mCluster, "drainCluster はクラスタモード専用"
  for i in 0 ..< db.client.peers.len:
    result.add db.client.drainReq(i)

proc resumeCluster*(db: KoutenDb): seq[string] =
  ## drainCluster 後に全ノードの書き込み受け入れを再開する。
  ## 先に全ノードが同じ topology で移送完了していることを検証する。
  doAssert db.mode == mCluster, "resumeCluster はクラスタモード専用"
  var expectedEpoch = 0'u32
  var expectedNodes = 0'u16
  var expectedVirtualArcs = 0
  for i in 0 ..< db.client.peers.len:
    let activation = db.client.activationReq(i)
    if i == 0:
      expectedEpoch = activation.epoch
      expectedNodes = activation.nodes
      expectedVirtualArcs = activation.virtualArcs
    elif activation.epoch != expectedEpoch or
        activation.nodes != expectedNodes or
        activation.virtualArcs != expectedVirtualArcs:
      raise newException(IOError,
        "resumeCluster refused mixed placement topology at node " & $i)
    if activation.state notin ["READY", "ACTIVE"] or
        activation.migrationPending != 0:
      raise newException(IOError,
        "resumeCluster refused node " & $i & " state=" & activation.state &
        " migrationPending=" & $activation.migrationPending)
  for i in 0 ..< db.client.peers.len:
    result.add db.client.resumeReq(i)

proc snapshotCluster*(db: KoutenDb): seq[string] =
  ## 全ノードを flush し、バックアップ前の軽量 barrier 情報を返す。
  ## 一貫した静止点が必要な場合は drainCluster 後に呼ぶ。
  doAssert db.mode == mCluster, "snapshotCluster はクラスタモード専用"
  for i in 0 ..< db.client.peers.len:
    result.add db.client.snapshotReq(i)

# ---------------------------------------------------------------- C ABI 用の内部変換

proc toRaw*(id: KoutenId): tuple[parent: uint64, epoch: uint32, seq: uint32, tWrite: float] =
  ## 内部用（C ABI 変換）。アプリケーションコードでは使わないこと。
  (id.parent, id.epoch, id.seq, id.tWrite)

proc fromRaw*(parent: uint64, epoch: uint32, seq: uint32, tWrite: float): KoutenId =
  ## 内部用（C ABI 変換）。アプリケーションコードでは使わないこと。
  KoutenId(parent: parent, epoch: epoch, seq: seq, tWrite: tWrite)
