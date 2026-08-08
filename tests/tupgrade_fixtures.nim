import std/[algorithm, json, os, sequtils, strutils, tempfiles,
            unittest]
import ../src/koutendb

const FixtureRoot = currentSourcePath().parentDir / "fixtures"

type UpgradeFixture = object
  release: string
  initialGeneration: uint64

const UpgradeFixtures = [
  UpgradeFixture(release: "v0.10.1", initialGeneration: 0'u64),
  UpgradeFixture(release: "v0.11.0", initialGeneration: 1'u64)
]

proc copyTree(source, destination: string) =
  createDir(destination)
  for kind, path in walkDir(source):
    let target = destination / path.extractFilename
    case kind
    of pcFile:
      copyFile(path, target)
    of pcDir:
      copyTree(path, target)
    else:
      raise newException(IOError, "upgrade fixture contains unsupported path: " & path)

proc normalizedDump(path: string; portable = false): seq[string] =
  for line in lines(path):
    if line.strip.len == 0:
      continue
    var node = parseJson(line)
    if portable:
      if node{"type"}.getStr == "meta":
        continue
      if node{"type"}.getStr == "ring":
        continue
      for field in ["id", "parent", "seq", "epoch", "tWrite", "period", "head"]:
        node.delete(field)
    result.add $node
  result.sort()

proc ringRecords(db: KoutenDb; ring: string): seq[KoutenRecord] =
  var options = defaultReadOptions()
  options.limit = 100
  options.sortField = "id"
  options.sortDirection = rsAsc
  db.readRing(ring, options).items

proc verifyLogicalContents(db: KoutenDb) =
  check db.getGalaxyDescription() == "upgrade compatibility fixture"
  check db.getRingDescription("users/123/profile") == "Current user profile"
  check db.ringPayloadProfile("codecs/nif") == RingPayloadProfile(
    defaultCodec: pcNif, charset: "UTF-8", formatVersion: "5")
  check db.ringPayloadProfile("codecs/bif") == RingPayloadProfile(
    defaultCodec: pcBif, charset: "binary", formatVersion: "5")

  let profiles = db.ringRecords("users/123/profile")
  check profiles.len == 1
  check profiles[0].codec == pcJson
  check parseJson(profiles[0].payload) == %*{
    "kind": "profile", "userId": 123, "name": "Ada Lovelace",
    "active": true
  }

  let orders = db.ringRecords("users/123/orders")
  check orders.len == 1
  check parseJson(orders[0].payload){"orderId"}.getStr == "A-100"

  let notifications = db.ringRecords("users/123/notifications")
  check notifications.len == 2
  check notifications.mapIt(parseJson(it.payload){"message"}.getStr).sorted ==
    @["first", "second"]

  let raw = db.ringRecords("codecs/raw")
  check raw.len == 1
  check raw[0].codec == pcRaw
  check raw[0].payload == "raw\0payload"
  let nif = db.ringRecords("codecs/nif")
  check nif.len == 1
  check nif[0].codec == pcNif
  check nif[0].payload == "(object (title \"NIF fixture\"))"
  let bif = db.ringRecords("codecs/bif")
  check bif.len == 1
  check bif[0].codec == pcBif
  check bif[0].payload == "BIF\0fixture\x01\x7f"

  let events = db.ringRecords("events/2026/08")
  check events.len == 19
  let sequences = events.mapIt(parseJson(it.payload){"sequence"}.getInt).sorted
  check 5 notin sequences
  check sequences[0] == 0
  check sequences[^1] == 19

proc generationFor(status: KoutenSegmentStatus; ring: string): uint64 =
  for item in status.rings:
    if item.ring == ring:
      return item.generation
  raise newException(KeyError, "missing segment status for " & ring)

suite "release upgrade fixtures":
  for fixture in UpgradeFixtures:
    test fixture.release & " opens, migrates, exports, and restores":
      let root = createTempDir("kouten-upgrade", fixture.release)
      let source = root / "source"
      let fixtureDir = FixtureRoot / fixture.release
      copyTree(fixtureDir / "data", source)

      let initialManifest = source / "segments" / "manifest"
      if fixture.initialGeneration == 0:
        check not fileExists(initialManifest)
        check fileExists(source / "segments" / "A2BEF6F1C7113CF5.seg")
      else:
        check fileExists(initialManifest)

      var db = open(nodes = 4, dataDir = source, durability = durStrong,
                    diskBacked = true)
      db.verifyLogicalContents()
      let beforePack = db.segmentStatus(minStaleRecords = 0)
      check beforePack.generationFor("events/2026/08") ==
        fixture.initialGeneration

      # Exercise the release's physical read layout before explicitly moving
      # the fixture to a new current-format generation.
      check db.ringRecords("events/2026/08").len == 19
      check db.segmentStatus(minStaleRecords = 0).segmentHits > 0

      discard db.packDiskBackedRing("events/2026/08")
      let afterPack = db.segmentStatus(minStaleRecords = 0)
      check afterPack.generationFor("events/2026/08") ==
        fixture.initialGeneration + 1
      check fileExists(initialManifest)

      let currentDump = root / "current.jsonl"
      let dumpStats = db.dump(currentDump)
      check dumpStats.documents == 26
      check dumpStats.rings == 12
      check normalizedDump(currentDump) ==
        normalizedDump(fixtureDir / "original-dump.jsonl")

      let checkpoint = db.createCheckpoint(root / "checkpoints", "upgraded")
      check checkpoint.verified
      check verifyCheckpoint(checkpoint.path).verified
      db.close()

      let offline = operationalVerify(source, diskBacked = true)
      check offline.ok
      check offline.items == 26
      check offline.rings == 12

      let restoredDir = root / "restored"
      let restoredStatus = restoreCheckpoint(checkpoint.path, restoredDir)
      check restoredStatus.verified
      var restored = open(nodes = 4, dataDir = restoredDir,
                          durability = durStrong, diskBacked = true)
      restored.verifyLogicalContents()
      let restoredDump = root / "restored.jsonl"
      discard restored.dump(restoredDump)
      check normalizedDump(restoredDump) == normalizedDump(currentDump)
      restored.close()
      check operationalVerify(restoredDir, diskBacked = true).ok

      let importedDir = root / "imported"
      var imported = open(nodes = 4, dataDir = importedDir,
                          durability = durStrong, diskBacked = true)
      let importedStats = imported.importJsonl(currentDump, batchSize = 7,
                                                packSegments = true)
      check importedStats.imported == 26
      check importedStats.errors == 0
      let importedDump = root / "imported.jsonl"
      discard imported.dump(importedDump)
      check normalizedDump(importedDump, portable = true) ==
        normalizedDump(currentDump, portable = true)
      imported.close()
      check operationalVerify(importedDir, diskBacked = true).ok

      removeDir(root)
