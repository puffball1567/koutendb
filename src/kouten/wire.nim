## kouten/wire — クラスタ用ワイヤプロトコルとクライアント側トランスポート（設計書 §14）
##
## テキストヘッダ＋長さ接頭辞 payload。接続は永続（connect-per-request をやめるのが
## ネットワーク経路の高速化の肝, §16.2）。
##
## フレーム:
##   PUTR <ringLen> <payloadLen> <vecDim>\n<ring><payload><vec>
##       → ID <parent> <epoch> <seq> <tWrite> <period> <head>\n
##   GETID <parent> <epoch> <seq> <tWrite> <period> <head>\n
##       → VAL <node> <len>\n<payload> | MISS
##         | FWD <parent> <epoch> <seq> <tWrite> <period> <head> [owner]\n
##   QRYID <parent> <epoch> <seq> <tWrite> <period> <head> <selLen>\n<sel>
##       → VAL <node> <len>\n<json> | MISS | ERR <msg>
##         | FWD <parent> <epoch> <seq> <tWrite> <period> <head> [owner]\n
##   TXGETID <parent> <epoch> <seq> <tWrite> <period> <head>\n
##       → VAL <node> <len>\n<payload> | MISS\n
##   TXQRYID <parent> <epoch> <seq> <tWrite> <period> <head> <selLen>\n<sel>
##       → VAL <node> <len>\n<json> | MISS | ERR <msg>\n
##   PUT <ringKey> <period> <head> <len> <vecDim>\n<payload><vec> → OK <seq> <tWrite>\n
##   GET <parent> <seq> <period> <head> <tWrite>\n
##       → VAL <node> <len>\n<payload> | MISS
##         | FWD <parent> <seq> <tWrite> [owner]\n
##   QRY <parent> <seq> <period> <head> <tWrite> <len>\n<sel>
##       → VAL <node> <len>\n<json> | MISS | ERR <msg>
##         | FWD <parent> <seq> <tWrite> [owner]\n
##   BGET <n> <bodyLen>\n repeated: <parent> <seq> <period> <head> <tWrite>\n
##       → BVAL <n> <payloadLen>\n repeated: <len>\n<payload>
##   TRF <parent> <seq> <period> <head> <tWrite> <len> <vecDim> <codec>
##       [<physicalMicros> <logical> <origin>
##        <placementEpoch> <placementNodes> <virtualArcs>]\n
##       <payload><vec> → OK APPLIED|SKIPPED\n
##     （ノード間ハンドオフ）
##   TRFD <parent> <seq> <period> <head> <tWrite>
##       <physicalMicros> <logical> <origin> [<ackedNodes> <reclaimAfter>
##       <placementEpoch> <placementNodes> <virtualArcs>]\n
##       → OK APPLIED|SKIPPED\n
##   TXBEGIN\n                                                  → OK <txid>\n
##   TXRESERVE <txid> <ringKey> <period> <head>\n              → OK <seq> <tWrite>\n
##   TXCOMMIT <txid> <n>\n repeated: <parent> ... <vecDim>\n<payload><vec> → OK\n
##   TXSTATUS <txid>\n                                             → OK APPLIED|PENDING|UNKNOWN\n
##   UAPPLY <len>\n<json event>                                    → UOK APPLIED|SKIPPED|DELAYED
##   USTATUS\n
##       → USTATUS <pending> <appliedKeys> <appliedOps> <skippedOps> <errors> <forwarded> <lastOk> <lastError>
##   WIREVER\n                                                     → WIREVER <version>
##   CODECS\n                                                      → CODECS raw json nif bif
##   CODECMETA ON\n                                                → OK codec-metadata
##   APPLYTX <txid> <parent> <seq> <period> <head> <tWrite> <len> <vecDim>\n<payload><vec> → OK\n
##   RETRIEVE <hasRing> <ringKey> <budget> <vecDim>\n<vec>
##     → RHIT <scanned> <ringsTouched> <n>\n repeated: <parent> <seq> <tWrite> <score> <len>\n<payload>
##   RINGS\n → RINGS <n>\n repeated: RING <ringKey> <count> <vecDim>\n<centroid>
##   STATS\n                                                   → OK <node> <count>\n
##   TOPOLOGY\n
##       → TOPOLOGY <placementEpoch> <nNodes> <virtualArcsPerNode>\n
##   MIGVERIFY <parent> <seq> <physicalMicros> <logical> <origin> <deleted>\n
##       → MIGRATION MATCH|AHEAD LIVE|DELETED\n
##   MIGMETA <placementEpoch> <placementNodes> <virtualArcs> <len>\n<json>
##       → OK APPLIED\n
##   MIGMETAVERIFY <placementEpoch> <placementNodes> <virtualArcs> <len>\n<json>
##       → MIGRATION MATCH\n

import std/[net, strutils, tables]
import ./[auth, payload, mutation, core]

export payload
export mutation

const
  WireProtocolVersion* = 1
  MaxWireHeaderBytes* = 8 * 1024
  MaxSecureFrameBytes = 64 * 1024 * 1024 + MaxWireHeaderBytes

