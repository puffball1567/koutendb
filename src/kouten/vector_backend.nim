## kouten/vector_backend — dependency-free, ring-scoped exact vector search.

import std/[algorithm, tables]
import ./[field, store]

type
  VectorCandidate* = object
    parent*: uint64
    seq*: uint32
    tWrite*: float
    score*: float
    payload*: string
    codec*: PayloadCodec

  VectorSearchResult* = object
    totalVectors*: int
    scanned*: int
    skippedVectors*: int
    ringsTouched*: int
    payloadBytes*: int
    estimatedTokens*: int
    hits*: seq[VectorCandidate]

  VectorEntry = object
    parent: uint64
    seq: uint32
    tWrite: float
    vec: seq[float32]
    payload: string
    codec: PayloadCodec

  VectorLoc = object
    ring: uint64
    index: int

  VectorBackend* = ref object
    byRing: Table[uint64, seq[VectorEntry]]
    indexed: Table[(uint64, uint32), VectorLoc]
    vectorCount: int

proc newExactVectorBackend*(): VectorBackend =
  VectorBackend()

proc upsert*(b: VectorBackend, p: Particle) =
  if p.vec.len == 0:
    return
  let k = (p.parent, p.seq)
  if k in b.indexed:
    let loc = b.indexed[k]
    if loc.ring in b.byRing and loc.index >= 0 and loc.index < b.byRing[loc.ring].len:
      b.byRing[loc.ring][loc.index] =
        VectorEntry(parent: p.parent, seq: p.seq, tWrite: p.tWrite,
                    vec: p.vec, payload: p.payload, codec: p.codec)
    return
  let idx = b.byRing.mgetOrPut(p.parent, @[]).len
  b.byRing[p.parent].add VectorEntry(parent: p.parent, seq: p.seq,
                                     tWrite: p.tWrite, vec: p.vec,
                                     payload: p.payload, codec: p.codec)
  b.indexed[k] = VectorLoc(ring: p.parent, index: idx)
  inc b.vectorCount

proc remove*(b: VectorBackend, parent: uint64, seq: uint32) =
  let k = (parent, seq)
  if k notin b.indexed:
    return
  let loc = b.indexed[k]
  b.indexed.del k
  dec b.vectorCount
  if loc.ring in b.byRing:
    var entries = b.byRing[loc.ring]
    let last = entries.len - 1
    if loc.index >= 0 and loc.index <= last:
      if loc.index != last:
        entries[loc.index] = entries[last]
        b.indexed[(entries[loc.index].parent, entries[loc.index].seq)] =
          VectorLoc(ring: loc.ring, index: loc.index)
      entries.setLen(last)
    if entries.len == 0:
      b.byRing.del loc.ring
    else:
      b.byRing[loc.ring] = entries

proc clear*(b: VectorBackend) =
  b.byRing.clear()
  b.indexed.clear()
  b.vectorCount = 0

proc addTopCandidate(hits: var seq[VectorCandidate], cand: VectorCandidate, budget: int) =
  if budget <= 0:
    return
  if hits.len < budget:
    hits.add cand
    return
  var worst = 0
  for i in 1 ..< hits.len:
    if hits[i].score < hits[worst].score:
      worst = i
  if cand.score > hits[worst].score:
    hits[worst] = cand

