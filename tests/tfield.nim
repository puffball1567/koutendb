## kouten/field の単体テスト

import std/[math, tables, unittest]
import ../src/kouten/[field, store, vector_backend]

suite "retained vector candidate byte accounting":
  test "insert, replacement, rejection and zero budget preserve exact totals":
    var hits: seq[VectorCandidate] = @[]
    check hits.addTopCandidate(VectorCandidate(score: 1, payload: "abc"), 0) == 0
    check hits.len == 0
    var bytes = hits.addTopCandidate(VectorCandidate(score: 1, payload: "abc"), 2)
    bytes += hits.addTopCandidate(VectorCandidate(score: 2, payload: "defgh"), 2)
    check bytes == 8
    check hits.addTopCandidate(VectorCandidate(score: 0, payload: "ignored"), 2) == 0
    bytes += hits.addTopCandidate(VectorCandidate(score: 3, payload: "x"), 2)
    check bytes == 6
    bytes += hits.addTopCandidate(VectorCandidate(score: 4, payload: "abcdefg"), 2)
    check bytes == 8
    check hits.len == 2
    check hits[0].payload.len + hits[1].payload.len == bytes

proc vec2(x, y: float32): seq[float32] =
  normalize(@[x, y])

proc nearestAxis(v: seq[float32]): int =
  let axes = @[vec2(1, 0), vec2(0, 1), vec2(-1, 0)]
  var best = -1
  var bestD = Inf
  for i, a in axes:
    let d = cosineDistance(v, a)
    if d < bestD:
      bestD = d
      best = i
  best

suite "field micro-clustering":
  test "合成3クラスタを予算内で凝集する":
    var st = openStore("")
    let centers = @[vec2(1, 0), vec2(0, 1), vec2(-1, 0)]
    var seqNo = 0'u32
    for ci, c in centers:
      for j in 0 ..< 32:
        let jitter = float32(j mod 4) * 0.005'f32
        var v =
          case ci
          of 0: vec2(c[0], c[1] + jitter)
          of 1: vec2(c[0] + jitter, c[1])
          else: vec2(c[0], c[1] + jitter)
        st.upsert Particle(parent: HaloKey, seq: seqNo, period: 3600.0,
                           head: 0.0, tWrite: float(seqNo),
                           payload: "p", vec: v)
        inc seqNo

    let fs = newFieldState()
    fs.clusterTick(st, budget = 128, cMax = 16, rJoin = 0.08)

    check fs.clumps.len >= 3
    check fs.clumps.len <= 4

    var pure = 0
    var total = 0
    for c in fs.clumps:
      var counts: array[3, int]
      for id in c.members:
        inc counts[nearestAxis(st.items[id].vec)]
        inc total
      var m = 0
      for x in counts:
        m = max(m, x)
      pure += m
    check total == 96
    check float(pure) / float(total) > 0.9

  test "budget は1 tick の処理数を制限する":
    var st = openStore("")
    for i in 0'u32 ..< 20'u32:
      st.upsert Particle(parent: HaloKey, seq: i, period: 3600.0,
                         head: 0.0, tWrite: float(i),
                         payload: "p", vec: vec2(1, 0))
    let fs = newFieldState()
    fs.clusterTick(st, budget = 5, cMax = 4, rJoin = 0.2)
    check fs.assigned.len == 5

  test "捕獲条件を満たす clump は対象環へ adopt され forwarder が残る":
    var st = openStore("")
    let target = 42'u64
    st.putRingMeta(target, 60.0, 1.0)

    let fs = newFieldState()
    for i in 0'u32 ..< 64'u32:
      let v = vec2(1, float32(i mod 3) * 0.002'f32)
      st.upsert Particle(parent: target, seq: i, period: 60.0,
                         head: 1.0, tWrite: float(i),
                         payload: "r", vec: v)
      fs.observeRingPut(target, v)

    for i in 0'u32 ..< 24'u32:
      st.upsert Particle(parent: HaloKey, seq: i, period: 3600.0,
                         head: 0.0, tWrite: float(i),
                         payload: "h" & $i, vec: vec2(1, 0.001))

    fs.clusterTick(st, budget = 64, cMax = 8, rJoin = 0.05)
    check fs.clumps.len == 1

    for _ in 0 ..< 2:
      check fs.captureTick(st, now = 100.0, hTicks = 3,
                           nMin = 16, r0 = 0.1,
                           mCapture = 8.0, cMin = 0.5) == 0
    check fs.captureTick(st, now = 100.0, hTicks = 3,
                         nMin = 16, r0 = 0.1,
                         mCapture = 8.0, cMin = 0.5) == 1

    check fs.clumps.len == 0
    for i in 0'u32 ..< 24'u32:
      check not st.contains(HaloKey, i)
      check (HaloKey, i) in st.forwarders
      let f = st.forwarders[(HaloKey, i)]
      check f.newParent == target
      check st.contains(f.newParent, f.newSeq)
