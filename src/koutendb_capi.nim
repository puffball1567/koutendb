## koutendb_capi — C ABI 層（設計書 §13）
##
## ビルド:  scripts/build_capi.sh
## ヘッダ:  include/koutendb.h（手書き・本ファイルと1:1対応）
##
## 規約:
##   - ハンドルは不透明ポインタ。ARC 管理の ref を GC_ref/GC_unref で寿命固定。
##   - kouten_id は 24 バイトの値渡し struct（ヘッダと ABI 一致必須）。
##   - 例外は境界を越えない: すべて捕捉し、エラーはリターンコード / nil で返す。
##   - kouten_get が返すバッファは呼び出し側が kouten_free で解放する。

import std/[base64, json, locks, math, tables]
import koutendb

type
  KoutenCHandle = ref object
    db: KoutenDb
    closed: bool

  KoutenCTxHandle = ref object
    owner: pointer
    tx: KoutenTx
    closed: bool

  KoutenCLockHandle = ref object
    owner: pointer
    db: KoutenDb
    token: KoutenLockToken
    released: bool

  KoutenCSelectionHandle = ref object
    selection: PreparedSelection
    closed: bool

  KoutenCId {.exportc: "kouten_id", bycopy.} = object
    parent: uint64
    epoch: uint32
    seq: uint32
    t_write: cdouble

  KoutenCHit {.exportc: "kouten_hit", bycopy.} = object
    id: KoutenCId
    score: cdouble
    payload: pointer
    payload_len: csize_t

  KoutenCRetrieveResult {.exportc: "kouten_retrieve_result", bycopy.} = object
    len: csize_t
    hits: ptr KoutenCHit
    total_vectors: cint
    scanned: cint
    skipped_vectors: cint
    returned: cint
    rings_touched: cint
    payload_bytes: cint
    estimated_tokens: cint
    fanout_nodes: cint
    candidate_reduction: cdouble

  KoutenCValue {.exportc: "kouten_value", bycopy.} = object
    data: pointer
    len: csize_t

  KoutenCBatchResult {.exportc: "kouten_batch_result", bycopy.} = object
    len: csize_t
    values: ptr KoutenCValue

const
  KoutenOk = cint(0)
  KoutenErr = cint(-1)
  KoutenAbiVersion = cint(2)
  MaxCInputBytes = 64 * 1024 * 1024
  MaxCVectorDim = 1_000_000
  MaxCBatchItems = 10_000
  MaxCStringBytes = 1024 * 1024

var lastError {.threadvar.}: string
var runtimeReady = false
var handles = initTable[pointer, KoutenCHandle]()
var txHandles = initTable[pointer, KoutenCTxHandle]()
var lockHandles = initTable[pointer, KoutenCLockHandle]()
var selectionHandles = initTable[pointer, KoutenCSelectionHandle]()
var handlesLock: Lock
initLock(handlesLock)

proc NimMain() {.cdecl, importc.}

proc clearError() =
  lastError = ""

proc setError(msg: string) =
  lastError = msg

proc setError(e: ref CatchableError) =
  if e == nil:
    setError("unknown error")
  else:
    setError(e.msg)

proc ensureHandle(h: pointer): KoutenDb =
  if h == nil:
    raise newException(ValueError, "db handle is nil")
  withLock handlesLock:
    if h notin handles:
      raise newException(ValueError, "db handle is unknown or closed")
    let handle = handles[h]
    if handle.closed or handle.db.isNil:
      raise newException(ValueError, "db handle is closed")
    result = handle.db

proc registerHandle(db: KoutenDb): pointer =
  let handle = KoutenCHandle(db: db)
  GC_ref(handle)
  result = cast[pointer](handle)
  withLock handlesLock:
    handles[result] = handle

proc registerTxHandle(owner: pointer, tx: KoutenTx): pointer =
  let handle = KoutenCTxHandle(owner: owner, tx: tx)
  GC_ref(handle)
  result = cast[pointer](handle)
  withLock handlesLock:
    txHandles[result] = handle

proc ensureTxHandle(h: pointer): KoutenCTxHandle =
  if h == nil:
    raise newException(ValueError, "transaction handle is nil")
  withLock handlesLock:
    if h notin txHandles:
      raise newException(ValueError, "transaction handle is unknown or closed")
    result = txHandles[h]
    if result.closed or result.tx.isNil:
      raise newException(ValueError, "transaction handle is closed")

proc unregisterTxHandle(h: pointer): KoutenCTxHandle =
  withLock handlesLock:
    if h notin txHandles:
      raise newException(ValueError, "transaction handle is unknown or closed")
    result = txHandles[h]
    txHandles.del h
  result.closed = true

proc registerLockHandle(owner: pointer, db: KoutenDb,
                        token: KoutenLockToken): pointer =
  let handle = KoutenCLockHandle(owner: owner, db: db, token: token)
  GC_ref(handle)
  result = cast[pointer](handle)
  withLock handlesLock:
    lockHandles[result] = handle

proc ensureLockHandle(h: pointer): KoutenCLockHandle =
  if h == nil:
    raise newException(ValueError, "lock handle is nil")
  withLock handlesLock:
    if h notin lockHandles:
      raise newException(ValueError, "lock handle is unknown or released")
    result = lockHandles[h]
    if result.released or result.db.isNil:
      raise newException(ValueError, "lock handle is released")

proc unregisterLockHandle(h: pointer): KoutenCLockHandle =
  withLock handlesLock:
    if h notin lockHandles:
      raise newException(ValueError, "lock handle is unknown or released")
    result = lockHandles[h]
    lockHandles.del h
  result.released = true

proc registerSelectionHandle(selection: PreparedSelection): pointer =
  let handle = KoutenCSelectionHandle(selection: selection)
  GC_ref(handle)
  result = cast[pointer](handle)
  withLock handlesLock:
    selectionHandles[result] = handle

proc ensureSelectionHandle(h: pointer): KoutenCSelectionHandle =
  if h == nil:
    raise newException(ValueError, "selection handle is nil")
  withLock handlesLock:
    if h notin selectionHandles:
      raise newException(ValueError, "selection handle is unknown or closed")
    result = selectionHandles[h]
    if result.closed:
      raise newException(ValueError, "selection handle is closed")

proc unregisterSelectionHandle(h: pointer): KoutenCSelectionHandle =
  withLock handlesLock:
    if h notin selectionHandles:
      raise newException(ValueError, "selection handle is unknown or closed")
    result = selectionHandles[h]
    selectionHandles.del h
  result.closed = true

proc initRuntime() =
  if not runtimeReady:
    NimMain()
    runtimeReady = true

proc cstringToString(s: cstring, name: string, allowNil = true): string =
  if s == nil:
    if allowNil:
      return ""
    raise newException(ValueError, name & " is nil")
  var length = 0
  while length <= MaxCStringBytes and s[length] != '\0':
    inc length
  if length > MaxCStringBytes:
    raise newException(ValueError, name & " exceeds max C string bytes")
  result = newString(length)
  if length > 0:
    copyMem(addr result[0], s, length)

proc copyStringToShared(s: string): pointer =
  result = allocShared0(s.len + 1)
  if s.len > 0:
    copyMem(result, unsafeAddr s[0], s.len)

proc copyJsonToShared(node: JsonNode; outLen: ptr csize_t): pointer =
  if outLen == nil:
    raise newException(ValueError, "out_len is nil")
  let encoded = $node
  outLen[] = csize_t(encoded.len)
  copyStringToShared(encoded)

proc copyTextToShared(value: string; outLen: ptr csize_t): pointer =
  if outLen == nil:
    raise newException(ValueError, "out_len is nil")
  outLen[] = csize_t(value.len)
  copyStringToShared(value)

proc toC(id: KoutenId): KoutenCId =
  let (p, e, s, t) = id.toRaw
  KoutenCId(parent: p, epoch: e, seq: s, t_write: t)

proc fromC(id: KoutenCId): KoutenId =
  fromRaw(id.parent, id.epoch, id.seq, id.t_write)

proc optStr(s: cstring): string =
  cstringToString(s, "string")

proc optStrOr(s: cstring, default: string): string =
  result = optStr(s)
  if result.len == 0:
    result = default

proc codecFromC(value: cint): PayloadCodec =
  case value
  of 0: pcRaw
  of 1: pcJson
  of 2: pcNif
  of 3: pcBif
  else: raise newException(ValueError, "invalid payload codec")

proc codecToC(value: PayloadCodec): cint =
  case value
  of pcRaw: 0
  of pcJson: 1
  of pcNif: 2
  of pcBif: 3

proc payloadCodecName(value: PayloadCodec): string =
  case value
  of pcRaw: "raw"
  of pcJson: "json"
  of pcNif: "nif"
  of pcBif: "bif"

proc requireCBool(value: cint, name: string): bool
proc vecFromC(vec: ptr cfloat, vecLen: csize_t): seq[float32]
proc writeAckModeFromC(value: cint): WriteAckMode

proc readFilterFromC(filterJson: cstring): JsonNode =
  let filterText = optStr(filterJson)
  result =
    if filterText.len == 0: newJObject()
    else: parseJson(filterText)
  if result.kind != JObject:
    raise newException(ValueError, "filter must be a JSON object")