proc search*(b: VectorBackend, st: Store, queryVec: seq[float32],
             hasRing: bool, ringKey: uint64, budget: int): VectorSearchResult =
  if queryVec.len == 0 or budget <= 0:
    return
  if st.diskBacked:
    result.totalVectors = st.vectorCount
    var rings = initTable[uint64, bool]()
    if hasRing:
      for p in st.particlesByRing(ringKey):
        if p.vec.len == 0:
          continue
        inc result.scanned
        rings[p.parent] = true
        let score = 1.0 - cosineDistance(queryVec, p.vec)
        result.hits.addTopCandidate(
          VectorCandidate(parent: p.parent, seq: p.seq, tWrite: p.tWrite,
                          score: score, payload: p.payload, codec: p.codec),
          budget)
    else:
      for p in st.allParticles():
        if p.vec.len == 0:
          continue
        inc result.scanned
        rings[p.parent] = true
        let score = 1.0 - cosineDistance(queryVec, p.vec)
        result.hits.addTopCandidate(
          VectorCandidate(parent: p.parent, seq: p.seq, tWrite: p.tWrite,
                          score: score, payload: p.payload, codec: p.codec),
          budget)
    result.ringsTouched = rings.len
    result.skippedVectors = max(0, result.totalVectors - result.scanned)
    result.hits.sort(proc(a, b: VectorCandidate): int = cmp(b.score, a.score))
    for h in result.hits:
      result.payloadBytes += h.payload.len
    result.estimatedTokens = (result.payloadBytes + 3) div 4
    return
  if hasRing:
    result.totalVectors = b.vectorCount
    var rings = initTable[uint64, bool]()
    for p in b.byRing.getOrDefault(ringKey, @[]):
      inc result.scanned
      rings[p.parent] = true
      let score = 1.0 - cosineDistance(queryVec, p.vec)
      result.hits.addTopCandidate(
        VectorCandidate(parent: p.parent, seq: p.seq, tWrite: p.tWrite,
                        score: score, payload: p.payload, codec: p.codec),
        budget)
    result.ringsTouched = rings.len
    result.skippedVectors = max(0, result.totalVectors - result.scanned)
    result.hits.sort(proc(a, b: VectorCandidate): int = cmp(b.score, a.score))
    for h in result.hits:
      result.payloadBytes += h.payload.len
    result.estimatedTokens = (result.payloadBytes + 3) div 4
    return

  var rings = initTable[uint64, bool]()
  result.totalVectors = b.vectorCount
  for ring, entries in b.byRing:
    for p in entries:
      inc result.scanned
      rings[ring] = true
      let score = 1.0 - cosineDistance(queryVec, p.vec)
      result.hits.addTopCandidate(
        VectorCandidate(parent: p.parent, seq: p.seq, tWrite: p.tWrite,
                        score: score, payload: p.payload, codec: p.codec),
        budget)
  result.ringsTouched = rings.len
  result.skippedVectors = max(0, result.totalVectors - result.scanned)
  result.hits.sort(proc(a, b: VectorCandidate): int = cmp(b.score, a.score))
  for h in result.hits:
    result.payloadBytes += h.payload.len
  result.estimatedTokens = (result.payloadBytes + 3) div 4

proc searchMany*(b: VectorBackend, st: Store, queryVec: seq[float32],
                 ringKeys: seq[uint64], budget: int): VectorSearchResult =
  if queryVec.len == 0 or budget <= 0:
    return
  if st.diskBacked:
    var allowed = initTable[uint64, bool]()
    for ring in ringKeys:
      allowed[ring] = true
    if allowed.len == 0:
      return b.search(st, queryVec, false, 0'u64, budget)
    result.totalVectors = st.vectorCount
    var rings = initTable[uint64, bool]()
    for ring in ringKeys:
      if ring notin allowed:
        continue
      allowed.del ring
      for p in st.particlesByRing(ring):
        if p.vec.len == 0:
          continue
        inc result.scanned
        rings[p.parent] = true
        let score = 1.0 - cosineDistance(queryVec, p.vec)
        result.hits.addTopCandidate(
          VectorCandidate(parent: p.parent, seq: p.seq, tWrite: p.tWrite,
                          score: score, payload: p.payload, codec: p.codec),
          budget)
    result.ringsTouched = rings.len
    result.skippedVectors = max(0, result.totalVectors - result.scanned)
    result.hits.sort(proc(a, b: VectorCandidate): int = cmp(b.score, a.score))
    for h in result.hits:
      result.payloadBytes += h.payload.len
    result.estimatedTokens = (result.payloadBytes + 3) div 4
    return
  var allowed = initTable[uint64, bool]()
  for ring in ringKeys:
    allowed[ring] = true
  if allowed.len == 0:
    return b.search(st, queryVec, false, 0'u64, budget)

  result.totalVectors = b.vectorCount
  var rings = initTable[uint64, bool]()
  for ring in ringKeys:
    if ring notin allowed:
      continue
    allowed.del ring
    for p in b.byRing.getOrDefault(ring, @[]):
      inc result.scanned
      rings[p.parent] = true
      let score = 1.0 - cosineDistance(queryVec, p.vec)
      result.hits.addTopCandidate(
        VectorCandidate(parent: p.parent, seq: p.seq, tWrite: p.tWrite,
                        score: score, payload: p.payload, codec: p.codec),
        budget)
  result.ringsTouched = rings.len
  result.skippedVectors = max(0, result.totalVectors - result.scanned)
  result.hits.sort(proc(a, b: VectorCandidate): int = cmp(b.score, a.score))
  for h in result.hits:
    result.payloadBytes += h.payload.len
  result.estimatedTokens = (result.payloadBytes + 3) div 4
