## Long-running cluster soak workload for KoutenDB.
##
## This is intentionally not part of CI. Use it for local/VM endurance runs
## such as 72-hour pre-release validation.

import std/[algorithm, json, math, os, strformat, strutils, times]
import ../src/koutendb

const LatencySampleCapacity = 4096

type
  SoakEntry = object
    id: KoutenId
    ring: string
    ringIndex: int
    payload: string
    seq: int

  Counters = object
    puts: int
    backfills: int
    updates: int
    deletes: int
    gets: int
    queries: int
    ringReads: int
    stellarReads: int
    retrieves: int
    metricsReads: int
    errors: int
    putLatency: LatencyStats
    backfillLatency: LatencyStats
    updateLatency: LatencyStats
    deleteLatency: LatencyStats
    getLatency: LatencyStats
    queryLatency: LatencyStats
    ringReadLatency: LatencyStats
    stellarReadLatency: LatencyStats
    retrieveLatency: LatencyStats
    metricsLatency: LatencyStats

  LatencyStats = object
    count: int
    totalUs: float
    maxUs: float
    samples: seq[float]
    nextSample: int

proc argValue(name, defaultValue: string): string =
  let prefix = "--" & name & "="
  for arg in commandLineParams():
    if arg.startsWith(prefix):
      return arg[prefix.len .. ^1]
  defaultValue

proc envValue(name, defaultValue: string): string =
  let v = getEnv(name)
  if v.len == 0: defaultValue else: v

proc intSetting(argName, envName: string, defaultValue: int): int =
  parseInt(argValue(argName, envValue(envName, $defaultValue)))

proc strSetting(argName, envName, defaultValue: string): string =
  argValue(argName, envValue(envName, defaultValue))

proc nextRand(rng: var uint64): uint64 =
  rng = rng * 6364136223846793005'u64 + 1442695040888963407'u64
  rng

proc stellarGroups(rings: int): int =
  max(1, (rings + 1) div 2)

proc stellarRoot(i, rings: int): string =
  "soak/group-" & $(i mod stellarGroups(rings))

proc ringName(i, rings: int): string =
  let child = if i < stellarGroups(rings): "events" else: "profiles"
  stellarRoot(i, rings) & "/" & child

proc vecFor(seqNo, rings: int): seq[float32] =
  @[
    float32((seqNo mod max(1, rings)) + 1),
    float32((seqNo mod 17) + 1),
    float32((seqNo mod 31) + 1)
  ]

proc recordLatency(stats: var LatencyStats; value: float) =
  inc stats.count
  stats.totalUs += value
  if value > stats.maxUs:
    stats.maxUs = value
  if stats.samples.len < LatencySampleCapacity:
    stats.samples.add value
  else:
    stats.samples[stats.nextSample] = value
    stats.nextSample = (stats.nextSample + 1) mod LatencySampleCapacity

template timed(stats: var LatencyStats; body: untyped) =
  let started = epochTime()
  body
  let us = (epochTime() - started) * 1_000_000.0
  recordLatency(stats, us)

proc percentile(stats: LatencyStats; fraction: float): float =
  if stats.samples.len == 0:
    return 0.0
  var values = stats.samples
  values.sort()
  let index = max(0, min(values.high,
    int(ceil(fraction * float(values.len))) - 1))
  values[index]

proc latencyJson(stats: LatencyStats): JsonNode =
  %*{
    "count": stats.count,
    "avg": (if stats.count == 0: 0.0 else: stats.totalUs / float(stats.count)),
    "p50": stats.percentile(0.50),
    "p95": stats.percentile(0.95),
    "p99": stats.percentile(0.99),
    "max": stats.maxUs,
    "sampleWindow": stats.samples.len
  }

proc appendJsonLine(path: string; node: JsonNode) =
  var f = open(path, fmAppend)
  try:
    f.writeLine($node)
  finally:
    f.close()

proc countersJson(c: Counters): JsonNode =
  %*{
    "puts": c.puts,
    "backfills": c.backfills,
    "updates": c.updates,
    "deletes": c.deletes,
    "gets": c.gets,
    "queries": c.queries,
    "ringReads": c.ringReads,
    "stellarReads": c.stellarReads,
    "retrieves": c.retrieves,
    "metricsReads": c.metricsReads,
    "errors": c.errors,
    "latencyUs": {
      "put": latencyJson(c.putLatency),
      "backfill": latencyJson(c.backfillLatency),
      "update": latencyJson(c.updateLatency),
      "delete": latencyJson(c.deleteLatency),
      "get": latencyJson(c.getLatency),
      "query": latencyJson(c.queryLatency),
      "ringRead": latencyJson(c.ringReadLatency),
      "stellarRead": latencyJson(c.stellarReadLatency),
      "retrieve": latencyJson(c.retrieveLatency),
      "metrics": latencyJson(c.metricsLatency)
    }
  }

