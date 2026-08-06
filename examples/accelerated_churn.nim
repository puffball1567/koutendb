## High-density v0.12 storage validation.
##
## This runner is intentionally manual. It compresses writes, updates,
## deletes, backfills, maintenance, checkpoints, reopen, and restore checks
## into a configurable duration without replacing the final 72-hour gate.

import std/[algorithm, json, monotimes, os, parseopt, strformat,
            strutils, tables, times]
import ../src/koutendb

const MaxLatencySamples = 65_536

type
  ExpectedRecord = object
    id: KoutenId
    ring: string
    payload: string
    logicalId: int
    revision: int

  LatencyReservoir = object
    count: uint64
    rng: uint64
    values: seq[float]

  ChurnCounters = object
    operations: int
    puts: int
    updates: int
    deletes: int
    reads: int
    maintenanceRuns: int
    checkpoints: int
    reopens: int
    backupRestores: int
    logicalChecks: int

  ChurnLatencies = object
    write: LatencyReservoir
    read: LatencyReservoir
    maintenance: LatencyReservoir
    checkpoint: LatencyReservoir
    reopen: LatencyReservoir
    backupRestore: LatencyReservoir
    logicalCheck: LatencyReservoir

  Settings = object
    dataDir: string
    outputPath: string
    durationSec: int
    maxOperations: int
    rings: int
    seedRecordsPerRing: int
    reportEverySec: int
    maintenanceEvery: int
    checkpointEvery: int
    reopenEvery: int
    backupEvery: int
    verifyEvery: int
    seed: uint64

proc nextRand(rng: var uint64): uint64 =
  rng = rng * 6364136223846793005'u64 + 1442695040888963407'u64
  rng

proc observe(samples: var LatencyReservoir, value: float) =
  inc samples.count
  if samples.rng == 0:
    samples.rng = 0x6a09e667f3bcc909'u64
  if samples.values.len < MaxLatencySamples:
    samples.values.add value
    return
  let slot = nextRand(samples.rng) mod samples.count
  if slot < uint64(MaxLatencySamples):
    samples.values[int(slot)] = value

proc elapsedUs(started: MonoTime): float =
  float((getMonoTime() - started).inNanoseconds) / 1000.0

proc percentile(samples: LatencyReservoir, quantile: float): float =
  if samples.values.len == 0:
    return 0.0
  var values = samples.values
  values.sort()
  let index = min(values.high,
                  max(0, int(quantile * float(values.high) + 0.5)))
  values[index]

proc latencyJson(samples: LatencyReservoir): JsonNode =
  %*{
    "count": $samples.count,
    "sampled": samples.values.len,
    "p50Us": samples.percentile(0.50),
    "p95Us": samples.percentile(0.95),
    "p99Us": samples.percentile(0.99)
  }

proc latenciesJson(latencies: ChurnLatencies): JsonNode =
  %*{
    "write": latencyJson(latencies.write),
    "read": latencyJson(latencies.read),
    "maintenance": latencyJson(latencies.maintenance),
    "checkpoint": latencyJson(latencies.checkpoint),
    "reopen": latencyJson(latencies.reopen),
    "backupRestore": latencyJson(latencies.backupRestore),
    "logicalCheck": latencyJson(latencies.logicalCheck)
  }

proc countersJson(counters: ChurnCounters): JsonNode =
  %*{
    "operations": counters.operations,
    "puts": counters.puts,
    "updates": counters.updates,
    "deletes": counters.deletes,
    "reads": counters.reads,
    "maintenanceRuns": counters.maintenanceRuns,
    "checkpoints": counters.checkpoints,
    "reopens": counters.reopens,
    "backupRestores": counters.backupRestores,
    "logicalChecks": counters.logicalChecks
  }

proc appendJsonLine(path: string, node: JsonNode) =
  var file = open(path, fmAppend)
  try:
    file.writeLine($node)
    file.flushFile()
  finally:
    file.close()

proc recordKey(id: KoutenId): string =
  let raw = id.toRaw()
  $raw.parent & ":" & $raw.seq

