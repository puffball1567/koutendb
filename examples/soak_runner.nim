## Long-running cluster soak workload for KoutenDB.
##
## This is intentionally not part of CI. Use it for local/VM endurance runs
## such as 72-hour pre-release validation.

import std/[json, os, strformat, strutils, times]
import ../src/koutendb

type
  SoakEntry = object
    id: KoutenId
    ring: string
    payload: string
    seq: int

  Counters = object
    puts: int
    gets: int
    queries: int
    ringReads: int
    retrieves: int
    metricsReads: int
    errors: int
    putUs: float
    getUs: float
    queryUs: float
    ringReadUs: float
    retrieveUs: float
    metricsUs: float
    maxPutUs: float
    maxGetUs: float
    maxQueryUs: float
    maxRingReadUs: float
    maxRetrieveUs: float
    maxMetricsUs: float

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

proc ringName(i: int): string =
  "soak/ring-" & $i

proc vecFor(seqNo, rings: int): seq[float32] =
  @[
    float32((seqNo mod max(1, rings)) + 1),
    float32((seqNo mod 17) + 1),
    float32((seqNo mod 31) + 1)
  ]

proc recordLatency(total: var float; maxValue: var float; value: float) =
  total += value
  if value > maxValue:
    maxValue = value

template timed(total: var float; maxValue: var float; body: untyped) =
  let started = epochTime()
  body
  let us = (epochTime() - started) * 1_000_000.0
  recordLatency(total, maxValue, us)

proc avg(total: float; n: int): float =
  if n <= 0: 0.0 else: total / float(n)

proc appendJsonLine(path: string; node: JsonNode) =
  var f = open(path, fmAppend)
  try:
    f.writeLine($node)
  finally:
    f.close()

proc countersJson(c: Counters): JsonNode =
  %*{
    "puts": c.puts,
    "gets": c.gets,
    "queries": c.queries,
    "ringReads": c.ringReads,
    "retrieves": c.retrieves,
    "metricsReads": c.metricsReads,
    "errors": c.errors,
    "latencyUs": {
      "putAvg": avg(c.putUs, c.puts),
      "getAvg": avg(c.getUs, c.gets),
      "queryAvg": avg(c.queryUs, c.queries),
      "ringReadAvg": avg(c.ringReadUs, c.ringReads),
      "retrieveAvg": avg(c.retrieveUs, c.retrieves),
      "metricsAvg": avg(c.metricsUs, c.metricsReads),
      "putMax": c.maxPutUs,
      "getMax": c.maxGetUs,
      "queryMax": c.maxQueryUs,
      "ringReadMax": c.maxRingReadUs,
      "retrieveMax": c.maxRetrieveUs,
      "metricsMax": c.maxMetricsUs
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
  let retrieveEvery = max(1, intSetting("retrieve-every", "KOUTEN_SOAK_RETRIEVE_EVERY", 10))
  let metricsEvery = max(1, intSetting("metrics-every", "KOUTEN_SOAK_METRICS_EVERY", 20))
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
    appendJsonLine(outPath, %*{
      "type": "start",
      "durationSec": durationSec,
      "intervalMs": intervalMs,
      "rings": rings,
      "ringReadLimit": ringReadLimit,
      "retrieveEvery": retrieveEvery,
      "metricsEvery": metricsEvery,
      "peers": peers,
      "startedAt": started
    })

    while epochTime() < deadline:
      inc seqNo
      let ringIdx = int(nextRand(rng) mod uint64(rings))
      let ring = ringName(ringIdx)
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
        timed(c.putUs, c.maxPutUs):
          id = db.put(doc, ring = ring, vec = vecFor(seqNo, rings))
        inc c.puts
        recent.add SoakEntry(id: id, ring: ring, payload: payload, seq: seqNo)
        if recent.len > maxRecent:
          recent.delete(0)

        if recent.len > 0:
          let pick = recent[int(nextRand(rng) mod uint64(recent.len))]
          currentPickSeq = pick.seq
          currentPickRing = pick.ring
          var got = ""
          currentOp = "get"
          timed(c.getUs, c.maxGetUs):
            got = db.get(pick.id)
          inc c.gets
          if got != pick.payload:
            raise newException(AssertionDefect,
              &"payload mismatch seq={pick.seq} expected={pick.payload} got={got}")

          currentOp = "query"
          timed(c.queryUs, c.maxQueryUs):
            let q = db.query(pick.id, "{ seq ring }")
            if q.kind != JObject or not q.hasKey("seq") or
                q["seq"].getInt() != pick.seq:
              raise newException(AssertionDefect,
                &"query projection mismatch seq={pick.seq} got={q}")
          inc c.queries

        currentOp = "readRing"
        timed(c.ringReadUs, c.maxRingReadUs):
          let page = db.readRing(ring, KoutenReadOptions(
            filter: newJObject(),
            limit: ringReadLimit,
            sortField: "time",
            sortDirection: rsDesc))
          if page.count < 0 or page.count > ringReadLimit:
            raise newException(AssertionDefect,
              &"invalid ring read count={page.count} limit={ringReadLimit}")
        inc c.ringReads

        if seqNo mod retrieveEvery == 0:
          currentOp = "retrieve"
          timed(c.retrieveUs, c.maxRetrieveUs):
            let rr = db.retrieveWithStats(vecFor(seqNo, rings), ring = ring, budget = 4)
            if rr.stats.returned != rr.hits.len:
              raise newException(AssertionDefect,
                &"retrieve stats mismatch returned={rr.stats.returned} hits={rr.hits.len}")
          inc c.retrieves

        if seqNo mod metricsEvery == 0:
          currentOp = "metrics"
          timed(c.metricsUs, c.maxMetricsUs):
            lastMetrics = db.metrics()
          inc c.metricsReads

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
