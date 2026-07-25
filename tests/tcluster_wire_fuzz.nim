## Deterministic wire-protocol robustness smoke.
##
## This is not coverage-guided fuzzing. It is a regression matrix for malformed
## frames that previously could block or escape the connection boundary.

import std/[net, os, strutils, unittest]
import ../src/kouten/payload
import ../src/kouten/wire

type FuzzCase = object
  name: string
  header: string
  payload: string
  closeAfterSend: bool

proc authSocket(peer: Peer): Socket =
  result = newSocket()
  result.connect(peer.host, Port(peer.port))
  result.sendFrame("AUTH alice secret")
  let r = result.readHeader(timeoutMs = 1_000)
  check r[0] == "OK"

proc tryReadResponse(sock: Socket) =
  try:
    discard sock.readHeader(timeoutMs = 500)
  except CatchableError:
    discard

proc checkAlive(peers: seq[Peer], label: string) =
  var c = newClusterClient(peers, username = "alice", password = "secret")
  check c.wireVersionReq(0) == WireProtocolVersion
  let h = c.healthReq(0)
  check h.contains("node=0")
  let id = c.putRingReq(0, "allowed/fuzz/" & label, "ok-" & label, @[])
  let got = c.getIdReq(0, id)
  check got.found
  check got.value == "ok-" & label
  c.close()

suite "cluster wire fuzz":
  test "malformed frames close only the offending connection":
    let peers = getEnv("KOUTEN_TEST_PEERS",
      "127.0.0.1:17711,127.0.0.1:17712,127.0.0.1:17713")
    let ps = parsePeers(peers)
    let deepJson = repeat("{\"x\":", 140) & "\"v\"" & repeat("}", 140)

    let cases = @[
      FuzzCase(name: "short-putr", header: "PUTR"),
      FuzzCase(name: "huge-ring", header: "PUTR 999999999 0 0"),
      FuzzCase(name: "negative-ring", header: "PUTR -1 0 0"),
      FuzzCase(name: "huge-payload", header: "PUTR 7 999999999 0",
               payload: "allowed"),
      FuzzCase(name: "huge-vector", header: "PUTR 7 0 999999999",
               payload: "allowed"),
      FuzzCase(name: "unknown-codec", header: "PUTR 7 0 0 executable",
               payload: "allowed"),
      FuzzCase(name: "short-put", header: "PUT"),
      FuzzCase(name: "huge-put-payload", header: "PUT 1 60 0 999999999 0"),
      FuzzCase(name: "negative-put-payload", header: "PUT 1 60 0 -1 0"),
      FuzzCase(name: "short-get", header: "GET"),
      FuzzCase(name: "bad-number", header: "GET not-a-number"),
      FuzzCase(name: "huge-header",
               header: "GET " & repeat("9", MaxWireHeaderBytes + 1)),
      FuzzCase(name: "huge-query-selection",
               header: "QRY 1 0 60 0 1 999999999"),
      FuzzCase(name: "huge-bget", header: "BGET 1 999999999"),
      FuzzCase(name: "negative-bget", header: "BGET 1 -1"),
      FuzzCase(name: "huge-retrieve-vector",
               header: "RETRIEVE 1 1 3 999999999"),
      FuzzCase(name: "short-uapply", header: "UAPPLY"),
      FuzzCase(name: "huge-uapply", header: "UAPPLY 999999999"),
      FuzzCase(name: "bad-uapply-json", header: "UAPPLY 8",
               payload: "not-json"),
      FuzzCase(name: "deep-uapply-json", header: "UAPPLY " & $deepJson.len,
               payload: deepJson),
      FuzzCase(name: "short-applytx", header: "APPLYTX"),
      FuzzCase(name: "short-trf", header: "TRF"),
      FuzzCase(name: "negative-trf-version",
               header: "TRF 1 0 60 0 1 0 0 raw -1 0 1"),
      FuzzCase(name: "zero-physical-trf-version",
               header: "TRF 1 0 60 0 1 0 0 raw 0 1 1"),
      FuzzCase(name: "oversized-trf-logical-version",
               header: "TRF 1 0 60 0 1 0 0 raw 1 4294967296 1"),
      FuzzCase(name: "oversized-trf-origin-version",
               header: "TRF 1 0 60 0 1 0 0 raw 1 0 4294967296"),
      FuzzCase(name: "short-trfd", header: "TRFD"),
      FuzzCase(name: "negative-trfd-version",
               header: "TRFD 1 0 60 0 1 -1 0 1"),
      FuzzCase(name: "zero-physical-trfd-version",
               header: "TRFD 1 0 60 0 1 0 1 1"),
      FuzzCase(name: "malformed-trfd-ack-set",
               header: "TRFD 1 0 60 0 1 1 0 1 0,,2 0"),
      FuzzCase(name: "oversized-trfd-ack-node",
               header: "TRFD 1 0 60 0 1 1 0 1 65536 0"),
      FuzzCase(name: "negative-trfd-reclaim-deadline",
               header: "TRFD 1 0 60 0 1 1 0 1 0 -1"),
      FuzzCase(name: "nan-trfd-reclaim-deadline",
               header: "TRFD 1 0 60 0 1 1 0 1 0 nan"),
      FuzzCase(name: "unknown-command", header: "WHAT_IS_THIS 1 2 3"),
      FuzzCase(name: "bad-codec-negotiation", header: "CODECMETA MAYBE"),
      FuzzCase(name: "truncated-txcommit", header: "TXCOMMIT 1 1",
               closeAfterSend: true)
    ]

    for tc in cases:
      var s = authSocket(ps[0])
      s.send(tc.header & "\n" & tc.payload)
      if not tc.closeAfterSend:
        s.tryReadResponse()
      s.close()
      checkAlive(ps, tc.name)

    var bad = authSocket(ps[0])
    bad.send("GET not-a-number\n")
    let badResp = bad.readHeader(timeoutMs = 1_000)
    check badResp == @["ERR", "bad-request"]
    bad.close()
    checkAlive(ps, "stable-error-category")

    var c = newClusterClient(ps, username = "alice", password = "secret")
    let id = c.putRingReq(0, "allowed/fuzz/selection-limit",
                          """{"title":"ok"}""", @[], pcJson)
    let hugeSelection = repeat("a", 64 * 1024 + 1)
    var rejected = false
    for node in 0 ..< ps.len:
      try:
        discard c.queryReq(node, id.parent, id.seq, id.period, id.head,
                           id.tWrite, hugeSelection)
      except ValueError:
        rejected = true
        break
    check rejected

    for i in 0 ..< 5:
      discard c.putRingReq(0, "allowed/fuzz/retrieve-cost/" & $i,
                           "cost-" & $i, @[1.0'f32, float32(i) / 10.0])
    expect IOError:
      discard c.retrieveReq(0, false, 0'u64, @[1.0'f32, 0.0'f32], 2)
    c.close()
    checkAlive(ps, "retrieve-cost-limit")