proc readOptionsFromC(filterJson, selection: cstring, limit: cint,
                      cursor: cstring, pagination, page, pageLimit: cint,
                      sortField: cstring, sortDesc: cint): KoutenReadOptions =
  KoutenReadOptions(
    filter: readFilterFromC(filterJson),
    selection: optStr(selection),
    limit: int(limit),
    cursor: optStr(cursor),
    pagination: if requireCBool(pagination, "pagination"): rpOn else: rpOff,
    page: int(page),
    pageLimit: int(pageLimit),
    sortField: optStr(sortField),
    sortDirection: if requireCBool(sortDesc, "sort_desc"): rsDesc else: rsAsc)

proc resultAmountFromC(value: cint): ResultAmount =
  case value
  of 0: raFew
  of 1: raNormal
  of 2: raMany
  of 3: raAllUseful
  else: raise newException(ValueError, "amount must be 0, 1, 2, or 3")

proc searchScopeFromC(value: cint): SearchScope =
  case value
  of 0: ssTight
  of 1: ssNear
  of 2: ssWide
  of 3: ssAll
  else: raise newException(ValueError, "scope must be 0, 1, 2, or 3")

proc searchDepthFromC(value: cint): SearchDepth =
  case value
  of 0: sdShallow
  of 1: sdNormal
  of 2: sdDeep
  of 3: sdVeryDeep
  else: raise newException(ValueError, "depth must be 0, 1, 2, or 3")

proc durabilityFromC(value: cint): KoutenDurability =
  case value
  of 0: durBuffered
  of 1: durStrong
  else: raise newException(ValueError, "durability must be 0 or 1")

proc retrievalTuningJson(tuning: RetrievalTuning): JsonNode =
  %*{
    "budget": tuning.budget,
    "focus": tuning.focus,
    "topRings": tuning.topRings,
    "branchBudget": tuning.branchBudget,
    "maxDepth": tuning.maxDepth,
    "includeChildren": tuning.includeChildren,
    "note": tuning.note
  }

proc compactStatsJson(stats: CompactStats): JsonNode =
  %*{
    "beforeBytes": stats.beforeBytes,
    "afterBytes": stats.afterBytes,
    "items": stats.items,
    "tombstones": stats.tombstones,
    "forwarders": stats.forwarders,
    "ringMeta": stats.ringMeta,
    "ringNames": stats.ringNames,
    "clusterTx": stats.clusterTx,
    "appliedClusterTx": stats.appliedClusterTx,
    "warpJobs": stats.warpJobs,
    "universeSyncEvents": stats.universeSyncEvents
  }

proc localityReportJson(report: LocalityReport): JsonNode =
  %*{
    "persistent": report.persistent,
    "walBytes": report.walBytes,
    "totalParticleRecords": report.totalParticleRecords,
    "liveParticleRecords": report.liveParticleRecords,
    "deadParticleRecords": report.deadParticleRecords,
    "ringCount": report.ringCount,
    "ringRuns": report.ringRuns,
    "fragmentedRings": report.fragmentedRings,
    "avgRunRecords": report.avgRunRecords,
    "maxRunRecords": report.maxRunRecords,
    "localityScore": report.localityScore
  }

proc backupStatsJson(stats: BackupStats; encrypted: bool): JsonNode =
  %*{
    "encrypted": encrypted,
    "bytes": stats.bytes,
    "items": stats.items,
    "tombstones": stats.tombstones,
    "forwarders": stats.forwarders,
    "ringMeta": stats.ringMeta,
    "ringNames": stats.ringNames,
    "clusterTx": stats.clusterTx,
    "appliedClusterTx": stats.appliedClusterTx,
    "warpJobs": stats.warpJobs,
    "universeSyncEvents": stats.universeSyncEvents,
    "source": stats.source,
    "destination": stats.destination
  }

proc dumpStatsJson(stats: DumpStats): JsonNode =
  %*{
    "bytes": stats.bytes,
    "records": stats.records,
    "rings": stats.rings,
    "documents": stats.documents,
    "destination": stats.destination
  }

proc importStatsJson(stats: ImportStats): JsonNode =
  %*{
    "read": stats.read,
    "imported": stats.imported,
    "skipped": stats.skipped,
    "errors": stats.errors,
    "rings": stats.rings,
    "batches": stats.batches,
    "batchSize": stats.batchSize,
    "source": stats.source,
    "defaultRing": stats.defaultRing
  }

proc packStatsJson[T](stats: T): JsonNode =
  %*{
    "records": stats.records,
    "rings": stats.rings,
    "bytes": stats.bytes,
    "indexBytes": stats.indexBytes,
    "removedFiles": stats.removedFiles
  }

proc operationalReportJson(report: KoutenOperationalVerifyReport): JsonNode =
  var checks = newJArray()
  for check in report.checks:
    checks.add %*{
      "name": check.name,
      "ok": check.ok,
      "message": check.message
    }
  %*{
    "ok": report.ok,
    "dataDir": report.dataDir,
    "persistent": report.persistent,
    "diskBacked": report.diskBacked,
    "wal": {
      "path": report.walPath,
      "exists": report.walExists,
      "bytes": report.walBytes
    },
    "store": {
      "items": report.items,
      "rings": report.rings,
      "ringNames": report.ringNames,
      "vectors": report.vectors,
      "galaxy": report.galaxy
    },
    "segments": {
      "path": report.segmentDir,
      "exists": report.segmentDirExists,
      "files": report.segmentFiles,
      "rebuiltRecords": report.segmentPackRecords,
      "status": segmentStatusJson(report.segmentStatus)
    },
    "locality": localityReportJson(report.locality),
    "checks": checks
  }

proc jsonOptions(value: cstring, name: string): JsonNode =
  let raw = optStr(value)
  if raw.len == 0:
    return newJObject()
  result = parseJson(raw)
  if result.kind != JObject:
    raise newException(ValueError, name & " must be a JSON object")

proc jsonStringOption(node: JsonNode, key, default: string): string =
  if not node.hasKey(key):
    return default
  if node[key].kind != JString:
    raise newException(ValueError, key & " must be a string")
  node[key].getStr()

proc jsonIntOption(node: JsonNode, key: string, default: int): int =
  if not node.hasKey(key):
    return default
  if node[key].kind != JInt:
    raise newException(ValueError, key & " must be an integer")
  let value = node[key].getBiggestInt()
  if value < BiggestInt(low(int)) or value > BiggestInt(high(int)):
    raise newException(ValueError, key & " exceeds platform integer range")
  int(value)

proc jsonInt64Option(node: JsonNode, key: string, default: int64): int64 =
  if not node.hasKey(key):
    return default
  if node[key].kind != JInt:
    raise newException(ValueError, key & " must be an integer")
  int64(node[key].getBiggestInt())

proc jsonFloatOption(node: JsonNode, key: string, default: float): float =
  if not node.hasKey(key):
    return default
  case node[key].kind
  of JInt: float(node[key].getInt())
  of JFloat: node[key].getFloat()
  else: raise newException(ValueError, key & " must be numeric")

proc jsonBoolOption(node: JsonNode, key: string, default: bool): bool =
  if not node.hasKey(key):
    return default
  if node[key].kind != JBool:
    raise newException(ValueError, key & " must be a boolean")
  node[key].getBool()

proc bytesFromC(data: pointer, len: csize_t): string =
  if len > 0 and data == nil:
    raise newException(ValueError, "data is nil")
  if len > csize_t(MaxCInputBytes):
    raise newException(ValueError, "data length exceeds max C input bytes")
  result = newString(int(len))
  if len > 0:
    copyMem(addr result[0], data, int(len))

proc countFromC(len: csize_t, name: string): int =
  if len > csize_t(high(int)):
    raise newException(ValueError, name & " is too large")
  int(len)

proc boundedCountFromC(len: csize_t, maxCount: int, name: string): int =
  result = countFromC(len, name)
  if result > maxCount:
    raise newException(ValueError, name & " exceeds max count " & $maxCount)

proc allocBytesFor(count: int, elemSize: int, name: string): int =
  if count < 0:
    raise newException(ValueError, name & " count is negative")
  if elemSize <= 0:
    raise newException(ValueError, name & " element size is invalid")
  if count > high(int) div elemSize:
    raise newException(ValueError, name & " allocation is too large")
  count * elemSize

proc requireCBool(value: cint, name: string): bool =
  if value notin [cint(0), cint(1)]:
    raise newException(ValueError, name & " must be 0 or 1")
  value != 0

proc kouten_abi_version(): cint {.exportc, cdecl, dynlib.} =
  KoutenAbiVersion

proc kouten_last_error(): cstring {.exportc, cdecl, dynlib.} =
  lastError.cstring

proc kouten_init() {.exportc, cdecl, dynlib.} =
  ## Nim runtime initialization. Idempotent for driver setup paths.
  initRuntime()

proc kouten_open(nodes: cint): pointer {.exportc, cdecl, dynlib.} =
  try:
    initRuntime()
    clearError()
    let db = koutendb.open(int(nodes))
    return registerHandle(db)
  except CatchableError as e:
    setError(e)
    return nil

proc kouten_open_dir(nodes: cint, dir: cstring): pointer {.exportc, cdecl, dynlib.} =
  ## 永続化つきで開く（設計書 §16）。
  try:
    initRuntime()
    clearError()
    let db = koutendb.open(int(nodes), dataDir = cstringToString(dir, "dir"))
    return registerHandle(db)
  except CatchableError as e:
    setError(e)
    return nil

