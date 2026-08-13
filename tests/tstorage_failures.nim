import std/[os, sequtils, strutils, tables, tempfiles, unittest]
import ../src/kouten/store

const
  MainRing = 801'u64
  OtherRing = 802'u64
  MainRecords = 8

proc seedStore(dir: string): Store =
  result = openStore(dir, durability = durStrong, diskBacked = true)
  result.putRingMeta(MainRing, 60.0, 0.1)
  result.putRingName(MainRing, "storage/main")
  result.putRingMeta(OtherRing, 120.0, 0.2)
  result.putRingName(OtherRing, "storage/other")
  for i in 0'u32 ..< MainRecords.uint32:
    result.upsert Particle(parent: MainRing, seq: i, period: 60.0,
                           head: 0.1, tWrite: float(i + 1),
                           payload: "main-" & $i)
  result.upsert Particle(parent: OtherRing, seq: 0, period: 120.0,
                         head: 0.2, tWrite: 20.0,
                         payload: "other")
  result.sync()

proc checkSeeded(st: Store) =
  check st.ringLiveCount(MainRing) == MainRecords
  check st.ringLiveCount(OtherRing) == 1
  for i in 0'u32 ..< MainRecords.uint32:
    check st.getParticle(MainRing, i).payload == "main-" & $i
  check st.getParticle(OtherRing, 0).payload == "other"

proc activePaths(st: Store; dir: string; ring: uint64):
    tuple[segment, index, manifest: string] =
  let report = st.segmentReport()
  let row = report.rings.filterIt(it.ring == ring)[0]
  let base = toHex(ring, 16) & ".g" & $row.generation
  result.segment = dir / "segments" / (base & ".seg")
  result.index = dir / "segments" / (base & ".idx")
  result.manifest = dir / "segments" / "manifest"

proc rewriteIndexWithWrongOffset(path: string) =
  var rows = readFile(path).splitLines()
  var first = -1
  var secondOffset = ""
  for i, row in rows:
    let parts = row.splitWhitespace()
    if parts.len == 5 and parts[0] == "P":
      if first < 0:
        first = i
      elif secondOffset.len == 0:
        secondOffset = parts[4]
  check first >= 0
  check secondOffset.len > 0
  var parts = rows[first].splitWhitespace()
  parts[4] = secondOffset
  rows[first] = parts.join(" ")
  writeFile(path, rows.join("\n"))