type
  Peer* = tuple[host: string, port: int]

  UniverseWireStatus* = object
    pending*: int
    applied*: int
    appliedOps*: int
    skippedOps*: int
    errors*: int
    forwarded*: int
    lastOk*: int
    lastError*: int

  TxWireOp* = object
    delete*: bool
    parent*: uint64
    seq*: uint32
    period*: float
    head*: float
    tWrite*: float
    payload*: string
    codec*: PayloadCodec
    vec*: seq[float32]
    version*: MutationVersion

  WireId* = object
    parent*: uint64
    epoch*: uint32
    seq*: uint32
    tWrite*: float
    period*: float
    head*: float

  WireGetResult* = object
    found*: bool
    node*: int
    targetNode*: int
    value*: string
    codec*: PayloadCodec
    deleted*: bool
    forwarded*: bool
    id*: WireId

  RetrieveWireHit* = object
    parent*: uint64
    seq*: uint32
    tWrite*: float
    score*: float
    payload*: string
    codec*: PayloadCodec

  RetrieveWireResult* = object
    totalVectors*: int
    scanned*: int
    skippedVectors*: int
    ringsTouched*: int
    payloadBytes*: int
    estimatedTokens*: int
    hits*: seq[RetrieveWireHit]

  RingSummary* = object
    ringKey*: uint64
    count*: int
    centroid*: seq[float32]

  WireListItem* = object
    parent*: uint64
    seq*: uint32
    tWrite*: float
    payload*: string
    codec*: PayloadCodec

  WireListResult* = object
    items*: seq[WireListItem]
    nextCursor*: string

  ClusterClient* = ref object
    peers*: seq[Peer]
    socks: Table[int, Socket]   # nodeId → 永続接続
    username: string
    password: string
    secretKey: string
    galaxy: string
    tls: bool
    tlsCaFile: string
    tlsServerName: string
    tlsInsecureSkipVerify: bool
    codecMetadata: Table[int, bool]

  SecureState = object
    secretKey: string
    challengeHex: string
    buffer: string

var secureConns {.threadvar.}: Table[int, SecureState]

proc parsePeers*(s: string): seq[Peer] =
  ## "host:port,host:port,..." を解析。リスト内の位置 = ノードID。
  for part in s.split(','):
    let hp = part.strip().rsplit(':', maxsplit = 1)
    doAssert hp.len == 2, "peers は host:port,host:port,... 形式: " & part
    result.add (hp[0], parseInt(hp[1]))
  doAssert result.len > 0, "peers が空"

proc newClusterClient*(peers: seq[Peer], username: string = "",
                       password: string = "", authToken: string = "",
                       secretKey: string = "", galaxy: string = "",
                       tls: bool = false, tlsCaFile: string = "",
                       tlsServerName: string = "",
                       tlsInsecureSkipVerify: bool = false): ClusterClient =
  if authToken.len > 0 and username.len == 0:
    return ClusterClient(peers: peers, username: "token", password: authToken,
                         secretKey: secretKey, galaxy: galaxy, tls: tls,
                         tlsCaFile: tlsCaFile, tlsServerName: tlsServerName,
                         tlsInsecureSkipVerify: tlsInsecureSkipVerify)
  ClusterClient(peers: peers, username: username, password: password,
                secretKey: secretKey, galaxy: galaxy, tls: tls,
                tlsCaFile: tlsCaFile, tlsServerName: tlsServerName,
                tlsInsecureSkipVerify: tlsInsecureSkipVerify)

proc close*(c: ClusterClient) =
  for _, s in c.socks:
    secureConns.del s.getFd.int
    s.close()
  c.socks.clear()

# ---------------------------------------------------------------- 低レベル入出力

proc rawReadExact(sock: Socket, n: int): string =
  if n < 0:
    raise newException(ValueError, "read length must be non-negative")
  result = newString(n)
  var got = 0
  while got < n:
    let r = sock.recv(addr result[got], n - got)
    if r <= 0:
      raise newException(IOError, "接続が切断された")
    got += r

proc readSecureFrame(sock: Socket) =
  let fd = sock.getFd.int
  var st = secureConns[fd]
  let line = sock.recvLine(timeout = 10_000)
  if line.len == 0 or line == "\r\n":
    raise newException(IOError, "接続が切断された")
  if line.len > MaxWireHeaderBytes:
    raise newException(ValueError, "wire header exceeds max bytes")
  let h = line.split(' ')
  if h.len < 2 or h[0] != "SEC":
    raise newException(IOError, "暗号化フレームではない: " & line.strip())
  let ciphertextLen = parseInt(h[1])
  if ciphertextLen < 0 or ciphertextLen > MaxSecureFrameBytes:
    raise newException(ValueError, "secure frame exceeds max bytes")
  let ciphertext = sock.rawReadExact(ciphertextLen)
  st.buffer.add decryptTransportFrame(ciphertext, st.secretKey, st.challengeHex)
  secureConns[fd] = st

proc enableSecure*(sock: Socket, secretKey, challengeHex: string) =
  secureConns[sock.getFd.int] = SecureState(secretKey: secretKey,
                                            challengeHex: challengeHex)

proc disableSecure*(sock: Socket) =
  secureConns.del sock.getFd.int

proc readExact*(sock: Socket, n: int): string =
  let fd = sock.getFd.int
  if fd notin secureConns:
    return sock.rawReadExact(n)
  while secureConns[fd].buffer.len < n:
    sock.readSecureFrame()
  result = secureConns[fd].buffer[0 ..< n]
  var st = secureConns[fd]
  if n == st.buffer.len:
    st.buffer = ""
  else:
    st.buffer = st.buffer[n .. ^1]
  secureConns[fd] = st

