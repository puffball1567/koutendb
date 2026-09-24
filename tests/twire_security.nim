import std/[net, os, strutils, unittest]
import ../src/kouten/wire
import ../src/kouten/payload

if paramCount() == 0:
  suite "wire header input boundaries":
    let peers = parsePeers("127.0.0.1:17301")
    test "connection tokens reject delimiters without echoing secrets":
      for bad in ["a\nb", "a\rb", "a b", "a\tb", "a\0b", "a\x7fb",
                  repeat("x", MaxWireHeaderBytes)]:
        for field in ["username", "password", "token", "galaxy"]:
          var rejected = false
          try:
            case field
            of "username": discard newClusterClient(peers, username = bad)
            of "password": discard newClusterClient(peers, password = bad)
            of "token": discard newClusterClient(peers, authToken = bad)
            else: discard newClusterClient(peers, galaxy = bad)
          except ValueError as error:
            rejected = true
            check bad notin error.msg
          check rejected
    test "encrypted passwords do not become header tokens":
      let client = newClusterClient(peers, username = "alice",
        password = "password with spaces\n", secretKey = "key")
      client.close()
    test "ordinary punctuation remains valid":
      let client = newClusterClient(peers, username = "alice@example.test",
        password = "a:b/c=+!", galaxy = "docs-v1")
      client.close()
    test "sendFrame rejects header injection before writing":
      let sock = newSocket()
      defer: sock.close()
      for bad in ["HEALTH\nSHUTDOWN", "HEALTH\rSHUTDOWN", "HEALTH\0",
                  repeat("x", MaxWireHeaderBytes + 1)]:
        expect ValueError:
          sock.sendFrame(bad)
else:
  let mode = paramStr(1)
  let peers = parsePeers(paramStr(2))
  let client = newClusterClient(peers,
    username = if mode == "auth-fds": "alice" else: "",
    password = if mode == "auth-fds": "test-secret" else: "")
  defer: client.close()
  case mode
  of "write":
    var rejected = false
    try:
      discard client.putRingReq(0, "security/test", "test-value")
    except IndeterminateWriteError:
      rejected = true
    doAssert rejected, "lost write acknowledgement must not be replayed"
  of "read":
    doAssert client.healthReq(0) == "healthy"
  of "read-fail":
    var rejected = false
    try:
      discard client.healthReq(0)
    except IOError:
      rejected = true
    doAssert rejected
  of "idempotent-control":
    doAssert client.coordinatorResumeReq(0, 7).contains("active")
  of "bad-list", "bad-rings", "bad-retrieve", "bad-batch":
    var rejected = false
    try:
      case mode
      of "bad-list": discard client.listRingReq(0, 1, 2)
      of "bad-rings": discard client.ringsReq(0)
      of "bad-retrieve": discard client.retrieveReq(0, true, 1, @[1.0'f32], 2)
      else:
        discard client.batchGetReq(0, @[(parent: 1'u64, seq: 0'u32,
          period: 60.0, head: 0.0, tWrite: 1.0)])
    except IOError:
      rejected = true
    doAssert rejected
    doAssert client.healthReq(0) == "healthy"
  of "codec-retry":
    for i in 0 .. 1:
      let page = client.listRingReq(0, 1, 1)
      doAssert page.items.len == 1
      doAssert page.items[0].codec == pcBif
      doAssert page.items[0].payload == "x"
      client.close()
  of "auth-fds":
    proc fdCount(): int =
      for entry in walkDir("/proc/self/fd"):
        inc result
    let before = fdCount()
    for i in 0 ..< 40:
      var rejected = false
      try:
        discard client.healthReq(0)
      except IOError:
        rejected = true
      doAssert rejected
    doAssert fdCount() <= before + 1, "failed authentication leaked sockets"
  else:
    raise newException(ValueError, "unknown test mode")