proc ringName(index: int): string =
  "churn/ring-" & $index

proc payloadFor(kind, ring: string, logicalId, revision: int): string =
  $(%*{
    "kind": kind,
    "ring": ring,
    "logicalId": logicalId,
    "revision": revision,
    "body": kind & "-" & $logicalId & "-r" & $revision
  })

proc digest(lines: seq[string]): string =
  var first = 1469598103934665603'u64
  var second = 1099511628211'u64
  for line in lines:
    for ch in line:
      first = (first xor uint64(ch.ord)) * 1099511628211'u64
      second = (second xor uint64(ch.ord)) * 14029467366897019727'u64
    first = (first xor 10'u64) * 1099511628211'u64
    second = (second xor 10'u64) * 14029467366897019727'u64
  first.toHex(16) & second.toHex(16)

proc expectedLines(expected: Table[string, ExpectedRecord]): seq[string] =
  for _, record in expected:
    result.add record.ring & "\x1f" & recordKey(record.id) & "\x1f" &
               record.payload
  result.sort()

proc actualLines(db: KoutenDb, ringCount: int): seq[string] =
  for ringIndex in 0 ..< ringCount:
    let ring = ringName(ringIndex)
    var cursor = ""
    while true:
      let page = db.listByRing(ring, limit = 512, cursor = cursor)
      for record in page.items:
        result.add ring & "\x1f" & recordKey(record.id) & "\x1f" &
                   record.payload
      if page.nextCursor.len == 0:
        break
      if page.nextCursor == cursor:
        raise newException(AssertionDefect,
          "ring cursor did not advance for " & ring)
      cursor = page.nextCursor
  result.sort()

proc verifyLogicalState(db: KoutenDb,
                        expected: Table[string, ExpectedRecord],
                        ringCount: int): string =
  let want = expected.expectedLines()
  let got = db.actualLines(ringCount)
  if got != want:
    raise newException(AssertionDefect,
      &"logical state diverged expectedCount={want.len} " &
      &"actualCount={got.len} expectedHash={want.digest()} " &
      &"actualHash={got.digest()}")
  got.digest()

proc rssBytes(): int64 =
  when defined(linux):
    if fileExists("/proc/self/status"):
      for line in lines("/proc/self/status"):
        if line.startsWith("VmRSS:"):
          let fields = line.splitWhitespace()
          if fields.len >= 2:
            return parseBiggestInt(fields[1]).int64 * 1024
  0'i64

proc metricSnapshot(db: KoutenDb, dataDir: string): JsonNode =
  let segment = db.segmentStatus(staleRatioThreshold = 0.05,
                                 minStaleRecords = 1)
  %*{
    "rssBytes": $rssBytes(),
    "walBytes": $(if fileExists(dataDir / "kouten.log"):
                     getFileSize(dataDir / "kouten.log") else: 0'i64),
    "segmentBytes": $segment.totalSegmentBytes,
    "segmentIndexBytes": $segment.totalIndexBytes,
    "maxGeneration": $segment.maxGeneration,
    "recommendedRings": segment.recommendedRings,
    "walFallbacks": $segment.walFallbacks,
    "walFallbackPointReads": $segment.walFallbackPointReads,
    "walFallbackRingScans": $segment.walFallbackRingScans,
    "walFallbackWindowReads": $segment.walFallbackWindowReads
  }

proc operationalSummaryJson(report: KoutenOperationalVerifyReport): JsonNode =
  var checks = newJArray()
  for check in report.checks:
    checks.add %*{
      "name": check.name,
      "ok": check.ok,
      "message": check.message
    }
  %*{
    "ok": report.ok,
    "walBytes": $report.walBytes,
    "items": report.items,
    "rings": report.rings,
    "segmentFiles": report.segmentFiles,
    "walFallbacks": $report.segmentStatus.walFallbacks,
    "checks": checks
  }

proc checkpointSummaryJson(status: CheckpointStatus): JsonNode =
  %*{
    "id": status.id,
    "complete": status.complete,
    "verified": status.verified,
    "reasonCode": status.reasonCode,
    "items": status.items,
    "rings": status.rings,
    "snapshotWalBytes": $status.snapshotWalBytes
  }

proc maintenancePolicy(): KoutenSegmentMaintenancePolicy =
  KoutenSegmentMaintenancePolicy(
    staleRatioThreshold: 0.05,
    minStaleRecords: 1,
    maxRings: 4,
    maxBytes: 64'i64 * 1024 * 1024,
    maxElapsedMs: 2000)

proc runMaintenancePass(db: KoutenDb, counters: var ChurnCounters,
                        latencies: var ChurnLatencies):
                        KoutenSegmentMaintenanceResult =
  let started = getMonoTime()
  result = db.runSegmentMaintenance(maintenancePolicy())
  latencies.maintenance.observe(elapsedUs(started))
  if result.outcome == "failed":
    raise newException(AssertionDefect,
      "segment maintenance failed: " & result.stopReason)
  inc counters.maintenanceRuns

proc drainMaintenance(db: KoutenDb, ringCount: int,
                      counters: var ChurnCounters,
                      latencies: var ChurnLatencies) =
  ## Keep each database maintenance pass bounded, while requiring the manual
  ## validation run to prove that a finite sequence drains all stale rings.
  for _ in 0 ..< max(1, ringCount * 2):
    let status = db.segmentStatus(staleRatioThreshold = 0.05,
                                  minStaleRecords = 1)
    if status.recommendedRings == 0:
      return
    let maintenance = db.runMaintenancePass(counters, latencies)
    if maintenance.packedRings == 0:
      raise newException(AssertionDefect,
        "segment maintenance made no progress with " &
        $status.recommendedRings & " recommended rings: " &
        maintenance.outcome & " " & maintenance.stopReason)
  let remaining = db.segmentStatus(staleRatioThreshold = 0.05,
                                    minStaleRecords = 1).recommendedRings
  if remaining != 0:
    raise newException(AssertionDefect,
      "segment maintenance drain exceeded its pass limit with " &
      $remaining & " recommended rings")

proc parseSettings(): Settings =
  result.durationSec = 3600
  result.maxOperations = 0
  result.rings = 16
  result.seedRecordsPerRing = 128
  result.reportEverySec = 10
  result.maintenanceEvery = 250
  result.checkpointEvery = 1000
  result.reopenEvery = 2000
  result.backupEvery = 4000
  result.verifyEvery = 100
  result.seed = 20260806'u64
  for kind, key, value in getopt():
    if kind != cmdLongOption:
      continue
    case key
    of "data": result.dataDir = value
    of "out": result.outputPath = value
    of "duration-sec": result.durationSec = parseInt(value)
    of "operations": result.maxOperations = parseInt(value)
    of "rings": result.rings = parseInt(value)
    of "seed-records-per-ring": result.seedRecordsPerRing = parseInt(value)
    of "report-every-sec": result.reportEverySec = parseInt(value)
    of "maintenance-every": result.maintenanceEvery = parseInt(value)
    of "checkpoint-every": result.checkpointEvery = parseInt(value)
    of "reopen-every": result.reopenEvery = parseInt(value)
    of "backup-every": result.backupEvery = parseInt(value)
    of "verify-every": result.verifyEvery = parseInt(value)
    of "seed": result.seed = parseBiggestUInt(value).uint64
    else:
      raise newException(ValueError, "unknown option --" & key)
  if result.dataDir.len == 0:
    raise newException(ValueError, "--data=DIR is required")
  if result.outputPath.len == 0:
    result.outputPath = result.dataDir.parentDir / "accelerated-churn.jsonl"
  if result.durationSec < 0 or result.maxOperations < 0:
    raise newException(ValueError,
      "duration-sec and operations must be >= 0")
  if result.durationSec == 0 and result.maxOperations == 0:
    raise newException(ValueError,
      "duration-sec and operations cannot both be zero")
  for value in [result.rings, result.seedRecordsPerRing,
                result.reportEverySec, result.maintenanceEvery,
                result.checkpointEvery, result.reopenEvery,
                result.backupEvery, result.verifyEvery]:
    if value <= 0:
      raise newException(ValueError, "all interval settings must be > 0")

proc main() =
  let settings = parseSettings()
  if dirExists(settings.dataDir):
    raise newException(ValueError, "data directory already exists")
  createDir(settings.dataDir.parentDir)
  if fileExists(settings.outputPath):
    raise newException(ValueError, "output file already exists")

  let checkpointRoot = settings.dataDir.parentDir / "checkpoints"
  let scratchRoot = settings.dataDir.parentDir / "scratch"
  createDir(scratchRoot)
  var db = koutendb.open(dataDir = settings.dataDir, durability = durStrong,
                         diskBacked = true)
  var expected = initTable[string, ExpectedRecord]()
  var liveKeys: seq[string] = @[]
  var counters: ChurnCounters
  var latencies: ChurnLatencies
  var rng = if settings.seed == 0: 1'u64 else: settings.seed
  var logicalId = 0
  let startedAt = epochTime()
  let deadline = startedAt + float(settings.durationSec)
  var nextReport = startedAt

  appendJsonLine(settings.outputPath, %*{
    "type": "start",
    "startedAt": startedAt,
    "durationSec": settings.durationSec,
    "maxOperations": settings.maxOperations,
    "rings": settings.rings,
    "seedRecordsPerRing": settings.seedRecordsPerRing,
    "seed": $settings.seed
  })

  try:
    for ringIndex in 0 ..< settings.rings:
      let ring = ringName(ringIndex)
      for _ in 0 ..< settings.seedRecordsPerRing:
        inc logicalId
        let payload = payloadFor("seed", ring, logicalId, 1)
        let started = getMonoTime()
        let id = db.put(payload, ring = ring)
        latencies.write.observe(elapsedUs(started))
        let key = recordKey(id)
        expected[key] = ExpectedRecord(id: id, ring: ring, payload: payload,
                                       logicalId: logicalId, revision: 1)
        liveKeys.add key
        inc counters.puts
    discard db.packDiskBackedSegments()
    discard db.verifyLogicalState(expected, settings.rings)
    inc counters.logicalChecks

    while true:
      if settings.maxOperations > 0 and
          counters.operations >= settings.maxOperations:
        break
      if settings.durationSec > 0 and epochTime() >= deadline:
        break

      inc counters.operations
      db.advance(0.001)
      let choice = int(nextRand(rng) mod 100'u64)
      if liveKeys.len == 0 or choice >= 75:
        inc logicalId
        let ring = ringName(int(nextRand(rng) mod uint64(settings.rings)))
        let payload = payloadFor("backfill", ring, logicalId, 1)
        let started = getMonoTime()
        let id = db.put(payload, ring = ring)
        latencies.write.observe(elapsedUs(started))
        let key = recordKey(id)
        expected[key] = ExpectedRecord(id: id, ring: ring, payload: payload,
                                       logicalId: logicalId, revision: 1)
        liveKeys.add key
        inc counters.puts
      else:
        let index = int(nextRand(rng) mod uint64(liveKeys.len))
        let key = liveKeys[index]
        var record = expected[key]
        if choice < 55:
          inc record.revision
          record.payload = payloadFor("update", record.ring, record.logicalId,
                                      record.revision)
          let started = getMonoTime()
          db.update(record.id, record.payload)
          latencies.write.observe(elapsedUs(started))
          expected[key] = record
          inc counters.updates
        else:
          let started = getMonoTime()
          db.remove(record.id)
          latencies.write.observe(elapsedUs(started))
          expected.del key
          liveKeys[index] = liveKeys[^1]
          liveKeys.setLen(liveKeys.len - 1)
          inc counters.deletes

      if liveKeys.len > 0:
        let record = expected[
          liveKeys[int(nextRand(rng) mod uint64(liveKeys.len))]]
        let started = getMonoTime()
        let payload = db.get(record.id)
        latencies.read.observe(elapsedUs(started))
        if payload != record.payload:
          raise newException(AssertionDefect,
            "point read diverged for " & recordKey(record.id))
        inc counters.reads

      if counters.operations mod settings.maintenanceEvery == 0:
        discard db.runMaintenancePass(counters, latencies)

      if counters.operations mod settings.checkpointEvery == 0:
        let started = getMonoTime()
        let checkpoint = db.createCheckpoint(
          checkpointRoot, "churn-" & $counters.operations)
        discard verifyCheckpoint(checkpoint.path)
        discard cleanupCheckpoints(checkpointRoot, keep = 2)
        latencies.checkpoint.observe(elapsedUs(started))
        inc counters.checkpoints

      if counters.operations mod settings.reopenEvery == 0:
        let started = getMonoTime()
        db.close()
        db = koutendb.open(dataDir = settings.dataDir,
                           durability = durStrong, diskBacked = true)
        latencies.reopen.observe(elapsedUs(started))
        inc counters.reopens

      if counters.operations mod settings.backupEvery == 0:
        let backupDir = scratchRoot / "backup-" & $counters.operations
        let restoreDir = scratchRoot / "restore-" & $counters.operations
        let started = getMonoTime()
        discard db.backup(backupDir)
        discard restoreBackup(backupDir, restoreDir, durability = durStrong)
        var restored = koutendb.open(dataDir = restoreDir,
                                     durability = durStrong, diskBacked = true)
        discard restored.verifyLogicalState(expected, settings.rings)
        restored.close()
        removeDir(backupDir)
        removeDir(restoreDir)
        latencies.backupRestore.observe(elapsedUs(started))
        inc counters.backupRestores

      if counters.operations mod settings.verifyEvery == 0:
        let started = getMonoTime()
        discard db.verifyLogicalState(expected, settings.rings)
        latencies.logicalCheck.observe(elapsedUs(started))
        inc counters.logicalChecks

      let now = epochTime()
      if now >= nextReport:
        appendJsonLine(settings.outputPath, %*{
          "type": "progress",
          "elapsedSec": int(now - startedAt),
          "counters": countersJson(counters),
          "liveRecords": expected.len,
          "logicalHash": expected.expectedLines().digest(),
          "latencies": latenciesJson(latencies),
          "metrics": metricSnapshot(db, settings.dataDir)
        })
        nextReport = now + float(settings.reportEverySec)

    db.drainMaintenance(settings.rings, counters, latencies)
    let finalHash = db.verifyLogicalState(expected, settings.rings)
    inc counters.logicalChecks
    let finalCheckpoint = db.createCheckpoint(checkpointRoot, "final")
    discard verifyCheckpoint(finalCheckpoint.path)
    let finalMetrics = metricSnapshot(db, settings.dataDir)
    if db.segmentStatus(staleRatioThreshold = 0.05,
                        minStaleRecords = 1).walFallbacks != 0:
      raise newException(AssertionDefect,
        "healthy churn run recorded a segment-to-WAL fallback")
    db.close()

    let verifyReport = operationalVerify(settings.dataDir, diskBacked = true,
                                         verifySegments = true)
    if not verifyReport.ok:
      raise newException(AssertionDefect,
        "final operational verification failed")
    appendJsonLine(settings.outputPath, %*{
      "type": "final",
      "elapsedSec": int(epochTime() - startedAt),
      "counters": countersJson(counters),
      "liveRecords": expected.len,
      "logicalHash": finalHash,
      "latencies": latenciesJson(latencies),
      "metrics": finalMetrics,
      "checkpoint": checkpointSummaryJson(finalCheckpoint),
      "operationalVerify": operationalSummaryJson(verifyReport)
    })
    writeFile(settings.dataDir.parentDir / "completed.ok", "ok\n")
    echo &"accelerated-churn OK operations={counters.operations} " &
         &"liveRecords={expected.len} logicalHash={finalHash}"
  except:
    if not db.isNil:
      try: db.close()
      except CatchableError: discard
    appendJsonLine(settings.outputPath, %*{
      "type": "failure",
      "elapsedSec": int(epochTime() - startedAt),
      "counters": countersJson(counters),
      "error": getCurrentExceptionMsg()
    })
    raise

when isMainModule:
  main()