proc kouten_open_dir_options(nodes: cint, dir: cstring,
                             durabilityStrong, diskBacked: cint): pointer
                             {.exportc, cdecl, dynlib.} =
  ## Additive embedded-open path for production durability and ring-local
  ## segment reads. Boolean options are strict to catch FFI declaration bugs.
  try:
    initRuntime()
    clearError()
    if durabilityStrong notin [cint(0), cint(1)]:
      raise newException(ValueError, "durability_strong must be 0 or 1")
    if diskBacked notin [cint(0), cint(1)]:
      raise newException(ValueError, "disk_backed must be 0 or 1")
    let db = koutendb.open(
      int(nodes),
      dataDir = cstringToString(dir, "dir", allowNil = false),
      durability = if durabilityStrong == 0: durBuffered else: durStrong,
      diskBacked = diskBacked != 0)
    return registerHandle(db)
  except CatchableError as e:
    setError(e)
    return nil

proc kouten_connect(peers: cstring): pointer {.exportc, cdecl, dynlib.} =
  ## クラスタへ接続（設計書 §14）。peers = "host:port,host:port,..."
  try:
    initRuntime()
    clearError()
    let db = koutendb.connect(cstringToString(peers, "peers", allowNil = false))
    return registerHandle(db)
  except CatchableError as e:
    setError(e)
    return nil

proc kouten_connect_auth(peers, username, password, authToken, secretKey,
                        galaxy: cstring): pointer {.exportc, cdecl, dynlib.} =
  ## 認証つきクラスタ接続。NULL は空文字として扱う。
  try:
    initRuntime()
    clearError()
    let db = koutendb.connect(optStr(peers),
                             username = optStr(username),
                             password = optStr(password),
                             authToken = optStr(authToken),
                             secretKey = optStr(secretKey),
                             galaxy = optStr(galaxy))
    return registerHandle(db)
  except CatchableError as e:
    setError(e)
    return nil

proc kouten_connect_auth_tls(peers, username, password, authToken, secretKey,
                            galaxy: cstring, tls: cint, tlsCaFile,
                            tlsServerName: cstring,
                            tlsInsecureSkipVerify: cint): pointer {.exportc, cdecl, dynlib.} =
  ## TLS-aware authenticated cluster connection. TLS requires a KoutenDB core
  ## build compiled with -d:ssl.
  try:
    initRuntime()
    clearError()
    let useTls = requireCBool(tls, "tls")
    let insecureSkipVerify = requireCBool(
      tlsInsecureSkipVerify, "tls_insecure_skip_verify")
    let db = koutendb.connect(optStr(peers),
                             username = optStr(username),
                             password = optStr(password),
                             authToken = optStr(authToken),
                             secretKey = optStr(secretKey),
                             galaxy = optStr(galaxy),
                             tls = useTls,
                             tlsCaFile = optStr(tlsCaFile),
                             tlsServerName = optStr(tlsServerName),
                             tlsInsecureSkipVerify = insecureSkipVerify)
    return registerHandle(db)
  except CatchableError as e:
    setError(e)
    return nil

proc kouten_close(h: pointer) {.exportc, cdecl, dynlib.} =
  try:
    initRuntime()
    clearError()
    if h == nil:
      return
    var handle: KoutenCHandle
    var ownedTxs: seq[KoutenCTxHandle] = @[]
    var ownedLocks: seq[KoutenCLockHandle] = @[]
    withLock handlesLock:
      if h notin handles:
        setError("db handle is unknown or closed")
        return
      handle = handles[h]
      handles.del h
      var txKeys: seq[pointer] = @[]
      for key, txHandle in txHandles:
        if txHandle.owner == h:
          txKeys.add key
          ownedTxs.add txHandle
      for key in txKeys:
        txHandles.del key
      var lockKeys: seq[pointer] = @[]
      for key, lockHandle in lockHandles:
        if lockHandle.owner == h:
          lockKeys.add key
          ownedLocks.add lockHandle
      for key in lockKeys:
        lockHandles.del key
    var cleanupError = ""
    for txHandle in ownedTxs:
      try:
        if not txHandle.closed and not txHandle.tx.isNil:
          txHandle.tx.rollback()
      except CatchableError as e:
        if cleanupError.len == 0:
          cleanupError = "transaction cleanup failed: " & e.msg
      finally:
        txHandle.closed = true
        txHandle.tx = nil
        GC_unref(txHandle)
    for lockHandle in ownedLocks:
      try:
        if not lockHandle.released and not lockHandle.db.isNil:
          lockHandle.db.releaseLock(lockHandle.token)
      except CatchableError as e:
        if cleanupError.len == 0:
          cleanupError = "lock cleanup failed: " & e.msg
      finally:
        lockHandle.released = true
        lockHandle.db = nil
        GC_unref(lockHandle)
    try:
      if not handle.closed and not handle.db.isNil:
        handle.db.close()
    except CatchableError as e:
      if cleanupError.len == 0:
        cleanupError = "database close failed: " & e.msg
    handle.closed = true
    handle.db = nil
    GC_unref(handle)
    if cleanupError.len > 0:
      setError(cleanupError)
  except CatchableError as e:
    setError(e)

