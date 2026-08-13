## Multi-process server concurrency and backpressure helper.

import std/[hashes, monotimes, net, os, parseopt, sets, strformat, strutils,
            times]
import ../src/koutendb
import ../src/kouten/wire

const
  SharedRing = "pressure/shared"
  LargeRing = "pressure/large"
  TestConnectionLimit = 8

proc require(condition: bool; message: string) =
  if not condition:
    raise newException(ValueError, message)

proc ringKey(name: string): uint64 =
  uint64(hash(name)) or 1'u64

proc metricValue(metrics, key: string): int64 =
  let fields = metrics.splitWhitespace()
  var i = 0
  while i + 1 < fields.len:
    if fields[i] == key:
      return parseBiggestInt(fields[i + 1]).int64
    inc i, 2
  raise newException(KeyError, "metric is missing: " & key)

proc runWriter(peers: string; worker, count: int) =
  var db = connect(peers)
  db.configureWriteAckMode(wamApplied)
  var ids: seq[KoutenId] = @[]
  for i in 0 ..< count:
    ids.add db.put(&"initial-{worker}-{i}", ring = SharedRing)
  for i, id in ids:
    db.update(id, &"final-{worker}-{i}")
  if ids.len > 0:
    echo &"writer={worker} firstId={ids[0]} lastId={ids[^1]} count={ids.len}"
  db.close()

proc runReader(peers: string; loops: int) =
  var db = connect(peers)
  var previousCount = 0
  for _ in 0 ..< loops:
    let currentCount = db.countByRing(SharedRing)
    require(currentCount >= previousCount,
            "live count regressed while only put/update traffic was active")
    previousCount = currentCount
    let page = db.listByRing(SharedRing, limit = 32)
    var ids = initHashSet[string]()
    for item in page.items:
      require($item.id notin ids, "reader observed a duplicate record")
      ids.incl $item.id
    sleep(2)
  db.close()

proc runObserver(peers: string; loops: int) =
  let ps = parsePeers(peers)
  var client = newClusterClient(ps)
  for _ in 0 ..< loops:
    let metrics = client.metricsReq(0)
    require(metrics.metricValue("activeConnections") >= 1,
            "metrics reported no active observer connection")
    let snapshot = client.snapshotReq(0)
    require(snapshot.contains("pendingTx"),
            "snapshot barrier omitted transaction state")
    sleep(3)
  client.close()

proc runHealth(peers: string) =
  var client = newClusterClient(parsePeers(peers))
  require(client.healthReq(0).contains("node=0"), "health check failed")
  client.close()

proc runAdmission(peers: string) =
  let peer = parsePeers(peers)[0]
  var held: seq[Socket] = @[]
  for _ in 0 ..< TestConnectionLimit:
    let sock = newSocket()
    sock.connect(peer.host, Port(peer.port))
    held.add sock
    sleep(20)

  var rejected = newSocket()
  rejected.connect(peer.host, Port(peer.port))
  let response = rejected.readHeader(timeoutMs = 2_000)
  require(response == @["ERR", "overloaded"],
          "connection pressure did not return ERR overloaded")
  rejected.close()
  for sock in held.mitems:
    sock.close()
  sleep(300)

  var client = newClusterClient(parsePeers(peers))
  require(client.healthReq(0).contains("node=0"),
          "server did not accept a connection after pressure was released")
  let metrics = client.metricsReq(0)
  require(metrics.metricValue("connectionsRejected") >= 1,
          "connection rejection metric did not advance")
  client.close()

proc runSlowInput(peers: string) =
  let peer = parsePeers(peers)[0]
  var slow = newSocket()
  slow.connect(peer.host, Port(peer.port))
  slow.send("PUTR 13 1024 0 raw\npressure/slowx")
  sleep(50)

  let started = getMonoTime()
  runHealth(peers)
  let elapsedMs = (getMonoTime() - started).inMilliseconds
  require(elapsedMs < 2_000,
          "partial request blocked unrelated health traffic for " &
            $elapsedMs & "ms")
  slow.close()

proc seedLargeResponses(peers: string) =
  var db = connect(peers)
  let payload = repeat("x", 1024 * 1024)
  for i in 0 ..< 16:
    discard db.put(payload & $i, ring = LargeRing)
  db.close()