suite "storage failure matrix":
  test "disk-full failure is explicit and poisons later writes":
    let root = createTempDir("kouten-storage", "disk-full")
    var st = seedStore(root)
    let beforeBytes = st.logSize()
    st.failNextWalWriteForTest(twfDiskFull)
    expect IOError:
      st.upsert Particle(parent: MainRing, seq: 99, period: 60.0,
                         head: 0.1, tWrite: 99.0, payload: "rejected")
    check st.writeFailed
    check not st.contains(MainRing, 99)
    check st.logSize() == beforeBytes
    expect IOError:
      st.upsert Particle(parent: MainRing, seq: 100, period: 60.0,
                         head: 0.1, tWrite: 100.0, payload: "also-rejected")
    st.close()

    var reopened = openStore(root, durability = durStrong, diskBacked = true)
    reopened.checkSeeded()
    check not reopened.contains(MainRing, 99)
    reopened.upsert Particle(parent: MainRing, seq: 101, period: 60.0,
                             head: 0.1, tWrite: 101.0,
                             payload: "retry-ok")
    reopened.close()
    removeDir(root)

  test "short WAL tail is repaired without exposing the failed mutation":
    let root = createTempDir("kouten-storage", "short-write")
    var st = seedStore(root)
    let beforeBytes = st.logSize()
    st.failNextWalWriteForTest(twfShortWrite, shortBytes = 11)
    expect IOError:
      st.upsert Particle(parent: MainRing, seq: 99, period: 60.0,
                         head: 0.1, tWrite: 99.0, payload: "partial")
    check st.writeFailed
    check not st.contains(MainRing, 99)
    check st.logSize() > beforeBytes
    st.close()

    var reopened = openStore(root, durability = durStrong, diskBacked = true)
    reopened.checkSeeded()
    check not reopened.contains(MainRing, 99)
    check reopened.logSize() == beforeBytes
    reopened.upsert Particle(parent: MainRing, seq: 100, period: 60.0,
                             head: 0.1, tWrite: 100.0,
                             payload: "after-repair")
    reopened.close()
    removeDir(root)

  test "failed metadata persistence does not publish in-memory state":
    let root = createTempDir("kouten-storage", "metadata-failure")
    var st = seedStore(root)
    check st.ringNames[MainRing] == "storage/main"
    st.failNextWalWriteForTest(twfDiskFull)
    expect IOError:
      st.putRingName(MainRing, "storage/uncommitted")
    check st.writeFailed
    check st.ringNames[MainRing] == "storage/main"
    st.close()

    var reopened = openStore(root, durability = durStrong, diskBacked = true)
    check reopened.ringNames[MainRing] == "storage/main"
    reopened.close()
    removeDir(root)

  when not defined(windows):
    test "segment permission loss keeps the prior generation active":
      let root = createTempDir("kouten-storage", "permission-loss")
      let segmentDir = root / "segments"
      var st = seedStore(root)
      discard st.packRingSegment(MainRing)
      st.upsert Particle(parent: MainRing, seq: 0, period: 60.0,
                         head: 0.1, tWrite: 200.0, payload: "latest")
      setFilePermissions(segmentDir, {fpUserRead, fpUserExec})
      try:
        expect IOError:
          discard st.packRingSegment(MainRing)
      finally:
        setFilePermissions(segmentDir,
          {fpUserRead, fpUserWrite, fpUserExec})
      check st.getParticle(MainRing, 0).payload == "latest"
      st.close()

      var reopened = openStore(root, durability = durStrong,
                               diskBacked = true)
      check reopened.getParticle(MainRing, 0).payload == "latest"
      let before = reopened.segmentReport()
      check before.rings.anyIt(it.ring == MainRing and it.generation == 1)
      discard reopened.packRingSegment(MainRing)
      let after = reopened.segmentReport()
      check after.rings.anyIt(it.ring == MainRing and it.generation == 2)
      reopened.close()
      removeDir(root)

  test "missing active segment rebuilds from the authoritative WAL":
    let root = createTempDir("kouten-storage", "missing-segment")
    var st = seedStore(root)
    discard st.packRingSegment(MainRing)
    let paths = st.activePaths(root, MainRing)
    st.close()
    removeFile(paths.segment)

    var reopened = openStore(root, durability = durStrong, diskBacked = true)
    reopened.checkSeeded()
    let report = reopened.segmentReport()
    check report.walFallbacks == 0
    check report.rings.anyIt(it.ring == MainRing and it.coveredRecords == MainRecords)
    reopened.close()
    removeDir(root)

  test "damaged manifest never selects a mixed generation":
    let root = createTempDir("kouten-storage", "damaged-manifest")
    var st = seedStore(root)
    discard st.packRingSegment(MainRing)
    discard st.packRingSegment(OtherRing)
    let paths = st.activePaths(root, MainRing)
    st.close()
    writeFile(paths.manifest, "!KOUTENDB-SEGMENTS 1\ninvalid row\n")

    var reopened = openStore(root, durability = durStrong, diskBacked = true)
    reopened.checkSeeded()
    let report = reopened.segmentReport()
    check report.walFallbacks == 0
    check report.rings.allIt(it.coveredRecords == it.liveRecords)
    reopened.close()
    removeDir(root)

  test "index-only corruption falls back per record and preserves results":
    let root = createTempDir("kouten-storage", "index-corruption")
    var st = seedStore(root)
    discard st.packRingSegment(MainRing)
    let paths = st.activePaths(root, MainRing)
    st.close()
    rewriteIndexWithWrongOffset(paths.index)

    var reopened = openStore(root, durability = durStrong, diskBacked = true)
    reopened.checkSeeded()
    let report = reopened.segmentReport()
    check report.walFallbacks == 1
    check report.walFallbackReasons[ssfrPointRead] == 1
    check report.rings.anyIt(it.ring == MainRing and
                             it.coveredRecords == MainRecords - 1)
    reopened.close()
    removeDir(root)