when isMainModule:
  let peers = strSetting("peers", "KOUTEN_SOAK_PEERS", "")
  if peers.len == 0:
    raise newException(ValueError, "--peers=host:port,... is required")

  let durationSec = max(1, intSetting("duration-sec", "KOUTEN_SOAK_SECONDS", 259200))
  let intervalMs = max(0, intSetting("interval-ms", "KOUTEN_SOAK_INTERVAL_MS", 250))
  let reportEverySec = max(1, intSetting("report-every-sec", "KOUTEN_SOAK_REPORT_EVERY_SECONDS", 60))
  let rings = max(1, intSetting("rings", "KOUTEN_SOAK_RINGS", 16))
  let maxRecent = max(1, intSetting("recent", "KOUTEN_SOAK_RECENT", 2048))
  let ringReadLimit = max(1, intSetting("ring-read-limit", "KOUTEN_SOAK_RING_READ_LIMIT", 16))
  let stellarEvery = max(1, intSetting("stellar-every", "KOUTEN_SOAK_STELLAR_EVERY", 5))
  let retrieveEvery = max(1, intSetting("retrieve-every", "KOUTEN_SOAK_RETRIEVE_EVERY", 10))
  let metricsEvery = max(1, intSetting("metrics-every", "KOUTEN_SOAK_METRICS_EVERY", 20))
  let updateEvery = max(1, intSetting("update-every", "KOUTEN_SOAK_UPDATE_EVERY", 7))
  let deleteEvery = max(1, intSetting("delete-every", "KOUTEN_SOAK_DELETE_EVERY", 29))
  let backfillEvery = max(1, intSetting("backfill-every", "KOUTEN_SOAK_BACKFILL_EVERY", 37))
  let outPath = strSetting("out", "KOUTEN_SOAK_OUT", "soak-progress.jsonl")
  var rng = uint64(max(1, intSetting("seed", "KOUTEN_SOAK_SEED", 20260723)))

  let started = epochTime()
  let deadline = started + float(durationSec)
  var nextReport = started
  var c: Counters
  var seqNo = 0
  var recent: seq[SoakEntry] = @[]
  var lastMetrics: seq[string] = @[]

  let db = connect(peers)
  try:
    for group in 0 ..< stellarGroups(rings):
      let root = "soak/group-" & $group
      discard db.put(%*{
        "kind": "soak-root",
        "group": group,
        "payload": "root-" & $group
      }, ring = root)

    appendJsonLine(outPath, %*{
      "type": "start",
      "durationSec": durationSec,
      "intervalMs": intervalMs,
      "rings": rings,
      "ringReadLimit": ringReadLimit,
      "stellarEvery": stellarEvery,
      "retrieveEvery": retrieveEvery,
      "metricsEvery": metricsEvery,
      "updateEvery": updateEvery,
      "deleteEvery": deleteEvery,
      "backfillEvery": backfillEvery,
      "peers": peers,
      "startedAt": started
    })

    while epochTime() < deadline:
      inc seqNo
      let ringIdx = int(nextRand(rng) mod uint64(rings))
      let ring = ringName(ringIdx, rings)
      let root = stellarRoot(ringIdx, rings)
      let doc = %*{
        "kind": "soak",
        "seq": seqNo,
        "ring": ring,
        "ringIndex": ringIdx,
        "payload": "record-" & $seqNo & "-" & $ringIdx
      }
      let payload = $doc
      var id: KoutenId
      var currentOp = "put"
      var currentPickSeq = 0
      var currentPickRing = ""

      try:
        currentOp = "put"
        timed(c.putLatency):
          id = db.put(doc, ring = ring, vec = vecFor(seqNo, rings))
        inc c.puts
        recent.add SoakEntry(
          id: id,
          ring: ring,
          ringIndex: ringIdx,
          payload: payload,
          seq: seqNo)
        if recent.len > maxRecent:
          recent.delete(0)

        if recent.len > 0:
          let pick = recent[int(nextRand(rng) mod uint64(recent.len))]
          currentPickSeq = pick.seq
          currentPickRing = pick.ring
          var got = ""
          currentOp = "get"
          timed(c.getLatency):
            got = db.get(pick.id)
          inc c.gets
          if got != pick.payload:
            raise newException(AssertionDefect,
              &"payload mismatch seq={pick.seq} expected={pick.payload} got={got}")

          currentOp = "query"
          timed(c.queryLatency):
            let q = db.query(pick.id, "{ seq ring }")
            if q.kind != JObject or not q.hasKey("seq") or
                q["seq"].getInt() != pick.seq:
              raise newException(AssertionDefect,
                &"query projection mismatch seq={pick.seq} got={q}")
          inc c.queries

        currentOp = "readRing"
        timed(c.ringReadLatency):
          let page = db.readRing(ring, KoutenReadOptions(
            filter: newJObject(),
            limit: ringReadLimit,
            sortField: "time",
            sortDirection: rsDesc))
          if page.count < 0 or page.count > ringReadLimit:
            raise newException(AssertionDefect,
              &"invalid ring read count={page.count} limit={ringReadLimit}")
        inc c.ringReads

        if seqNo mod stellarEvery == 0:
          currentOp = "readStellar"
          var stellarOptions = defaultStellarOptions()
          stellarOptions.limitPerRing = max(1, ringReadLimit div 2)
          stellarOptions.maxDepth = 1
          stellarOptions.branchBudget = rings + stellarGroups(rings)
          timed(c.stellarReadLatency):
            let page = db.readStellar(root, stellarOptions)
            if page.ringsVisited <= 0 or page.count <= 0:
              raise newException(AssertionDefect,
                &"stellar read returned no local context root={root}")
          inc c.stellarReads

        if seqNo mod retrieveEvery == 0:
          currentOp = "retrieve"
          timed(c.retrieveLatency):
            let rr = db.retrieveWithStats(vecFor(seqNo, rings), ring = ring, budget = 4)
            if rr.stats.returned != rr.hits.len:
              raise newException(AssertionDefect,
                &"retrieve stats mismatch returned={rr.stats.returned} hits={rr.hits.len}")
          inc c.retrieves

        if seqNo mod metricsEvery == 0:
          currentOp = "metrics"
          timed(c.metricsLatency):
            lastMetrics = db.metrics()
          inc c.metricsReads

        if recent.len > 0 and seqNo mod updateEvery == 0:
          let updateIndex = int(nextRand(rng) mod uint64(recent.len))
          let entry = recent[updateIndex]
          let updated = %*{
            "kind": "soak",
            "seq": entry.seq,
            "ring": entry.ring,
            "ringIndex": entry.ringIndex,
            "revision": seqNo,
            "payload": "updated-" & $entry.seq & "-" & $seqNo
          }
          currentOp = "update"
          timed(c.updateLatency):
            db.update(entry.id, updated, vecFor(entry.seq, rings))
          recent[updateIndex].payload = $updated
          inc c.updates

        if recent.len > 1 and seqNo mod deleteEvery == 0:
          let deleteIndex = int(nextRand(rng) mod uint64(recent.len - 1))
          currentOp = "delete"
          timed(c.deleteLatency):
            db.remove(recent[deleteIndex].id)
          recent.delete(deleteIndex)
          inc c.deletes

        if seqNo mod backfillEvery == 0:
          let backfillRing = root & "/backfill"
          let backfill = %*{
            "kind": "soak-backfill",
            "seq": seqNo,
            "eventTime": seqNo - backfillEvery,
            "payload": "backfill-" & $seqNo
          }
          currentOp = "backfill"
          timed(c.backfillLatency):
            discard db.put(backfill, ring = backfillRing,
                           vec = vecFor(seqNo, rings))
          inc c.backfills

        let now = epochTime()
        if now >= nextReport:
          appendJsonLine(outPath, %*{
            "type": "progress",
            "elapsedSec": int(now - started),
            "remainingSec": max(0, int(deadline - now)),
            "counters": countersJson(c),
            "recentBuffered": recent.len,
            "lastMetrics": %lastMetrics
          })
          nextReport = now + float(reportEverySec)

        if intervalMs > 0:
          sleep(intervalMs)
      except CatchableError as e:
        inc c.errors
        appendJsonLine(outPath, %*{
          "type": "error",
          "elapsedSec": int(epochTime() - started),
          "seq": seqNo,
          "op": currentOp,
          "ring": ring,
          "pickSeq": currentPickSeq,
          "pickRing": currentPickRing,
          "error": e.msg,
          "counters": countersJson(c)
        })
        raise

    appendJsonLine(outPath, %*{
      "type": "final",
      "elapsedSec": int(epochTime() - started),
      "counters": countersJson(c),
      "recentBuffered": recent.len,
      "lastMetrics": %lastMetrics
    })
    echo $countersJson(c)
  finally:
    db.close()