proc sendFrame*(sock: Socket, header: string, payload: string = "") =
  # ヘッダと payload を1回の send にまとめる（syscall 削減）
  let plaintext = header & "\n" & payload
  let fd = sock.getFd.int
  if fd in secureConns:
    let st = secureConns[fd]
    let ciphertext = encryptTransportFrame(plaintext, st.secretKey, st.challengeHex)
    sock.send("SEC " & $ciphertext.len & "\n" & ciphertext)
  else:
    sock.send(plaintext)

proc vecBytes*(vec: seq[float32]): string =
  ## Wire vectors are canonical little-endian IEEE-754 float32 values.
  ## Do not use host-endian copyMem here; native wire drivers depend on this.
  result = newString(vec.len * sizeof(float32))
  var pos = 0
  for value in vec:
    var bits: uint32
    copyMem(addr bits, unsafeAddr value, sizeof(uint32))
    result[pos] = char(bits and 0xff'u32)
    result[pos + 1] = char((bits shr 8) and 0xff'u32)
    result[pos + 2] = char((bits shr 16) and 0xff'u32)
    result[pos + 3] = char((bits shr 24) and 0xff'u32)
    pos += 4

proc bytesVec*(bytes: string, dim: int): seq[float32] =
  ## Decode canonical little-endian IEEE-754 float32 values from the wire.
  doAssert bytes.len == dim * sizeof(float32), "vec bytes length mismatch"
  result = newSeq[float32](dim)
  var pos = 0
  for i in 0 ..< dim:
    let bits =
      uint32(ord(bytes[pos])) or
      (uint32(ord(bytes[pos + 1])) shl 8) or
      (uint32(ord(bytes[pos + 2])) shl 16) or
      (uint32(ord(bytes[pos + 3])) shl 24)
    copyMem(addr result[i], unsafeAddr bits, sizeof(uint32))
    pos += 4

proc splitHeaderLine(line: string): seq[string] =
  let clean = line.strip(chars = {'\r', '\n'})
  if clean.len == 0:
    raise newException(IOError, "接続が切断された")
  if clean.len > MaxWireHeaderBytes:
    raise newException(ValueError, "wire header exceeds max bytes")
  result = clean.splitWhitespace()
  if result.len == 0:
    raise newException(ValueError, "empty wire header")

proc readHeader*(sock: Socket, timeoutMs = 10_000): seq[string] =
  let fd = sock.getFd.int
  if fd notin secureConns:
    let line = sock.recvLine(timeout = timeoutMs)
    if line.len == 0 or line == "\r\n":
      raise newException(IOError, "接続が切断された")
    return splitHeaderLine(line)

  while true:
    var st = secureConns[fd]
    let nl = st.buffer.find('\n')
    if nl >= 0:
      let line = st.buffer[0 ..< nl]
      if nl + 1 == st.buffer.len:
        st.buffer = ""
      else:
        st.buffer = st.buffer[nl + 1 .. ^1]
      secureConns[fd] = st
      return splitHeaderLine(line)
    if st.buffer.len > MaxWireHeaderBytes:
      raise newException(ValueError, "wire header exceeds max bytes")
    secureConns[fd] = st
    sock.readSecureFrame()

# ---------------------------------------------------------------- クライアント

proc expect(r: seq[string], tag, op: string) =
  if r.len == 0 or r[0] != tag:
    raise newException(IOError, op & " failed: " & r.join(" "))

proc socketFor(c: ClusterClient, node: int): Socket =
  if node in c.socks:
    return c.socks[node]
  result = newSocket()
  result.connect(c.peers[node].host, Port(c.peers[node].port))
  result.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)  # short request/response frames dominate
  if c.tls:
    when defined(ssl):
      let verifyMode =
        if c.tlsInsecureSkipVerify:
          CVerifyNone
        elif c.tlsCaFile.len > 0:
          CVerifyPeer
        else:
          CVerifyPeerUseEnvVars
      let ctx = newContext(verifyMode = verifyMode, caFile = c.tlsCaFile)
      let hostname = if c.tlsServerName.len > 0: c.tlsServerName else: c.peers[node].host
      ctx.wrapConnectedSocket(result, handshakeAsClient, hostname)
    else:
      raise newException(IOError, "TLS support requires building KoutenDB with -d:ssl")
  if c.username.len > 0:
    if c.secretKey.len > 0:
      result.sendFrame("AUTHCHAL " & c.username)
      let chal = result.readHeader()
      expect(chal, "CHAL", "AUTHCHAL")
      result.sendFrame("AUTHRESP " &
                       secretResponseHex(c.username, c.password, chal[1],
                                         c.secretKey))
      let r = result.readHeader()
      expect(r, "OK", "AUTHRESP")
      result.enableSecure(c.secretKey, chal[1])
    else:
      result.sendFrame("AUTH " & c.username & " " & c.password)
      let r = result.readHeader()
      expect(r, "OK", "AUTH")
  if c.galaxy.len > 0:
    result.sendFrame("HELLO " & c.galaxy)
    let r = result.readHeader()
    expect(r, "OK", "HELLO")
  c.socks[node] = result

proc ensureCodecMetadata*(c: ClusterClient, node: int) =
  ## Enable codec metadata only for calls that need it. Keeping ordinary
  ## get()/batchGet() on the legacy payload-only response avoids an extra
  ## per-response suffix check on the hottest wire path.
  if c.codecMetadata.getOrDefault(node, false):
    return
  let sock = c.socketFor(node)
  sock.sendFrame("CODECMETA ON")
  let r = sock.readHeader()
  expect(r, "OK", "CODECMETA")
  c.codecMetadata[node] = true

proc rpc(c: ClusterClient, node: int, header: string,
         payload: string = "", timeoutMs = 10_000): seq[string] =
  ## One round trip. Reconnect and retry once after disconnect or timeout.
  for attempt in 0 .. 1:
    let sock = c.socketFor(node)
    try:
      sock.sendFrame(header, payload)
      return sock.readHeader(timeoutMs)
    except IOError, OSError, TimeoutError:
      sock.disableSecure()
      sock.close()
      c.socks.del node
      c.codecMetadata.del node
      if attempt == 1: raise
  @[]

proc putReq*(c: ClusterClient, node: int, ringKey: uint64,
             period, head: float, payload: string,
             vec: seq[float32] = @[], codec = pcRaw): tuple[seq: uint32, tWrite: float] =
  let body =
    if vec.len == 0: payload
    else: payload & vec.vecBytes
  let r = c.rpc(node, "PUT " & $ringKey & " " & $period & " " & $head & " " &
                $payload.len & " " & $vec.len & " " & codec.payloadCodecName, body)
  expect(r, "OK", "PUT")
  (parseUInt(r[1]).uint32, parseFloat(r[2]))

proc putRingReq*(c: ClusterClient, node: int, ring: string, payload: string,
                 vec: seq[float32] = @[], codec = pcRaw): WireId =
  ## Named put for drivers. ringKey/period/head are server-side conventions.
  let body =
    if vec.len == 0: ring & payload
    else: ring & payload & vec.vecBytes
  let r = c.rpc(node, "PUTR " & $ring.len & " " & $payload.len & " " & $vec.len &
                " " & codec.payloadCodecName,
                body)
  expect(r, "ID", "PUTR")
  WireId(parent: parseBiggestUInt(r[1]).uint64,
         epoch: parseUInt(r[2]).uint32,
         seq: parseUInt(r[3]).uint32,
         tWrite: parseFloat(r[4]),
         period: parseFloat(r[5]),
         head: parseFloat(r[6]))

proc getIdReq*(c: ClusterClient, node: int, id: WireId,
               redirectsLeft = 2): WireGetResult =
  c.ensureCodecMetadata(node)
  let r = c.rpc(node, "GETID " & $id.parent & " " & $id.epoch & " " &
                $id.seq & " " & $id.tWrite & " " & $id.period & " " &
                $id.head)
  if r[0] == "MISS":
    return WireGetResult(found: false, node: node)
  if r[0] == "GONE":
    return WireGetResult(found: false, node: node, deleted: true)
  if r[0] == "FWD":
    let forwardedId = WireId(parent: parseBiggestUInt(r[1]).uint64,
                             epoch: parseUInt(r[2]).uint32,
                             seq: parseUInt(r[3]).uint32,
                             tWrite: parseFloat(r[4]),
                             period: parseFloat(r[5]),
                             head: parseFloat(r[6]))
    let targetNode = if r.len >= 8: parseInt(r[7]) else: -1
    if targetNode >= 0 and redirectsLeft > 0:
      return c.getIdReq(targetNode, forwardedId, redirectsLeft - 1)
    return WireGetResult(found: false, node: node, forwarded: true,
                         id: forwardedId, targetNode: targetNode)
  expect(r, "VAL", "GETID")
  WireGetResult(found: true, node: parseInt(r[1]),
                value: c.socks[node].readExact(parseInt(r[2])),
                codec: if r.len >= 4: parsePayloadCodec(r[3]) else: pcRaw)

proc queryIdReq*(c: ClusterClient, node: int, id: WireId,
                 selection: string, redirectsLeft = 2): WireGetResult =
  c.ensureCodecMetadata(node)
  let r = c.rpc(node, "QRYID " & $id.parent & " " & $id.epoch & " " &
                $id.seq & " " & $id.tWrite & " " & $id.period & " " &
                $id.head & " " & $selection.len, selection)
  if r[0] == "MISS":
    return WireGetResult(found: false, node: node)
  if r[0] == "FWD":
    let forwardedId = WireId(parent: parseBiggestUInt(r[1]).uint64,
                             epoch: parseUInt(r[2]).uint32,
                             seq: parseUInt(r[3]).uint32,
                             tWrite: parseFloat(r[4]),
                             period: parseFloat(r[5]),
                             head: parseFloat(r[6]))
    let targetNode = if r.len >= 8: parseInt(r[7]) else: -1
    if targetNode >= 0 and redirectsLeft > 0:
      return c.queryIdReq(targetNode, forwardedId, selection,
                          redirectsLeft - 1)
    return WireGetResult(found: false, node: node, forwarded: true,
                         id: forwardedId, targetNode: targetNode)
  if r[0] == "ERR":
    raise newException(ValueError, "query: " & r[1 .. ^1].join(" "))
  expect(r, "VAL", "QRYID")
  WireGetResult(found: true, node: parseInt(r[1]),
                value: c.socks[node].readExact(parseInt(r[2])), codec: pcJson)

proc txGetIdReq*(c: ClusterClient, node: int, id: WireId,
                 selection: string = ""): WireGetResult =
  ## Read committed cluster transaction intent from the landing zone.
  ## Used as read-your-writes fallback before asynchronous owner apply.
  if selection.len == 0:
    c.ensureCodecMetadata(node)
  let op = if selection.len == 0: "TXGETID" else: "TXQRYID"
  let header = op & " " & $id.parent & " " & $id.epoch & " " &
               $id.seq & " " & $id.tWrite & " " & $id.period & " " &
               $id.head & (if selection.len == 0: "" else: " " & $selection.len)
  let r = c.rpc(node, header, selection)
  if r[0] == "MISS":
    return WireGetResult(found: false, node: node)
  if r[0] == "GONE":
    return WireGetResult(found: false, node: node, deleted: true)
  if r[0] == "ERR":
    raise newException(ValueError, "tx-get: " & r[1 .. ^1].join(" "))
  expect(r, "VAL", op)
  WireGetResult(found: true, node: parseInt(r[1]),
                value: c.socks[node].readExact(parseInt(r[2])),
                codec: if selection.len > 0: pcJson
                       elif r.len >= 4: parsePayloadCodec(r[3])
                       else: pcRaw)

proc getReq*(c: ClusterClient, node: int, parent: uint64, seq: uint32,
             period, head, tWrite: float): tuple[found: bool, node: int, value: string,
                                                  codec: PayloadCodec,
                                                  forwarded: bool, newParent: uint64,
                                                  newSeq: uint32, newTWrite: float,
                                                  targetNode: int] =
  c.ensureCodecMetadata(node)
  let r = c.rpc(node, "GET " & $parent & " " & $seq & " " & $period & " " &
                $head & " " & $tWrite)
  if r[0] == "MISS": return (false, node, "", pcRaw, false, 0'u64, 0'u32, 0.0, -1)
  if r[0] == "FWD":
    return (false, node, "", pcRaw, true, parseBiggestUInt(r[1]).uint64,
            parseUInt(r[2]).uint32, parseFloat(r[3]),
            if r.len >= 5: parseInt(r[4]) else: -1)
  expect(r, "VAL", "GET")
  (true, parseInt(r[1]), c.socks[node].readExact(parseInt(r[2])),
   (if r.len >= 4: parsePayloadCodec(r[3]) else: pcRaw),
   false, 0'u64, 0'u32, 0.0, -1)

proc getValueReq*(c: ClusterClient, node: int, parent: uint64, seq: uint32,
                  period, head, tWrite: float): tuple[found: bool, node: int,
                                                       value: string,
                                                       forwarded: bool,
                                                       newParent: uint64,
                                                       newSeq: uint32,
                                                       newTWrite: float,
                                                       targetNode: int] =
  ## Hot path for ordinary get(). It intentionally ignores optional codec
  ## metadata because callers only need the payload bytes.
  let r = c.rpc(node, "GET " & $parent & " " & $seq & " " & $period & " " &
                $head & " " & $tWrite)
  if r[0] == "MISS":
    return (false, node, "", false, 0'u64, 0'u32, 0.0, -1)
  if r[0] == "FWD":
    return (false, node, "", true, parseBiggestUInt(r[1]).uint64,
            parseUInt(r[2]).uint32, parseFloat(r[3]),
            if r.len >= 5: parseInt(r[4]) else: -1)
  expect(r, "VAL", "GET")
  (true, parseInt(r[1]), c.socks[node].readExact(parseInt(r[2])),
   false, 0'u64, 0'u32, 0.0, -1)

proc batchGetReq*(c: ClusterClient, node: int,
                  ids: seq[tuple[parent: uint64, seq: uint32, period: float,
                                 head: float, tWrite: float]]): seq[string] =
  var body = ""
  for id in ids:
    body.add($id.parent & " " & $id.seq & " " & $id.period & " " &
             $id.head & " " & $id.tWrite & "\n")
  let r = c.rpc(node, "BGET " & $ids.len & " " & $body.len, body)
  expect(r, "BVAL", "BGET")
  let n = parseInt(r[1])
  let payloadLen = parseInt(r[2])
  let payloads = c.socks[node].readExact(payloadLen)
  var pos = 0
  for _ in 0 ..< n:
    let nl = payloads.find('\n', pos)
    doAssert nl >= 0, "BGET payload length header missing"
    let len = parseInt(payloads[pos ..< nl])
    pos = nl + 1
    result.add payloads[pos ..< pos + len]
    pos += len

proc listRingReq*(c: ClusterClient, node: int, ringKey: uint64, limit: int,
                  cursor: string = ""): WireListResult =
  c.ensureCodecMetadata(node)
  let r = c.rpc(node, "LISTR " & $ringKey & " " & $limit & " " & $cursor.len,
                cursor)
  expect(r, "LVAL", "LISTR")
  let n = parseInt(r[1])
  result.nextCursor = if r[2] == "_": "" else: r[2]
  for _ in 0 ..< n:
    let h = c.socks[node].readHeader()
    doAssert h[0] == "ITEM", "LISTR item failed: " & h.join(" ")
    let payload = c.socks[node].readExact(parseInt(h[4]))
    result.items.add WireListItem(parent: ringKey,
                                  seq: parseUInt(h[1]).uint32,
                                  tWrite: parseFloat(h[2]),
                                  payload: payload,
                                  codec: if h.len >= 6: parsePayloadCodec(h[5]) else: pcRaw)

proc countRingReq*(c: ClusterClient, node: int, ringKey: uint64): int =
  let r = c.rpc(node, "COUNTR " & $ringKey)
  expect(r, "COUNT", "COUNTR")
  parseInt(r[1])

proc queryReq*(c: ClusterClient, node: int, parent: uint64, seq: uint32,
               period, head, tWrite: float,
               selection: string): tuple[found: bool, node: int, value: string,
                                          codec: PayloadCodec,
                                          forwarded: bool, newParent: uint64,
                                          newSeq: uint32, newTWrite: float,
                                          targetNode: int] =
  let r = c.rpc(node, "QRY " & $parent & " " & $seq & " " & $period & " " &
                $head & " " & $tWrite & " " & $selection.len, selection)
  if r[0] == "MISS": return (false, node, "", pcJson, false, 0'u64, 0'u32, 0.0, -1)
  if r[0] == "FWD":
    return (false, node, "", pcJson, true, parseBiggestUInt(r[1]).uint64,
            parseUInt(r[2]).uint32, parseFloat(r[3]),
            if r.len >= 5: parseInt(r[4]) else: -1)
  if r[0] == "ERR":
    raise newException(ValueError, "query: " & r[1 .. ^1].join(" "))
  expect(r, "VAL", "QRY")
  (true, parseInt(r[1]), c.socks[node].readExact(parseInt(r[2])), pcJson,
   false, 0'u64, 0'u32, 0.0, -1)

proc transferStatusReq*(c: ClusterClient, node: int, parent: uint64,
                        seq: uint32, period, head, tWrite: float,
                        payload: string, vec: seq[float32] = @[],
                        codec = pcRaw,
                        version = MutationVersion(),
                        timeoutMs = 10_000,
                        expectedPlacementEpoch = 0'u32,
                        expectedPlacementNodes = 0'u16,
                        expectedVirtualArcs = 0): string =
  ## Inter-node handoff. koutend is single-threaded, so callers should pass a
  ## short timeoutMs to avoid long blocking during mutual transfer.
  let body =
    if vec.len == 0: payload
    else: payload & vec.vecBytes
  let placementFence =
    if expectedPlacementEpoch == 0 and expectedPlacementNodes == 0 and
        expectedVirtualArcs == 0:
      ""
    elif expectedPlacementEpoch > 0 and expectedPlacementNodes > 0 and
        expectedVirtualArcs > 0:
      " " & $expectedPlacementEpoch & " " & $expectedPlacementNodes & " " &
        $expectedVirtualArcs
    else:
      raise newException(ValueError,
        "TRF placement fence must be entirely specified or omitted")
  let r = c.rpc(node, "TRF " & $parent & " " & $seq & " " & $period & " " &
                $head & " " & $tWrite & " " & $payload.len & " " & $vec.len &
                " " & codec.payloadCodecName & " " &
                version.mutationVersionFields & placementFence, body,
                timeoutMs = timeoutMs)
  expect(r, "OK", "TRF")
  if r.len != 2 or r[1] notin ["APPLIED", "SKIPPED"]:
    raise newException(IOError,
      "TRF returned an invalid acknowledgement")
  r[1]

proc transferReq*(c: ClusterClient, node: int, parent: uint64, seq: uint32,
                  period, head, tWrite: float, payload: string,
                  vec: seq[float32] = @[],
                  codec = pcRaw,
                  version = MutationVersion(),
                  timeoutMs = 10_000,
                  expectedPlacementEpoch = 0'u32,
                  expectedPlacementNodes = 0'u16,
                  expectedVirtualArcs = 0) =
  discard c.transferStatusReq(
    node, parent, seq, period, head, tWrite, payload, vec, codec, version,
    timeoutMs, expectedPlacementEpoch, expectedPlacementNodes,
    expectedVirtualArcs)

proc transferDeleteStatusReq*(c: ClusterClient, node: int, parent: uint64,
                              seq: uint32, period, head, tWrite: float,
                              version: MutationVersion,
                              acknowledgedNodes: seq[uint16] = @[],
                              reclaimAfter = 0.0,
                              timeoutMs = 10_000,
                              expectedPlacementEpoch = 0'u32,
                              expectedPlacementNodes = 0'u16,
                              expectedVirtualArcs = 0): string =
  let placementFence =
    if expectedPlacementEpoch == 0 and expectedPlacementNodes == 0 and
        expectedVirtualArcs == 0:
      ""
    elif expectedPlacementEpoch > 0 and expectedPlacementNodes > 0 and
        expectedVirtualArcs > 0:
      " " & $expectedPlacementEpoch & " " & $expectedPlacementNodes & " " &
        $expectedVirtualArcs
    else:
      raise newException(ValueError,
        "TRFD placement fence must be entirely specified or omitted")
  let r = c.rpc(node, "TRFD " & $parent & " " & $seq & " " & $period & " " &
                $head & " " & $tWrite & " " &
                version.mutationVersionFields & " " &
                acknowledgedNodes.acknowledgedNodesField & " " &
                $reclaimAfter & placementFence, timeoutMs = timeoutMs)
  expect(r, "OK", "TRFD")
  if r.len != 2 or r[1] notin ["APPLIED", "SKIPPED"]:
    raise newException(IOError,
      "TRFD returned an invalid acknowledgement")
  r[1]

proc transferDeleteReq*(c: ClusterClient, node: int, parent: uint64,
                        seq: uint32, period, head, tWrite: float,
                        version: MutationVersion,
                        acknowledgedNodes: seq[uint16] = @[],
                        reclaimAfter = 0.0,
                        timeoutMs = 10_000,
                        expectedPlacementEpoch = 0'u32,
                        expectedPlacementNodes = 0'u16,
                        expectedVirtualArcs = 0) =
  discard c.transferDeleteStatusReq(
    node, parent, seq, period, head, tWrite, version, acknowledgedNodes,
    reclaimAfter, timeoutMs, expectedPlacementEpoch, expectedPlacementNodes,
    expectedVirtualArcs)

proc txBeginReq*(c: ClusterClient, node = 0): uint64 =
  let r = c.rpc(node, "TXBEGIN")
  expect(r, "OK", "TXBEGIN")
  parseBiggestUInt(r[1]).uint64

proc txReserveReq*(c: ClusterClient, node: int, txid, ringKey: uint64,
                   period, head: float): tuple[seq: uint32, tWrite: float] =
  let r = c.rpc(node, "TXRESERVE " & $txid & " " & $ringKey & " " &
                $period & " " & $head)
  expect(r, "OK", "TXRESERVE")
  (parseUInt(r[1]).uint32, parseFloat(r[2]))

proc txCommitReq*(c: ClusterClient, node: int, txid: uint64, ops: seq[TxWireOp]) =
  var body = ""
  for op in ops:
    body.add((if op.delete: "D " else: "P ") & $op.parent & " " & $op.seq &
             " " & $op.period & " " & $op.head & " " & $op.tWrite & " " &
             $op.payload.len & " " & $op.vec.len & " " &
             op.codec.payloadCodecName)
    if not op.version.isZero:
      body.add " " & op.version.mutationVersionFields
    body.add "\n"
    body.add(op.payload)
    if op.vec.len > 0:
      body.add(op.vec.vecBytes)
    body.add("\n")
  let r = c.rpc(node, "TXCOMMIT " & $txid & " " & $ops.len, body)
  expect(r, "OK", "TXCOMMIT")

proc txStatusReq*(c: ClusterClient, node: int, txid: uint64): string =
  let r = c.rpc(node, "TXSTATUS " & $txid)
  expect(r, "OK", "TXSTATUS")
  r[1]

proc universeApplyReq*(c: ClusterClient, node: int, eventJson: string): string =
  let r = c.rpc(node, "UAPPLY " & $eventJson.len, eventJson)
  expect(r, "UOK", "UAPPLY")
  if r[1] != "APPLIED" and r[1] != "SKIPPED" and r[1] != "DELAYED":
    raise newException(IOError, "UAPPLY returned invalid status: " & r[1])
  r[1]

proc universeStatusReq*(c: ClusterClient, node: int): UniverseWireStatus =
  let r = c.rpc(node, "USTATUS")
  expect(r, "USTATUS", "USTATUS")
  result.pending = parseInt(r[1])
  result.applied = parseInt(r[2])
  if r.len > 3:
    result.appliedOps = parseInt(r[3])
  if r.len > 4:
    result.skippedOps = parseInt(r[4])
  if r.len > 5:
    result.errors = parseInt(r[5])
  if r.len > 6:
    result.forwarded = parseInt(r[6])
  if r.len > 7:
    result.lastOk = parseInt(r[7])
  if r.len > 8:
    result.lastError = parseInt(r[8])

proc applyTxReq*(c: ClusterClient, node: int, txid: uint64, op: TxWireOp,
                 timeoutMs = 10_000) =
  let body =
    if op.vec.len == 0: op.payload
    else: op.payload & op.vec.vecBytes
  let kind = if op.delete: "D" else: "P"
  let r = c.rpc(node, "APPLYTX " & $txid & " " & kind & " " & $op.parent & " " & $op.seq & " " &
                $op.period & " " & $op.head & " " & $op.tWrite & " " &
                $op.payload.len & " " & $op.vec.len & " " &
                op.codec.payloadCodecName & " " &
                op.version.mutationVersionFields, body, timeoutMs = timeoutMs)
  expect(r, "OK", "APPLYTX")

proc retrieveReq*(c: ClusterClient, node: int, hasRing: bool, ringKey: uint64,
                  queryVec: seq[float32], budget: int): RetrieveWireResult =
  c.ensureCodecMetadata(node)
  let body = queryVec.vecBytes
  let r = c.rpc(node, "RETRIEVE " & (if hasRing: "1" else: "0") & " " &
                $ringKey & " " & $budget & " " & $queryVec.len, body)
  expect(r, "RHIT", "RETRIEVE")
  result.scanned = parseInt(r[1])
  result.ringsTouched = parseInt(r[2])
  let n = parseInt(r[3])
  if r.len >= 6:
    result.totalVectors = parseInt(r[4])
    result.payloadBytes = parseInt(r[5])
  else:
    result.totalVectors = result.scanned
  for _ in 0 ..< n:
    let h = c.socks[node].readHeader()
    doAssert h[0] == "HIT", "RETRIEVE HIT failed: " & h.join(" ")
    result.hits.add RetrieveWireHit(parent: parseBiggestUInt(h[1]).uint64,
                                    seq: parseUInt(h[2]).uint32,
                                    tWrite: parseFloat(h[3]),
                                    score: parseFloat(h[4]),
                                    payload: c.socks[node].readExact(parseInt(h[5])),
                                    codec: if h.len >= 7: parsePayloadCodec(h[6]) else: pcRaw)
  result.skippedVectors = max(0, result.totalVectors - result.scanned)
  if result.payloadBytes == 0:
    for h in result.hits:
      result.payloadBytes += h.payload.len
  result.estimatedTokens = (result.payloadBytes + 3) div 4

proc ringsReq*(c: ClusterClient, node: int): seq[RingSummary] =
  let r = c.rpc(node, "RINGS")
  expect(r, "RINGS", "RINGS")
  let n = parseInt(r[1])
  for _ in 0 ..< n:
    let h = c.socks[node].readHeader()
    doAssert h[0] == "RING", "RING failed: " & h.join(" ")
    let dim = parseInt(h[3])
    result.add RingSummary(ringKey: parseBiggestUInt(h[1]).uint64,
                           count: parseInt(h[2]),
                           centroid: c.socks[node].readExact(dim * sizeof(float32)).bytesVec(dim))

proc statsReq*(c: ClusterClient, node: int): tuple[node, count: int] =
  let r = c.rpc(node, "STATS")
  expect(r, "OK", "STATS")
  (parseInt(r[1]), parseInt(r[2]))

proc healthReq*(c: ClusterClient, node: int): string =
  let r = c.rpc(node, "HEALTH")
  expect(r, "OK", "HEALTH")
  r[1 .. ^1].join(" ")

proc metricsReq*(c: ClusterClient, node: int): string =
  let r = c.rpc(node, "METRICS")
  expect(r, "OK", "METRICS")
  r[1 .. ^1].join(" ")

proc drainReq*(c: ClusterClient, node: int): string =
  let r = c.rpc(node, "DRAIN")
  expect(r, "OK", "DRAIN")
  r[1 .. ^1].join(" ")

proc resumeReq*(c: ClusterClient, node: int): string =
  let r = c.rpc(node, "RESUME")
  expect(r, "OK", "RESUME")
  r[1 .. ^1].join(" ")

proc snapshotReq*(c: ClusterClient, node: int): string =
  let r = c.rpc(node, "SNAPSHOT")
  expect(r, "SNAPSHOT", "SNAPSHOT")
  r[1 .. ^1].join(" ")

proc wireVersionReq*(c: ClusterClient, node: int): int =
  let r = c.rpc(node, "WIREVER")
  expect(r, "WIREVER", "WIREVER")
  parseInt(r[1])

proc topologyReq*(c: ClusterClient, node: int): ArcTable =
  let r = c.rpc(node, "TOPOLOGY")
  expect(r, "TOPOLOGY", "TOPOLOGY")
  if r.len != 4:
    raise newException(IOError, "TOPOLOGY returned an invalid response")
  let epoch = parseUInt(r[1])
  let nNodes = parseUInt(r[2])
  let virtualArcs = parseInt(r[3])
  if epoch == 0 or epoch > uint32.high.uint64 or
      nNodes == 0 or nNodes > uint16.high.uint64 or virtualArcs <= 0:
    raise newException(IOError, "TOPOLOGY returned invalid values")
  virtualArcTable(uint32(epoch), uint16(nNodes), virtualArcs)

proc migrationVerifyReq*(c: ClusterClient, node: int, parent: uint64,
                         seq: uint32, version: MutationVersion,
                         deleted: bool): tuple[ahead: bool, deleted: bool] =
  version.validateMutationVersion()
  if version.isZero:
    raise newException(ValueError,
      "migration verification requires a non-zero mutation version")
  let r = c.rpc(node, "MIGVERIFY " & $parent & " " & $seq & " " &
                version.mutationVersionFields & " " &
                $(if deleted: 1 else: 0))
  expect(r, "MIGRATION", "MIGVERIFY")
  if r.len != 3 or r[1] notin ["MATCH", "AHEAD"] or
      r[2] notin ["LIVE", "DELETED"]:
    raise newException(IOError,
      "MIGVERIFY returned an invalid response: " & r.join(" "))
  (ahead: r[1] == "AHEAD", deleted: r[2] == "DELETED")

proc migrationMetadataReq*(c: ClusterClient, node: int, metadataJson: string,
                           expectedPlacementEpoch: uint32,
                           expectedPlacementNodes: uint16,
                           expectedVirtualArcs: int) =
  if metadataJson.len == 0:
    raise newException(ValueError, "migration metadata is empty")
  if expectedPlacementEpoch == 0 or expectedPlacementNodes == 0 or
      expectedVirtualArcs <= 0:
    raise newException(ValueError,
      "migration metadata requires a complete topology fence")
  let r = c.rpc(node, "MIGMETA " & $expectedPlacementEpoch & " " &
                $expectedPlacementNodes & " " & $expectedVirtualArcs & " " &
                $metadataJson.len, metadataJson)
  expect(r, "OK", "MIGMETA")
  if r.len != 2 or r[1] != "APPLIED":
    raise newException(IOError,
      "MIGMETA returned an invalid acknowledgement")

proc migrationMetadataVerifyReq*(
    c: ClusterClient, node: int, metadataJson: string,
    expectedPlacementEpoch: uint32, expectedPlacementNodes: uint16,
    expectedVirtualArcs: int) =
  if metadataJson.len == 0:
    raise newException(ValueError, "migration metadata is empty")
  if expectedPlacementEpoch == 0 or expectedPlacementNodes == 0 or
      expectedVirtualArcs <= 0:
    raise newException(ValueError,
      "migration metadata verification requires a complete topology fence")
  let r = c.rpc(node, "MIGMETAVERIFY " & $expectedPlacementEpoch & " " &
                $expectedPlacementNodes & " " & $expectedVirtualArcs & " " &
                $metadataJson.len, metadataJson)
  expect(r, "MIGRATION", "MIGMETAVERIFY")
  if r.len != 2 or r[1] != "MATCH":
    raise newException(IOError,
      "MIGMETAVERIFY returned an invalid response")

proc codecsReq*(c: ClusterClient, node: int): seq[PayloadCodec] =
  let r = c.rpc(node, "CODECS")
  expect(r, "CODECS", "CODECS")
  for i in 1 ..< r.len:
    result.add parsePayloadCodec(r[i])

proc shutdownReq*(c: ClusterClient, node: int): string =
  let r = c.rpc(node, "SHUTDOWN")
  expect(r, "OK", "SHUTDOWN")
  r[1 .. ^1].join(" ")
