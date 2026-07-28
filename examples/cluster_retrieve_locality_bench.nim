## Reproducible cluster benchmark for physical ring-local retrieval.
##
## The target and unrelated rings are deliberately placed on the same owner.
## Global and scoped queries must return the same top payloads, while metrics
## expose the difference in records physically visited and vectors scored.

import std/[algorithm, hashes, monotimes, os, strutils, times]
import ../src/koutendb
import ../src/kouten/[core, wire]

proc intSetting(name: string, default: int): int =
  let raw = getEnv(name, $default)
  result = parseInt(raw)
  if result <= 0:
    raise newException(ValueError, name & " must be positive")

proc ringKey(name: string): uint64 =
  uint64(hash(name)) or 1'u64

proc metricValue(metrics, name: string): int =
  let parts = metrics.splitWhitespace()
  for i in 0 ..< parts.len - 1:
    if parts[i] == name:
      return parseInt(parts[i + 1])
  raise newException(ValueError, "metric not found: " & name)

proc metricTotal(client: ClusterClient, nodes: int, name: string): int =
  for node in 0 ..< nodes:
    result += metricValue(client.metricsReq(node), name)

proc waitCluster(client: ClusterClient, nodes: int): bool =
  for _ in 0 ..< 100:
    var ready = true
    for node in 0 ..< nodes:
      try:
        discard client.healthReq(node)
      except CatchableError:
        ready = false
    if ready:
      return true
    sleep(100)
  false

proc payloads(hits: seq[KoutenHit]): seq[string] =
  for hit in hits:
    result.add hit.payload
  result.sort()

when isMainModule:
  let peers = getEnv(
    "KOUTEN_BENCH_PEERS", "127.0.0.1:17881,127.0.0.1:17882")
  let unrelated = intSetting("KOUTEN_BENCH_UNRELATED", 10_000)
  let targetCount = intSetting("KOUTEN_BENCH_TARGET", 100)
  let queries = intSetting("KOUTEN_BENCH_QUERIES", 50)
  let parsedPeers = parsePeers(peers)
  let client = newClusterClient(parsedPeers)
  if not client.waitCluster(parsedPeers.len):
    client.close()
    raise newException(IOError, "cluster did not become ready")
  let db = connect(peers)
  try:
    let topology = client.topologyReq(0)
    var targetRing = ""
    var unrelatedRing = ""
    var owner = -1
    for i in 0 ..< 256:
      let candidate = "bench/locality-" & $i
      let candidateOwner = int(topology.placementOwner(candidate.ringKey))
      if targetRing.len == 0:
        targetRing = candidate
        owner = candidateOwner
      elif candidateOwner == owner:
        unrelatedRing = candidate
        break
    if unrelatedRing.len == 0:
      raise newException(ValueError, "could not find two rings on one owner")

    for i in 0 ..< targetCount:
      discard db.put("target-" & align($i, 8, '0'), ring = targetRing,
                     vec = @[1.0'f32, float32(i mod 10) / 10_000.0'f32])
    for i in 0 ..< unrelated:
      discard db.put("unrelated-" & $i, ring = unrelatedRing,
                     vec = @[0.0'f32, 1.0'f32])

    let query = @[1.0'f32, 0.0'f32]
    let budget = min(8, targetCount)
    let scopedWarm = db.retrieveWithStats(
      query, ring = targetRing, budget = budget)
    let globalWarm = db.retrieveWithStats(query, budget = budget)
    let sameResults = scopedWarm.hits.payloads == globalWarm.hits.payloads
    if not sameResults:
      raise newException(ValueError,
        "global and scoped retrieval returned different semantic results")

    let visitedBefore = client.metricTotal(
      parsedPeers.len, "retrievePhysicalVisited")
    let scoredBefore = client.metricTotal(
      parsedPeers.len, "retrieveCandidatesScored")
    var scopedNs = 0'i64
    for _ in 0 ..< queries:
      let started = getMonoTime()
      discard db.retrieveWithStats(query, ring = targetRing, budget = budget)
      scopedNs += (getMonoTime() - started).inNanoseconds
    let scopedVisited = client.metricTotal(
      parsedPeers.len, "retrievePhysicalVisited") - visitedBefore
    let scopedScored = client.metricTotal(
      parsedPeers.len, "retrieveCandidatesScored") - scoredBefore

    let globalVisitedBefore = client.metricTotal(
      parsedPeers.len, "retrievePhysicalVisited")
    let globalScoredBefore = client.metricTotal(
      parsedPeers.len, "retrieveCandidatesScored")
    var globalNs = 0'i64
    for _ in 0 ..< queries:
      let started = getMonoTime()
      discard db.retrieveWithStats(query, budget = budget)
      globalNs += (getMonoTime() - started).inNanoseconds
    let globalVisited = client.metricTotal(
      parsedPeers.len, "retrievePhysicalVisited") - globalVisitedBefore
    let globalScored = client.metricTotal(
      parsedPeers.len, "retrieveCandidatesScored") - globalScoredBefore

    echo "KoutenDB cluster retrieval locality benchmark"
    echo "nodes=", parsedPeers.len,
         " target=", targetCount,
         " unrelated=", unrelated,
         " queries=", queries,
         " owner=", owner
    echo "semantic_results_equal=", sameResults
    echo "scoped avg_us=", float(scopedNs) / 1_000.0 / float(queries),
         " visited/query=", float(scopedVisited) / float(queries),
         " scored/query=", float(scopedScored) / float(queries),
         " fanout=", scopedWarm.stats.fanoutNodes
    echo "global avg_us=", float(globalNs) / 1_000.0 / float(queries),
         " visited/query=", float(globalVisited) / float(queries),
         " scored/query=", float(globalScored) / float(queries),
         " fanout=", globalWarm.stats.fanoutNodes
  finally:
    db.close()
    client.close()
