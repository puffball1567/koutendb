import std/[algorithm, math, random, strutils, unittest]
import ../src/kouten/[field, store, vector_backend]

proc sameCandidates(a, b: seq[VectorCandidate]): bool =
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i].parent != b[i].parent or a[i].seq != b[i].seq or
        a[i].payload != b[i].payload or a[i].codec != b[i].codec:
      return false
    if a[i].score != b[i].score and not (a[i].score.isNaN and b[i].score.isNaN):
      return false
  true

suite "exact vector top-k materialization":
  test "retained-byte deltas preserve shrinking replacements and rejected payloads":
    let query = @[1.0'f32, 0.0'f32]
    var hits: seq[VectorCandidate]
    check hits.addExactCandidate(Particle(vec: @[0.0'f32, 1.0'f32],
      payload: repeat('x', 1024)), query, 1) == 1024
    check hits.addExactCandidate(Particle(vec: query, payload: "a"), query, 1) == -1023
    check hits.addExactCandidate(Particle(vec: @[0.0'f32, 1.0'f32],
      payload: repeat('y', 10000)), query, 1) == 0
    check hits.addExactCandidate(Particle(vec: query, payload: "tie"), query, 1) == 0
    check hits.len == 1
    check hits[0].payload == "a"

  test "incremental selection matches legacy scores, ties, invalid dimensions and owned payloads":
    var rng = initRand(731)
    var particles: seq[Particle]
    for i in 0 ..< 150:
      var v: seq[float32]
      for _ in 0 ..< 16:
        v.add float32(rng.rand(2.0) - 1.0)
      particles.add Particle(parent: uint64(1 + i mod 3), seq: uint32(i),
        vec: v.normalize(), payload: $i & "\x00" & repeat('x', 4096), codec: pcRaw)
    particles.add Particle(parent: 9, seq: 0, vec: particles[0].vec, payload: "tie")
    particles.add Particle(parent: 9, seq: 1, vec: @[1.0'f32], payload: "different dimension")
    particles.add Particle(parent: 9, seq: 2, vec: @[NaN.float32], payload: "nan dimension")
    for budget in [0, 1, 3, 16, 200]:
      for q in [particles[0].vec, particles[50].vec, @[1.0'f32], @[NaN.float32]]:
        var legacy, optimized: seq[VectorCandidate]
        var retainedBytes = 0
        for p in particles:
          let expectedDelta = legacy.addTopCandidate(p.exactCandidate(q), budget)
          let actualDelta = optimized.addExactCandidate(p, q, budget)
          check actualDelta == expectedDelta
          retainedBytes += actualDelta
          var expectedBytes = 0
          for hit in optimized:
            expectedBytes += hit.payload.len
          check retainedBytes == expectedBytes
          check sameCandidates(legacy, optimized)

  test "embedded global and multi-ring results match a brute-force exact reference":
    var rng = initRand(119)
    var st = openStore("")
    defer: st.close()
    let backend = newExactVectorBackend()
    var particles: seq[Particle]
    for i in 0 ..< 100:
      var v: seq[float32]
      for _ in 0 ..< 24:
        v.add float32(rng.rand(2.0) - 1.0)
      let p = Particle(parent: uint64(i mod 4 + 1), seq: uint32(i),
                       vec: v.normalize(), payload: "payload-" & $i)
      particles.add p
      st.upsert p
      backend.upsert p
    for q in [particles[17].vec, particles[61].vec]:
      for selected in [newSeq[uint64](), @[1'u64, 3'u64]]:
        var expected: seq[VectorCandidate]
        var scanned = 0
        for p in particles:
          if selected.len == 0 or p.parent in selected:
            inc scanned
            expected.addTopCandidate(p.exactCandidate(q), 5)
        expected.sort(proc(a, b: VectorCandidate): int = cmp(b.score, a.score))
        let actual = backend.searchMany(st, q, selected, 5)
        check actual.scanned == scanned
        check sameCandidates(actual.hits, expected)