proc kouten_now(h: pointer): cdouble {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureHandle(h).now
  except CatchableError as e:
    setError(e)
    -1.0

proc kouten_advance(h: pointer, dt: cdouble) {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureHandle(h).advance(dt)
  except CatchableError as e:
    setError(e)

proc kouten_ring_configure(h: pointer, ring: cstring,
                          period: cdouble): cint {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureHandle(h).configureRing(cstringToString(ring, "ring", allowNil = false), period)
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_set_galaxy_description(h: pointer, description: cstring): cint
                                  {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureHandle(h).setGalaxyDescription(optStr(description))
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_set_ring_description(h: pointer, ring, description: cstring): cint
                                {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureHandle(h).setRingDescription(cstringToString(ring, "ring", allowNil = false),
                                       optStr(description))
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_get_galaxy_description(h: pointer, outLen: ptr csize_t): pointer
                                    {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    copyTextToShared(ensureHandle(h).getGalaxyDescription(), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_get_ring_description(h: pointer, ring: cstring,
                                 outLen: ptr csize_t): pointer
                                 {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let value = ensureHandle(h).getRingDescription(
      cstringToString(ring, "ring", allowNil = false))
    copyTextToShared(value, outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_ring_payload_profile_configure(
    h: pointer, ring: cstring, codec: cint, charset,
    formatVersion: cstring): cint {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureHandle(h).configureRingPayloadProfile(
      cstringToString(ring, "ring", allowNil = false),
      RingPayloadProfile(defaultCodec: codecFromC(codec),
                         charset: optStr(charset),
                         formatVersion: optStr(formatVersion)))
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_ring_payload_profile_json(h: pointer, ring: cstring,
                                      outLen: ptr csize_t): pointer
                                      {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let profile = ensureHandle(h).ringPayloadProfile(
      cstringToString(ring, "ring", allowNil = false))
    copyJsonToShared(%*{
      "codec": payloadCodecName(profile.defaultCodec),
      "codecValue": codecToC(profile.defaultCodec),
      "charset": profile.charset,
      "formatVersion": profile.formatVersion
    }, outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_time_orbit_profile_configure(
    h: pointer, ring: cstring, bits: cint, bucketMs: int64,
    phase: uint64, salt: cstring): cint {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureHandle(h).configureTimeOrbitProfile(
      cstringToString(ring, "ring", allowNil = false),
      TimeOrbitProfile(bits: int(bits), bucketMs: bucketMs,
                       phase: phase, salt: optStr(salt)))
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_time_orbit_profile_json(h: pointer, ring: cstring,
                                    outLen: ptr csize_t): pointer
                                    {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let profile = ensureHandle(h).timeOrbitProfile(
      cstringToString(ring, "ring", allowNil = false))
    copyJsonToShared(%*{
      "bits": profile.bits,
      "bucketMs": profile.bucketMs,
      "phase": $profile.phase,
      "salt": profile.salt
    }, outLen)
  except CatchableError as e:
    setError(e)
    nil

proc ringApplyModeFromC(value: cint): RingApplyMode =
  case value
  of 0: ramLatestOnly
  of 1: ramAppendOnly
  of 2: ramBoundedHistory
  of 3: ramDelayedTimestamp
  else: raise newException(ValueError, "apply_mode must be in 0..3")

proc ringApplyModeName(value: RingApplyMode): string =
  case value
  of ramLatestOnly: "latest-only"
  of ramAppendOnly: "append-only"
  of ramBoundedHistory: "bounded-history"
  of ramDelayedTimestamp: "delayed-timestamp"

proc kouten_write_ack_mode_configure(h: pointer, ackMode: cint): cint
                                     {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureHandle(h).configureWriteAckMode(writeAckModeFromC(ackMode))
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_ring_write_ack_mode_configure(h: pointer, ring: cstring,
                                          ackMode: cint): cint
                                          {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureHandle(h).configureRingWriteAckMode(
      cstringToString(ring, "ring", allowNil = false),
      writeAckModeFromC(ackMode))
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_ring_apply_policy_configure(h: pointer, ring: cstring,
                                        applyMode, historyKeep,
                                        delayMs: cint): cint
                                        {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureHandle(h).configureRingApplyPolicy(
      cstringToString(ring, "ring", allowNil = false),
      RingApplyPolicy(mode: ringApplyModeFromC(applyMode),
                      historyKeep: int(historyKeep), delayMs: int(delayMs)))
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_ring_apply_policy_json(h: pointer, ring: cstring,
                                   outLen: ptr csize_t): pointer
                                   {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let policy = ensureHandle(h).ringApplyPolicy(
      cstringToString(ring, "ring", allowNil = false))
    copyJsonToShared(%*{
      "mode": ringApplyModeName(policy.mode),
      "modeValue": policy.mode.ord,
      "historyKeep": policy.historyKeep,
      "delayMs": policy.delayMs
    }, outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_guardrails_configure(h: pointer, maxPayloadBytes,
                                 maxVectorDim, maxRingCount,
                                 maxRecordsPerRing: int64): cint
                                 {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    for value in [maxPayloadBytes, maxVectorDim, maxRingCount,
                  maxRecordsPerRing]:
      if value > int64(high(int)):
        raise newException(ValueError, "guardrail value exceeds platform int")
    ensureHandle(h).configureGuardrails(KoutenGuardrails(
      maxPayloadBytes: int(maxPayloadBytes),
      maxVectorDim: int(maxVectorDim),
      maxRingCount: int(maxRingCount),
      maxRecordsPerRing: int(maxRecordsPerRing)))
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_guardrails_json(h: pointer, outLen: ptr csize_t): pointer
                            {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let guardrails = ensureHandle(h).guardrails()
    copyJsonToShared(%*{
      "maxPayloadBytes": guardrails.maxPayloadBytes,
      "maxVectorDim": guardrails.maxVectorDim,
      "maxRingCount": guardrails.maxRingCount,
      "maxRecordsPerRing": guardrails.maxRecordsPerRing
    }, outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_retrieval_tuning_configure(
    h: pointer, profile: cstring, budget, focus, topRings,
    branchBudget, maxDepth, includeChildren: cint,
    note: cstring): cint {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureHandle(h).configureRetrievalTuning(
      cstringToString(profile, "profile", allowNil = false),
      RetrievalTuning(
        budget: int(budget), focus: int(focus), topRings: int(topRings),
        branchBudget: int(branchBudget), maxDepth: int(maxDepth),
        includeChildren: requireCBool(includeChildren, "include_children"),
        note: optStr(note)))
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_retrieval_tuning_json(h: pointer, profile: cstring,
                                  outLen: ptr csize_t): pointer
                                  {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let tuning = ensureHandle(h).retrievalTuning(optStrOr(profile, "default"))
    copyJsonToShared(retrievalTuningJson(tuning), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_search_profile_configure(h: pointer, name: cstring,
                                     amount, scope, depth: cint,
                                     note: cstring): cint
                                     {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureHandle(h).configureSearchProfile(
      cstringToString(name, "name", allowNil = false),
      SearchProfile(amount: resultAmountFromC(amount),
                    scope: searchScopeFromC(scope),
                    depth: searchDepthFromC(depth),
                    note: optStr(note)))
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_retrieval_plan_json(
    h: pointer, ring, profile: cstring, budget, topRings, focus,
    includeChildren, maxDepth, branchBudget: cint,
    outLen: ptr csize_t): pointer {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let plan = ensureHandle(h).tunedRetrievalPlan(
      ring = optStr(ring), profile = optStrOr(profile, "default"),
      budget = int(budget), topRings = int(topRings), focus = int(focus),
      includeChildren = requireCBool(includeChildren, "include_children"),
      maxDepth = int(maxDepth), branchBudget = int(branchBudget))
    copyJsonToShared(planJson(plan), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_search_plan_json(ring: cstring, amount, scope, depth: cint,
                             profile: cstring,
                             outLen: ptr csize_t): pointer
                             {.exportc, cdecl, dynlib.} =
  try:
    initRuntime()
    clearError()
    let plan = searchPlan(ring = optStr(ring),
                          amount = resultAmountFromC(amount),
                          scope = searchScopeFromC(scope),
                          depth = searchDepthFromC(depth),
                          profile = optStr(profile))
    copyJsonToShared(planJson(plan), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_put(h: pointer, ring: cstring, data: pointer, len: csize_t,
               outId: ptr KoutenCId): cint {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    if outId == nil:
      raise newException(ValueError, "out_id is nil")
    let payload = bytesFromC(data, len)
    outId[] = ensureHandle(h).put(payload, cstringToString(ring, "ring", allowNil = false)).toC
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_put_profile(h: pointer, ring: cstring, data: pointer,
                        len: csize_t, vec: ptr cfloat, vecLen: csize_t,
                        outId: ptr KoutenCId): cint
                        {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    if outId == nil:
      raise newException(ValueError, "out_id is nil")
    outId[] = ensureHandle(h).putUsingRingProfile(
      bytesFromC(data, len),
      cstringToString(ring, "ring", allowNil = false),
      vecFromC(vec, vecLen)).toC
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_put_codec(h: pointer, ring: cstring, data: pointer, len: csize_t,
                     codec: cint, outId: ptr KoutenCId): cint
                     {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    if outId == nil:
      raise newException(ValueError, "out_id is nil")
    outId[] = ensureHandle(h).put(encodedPayload(bytesFromC(data, len),
      codecFromC(codec)), cstringToString(ring, "ring", allowNil = false)).toC
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_put_vec(h: pointer, ring: cstring, data: pointer, len: csize_t,
                   vec: ptr cfloat, vecLen: csize_t,
                   outId: ptr KoutenCId): cint {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    if outId == nil:
      raise newException(ValueError, "out_id is nil")
    if vecLen > 0 and vec == nil:
      raise newException(ValueError, "vec is nil")
    let payload = bytesFromC(data, len)
    let nVec = boundedCountFromC(vecLen, MaxCVectorDim, "vec_len")
    var values = newSeq[float32](nVec)
    let rawVec = cast[ptr UncheckedArray[cfloat]](vec)
    for i in 0 ..< nVec:
      values[i] = float32(rawVec[i])
    outId[] = ensureHandle(h).put(payload, cstringToString(ring, "ring", allowNil = false),
                                  vec = values).toC
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_put_vec_codec(h: pointer, ring: cstring, data: pointer, len: csize_t,
                         codec: cint, vec: ptr cfloat, vecLen: csize_t,
                         outId: ptr KoutenCId): cint {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    if outId == nil:
      raise newException(ValueError, "out_id is nil")
    if vecLen > 0 and vec == nil:
      raise newException(ValueError, "vec is nil")
    let nVec = boundedCountFromC(vecLen, MaxCVectorDim, "vec_len")
    var values = newSeq[float32](nVec)
    let rawVec = cast[ptr UncheckedArray[cfloat]](vec)
    for i in 0 ..< nVec:
      values[i] = float32(rawVec[i])
    outId[] = ensureHandle(h).put(encodedPayload(bytesFromC(data, len),
      codecFromC(codec)), cstringToString(ring, "ring", allowNil = false),
      vec = values).toC
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_put_near_codec(h: pointer, baseRing, ring: cstring,
                           data: pointer, len: csize_t, codec: cint,
                           vec: ptr cfloat, vecLen: csize_t,
                           outId: ptr KoutenCId): cint
                           {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    if outId == nil:
      raise newException(ValueError, "out_id is nil")
    outId[] = ensureHandle(h).putNear(
      cstringToString(baseRing, "base_ring", allowNil = false),
      encodedPayload(bytesFromC(data, len), codecFromC(codec)),
      ring = cstringToString(ring, "ring", allowNil = false),
      vec = vecFromC(vec, vecLen)).toC
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_put_near_id_codec(h: pointer, anchor: KoutenCId,
                              relation: cstring, data: pointer,
                              len: csize_t, codec: cint,
                              vec: ptr cfloat, vecLen: csize_t,
                              outId: ptr KoutenCId): cint
                              {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    if outId == nil:
      raise newException(ValueError, "out_id is nil")
    outId[] = ensureHandle(h).putNear(
      fromC(anchor), encodedPayload(bytesFromC(data, len), codecFromC(codec)),
      relation = optStr(relation), vec = vecFromC(vec, vecLen)).toC
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_put_time(h: pointer, ring: cstring, timestampMs: int64,
                     data: pointer, len: csize_t,
                     vec: ptr cfloat, vecLen: csize_t,
                     outId: ptr KoutenCId): cint
                     {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    if outId == nil:
      raise newException(ValueError, "out_id is nil")
    outId[] = ensureHandle(h).putTime(
      bytesFromC(data, len),
      cstringToString(ring, "ring", allowNil = false),
      timestampMs, vecFromC(vec, vecLen)).toC
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_get(h: pointer, id: KoutenCId,
               outLen: ptr csize_t): pointer {.exportc, cdecl, dynlib.} =
  ## 見つからなければ nil。返るバッファは kouten_free で解放すること。
  try:
    clearError()
    if outLen == nil:
      raise newException(ValueError, "out_len is nil")
    let db = ensureHandle(h)
    let s = db.get(fromC(id))   # 見つからなければ KeyError → nil
    outLen[] = csize_t(s.len)
    result = copyStringToShared(s)   # +1: NUL 終端（文字列として扱う C 側の便宜）
  except CatchableError as e:
    setError(e)
    return nil

proc kouten_get_codec(h: pointer, id: KoutenCId, outLen: ptr csize_t,
                     outCodec: ptr cint): pointer {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    if outLen == nil or outCodec == nil:
      raise newException(ValueError, "out_len and out_codec are required")
    let value = ensureHandle(h).getEncoded(fromC(id))
    outLen[] = csize_t(value.data.len)
    outCodec[] = value.codec.codecToC
    copyStringToShared(value.data)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_exists(h: pointer, id: KoutenCId): cint
                  {.exportc, cdecl, dynlib.} =
  ## Returns 1 when present, 0 when absent, and KOUTEN_ERR on API failure.
  try:
    clearError()
    if ensureHandle(h).exists(fromC(id)): cint(1) else: cint(0)
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_update(h: pointer, id: KoutenCId, data: pointer,
                   len: csize_t): cint {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureHandle(h).update(fromC(id), bytesFromC(data, len))
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_update_codec(h: pointer, id: KoutenCId, data: pointer,
                         len: csize_t, codec: cint): cint
                         {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureHandle(h).update(fromC(id), encodedPayload(bytesFromC(data, len),
      codecFromC(codec)))
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_remove(h: pointer, id: KoutenCId): cint
                   {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureHandle(h).remove(fromC(id))
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_patch_json(h: pointer, id: KoutenCId, patchJson: cstring,
                       outLen: ptr csize_t): pointer
                       {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let patchNode = parseJson(cstringToString(
      patchJson, "patch_json", allowNil = false))
    if patchNode.kind != JObject:
      raise newException(ValueError, "patch_json must be a JSON object")
    copyJsonToShared(ensureHandle(h).patch(fromC(id), patchNode), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_count_ring(h: pointer, ring: cstring,
                       outCount: ptr int64): cint
                       {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    if outCount == nil:
      raise newException(ValueError, "out_count is nil")
    outCount[] = int64(ensureHandle(h).countByRing(
      cstringToString(ring, "ring", allowNil = false)))
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_tx_begin(h: pointer): pointer {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let db = ensureHandle(h)
    registerTxHandle(h, db.beginTransaction())
  except CatchableError as e:
    setError(e)
    nil

proc kouten_tx_identity(txHandle: pointer, outTxid: ptr uint64,
                        outCoordinatorNode: ptr cint): cint
                        {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    if outTxid == nil or outCoordinatorNode == nil:
      raise newException(ValueError,
        "out_txid and out_coordinator_node are required")
    let tx = ensureTxHandle(txHandle).tx
    outTxid[] = tx.transactionId()
    outCoordinatorNode[] = cint(tx.transactionCoordinatorNode())
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_tx_put_codec(txHandle: pointer, ring: cstring,
                         data: pointer, len: csize_t, codec: cint,
                         vec: ptr cfloat, vecLen: csize_t,
                         outId: ptr KoutenCId): cint
                         {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    if outId == nil:
      raise newException(ValueError, "out_id is nil")
    let tx = ensureTxHandle(txHandle).tx
    outId[] = tx.put(encodedPayload(bytesFromC(data, len), codecFromC(codec)),
                     cstringToString(ring, "ring", allowNil = false),
                     vecFromC(vec, vecLen)).toC
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_tx_update_codec(txHandle: pointer, id: KoutenCId,
                            data: pointer, len: csize_t, codec: cint,
                            vec: ptr cfloat, vecLen: csize_t): cint
                            {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureTxHandle(txHandle).tx.update(
      fromC(id), encodedPayload(bytesFromC(data, len), codecFromC(codec)),
      vecFromC(vec, vecLen))
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_tx_remove(txHandle: pointer, id: KoutenCId): cint
                      {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureTxHandle(txHandle).tx.remove(fromC(id))
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc writeAckModeFromC(value: cint): WriteAckMode =
  case value
  of 0: wamAccepted
  of 1: wamApplied
  else: raise newException(ValueError, "ack_mode must be 0 or 1")

proc kouten_tx_commit(txHandle: pointer, ackMode: cint): cint
                      {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let handle = ensureTxHandle(txHandle)
    handle.tx.commit(writeAckModeFromC(ackMode))
    discard unregisterTxHandle(txHandle)
    handle.tx = nil
    GC_unref(handle)
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_tx_rollback(txHandle: pointer): cint
                        {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let handle = ensureTxHandle(txHandle)
    handle.tx.rollback()
    discard unregisterTxHandle(txHandle)
    handle.tx = nil
    GC_unref(handle)
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc lockTokenJson(token: KoutenLockToken): JsonNode =
  %*{
    "scope": if token.scope == rlsRing: "ring" else: "stellar",
    "coordinate": token.coordinate,
    "token": token.token,
    "fence": $token.fence,
    "expiresAt": token.expiresAt,
    "keys": token.keys
  }

proc kouten_lock_ring(h: pointer, ring: cstring, ttlSeconds: cdouble,
                      waitMs: cint): pointer {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    if float(ttlSeconds).classify in {fcNan, fcInf, fcNegInf}:
      raise newException(ValueError, "ttl_seconds must be finite")
    if waitMs < 0:
      raise newException(ValueError, "wait_ms must be non-negative")
    let db = ensureHandle(h)
    registerLockHandle(h, db, db.acquireRingLock(
      cstringToString(ring, "ring", allowNil = false),
      float(ttlSeconds), int(waitMs)))
  except CatchableError as e:
    setError(e)
    nil

proc kouten_lock_stellar(h: pointer, stellar: cstring, ttlSeconds: cdouble,
                         waitMs: cint): pointer {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    if float(ttlSeconds).classify in {fcNan, fcInf, fcNegInf}:
      raise newException(ValueError, "ttl_seconds must be finite")
    if waitMs < 0:
      raise newException(ValueError, "wait_ms must be non-negative")
    let db = ensureHandle(h)
    registerLockHandle(h, db, db.acquireStellarLock(
      cstringToString(stellar, "stellar", allowNil = false),
      float(ttlSeconds), int(waitMs)))
  except CatchableError as e:
    setError(e)
    nil

proc kouten_lock_info_json(lockHandle: pointer,
                           outLen: ptr csize_t): pointer
                           {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    copyJsonToShared(lockTokenJson(ensureLockHandle(lockHandle).token), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_lock_active(lockHandle: pointer): cint
                        {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let handle = ensureLockHandle(lockHandle)
    if handle.db.lockActive(handle.token): cint(1) else: cint(0)
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_lock_release(lockHandle: pointer): cint
                         {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let handle = ensureLockHandle(lockHandle)
    handle.db.releaseLock(handle.token)
    discard unregisterLockHandle(lockHandle)
    handle.db = nil
    GC_unref(handle)
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_free(p: pointer) {.exportc, cdecl, dynlib.} =
  if p != nil:
    deallocShared(p)

proc copyPayloadToShared(s: string): KoutenCValue =
  result.len = csize_t(s.len)
  result.data = copyStringToShared(s)

proc kouten_batch_get(h: pointer, ids: ptr KoutenCId,
                     idsLen: csize_t): ptr KoutenCBatchResult
                     {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    if idsLen > 0 and ids == nil:
      raise newException(ValueError, "ids is nil")
    let db = ensureHandle(h)
    let nIds = boundedCountFromC(idsLen, MaxCBatchItems, "ids_len")
    var nimIds = newSeq[KoutenId](nIds)
    let rawIds = cast[ptr UncheckedArray[KoutenCId]](ids)
    for i in 0 ..< nIds:
      nimIds[i] = fromC(rawIds[i])
    let values = db.batchGet(nimIds)
    result = cast[ptr KoutenCBatchResult](allocShared0(sizeof(KoutenCBatchResult)))
    result.len = csize_t(values.len)
    if values.len > 0:
      let valueBytes = allocBytesFor(values.len, sizeof(KoutenCValue), "batch values")
      result.values = cast[ptr KoutenCValue](allocShared0(valueBytes))
      let rawValues = cast[ptr UncheckedArray[KoutenCValue]](result.values)
      for i, value in values:
        rawValues[i] = copyPayloadToShared(value)
  except CatchableError as e:
    setError(e)
    return nil

proc kouten_batch_get_free(r: ptr KoutenCBatchResult) {.exportc, cdecl, dynlib.} =
  if r == nil:
    return
  if r.values != nil:
    let rawValues = cast[ptr UncheckedArray[KoutenCValue]](r.values)
    for i in 0 ..< int(r.len):
      if rawValues[i].data != nil:
        deallocShared(rawValues[i].data)
    deallocShared(r.values)
  deallocShared(r)

proc kouten_query(h: pointer, id: KoutenCId, selection: cstring,
                 outLen: ptr csize_t): pointer {.exportc, cdecl, dynlib.} =
  ## 選択取得（GraphQL 風, 設計書 §15）。JSON 文字列の複製バッファを返す
  ## （kouten_free で解放）。見つからない/エラー時は nil。
  try:
    clearError()
    if outLen == nil:
      raise newException(ValueError, "out_len is nil")
    let db = ensureHandle(h)
    let s = $db.query(fromC(id), cstringToString(selection, "selection", allowNil = false))
    outLen[] = csize_t(s.len)
    result = copyStringToShared(s)
  except CatchableError as e:
    setError(e)
    return nil

proc kouten_selection_prepare(selection: cstring): pointer
                              {.exportc, cdecl, dynlib.} =
  try:
    initRuntime()
    clearError()
    registerSelectionHandle(prepareSelection(cstringToString(
      selection, "selection", allowNil = false)))
  except CatchableError as e:
    setError(e)
    nil

proc kouten_query_prepared(h: pointer, id: KoutenCId,
                           selectionHandle: pointer,
                           outLen: ptr csize_t): pointer
                           {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let selected = ensureHandle(h).query(
      fromC(id), ensureSelectionHandle(selectionHandle).selection)
    copyJsonToShared(selected, outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_selection_close(selectionHandle: pointer): cint
                            {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let handle = unregisterSelectionHandle(selectionHandle)
    GC_unref(handle)
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc koutenReadPayloadNode(item: KoutenRecord): JsonNode =
  if item.codec == pcJson:
    try:
      return %*{"encoding": "json", "payload": parseJson(item.payload)}
    except JsonParsingError:
      discard
  %*{"encoding": "base64", "payload": base64.encode(item.payload)}

proc koutenRecordJson(item: KoutenRecord): JsonNode =
  let display = koutenReadPayloadNode(item)
  let (parent, epoch, seq, tWrite) = item.id.toRaw
  %*{
    "id": $item.id,
    "rawId": $parent & ":" & $epoch & ":" & $seq & ":" & $tWrite,
    "codec": item.codec.payloadCodecName,
    "encoding": display["encoding"].getStr(),
    "payload": display["payload"]
  }

proc koutenReadPageJson(page: KoutenReadPage): string =
  var items = newJArray()
  for item in page.items:
    items.add koutenRecordJson(item)
  $(%*{
    "ring": page.ring,
    "count": page.count,
    "pagination": if page.pagination == rpOn: "on" else: "off",
    "page": page.page,
    "pageLimit": page.pageLimit,
    "sort": page.sortField,
    "sortDirection": if page.sortDirection == rsDesc: "desc" else: "asc",
    "items": items,
    "nextCursor": page.nextCursor
  })

proc kouten_read_ring_json(h: pointer, ring, filterJson, selection: cstring,
                          limit: cint, cursor: cstring, pagination: cint,
                          page: cint, pageLimit: cint, sortField: cstring,
                          sortDesc: cint, outLen: ptr csize_t): pointer
                          {.exportc, cdecl, dynlib.} =
  ## Returns a JSON read page compatible with CLI get --ring output.
  ## Binary/non-JSON payloads are base64 encoded and marked with encoding=base64.
  try:
    clearError()
    if outLen == nil:
      raise newException(ValueError, "out_len is nil")
    let opts = readOptionsFromC(filterJson, selection, limit, cursor,
                                pagination, page, pageLimit, sortField,
                                sortDesc)
    let pageResult = ensureHandle(h).readRing(
      cstringToString(ring, "ring", allowNil = false), opts)
    let s = koutenReadPageJson(pageResult)
    outLen[] = csize_t(s.len)
    copyStringToShared(s)
  except CatchableError as e:
    setError(e)
    nil

proc koutenTimePageJson(page: KoutenTimeReadPage): JsonNode =
  var items = newJArray()
  for item in page.items:
    items.add koutenRecordJson(item)
  %*{
    "ring": page.ring,
    "fromMs": page.fromMs,
    "toMs": page.toMs,
    "bucketsVisited": page.bucketsVisited,
    "count": page.count,
    "rings": page.rings,
    "items": items
  }

proc kouten_read_time_json(h: pointer, ring: cstring,
                           fromMs, toMs: int64,
                           filterJson, selection: cstring,
                           limit: cint, sortField: cstring,
                           sortDesc, maxBuckets: cint,
                           outLen: ptr csize_t): pointer
                           {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let opts = readOptionsFromC(filterJson, selection, limit, nil,
                                0, 1, int(limit).cint, sortField, sortDesc)
    let page = ensureHandle(h).readTime(
      cstringToString(ring, "ring", allowNil = false),
      fromMs, toMs, opts, int(maxBuckets))
    copyJsonToShared(koutenTimePageJson(page), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc parseStringArray(node: JsonNode, name: string): seq[string] =
  if node.kind != JArray:
    raise newException(ValueError, name & " must be a JSON array")
  for item in node:
    if item.kind != JString:
      raise newException(ValueError, name & " entries must be strings")
    result.add item.getStr()

proc parsePositiveIntMap(node: JsonNode, name: string): Table[string, int] =
  result = initTable[string, int]()
  if node.kind != JObject:
    raise newException(ValueError, name & " must be a JSON object")
  for key, value in node:
    if value.kind != JInt or value.getInt() <= 0:
      raise newException(ValueError, name & " values must be positive integers")
    result[key] = value.getInt()

proc parseStringMap(node: JsonNode, name: string): Table[string, string] =
  result = initTable[string, string]()
  if node.kind != JObject:
    raise newException(ValueError, name & " must be a JSON object")
  for key, value in node:
    if value.kind != JString:
      raise newException(ValueError, name & " values must be strings")
    result[key] = value.getStr()

proc parseSortDirection(value, name: string): KoutenReadSortDirection =
  case value
  of "asc": rsAsc
  of "desc": rsDesc
  else: raise newException(ValueError, name & " must be asc or desc")

proc parseSortDirectionMap(node: JsonNode,
                           name: string): Table[string, KoutenReadSortDirection] =
  result = initTable[string, KoutenReadSortDirection]()
  for key, value in parseStringMap(node, name):
    result[key] = parseSortDirection(value, name & "." & key)

proc stellarOptionsFromC(optionsJson: cstring): KoutenStellarOptions =
  result = defaultStellarOptions()
  let raw = optStr(optionsJson)
  if raw.len == 0:
    return
  let node = parseJson(raw)
  if node.kind != JObject:
    raise newException(ValueError, "stellar options must be a JSON object")
  if node.hasKey("filter"):
    if node["filter"].kind != JObject:
      raise newException(ValueError, "filter must be a JSON object")
    result.filter = node["filter"]
  if node.hasKey("selection"):
    result.selection = node["selection"].getStr()
  if node.hasKey("limitPerRing"):
    result.limitPerRing = node["limitPerRing"].getInt()
  if node.hasKey("subringLimits"):
    result.subringLimits = parsePositiveIntMap(node["subringLimits"],
                                               "subringLimits")
  if node.hasKey("subringSortFields"):
    result.subringSortFields = parseStringMap(node["subringSortFields"],
                                              "subringSortFields")
  if node.hasKey("subringSortDirections"):
    result.subringSortDirections = parseSortDirectionMap(
      node["subringSortDirections"], "subringSortDirections")
  if node.hasKey("maxDepth"):
    result.maxDepth = node["maxDepth"].getInt()
  if node.hasKey("branchBudget"):
    result.branchBudget = node["branchBudget"].getInt()
  if node.hasKey("subrings"):
    result.subrings = parseStringArray(node["subrings"], "subrings")
  if node.hasKey("includeRoot"):
    result.includeRoot = node["includeRoot"].getBool()
  if node.hasKey("sortField"):
    result.sortField = node["sortField"].getStr()
  if node.hasKey("sortDirection"):
    result.sortDirection = parseSortDirection(
      node["sortDirection"].getStr(), "sortDirection")

proc koutenStellarPageJson(page: KoutenStellarPage): JsonNode =
  var rings = newJArray()
  for ringPage in page.rings:
    var items = newJArray()
    for item in ringPage.items:
      items.add koutenRecordJson(item)
    rings.add %*{
      "ring": ringPage.ring,
      "count": ringPage.count,
      "items": items
    }
  %*{
    "root": page.root,
    "maxDepth": page.maxDepth,
    "branchBudget": page.branchBudget,
    "ringsVisited": page.ringsVisited,
    "count": page.count,
    "rings": rings
  }

proc kouten_stellar_attach(h: pointer, stellar, ring: cstring): cint
                           {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureHandle(h).attachStellar(
      cstringToString(stellar, "stellar", allowNil = false),
      cstringToString(ring, "ring", allowNil = false))
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_stellar_detach(h: pointer, stellar, ring: cstring): cint
                           {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureHandle(h).detachStellar(
      cstringToString(stellar, "stellar", allowNil = false),
      cstringToString(ring, "ring", allowNil = false))
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc stringArrayJson(values: seq[string]): JsonNode =
  result = newJArray()
  for value in values:
    result.add %value

proc kouten_stellar_members_json(h: pointer, stellar: cstring,
                                 outLen: ptr csize_t): pointer
                                 {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let values = ensureHandle(h).stellarMembers(
      cstringToString(stellar, "stellar", allowNil = false))
    copyJsonToShared(stringArrayJson(values), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_stellar_coordinates_json(h: pointer, ring: cstring,
                                     outLen: ptr csize_t): pointer
                                     {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let values = ensureHandle(h).stellarCoordinatesFor(
      cstringToString(ring, "ring", allowNil = false))
    copyJsonToShared(stringArrayJson(values), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_read_stellar_json(h: pointer, root, optionsJson: cstring,
                              outLen: ptr csize_t): pointer
                              {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let page = ensureHandle(h).readStellar(
      cstringToString(root, "root", allowNil = false),
      stellarOptionsFromC(optionsJson))
    copyJsonToShared(koutenStellarPageJson(page), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc vecFromC(vec: ptr cfloat, vecLen: csize_t): seq[float32] =
  if vecLen == 0:
    return @[]
  if vec == nil:
    raise newException(ValueError, "vec is nil")
  let nVec = boundedCountFromC(vecLen, MaxCVectorDim, "vec_len")
  result = newSeq[float32](nVec)
  let rawVec = cast[ptr UncheckedArray[cfloat]](vec)
  for i in 0 ..< nVec:
    result[i] = float32(rawVec[i])

proc retrieveResultToC(hits: seq[KoutenHit], stats: RetrieveStats):
                       ptr KoutenCRetrieveResult =
  result = cast[ptr KoutenCRetrieveResult](
    allocShared0(sizeof(KoutenCRetrieveResult)))
  result.len = csize_t(hits.len)
  result.total_vectors = cint(stats.totalVectors)
  result.scanned = cint(stats.scanned)
  result.skipped_vectors = cint(stats.skippedVectors)
  result.returned = cint(stats.returned)
  result.rings_touched = cint(stats.ringsTouched)
  result.payload_bytes = cint(stats.payloadBytes)
  result.estimated_tokens = cint(stats.estimatedTokens)
  result.fanout_nodes = cint(stats.fanoutNodes)
  result.candidate_reduction = cdouble(stats.candidateReduction)
  if hits.len > 0:
    let hitBytes = allocBytesFor(hits.len, sizeof(KoutenCHit), "retrieve hits")
    result.hits = cast[ptr KoutenCHit](allocShared0(hitBytes))
    let rawHits = cast[ptr UncheckedArray[KoutenCHit]](result.hits)
    for i, hit in hits:
      rawHits[i].id = hit.id.toC
      rawHits[i].score = cdouble(hit.score)
      rawHits[i].payload_len = csize_t(hit.payload.len)
      rawHits[i].payload = allocShared0(hit.payload.len + 1)
      if hit.payload.len > 0:
        copyMem(rawHits[i].payload, unsafeAddr hit.payload[0], hit.payload.len)

proc kouten_retrieve(h: pointer, vec: ptr cfloat, vecLen: csize_t, ring: cstring,
                    budget, topRings, focus: cint): ptr KoutenCRetrieveResult
                    {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let db = ensureHandle(h)
    let q = vecFromC(vec, vecLen)
    let rr = db.retrieveWithStats(q, ring = optStr(ring),
                                  budget = int(budget),
                                  topRings = int(topRings),
                                  focus = int(focus))
    result = retrieveResultToC(rr.hits, rr.stats)
  except CatchableError as e:
    setError(e)
    return nil

proc kouten_retrieve_tuned(h: pointer, vec: ptr cfloat, vecLen: csize_t,
                           ring, profile: cstring): ptr KoutenCRetrieveResult
                           {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let rr = ensureHandle(h).retrieveTunedWithStats(
      vecFromC(vec, vecLen), ring = optStr(ring),
      profile = cstringToString(profile, "profile", allowNil = false))
    result = retrieveResultToC(rr.hits, rr.stats)
  except CatchableError as e:
    setError(e)
    return nil

proc kouten_retrieve_free(r: ptr KoutenCRetrieveResult) {.exportc, cdecl, dynlib.} =
  if r == nil:
    return
  if r.hits != nil:
    let rawHits = cast[ptr UncheckedArray[KoutenCHit]](r.hits)
    for i in 0 ..< int(r.len):
      if rawHits[i].payload != nil:
        deallocShared(rawHits[i].payload)
    deallocShared(r.hits)
  deallocShared(r)

proc kouten_ring_summaries_json(h: pointer, queryVec: ptr cfloat,
                                queryVecLen: csize_t,
                                outLen: ptr csize_t): pointer
                                {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    var output = newJArray()
    for summary in ensureHandle(h).ringSummaries(
        vecFromC(queryVec, queryVecLen)):
      output.add %*{
        "ringKey": $summary.ringKey,
        "count": summary.count,
        "centroid": summary.centroid,
        "score": summary.score,
        "coherence": summary.coherence,
        "massG": summary.massG
      }
    copyJsonToShared(output, outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_retrieval_envelope_json(
    h: pointer, queryVec: ptr cfloat, queryVecLen: csize_t,
    ring: cstring, budget, topRings, focus: cint,
    outLen: ptr csize_t): pointer {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let envelope = ensureHandle(h).retrievalEnvelope(
      vecFromC(queryVec, queryVecLen), ring = optStr(ring),
      budget = int(budget), topRings = int(topRings), focus = int(focus))
    copyJsonToShared(envelope, outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_retrieval_envelope_tuned_json(
    h: pointer, queryVec: ptr cfloat, queryVecLen: csize_t,
    ring, profile: cstring, outLen: ptr csize_t): pointer
    {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let envelope = ensureHandle(h).retrievalEnvelopeTuned(
      vecFromC(queryVec, queryVecLen), ring = optStr(ring),
      profile = optStrOr(profile, "default"))
    copyJsonToShared(envelope, outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_retrieval_envelope_validate_json(
    envelopeJson: cstring, outLen: ptr csize_t): pointer
    {.exportc, cdecl, dynlib.} =
  try:
    initRuntime()
    clearError()
    let envelope = parseJson(cstringToString(
      envelopeJson, "envelope_json", allowNil = false))
    let errors = retrievalEnvelopeValidationErrors(envelope)
    copyJsonToShared(%*{
      "valid": errors.len == 0,
      "errors": errors
    }, outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_locality_report_json(h: pointer,
                                 outLen: ptr csize_t): pointer
                                 {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    copyJsonToShared(localityReportJson(ensureHandle(h).localityReport()), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_atlas(h: pointer, queryVec: ptr cfloat, queryVecLen: csize_t,
                 maxCentroidDims: cint, outLen: ptr csize_t): pointer
                 {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    if outLen == nil:
      raise newException(ValueError, "out_len is nil")
    let db = ensureHandle(h)
    let q = vecFromC(queryVec, queryVecLen)
    let maxDims = if maxCentroidDims < 0: 0 else: int(maxCentroidDims)
    let s = $db.atlas(q, maxCentroidDims = maxDims)
    outLen[] = csize_t(s.len)
    result = copyStringToShared(s)
  except CatchableError as e:
    setError(e)
    return nil

proc kouten_compact_json(h: pointer, outLen: ptr csize_t): pointer
                         {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    copyJsonToShared(compactStatsJson(ensureHandle(h).compact()), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_dump_jsonl(h: pointer, path: cstring, includeVectors: cint,
                       outLen: ptr csize_t): pointer
                       {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let destination = cstringToString(path, "path", allowNil = false)
    if destination.len == 0 or destination == "-":
      raise newException(ValueError,
        "C ABI dump requires a file path and cannot write to process stdout")
    let stats = ensureHandle(h).dump(
      destination, requireCBool(includeVectors, "include_vectors"))
    copyJsonToShared(dumpStatsJson(stats), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_import_jsonl(h: pointer, path: cstring, optionsJson: cstring,
                         outLen: ptr csize_t): pointer
                         {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let options = jsonOptions(optionsJson, "import options")
    let stats = ensureHandle(h).importJsonl(
      cstringToString(path, "path", allowNil = false),
      defaultRing = jsonStringOption(options, "defaultRing", "imported"),
      ringField = jsonStringOption(options, "ringField", ""),
      ringPrefix = jsonStringOption(options, "ringPrefix", ""),
      payloadField = jsonStringOption(options, "payloadField", ""),
      vecField = jsonStringOption(options, "vecField", ""),
      maxRecords = jsonIntOption(options, "maxRecords", 0),
      batchSize = jsonIntOption(options, "batchSize", 1000),
      packSegments = jsonBoolOption(options, "packSegments", false))
    copyJsonToShared(importStatsJson(stats), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_pack_all_json(h: pointer, outLen: ptr csize_t): pointer
                          {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    copyJsonToShared(packStatsJson(
      ensureHandle(h).packDiskBackedSegments()), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_pack_ring_json(h: pointer, ring: cstring,
                           outLen: ptr csize_t): pointer
                           {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let stats = ensureHandle(h).packDiskBackedRing(
      cstringToString(ring, "ring", allowNil = false))
    copyJsonToShared(packStatsJson(stats), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_backup_json(h: pointer, destination: cstring,
                        outLen: ptr csize_t): pointer
                        {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let stats = ensureHandle(h).backup(cstringToString(
      destination, "destination", allowNil = false))
    copyJsonToShared(backupStatsJson(stats, encrypted = false), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_backup_encrypted_json(h: pointer, destination,
                                  passphrase: cstring,
                                  outLen: ptr csize_t): pointer
                                  {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let stats = ensureHandle(h).backupEncrypted(
      cstringToString(destination, "destination", allowNil = false),
      cstringToString(passphrase, "passphrase", allowNil = false))
    copyJsonToShared(backupStatsJson(stats, encrypted = true), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_backup_verify_json(backupDir: cstring,
                               outLen: ptr csize_t): pointer
                               {.exportc, cdecl, dynlib.} =
  try:
    initRuntime()
    clearError()
    let stats = verifyBackup(cstringToString(
      backupDir, "backup_dir", allowNil = false))
    copyJsonToShared(backupStatsJson(stats, encrypted = false), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_backup_encrypted_verify_json(
    backupDir, passphrase: cstring, outLen: ptr csize_t): pointer
    {.exportc, cdecl, dynlib.} =
  try:
    initRuntime()
    clearError()
    let stats = verifyEncryptedBackup(
      cstringToString(backupDir, "backup_dir", allowNil = false),
      cstringToString(passphrase, "passphrase", allowNil = false))
    copyJsonToShared(backupStatsJson(stats, encrypted = true), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_backup_restore_json(backupDir, dataDir: cstring,
                                overwrite, durability: cint,
                                outLen: ptr csize_t): pointer
                                {.exportc, cdecl, dynlib.} =
  try:
    initRuntime()
    clearError()
    let stats = restoreBackup(
      cstringToString(backupDir, "backup_dir", allowNil = false),
      cstringToString(dataDir, "data_dir", allowNil = false),
      overwrite = requireCBool(overwrite, "overwrite"),
      durability = durabilityFromC(durability))
    copyJsonToShared(backupStatsJson(stats, encrypted = false), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_backup_encrypted_restore_json(
    backupDir, dataDir, passphrase: cstring, overwrite, durability: cint,
    outLen: ptr csize_t): pointer {.exportc, cdecl, dynlib.} =
  try:
    initRuntime()
    clearError()
    let stats = restoreEncryptedBackup(
      cstringToString(backupDir, "backup_dir", allowNil = false),
      cstringToString(dataDir, "data_dir", allowNil = false),
      cstringToString(passphrase, "passphrase", allowNil = false),
      overwrite = requireCBool(overwrite, "overwrite"),
      durability = durabilityFromC(durability))
    copyJsonToShared(backupStatsJson(stats, encrypted = true), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_operational_verify_json(dataDir, optionsJson: cstring,
                                    outLen: ptr csize_t): pointer
                                    {.exportc, cdecl, dynlib.} =
  try:
    initRuntime()
    clearError()
    let options = jsonOptions(optionsJson, "verify options")
    let report = operationalVerify(
      cstringToString(dataDir, "data_dir", allowNil = false),
      diskBacked = jsonBoolOption(options, "diskBacked", true),
      verifySegments = jsonBoolOption(options, "verifySegments", false),
      maxWalBytes = jsonInt64Option(options, "maxWalBytes", -1),
      maxSegmentFiles = jsonIntOption(options, "maxSegmentFiles", -1),
      maxItems = jsonIntOption(options, "maxItems", -1),
      maxRings = jsonIntOption(options, "maxRings", -1),
      maxSegmentBytes = jsonInt64Option(options, "maxSegmentBytes", -1),
      maxDeadRecords = jsonIntOption(options, "maxDeadRecords", -1),
      maxDeadRatio = jsonFloatOption(options, "maxDeadRatio", -1.0),
      maxSegmentGeneration = jsonInt64Option(
        options, "maxSegmentGeneration", -1),
      staleRatioThreshold = jsonFloatOption(
        options, "staleRatioThreshold", 0.25),
      minStaleRecords = jsonIntOption(options, "minStaleRecords", 256))
    copyJsonToShared(operationalReportJson(report), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_wait_cluster_tx_applied(h: pointer, txid: uint64,
                                    coordinatorNode, timeoutMs,
                                    pollMs: cint): cint
                                    {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    if timeoutMs < 0:
      raise newException(ValueError, "timeout_ms must be non-negative")
    if pollMs <= 0:
      raise newException(ValueError, "poll_ms must be positive")
    if ensureHandle(h).waitClusterTxApplied(
        txid, coordinatorNode = int(coordinatorNode),
        timeoutMs = int(timeoutMs), pollMs = int(pollMs)):
      cint(1)
    else:
      cint(0)
  except CatchableError as e:
    setError(e)
    KoutenErr

proc maintenancePolicyFromC(staleRatio: cdouble, minStaleRecords,
                            maxRings: cint, maxBytes,
                            maxElapsedMs: int64):
                            KoutenSegmentMaintenancePolicy =
  result = KoutenSegmentMaintenancePolicy(
    staleRatioThreshold: float(staleRatio),
    minStaleRecords: int(minStaleRecords),
    maxRings: int(maxRings),
    maxBytes: maxBytes,
    maxElapsedMs: maxElapsedMs)
  validateSegmentMaintenancePolicy(result)

proc metricsFormatFromC(format: cint): KoutenMetricsFormat =
  case format
  of 0: kmfKeyValue
  of 1: kmfPrometheus
  of 2: kmfOpenMetrics
  else:
    raise newException(ValueError, "metrics format must be 0, 1, or 2")

proc kouten_metrics_text(h: pointer, format: cint,
                         outLen: ptr csize_t): pointer
                         {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    if outLen == nil:
      raise newException(ValueError, "out_len is nil")
    let output = ensureHandle(h).metricsText(metricsFormatFromC(format))
    outLen[] = csize_t(output.len)
    copyStringToShared(output)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_checkpoint_metrics_text(root: cstring, format: cint,
                                    outLen: ptr csize_t): pointer
                                    {.exportc, cdecl, dynlib.} =
  try:
    initRuntime()
    clearError()
    if outLen == nil:
      raise newException(ValueError, "out_len is nil")
    let output = checkpointMetricsText(
      cstringToString(root, "root", allowNil = false),
      metricsFormatFromC(format))
    outLen[] = csize_t(output.len)
    copyStringToShared(output)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_segment_status_json(h: pointer, staleRatio: cdouble,
                                minStaleRecords: cint,
                                outLen: ptr csize_t): pointer
                                {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let status = ensureHandle(h).segmentStatus(float(staleRatio),
                                               int(minStaleRecords))
    copyJsonToShared(segmentStatusJson(status), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_segment_maintenance_plan_json(
    h: pointer, staleRatio: cdouble, minStaleRecords, maxRings: cint,
    maxBytes, maxElapsedMs: int64, outLen: ptr csize_t): pointer
    {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let policy = maintenancePolicyFromC(staleRatio, minStaleRecords,
                                        maxRings, maxBytes, maxElapsedMs)
    let maintenance = ensureHandle(h).planSegmentMaintenance(policy)
    copyJsonToShared(segmentMaintenanceJson(maintenance, policy), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_segment_maintenance_run_json(
    h: pointer, staleRatio: cdouble, minStaleRecords, maxRings: cint,
    maxBytes, maxElapsedMs: int64, outLen: ptr csize_t): pointer
    {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let policy = maintenancePolicyFromC(staleRatio, minStaleRecords,
                                        maxRings, maxBytes, maxElapsedMs)
    let maintenance = ensureHandle(h).runSegmentMaintenance(policy)
    copyJsonToShared(segmentMaintenanceJson(maintenance, policy), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_segment_maintenance_status_json(h: pointer,
                                            outLen: ptr csize_t): pointer
    {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    copyJsonToShared(ensureHandle(h).segmentMaintenanceStatus(), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_segment_maintenance_recover(h: pointer,
                                        outRecovered: ptr cint): cint
    {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    if outRecovered == nil:
      raise newException(ValueError, "out_recovered is nil")
    outRecovered[] =
      if ensureHandle(h).recoverInterruptedSegmentMaintenance(): cint(1)
      else: cint(0)
    KoutenOk
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_checkpoint_create_json(h: pointer, root, checkpointId: cstring,
                                   outLen: ptr csize_t): pointer
    {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    let status = ensureHandle(h).createCheckpoint(optStr(root),
                                                   optStr(checkpointId))
    copyJsonToShared(checkpointStatusJson(status), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_checkpoint_status_json(checkpointDir: cstring,
                                   outLen: ptr csize_t): pointer
    {.exportc, cdecl, dynlib.} =
  try:
    initRuntime()
    clearError()
    let path = cstringToString(checkpointDir, "checkpoint_dir",
                               allowNil = false)
    copyJsonToShared(checkpointStatusJson(checkpointStatus(path)), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_checkpoint_list_json(root: cstring,
                                 outLen: ptr csize_t): pointer
    {.exportc, cdecl, dynlib.} =
  try:
    initRuntime()
    clearError()
    let path = cstringToString(root, "root", allowNil = false)
    copyJsonToShared(checkpointListJson(path, listCheckpoints(path)), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_checkpoint_cleanup_json(root: cstring, keep: cint,
                                    outLen: ptr csize_t): pointer
    {.exportc, cdecl, dynlib.} =
  try:
    initRuntime()
    clearError()
    let path = cstringToString(root, "root", allowNil = false)
    copyJsonToShared(checkpointCleanupJson(
      cleanupCheckpoints(path, int(keep))), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_checkpoint_restore_json(checkpointDir, dataDir: cstring,
                                    overwrite: cint,
                                    outLen: ptr csize_t): pointer
    {.exportc, cdecl, dynlib.} =
  try:
    initRuntime()
    clearError()
    if overwrite notin [cint(0), cint(1)]:
      raise newException(ValueError, "overwrite must be 0 or 1")
    let status = restoreCheckpoint(
      cstringToString(checkpointDir, "checkpoint_dir", allowNil = false),
      cstringToString(dataDir, "data_dir", allowNil = false),
      overwrite = overwrite != 0)
    copyJsonToShared(checkpointStatusJson(status), outLen)
  except CatchableError as e:
    setError(e)
    nil

proc kouten_locate(h: pointer, id: KoutenCId,
                  at: cdouble): cint {.exportc, cdecl, dynlib.} =
  ## at < 0 で「現在」。失敗時 -1。
  try:
    clearError()
    cint(ensureHandle(h).locate(fromC(id), at))
  except CatchableError as e:
    setError(e)
    KoutenErr

proc kouten_next_visit(h: pointer, id: KoutenCId,
                      node: cint): cdouble {.exportc, cdecl, dynlib.} =
  try:
    clearError()
    ensureHandle(h).nextVisit(fromC(id), int(node))
  except CatchableError as e:
    setError(e)
    -1.0

proc kouten_next_join(h: pointer, a, b: KoutenCId): cdouble {.exportc, cdecl, dynlib.} =
  ## 会合しない場合は -1。
  try:
    clearError()
    ensureHandle(h).nextJoin(fromC(a), fromC(b))
  except CatchableError as e:
    setError(e)
    -1.0
