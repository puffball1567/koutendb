import std/[os, tempfiles, unittest]
import ../src/kouten/store

suite "ring segment manifest failpoints":
  test "interruption after one file replacement keeps the prior generation active":
    let dir = createTempDir("kouten-store", "segment-replace-failpoint")
    let ring = 90'u64
    var st = openStore(dir, diskBacked = true)
    for i in 0'u32 ..< 3'u32:
      st.upsert Particle(parent: ring, seq: i, period: 60.0, head: 0.0,
                         tWrite: float(i), payload: "base-" & $i)
    discard st.packRingSegment(ring)
    st.upsert Particle(parent: ring, seq: 1'u32, period: 60.0, head: 0.0,
                       tWrite: 10.0, payload: "latest")
    st.failSegmentPackAfterSegmentReplaceForTest(true)
    expect IOError:
      discard st.packRingSegment(ring)
    check st.getParticle(ring, 1'u32).payload == "latest"
    st.close()

    var reopened = openStore(dir, diskBacked = true)
    check reopened.getParticle(ring, 0'u32).payload == "base-0"
    check reopened.getParticle(ring, 1'u32).payload == "latest"
    check reopened.getParticle(ring, 2'u32).payload == "base-2"
    let before = reopened.segmentReport()
    check before.rings.len == 1
    check before.rings[0].generation == 1
    let packed = reopened.packRingSegment(ring)
    check packed.records == 3
    check packed.removedFiles >= 2
    reopened.close()

    var finalStore = openStore(dir, diskBacked = true)
    check finalStore.getParticle(ring, 1'u32).payload == "latest"
    let after = finalStore.segmentReport()
    check after.rings[0].generation == 2
    for path in walkFiles(dir / "segments" / "*.tmp"):
      checkpoint path
      check false
    finalStore.close()
    removeDir(dir)

  test "pre-manifest interruption keeps prior generations and other rings readable":
    let dir = createTempDir("kouten-store", "segment-pack-failpoint")
    let ring = 91'u64
    let otherRing = 92'u64
    var st = openStore(dir, diskBacked = true)
    st.upsert Particle(parent: ring, seq: 0'u32, period: 60.0, head: 0.0,
                       tWrite: 1.0, payload: "generation-0")
    st.upsert Particle(parent: otherRing, seq: 0'u32, period: 60.0, head: 0.0,
                       tWrite: 1.0, payload: "other-ring")
    discard st.packRingSegment(ring)
    discard st.packRingSegment(otherRing)
    st.upsert Particle(parent: ring, seq: 0'u32, period: 60.0, head: 0.0,
                       tWrite: 2.0, payload: "generation-1-update")
    st.failSegmentPackBeforeManifestForTest(true)
    expect IOError:
      discard st.packRingSegment(ring)
    st.close()

    var reopened = openStore(dir, diskBacked = true)
    check reopened.getParticle(ring, 0'u32).payload == "generation-1-update"
    check reopened.getParticle(otherRing, 0'u32).payload == "other-ring"
    let before = reopened.segmentReport(staleRatioThreshold = 0.0,
                                        minStaleRecords = 1)
    check before.rings.len == 2
    check before.rings[0].ring == ring
    check before.rings[0].generation == 1
    check before.rings[1].ring == otherRing
    check before.rings[1].generation == 1
    let packed = reopened.packRingSegment(ring)
    check packed.records == 1
    check packed.removedFiles >= 2
    reopened.close()

    var finalStore = openStore(dir, diskBacked = true)
    check finalStore.getParticle(ring, 0'u32).payload == "generation-1-update"
    check finalStore.getParticle(otherRing, 0'u32).payload == "other-ring"
    let after = finalStore.segmentReport()
    check after.rings[0].generation == 2
    check after.rings[1].generation == 1
    for path in walkFiles(dir / "segments" / "*.tmp"):
      checkpoint path
      check false
    finalStore.close()
    removeDir(dir)
