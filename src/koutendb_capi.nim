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

import std/[base64, json, tables]
import koutendb

type
  KoutenCHandle = ref object
    db: KoutenDb
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

var lastError {.threadvar.}: string
var runtimeReady = false
var handles = initTable[pointer, KoutenCHandle]()

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
  if h notin handles:
    raise newException(ValueError, "db handle is unknown or closed")
  let handle = handles[h]
  if handle.closed or handle.db.isNil:
    raise newException(ValueError, "db handle is closed")
  handle.db

proc registerHandle(db: KoutenDb): pointer =
  let handle = KoutenCHandle(db: db)
  GC_ref(handle)
  result = cast[pointer](handle)
  handles[result] = handle

proc initRuntime() =
  if not runtimeReady:
    NimMain()
    runtimeReady = true

proc cstringToString(s: cstring, name: string, allowNil = true): string =
  if s == nil:
    if allowNil:
      return ""
    raise newException(ValueError, name & " is nil")
  $s

proc copyStringToShared(s: string): pointer =
  result = allocShared0(s.len + 1)
  if s.len > 0:
    copyMem(result, unsafeAddr s[0], s.len)

proc toC(id: KoutenId): KoutenCId =
  let (p, e, s, t) = id.toRaw
  KoutenCId(parent: p, epoch: e, seq: s, t_write: t)

proc fromC(id: KoutenCId): KoutenId =
  fromRaw(id.parent, id.epoch, id.seq, id.t_write)

proc optStr(s: cstring): string =
  if s == nil:
    ""
  else:
    $s

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

proc bytesFromC(data: pointer, len: csize_t): string =
  if len > 0 and data == nil:
    raise newException(ValueError, "data is nil")
  if len > csize_t(high(int)):
    raise newException(ValueError, "data length is too large")
  result = newString(int(len))
  if len > 0:
    copyMem(addr result[0], data, int(len))

proc countFromC(len: csize_t, name: string): int =
  if len > csize_t(high(int)):
    raise newException(ValueError, name & " is too large")
  int(len)

proc allocBytesFor(count: int, elemSize: int, name: string): int =
  if count < 0:
    raise newException(ValueError, name & " count is negative")
  if elemSize <= 0:
    raise newException(ValueError, name & " element size is invalid")
  if count > high(int) div elemSize:
    raise newException(ValueError, name & " allocation is too large")
  count * elemSize

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
    let db = koutendb.connect(optStr(peers),
                             username = optStr(username),
                             password = optStr(password),
                             authToken = optStr(authToken),
                             secretKey = optStr(secretKey),
                             galaxy = optStr(galaxy),
                             tls = tls != 0,
                             tlsCaFile = optStr(tlsCaFile),
                             tlsServerName = optStr(tlsServerName),
                             tlsInsecureSkipVerify = tlsInsecureSkipVerify != 0)
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
    if h notin handles:
      setError("db handle is unknown or closed")
      return
    let handle = handles[h]
    handles.del h
    if not handle.closed and not handle.db.isNil:
      handle.db.close()
    handle.closed = true
    handle.db = nil
    GC_unref(handle)
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
    let nVec = countFromC(vecLen, "vec_len")
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
    let nVec = countFromC(vecLen, "vec_len")
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
    let nIds = countFromC(idsLen, "ids_len")
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

proc koutenReadPayloadNode(item: KoutenRecord): JsonNode =
  if item.codec == pcJson:
    try:
      return %*{"encoding": "json", "payload": parseJson(item.payload)}
    except JsonParsingError:
      discard
  %*{"encoding": "base64", "payload": base64.encode(item.payload)}

proc koutenReadPageJson(page: KoutenReadPage): string =
  var items = newJArray()
  for item in page.items:
    let display = koutenReadPayloadNode(item)
    let (parent, epoch, seq, tWrite) = item.id.toRaw
    items.add %*{
      "id": $item.id,
      "rawId": $parent & ":" & $epoch & ":" & $seq & ":" & $tWrite,
      "codec": item.codec.payloadCodecName,
      "encoding": display["encoding"].getStr(),
      "payload": display["payload"]
    }
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
    let filterText = optStr(filterJson)
    let filterNode =
      if filterText.len == 0: newJObject()
      else: parseJson(filterText)
    if filterNode.kind != JObject:
      raise newException(ValueError, "filter must be a JSON object")
    let opts = KoutenReadOptions(
      filter: filterNode,
      selection: optStr(selection),
      limit: int(limit),
      cursor: optStr(cursor),
      pagination: if pagination == 0: rpOff else: rpOn,
      page: int(page),
      pageLimit: int(pageLimit),
      sortField: optStr(sortField),
      sortDirection: if sortDesc == 0: rsAsc else: rsDesc)
    let pageResult = ensureHandle(h).readRing(
      cstringToString(ring, "ring", allowNil = false), opts)
    let s = koutenReadPageJson(pageResult)
    outLen[] = csize_t(s.len)
    copyStringToShared(s)
  except CatchableError as e:
    setError(e)
    nil

proc vecFromC(vec: ptr cfloat, vecLen: csize_t): seq[float32] =
  if vecLen == 0:
    return @[]
  if vec == nil:
    raise newException(ValueError, "vec is nil")
  let nVec = countFromC(vecLen, "vec_len")
  result = newSeq[float32](nVec)
  let rawVec = cast[ptr UncheckedArray[cfloat]](vec)
  for i in 0 ..< nVec:
    result[i] = float32(rawVec[i])

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
    result = cast[ptr KoutenCRetrieveResult](allocShared0(sizeof(KoutenCRetrieveResult)))
    result.len = csize_t(rr.hits.len)
    result.total_vectors = cint(rr.stats.totalVectors)
    result.scanned = cint(rr.stats.scanned)
    result.skipped_vectors = cint(rr.stats.skippedVectors)
    result.returned = cint(rr.stats.returned)
    result.rings_touched = cint(rr.stats.ringsTouched)
    result.payload_bytes = cint(rr.stats.payloadBytes)
    result.estimated_tokens = cint(rr.stats.estimatedTokens)
    result.fanout_nodes = cint(rr.stats.fanoutNodes)
    result.candidate_reduction = cdouble(rr.stats.candidateReduction)
    if rr.hits.len > 0:
      let hitBytes = allocBytesFor(rr.hits.len, sizeof(KoutenCHit), "retrieve hits")
      result.hits = cast[ptr KoutenCHit](allocShared0(hitBytes))
      let rawHits = cast[ptr UncheckedArray[KoutenCHit]](result.hits)
      for i, hit in rr.hits:
        rawHits[i].id = hit.id.toC
        rawHits[i].score = cdouble(hit.score)
        rawHits[i].payload_len = csize_t(hit.payload.len)
        rawHits[i].payload = allocShared0(hit.payload.len + 1)
        if hit.payload.len > 0:
          copyMem(rawHits[i].payload, unsafeAddr hit.payload[0], hit.payload.len)
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