proc runSlowOutput(peers: string) =
  seedLargeResponses(peers)
  let peer = parsePeers(peers)[0]
  var slow = newSocket()
  slow.connect(peer.host, Port(peer.port))
  slow.send("LISTR " & $ringKey(LargeRing) & " 32 0\n")
  sleep(50)

  let started = getMonoTime()
  runHealth(peers)
  let elapsedMs = (getMonoTime() - started).inMilliseconds
  require(elapsedMs < 2_000,
          "non-reading client blocked unrelated health traffic for " &
            $elapsedMs & "ms")
  slow.close()

proc runListLimit(peers: string) =
  let peer = parsePeers(peers)[0]
  var sock = newSocket()
  sock.connect(peer.host, Port(peer.port))
  sock.send("LISTR " & $ringKey(SharedRing) & " 33 0\n")
  let response = sock.readHeader(timeoutMs = 2_000)
  require(response == @["ERR", "bad-request"],
          "oversized LISTR did not fail with a stable bad-request")
  sock.close()
  runHealth(peers)

proc verifyRecords(db: KoutenDb; writers, count: int) =
  let expected = writers * count
  let actual = db.countByRing(SharedRing)
  require(actual == expected,
          &"final shared-ring count mismatch ringKey={ringKey(SharedRing)} " &
            &"expected={expected} actual={actual}")
  var cursor = ""
  var payloads = initHashSet[string]()
  var ids = initHashSet[string]()
  while true:
    let page = db.listByRing(SharedRing, limit = 32, cursor = cursor)
    for item in page.items:
      require($item.id notin ids, "final pagination returned a duplicate ID")
      ids.incl $item.id
      payloads.incl item.payload
    if page.nextCursor.len == 0:
      break
    require(page.nextCursor != cursor, "pagination cursor did not advance")
    cursor = page.nextCursor
  require(ids.len == expected, "final pagination omitted records")
  for worker in 0 ..< writers:
    for i in 0 ..< count:
      require(&"final-{worker}-{i}" in payloads,
              &"final payload is missing for writer={worker} item={i}")

proc runVerify(peers: string; writers, count: int) =
  var db = connect(peers)
  db.verifyRecords(writers, count)
  let metrics = db.metrics()[0]
  require(metrics.metricValue("autoPackAttempts") > 0,
          "automatic maintenance did not run during concurrent traffic")
  require(metrics.metricValue("activeConnections") >= 1,
          "verification connection is not visible in metrics")
  db.close()

proc runOffline(dataDir: string; writers, count: int) =
  var db = koutendb.open(dataDir = dataDir,
                         durability = koutendb.durStrong,
                         diskBacked = true)
  db.verifyRecords(writers, count)
  db.close()
  let verification = operationalVerify(dataDir, verifySegments = true)
  require(verification.ok, "offline operational verification failed")

proc runShutdown(peers: string) =
  var client = newClusterClient(parsePeers(peers))
  discard client.shutdownReq(0)
  client.close()

proc usage() =
  quit("usage: concurrency_backpressure_matrix --mode=MODE " &
       "[--peers=HOST:PORT] [--data=DIR] [--worker=N] [--count=N] " &
       "[--writers=N] [--loops=N]", 2)

proc main() =
  var mode = ""
  var peers = "127.0.0.1:17841"
  var dataDir = ""
  var worker = 0
  var count = 12
  var writers = 4
  var loops = 40
  for kind, key, value in getopt():
    if kind != cmdLongOption:
      continue
    case key
    of "mode": mode = value
    of "peers": peers = value
    of "data": dataDir = value
    of "worker": worker = parseInt(value)
    of "count": count = parseInt(value)
    of "writers": writers = parseInt(value)
    of "loops": loops = parseInt(value)
    else: usage()
  case mode
  of "writer": runWriter(peers, worker, count)
  of "reader": runReader(peers, loops)
  of "observer": runObserver(peers, loops)
  of "health": runHealth(peers)
  of "admission": runAdmission(peers)
  of "slow-input": runSlowInput(peers)
  of "slow-output": runSlowOutput(peers)
  of "list-limit": runListLimit(peers)
  of "verify": runVerify(peers, writers, count)
  of "offline":
    if dataDir.len == 0: usage()
    runOffline(dataDir, writers, count)
  of "shutdown": runShutdown(peers)
  else: usage()

when isMainModule:
  main()
