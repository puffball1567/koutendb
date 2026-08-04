## Compare disk-backed reads before and after explicit ring-local packing.
##
## The benchmark builds one seed store with interleaved writes and updates,
## copies it into fresh before/after directories, and packs only the after
## copy. It reports point, full-ring, and stellar-neighborhood reads. Results
## are local micro-measurements, not universal performance claims.

import std/[json, monotimes, os, parseopt, strformat, strutils, tempfiles, times]
import ../src/koutendb
import ../src/kouten/store

type
  ReadSample = object
    pointUs: float
    segmentScanUs: float
    ringUs: float
    stellarUs: float
    pointBytes: int
    segmentRecords: int
    ringItems: int
    stellarItems: int

proc elapsedUs(start: MonoTime): float =
  float((getMonoTime() - start).inNanoseconds) / 1_000.0

proc sample(dataDir, root: string, id: KoutenId, ringKey: uint64,
            limit, iters: int): ReadSample =
  var store = openStore(dataDir, diskBacked = true)
  let segmentStart = getMonoTime()
  for _ in 0 ..< iters:
    for p in store.particlesByRing(ringKey):
      result.segmentRecords += p.payload.len
  result.segmentScanUs = elapsedUs(segmentStart) / float(iters)
  store.close()

  var db = open(dataDir = dataDir, diskBacked = true)
  defer: db.close()
  var read = defaultReadOptions()
  read.limit = limit
  var stellar = defaultStellarOptions()
  stellar.limitPerRing = limit

  let pointStart = getMonoTime()
  for _ in 0 ..< iters:
    result.pointBytes += db.get(id).len
  result.pointUs = elapsedUs(pointStart) / float(iters)

  let ringStart = getMonoTime()
  for _ in 0 ..< iters:
    result.ringItems += db.readRing(root, read).items.len
  result.ringUs = elapsedUs(ringStart) / float(iters)

  let stellarStart = getMonoTime()
  for _ in 0 ..< iters:
    result.stellarItems += db.readStellar(root, stellar).count
  result.stellarUs = elapsedUs(stellarStart) / float(iters)

proc printSample(label: string, sample: ReadSample) =
  echo &"{label} point_get_us={sample.pointUs:.3f} segment_scan_us={sample.segmentScanUs:.3f} " &
       &"ring_read_us={sample.ringUs:.3f} stellar_read_us={sample.stellarUs:.3f} " &
       &"point_bytes={sample.pointBytes} segment_bytes={sample.segmentRecords} " &
       &"ring_items={sample.ringItems} stellar_items={sample.stellarItems}"

proc main() =
  var perRing = 1_000
  var updates = 3_000
  var iters = 100
  var keep = false
  for kind, key, value in getopt():
    case kind
    of cmdLongOption:
      case key
      of "per-ring": perRing = parseInt(value)
      of "updates": updates = parseInt(value)
      of "iters": iters = parseInt(value)
      of "keep": keep = true
      else: discard
    of cmdArgument, cmdShortOption, cmdEnd:
      discard
  if perRing <= 0 or updates < 0 or iters <= 0:
    raise newException(ValueError, "per-ring and iters must be positive; updates must be non-negative")

  let rootDir = createTempDir("koutendb", "segment-layout")
  let seedDir = rootDir / "seed"
  let beforeDir = rootDir / "before"
  let afterDir = rootDir / "after"
  let root = "users/42"
  let related = ["users/42/orders", "users/42/billing"]
  var anchor: KoutenId
  var rootIds: seq[KoutenId] = @[]
  try:
    var seed = open(dataDir = seedDir, diskBacked = true)
    for i in 0 ..< perRing:
      let doc = %*{"kind": "profile", "n": i, "state": "base"}
      let id = seed.put(doc, ring = root)
      if i == 0: anchor = id
      rootIds.add id
      discard seed.put(%*{"kind": "order", "n": i}, ring = related[0])
      discard seed.put(%*{"kind": "billing", "n": i}, ring = related[1])
    seed.attachStellar(root, related[0])
    seed.attachStellar(root, related[1])
    for i in 0 ..< updates:
      let target = rootIds[i mod rootIds.len]
      seed.update(target, %*{"kind": "profile", "n": i mod perRing,
                            "state": "updated", "revision": i})
    seed.close()
    copyDir(seedDir, beforeDir)
    copyDir(seedDir, afterDir)

    let rootKey = parseBiggestUInt(($anchor).split(':')[0]).uint64
    let before = sample(beforeDir, root, anchor, rootKey, perRing, iters)
    var packed = open(dataDir = afterDir, diskBacked = true)
    let rootPack = packed.packDiskBackedRing(root)
    let orderPack = packed.packDiskBackedRing(related[0])
    let billingPack = packed.packDiskBackedRing(related[1])
    packed.close()
    let after = sample(afterDir, root, anchor, rootKey, perRing, iters)

    echo "== KoutenDB ring-local segment benchmark =="
    echo &"per_ring={perRing} updates={updates} iters={iters}"
    echo &"pack records={rootPack.records + orderPack.records + billingPack.records} " &
         &"bytes={rootPack.bytes + orderPack.bytes + billingPack.bytes}"
    printSample("before", before)
    printSample("after", after)
    echo &"result_sets point_same={before.pointBytes == after.pointBytes} " &
         &"segment_same={before.segmentRecords == after.segmentRecords} " &
         &"ring_same={before.ringItems == after.ringItems} " &
         &"stellar_same={before.stellarItems == after.stellarItems}"
    echo "note=fresh before/after directories; OS page cache is not dropped"
    if keep:
      echo &"data_root={rootDir}"
  finally:
    if not keep and dirExists(rootDir):
      removeDir(rootDir)

when isMainModule:
  main()
