## Dependency-free exact vector retrieval benchmark.
##
## This benchmark compares broad retrieval with KoutenDB's normal ring-scoped
## path. It is intentionally deterministic and does not make universal claims.

import std/[math, monotimes, parseopt, strformat, strutils, times]
import ../src/koutendb

type
  BenchResult = object
    docs: int
    rings: int
    dim: int
    queries: int
    budget: int
    globalUs: float
    scopedUs: float
    globalScanned: int
    scopedScanned: int

proc lcg(seed: var uint32): float32 =
  seed = seed * 1664525'u32 + 1013904223'u32
  float32(seed shr 8) / float32(0x00ff_ffff'u32)

proc makeVec(ring, item, dim: int): seq[float32] =
  var seed = uint32((ring + 1) * 1_000_003 + (item + 1) * 97)
  result = newSeq[float32](dim)
  var sum = 0.0'f32
  for i in 0 ..< dim:
    let base =
      if i == (ring mod dim): 1.0'f32
      elif i == ((ring + 1) mod dim): 0.25'f32
      else: 0.02'f32
    let v = base + (lcg(seed) - 0.5'f32) * 0.01'f32
    result[i] = v
    sum += v * v
  let denom = sqrt(sum)
  if denom > 0:
    for i in 0 ..< result.len:
      result[i] = result[i] / denom

proc loadCorpus(db: KoutenDb, docs, rings, dim: int) =
  for i in 0 ..< docs:
    let ringId = i mod rings
    let ring = "bench/ring-" & $ringId
    let payload = &"{{\"id\":\"doc-{i}\",\"ring\":\"{ring}\",\"body\":\"deterministic vector backend benchmark payload\"}}"
    discard db.put(payload, ring = ring, vec = makeVec(ringId, i, dim))

proc runBenchmark(docs, rings, dim, queries, budget: int): BenchResult =
  var db = open()
  defer: db.close()

  db.loadCorpus(docs, rings, dim)

  result.docs = docs
  result.rings = rings
  result.dim = dim
  result.queries = queries
  result.budget = budget

  var t = getMonoTime()
  for q in 0 ..< queries:
    let ringId = q mod rings
    let rr = db.retrieveWithStats(makeVec(ringId, q, dim), budget = budget)
    result.globalScanned += rr.stats.scanned
  result.globalUs = float((getMonoTime() - t).inNanoseconds) / 1e3 / float(queries)

  t = getMonoTime()
  for q in 0 ..< queries:
    let ringId = q mod rings
    let rr = db.retrieveWithStats(makeVec(ringId, q, dim),
                                  ring = "bench/ring-" & $ringId,
                                  budget = budget)
    result.scopedScanned += rr.stats.scanned
  result.scopedUs = float((getMonoTime() - t).inNanoseconds) / 1e3 / float(queries)

proc printResult(r: BenchResult) =
  echo &"exact: docs={r.docs} rings={r.rings} dim={r.dim} queries={r.queries} budget={r.budget}"
  echo &"  global: {r.globalUs:.2f} us/query, scanned/query={float(r.globalScanned) / float(r.queries):.1f}"
  echo &"  scoped: {r.scopedUs:.2f} us/query, scanned/query={float(r.scopedScanned) / float(r.queries):.1f}"

proc main() =
  var docs = 20_000
  var rings = 100
  var dim = 64
  var queries = 200
  var budget = 8

  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "docs": docs = parseInt(val)
      of "rings": rings = parseInt(val)
      of "dim": dim = parseInt(val)
      of "queries": queries = parseInt(val)
      of "budget": budget = parseInt(val)
      else: discard
    of cmdArgument, cmdShortOption, cmdEnd:
      discard

  if docs <= 0 or rings <= 0 or dim <= 0 or queries <= 0 or budget <= 0:
    raise newException(ValueError, "docs, rings, dim, queries, and budget must be positive")

  runBenchmark(docs, rings, dim, queries, budget).printResult()

when isMainModule:
  main()
