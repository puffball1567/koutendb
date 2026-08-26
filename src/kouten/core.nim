## kouten/core — ephemeris 評価の fast 層（設計書 §1–§2, §8）
##
## 規律: `theta`/`owner`/`node` が fast 層のすべて。sin 1回＋弧表引きで所在が出る。
## 質量（m_i / m_g）はこのモジュールに一切登場しない（設計書 §5:
## 質量は elements を書き換える slow 層の力であって、位置計算には効かせない）。

import std/[math, algorithm]

export math.TAU   # 角度定数は math のものを使う（独自定義は識別子衝突のもと）

const
  EMax* = 0.3
    ## 離心率の上限（設計書 §1 歯止め）。一次近似 θ = M + 2e·sin(M−ϖ) の
    ## 誤差 O(e²) と dθ/dM = 1 + 2e·cos > 0（単調・可逆）を保つ範囲に制限する。

type
  NodeId* = uint16

  Orbit* = object
    ## 軌道要素（設計書 §1）。
    a*: float        ## 帯。Heavy: 円盤半径=重要度シェル / Particle: 環の温度半径（§4）
    phi*: float      ## t=0 での平均経度 [rad]
    period*: float   ## 公転周期 T [s]。Heavy は事実上 Inf（固定, §6.2）
    e*: float        ## 滞在偏り（0=均等, ≤ EMax）
    pomega*: float   ## 近点角 ϖ。滞在が最長になる遠点は ϖ + π

  ArcOwner* = object
    ## Arc start and owner node. The arc owns `[start, nextStart)`.
    start*: float
    node*: NodeId

  ArcTable* = object
    ## epoch ごとのリング弧所有表（§9）。
    ## `arcs` が空の場合は従来互換の等分割弧。`arcs` がある場合は
    ## start angle -> owner node の persisted/virtual arc table として使う。
    epoch*: uint32
    nNodes*: uint16
    arcs*: seq[ArcOwner]

  OrbitalId* = object
    ## 自己記述ID（§2.2）: elements は id から計算する。粒子ごとの所在表は存在しない。
    parent*: uint64
    epoch*: uint32
    tWrite*: float
    seq*: uint32

proc wrap*(x: float): float {.inline.} =
  ## [0, 2π) へ正規化
  result = x mod TAU
  if result < 0.0: result += TAU

proc angDist*(x, y: float): float =
  ## 円周上の距離（テスト・検証用）
  let d = wrap(x - y)
  min(d, TAU - d)

proc circular*(phi, period: float): Orbit =
  Orbit(a: 1.0, phi: phi, period: period, e: 0.0, pomega: 0.0)

# ---------------------------------------------------------------- fast 層

proc meanLongitude*(o: Orbit, t: float): float {.inline.} =
  ## M(t) = φ + 2π·t/T
  wrap(o.phi + TAU * t / o.period)

proc theta*(o: Orbit, t: float): float {.inline.} =
  ## θ(t) = M + 2e·sin(M − ϖ) — 中心差の一次近似（設計書 §1）。sin 1回で終わる。
  let m = o.meanLongitude(t)
  wrap(m + 2.0 * o.e * sin(m - o.pomega))

proc arcWidth*(tbl: ArcTable): float {.inline.} =
  ## Average arc width. Equal tables use this as the exact width.
  if tbl.arcs.len > 0: TAU / float(tbl.arcs.len)
  else: TAU / float(tbl.nNodes)

proc arcStart*(tbl: ArcTable, n: NodeId): float =
  ## Representative boundary for a node. Equal tables return the exact node
  ## boundary; custom arc tables return the first persisted arc for the node.
  if tbl.arcs.len == 0:
    return float(n) * tbl.arcWidth
  result = Inf
  for arc in tbl.arcs:
    if arc.node == n:
      result = min(result, arc.start)
  if result == Inf:
    result = float(n) * TAU / float(max(1'u16, tbl.nNodes))

proc owner*(tbl: ArcTable, th: float): NodeId =
  let angle = wrap(th)
  if tbl.arcs.len == 0:
    return NodeId(int(angle / TAU * float(tbl.nNodes)) mod int(tbl.nNodes))

  var lo = 0
  var hi = tbl.arcs.len
  while lo < hi:
    let mid = (lo + hi) div 2
    if tbl.arcs[mid].start <= angle:
      lo = mid + 1
    else:
      hi = mid
  if lo == 0: tbl.arcs[^1].node else: tbl.arcs[lo - 1].node

proc node*(tbl: ArcTable, o: Orbit, t: float): NodeId {.inline.} =
  ## node(id, t) = arc_owner(θ(t)) — 誰にも問い合わせない所在解決（概念書 2章）
  tbl.owner(o.theta(t))

proc validateArcTable*(tbl: ArcTable) =
  if tbl.nNodes == 0:
    raise newException(ValueError, "ArcTable requires at least one node")
  if tbl.arcs.len == 0:
    return
  var prev = -1.0
  for arc in tbl.arcs:
    if arc.start < 0.0 or arc.start >= TAU:
      raise newException(ValueError, "arc start must be in [0, TAU)")
    if arc.start <= prev:
      raise newException(ValueError, "arc starts must be strictly increasing")
    if arc.node >= tbl.nNodes:
      raise newException(ValueError, "arc owner is outside nNodes")
    prev = arc.start

proc equalArcTable*(epoch: uint32, nNodes: uint16): ArcTable =
  result = ArcTable(epoch: epoch, nNodes: nNodes)
  result.validateArcTable()

proc weightedArcTable*(epoch: uint32; weights: openArray[int]): ArcTable =
  ## Build a persisted arc table from node weights. Each positive weight
  ## receives one contiguous arc sized by weight / totalWeight.
  if weights.len == 0:
    raise newException(ValueError, "weightedArcTable requires at least one weight")
  var total = 0
  for w in weights:
    if w < 0:
      raise newException(ValueError, "node weights must be non-negative")
    total += w
  if total <= 0:
    raise newException(ValueError, "at least one node weight must be positive")

  result = ArcTable(epoch: epoch, nNodes: uint16(weights.len))
  var at = 0.0
  for node, w in weights:
    if w <= 0:
      continue
    result.arcs.add ArcOwner(start: at, node: NodeId(node))
    at += TAU * float(w) / float(total)
  result.validateArcTable()

proc mix64(x: uint64): uint64 =
  var z = x + 0x9e3779b97f4a7c15'u64
  z = (z xor (z shr 30)) * 0xbf58476d1ce4e5b9'u64
  z = (z xor (z shr 27)) * 0x94d049bb133111eb'u64
  z xor (z shr 31)

proc placementAngle*(parent: uint64): float {.inline.} =
  ## Stable physical coordinate for one ring. Logical orbital position remains
  ## time-dependent; physical ownership deliberately does not.
  let h = mix64(parent)
  let unit = float(h shr 11) / float(1'u64 shl 53)
  unit * TAU

proc placementOwner*(tbl: ArcTable, parent: uint64): NodeId {.inline.} =
  tbl.owner(parent.placementAngle)

proc virtualArcTable*(epoch: uint32, nNodes: uint16,
                      virtualArcsPerNode = 64): ArcTable =
  ## Build a deterministic virtual-arc table. Existing node/slot arc positions
  ## stay stable when a new node is added, so membership changes move only the
  ## ranges captured by the new node's virtual arcs instead of remapping the
  ## whole equal-division table.
  if nNodes == 0:
    raise newException(ValueError, "virtualArcTable requires at least one node")
  if virtualArcsPerNode <= 0:
    raise newException(ValueError, "virtualArcsPerNode must be positive")
  result = ArcTable(epoch: epoch, nNodes: nNodes)
  for node in 0 ..< int(nNodes):
    for slot in 0 ..< virtualArcsPerNode:
      let h = mix64((uint64(node) shl 32) xor uint64(slot))
      let unit = float(h shr 11) / float(1'u64 shl 53)
      result.arcs.add ArcOwner(start: unit * TAU, node: NodeId(node))
  result.arcs.sort(proc(a, b: ArcOwner): int = cmp(a.start, b.start))
  result.validateArcTable()

proc remapFraction*(oldTable, newTable: ArcTable; samples = 4096): float =
  ## Estimate how much of the angle space changes owner between two tables.
  ## This is a topology-planning metric, not a runtime routing primitive.
  if samples <= 0:
    raise newException(ValueError, "samples must be positive")
  var changed = 0
  for i in 0 ..< samples:
    let th = (float(i) + 0.5) * TAU / float(samples)
    if oldTable.owner(th) != newTable.owner(th):
      inc changed
  float(changed) / float(samples)

# ---------------------------------------------------------------- slow パス（予測・逆算）

proc meanAtTheta*(o: Orbit, target: float): float =
  ## θ = target となる平均経度 M の逆算（境界予測・滞在比計算用の slow パス）。
  ## dθ/dM = 1 + 2e·cos ≥ 1 − 2·EMax > 0 なので単調で、Newton 反復が安全に収束する。
  var m = target
  for _ in 0 ..< 20:
    let f = m + 2.0 * o.e * sin(m - o.pomega) - target
    if abs(f) < 1e-12: break
    m -= f / (1.0 + 2.0 * o.e * cos(m - o.pomega))
  wrap(m)

proc nextArrival*(o: Orbit, target: float, t: float): float =
  ## t 以降で θ が target 角に到達する最初の時刻。
  ## ハンドオフの事前転送（§6.1）と弾道プリフェッチ（概念書 2.3③）の基礎。
  let mNow = o.meanLongitude(t)
  let mTarget = o.meanAtTheta(target)
  var dm = mTarget - mNow
  if dm < 0.0: dm += TAU
  t + dm / TAU * o.period

# ---------------------------------------------------------------- OrbitalId（§2.2）

proc ringOrbit*(id: OrbitalId, ringPeriod: float, headAngle: float = 0.0,
                aInner: float = 0.0): Orbit =
  ## 粒子は書き込み時刻のヘッド位置（環ごとの固定角 headAngle）に追記され、
  ## プラッタと共に公転する:
  ##   θ_p(t) = headAngle + 2π·(t − tWrite)/T
  ## ちょうど1回転後にヘッド下へ戻る＝ヘッドは粒子を時系列順に舐める
  ## （§4.2「1回転=1エポック」）。所在は id・親の周期・ヘッド角だけから出る
  ## （親情報は almanac にあるので、粒子ごとの所在表は不要 = §2.2）。
  Orbit(a: aInner, phi: wrap(headAngle - TAU * id.tWrite / ringPeriod),
        period: ringPeriod, e: 0.0, pomega: 0.0)

# ---------------------------------------------------------------- 会合（§8）

proc synodicPeriod*(t1, t2: float): float =
  ## T_syn = T₁T₂ / |T₁ − T₂|
  t1 * t2 / abs(t1 - t2)

proc conjunctions*(o1, o2: Orbit, fromT, horizon: float): seq[float] =
  ## e=0 の2軌道が同角度（⇒同弧⇒同ノード⇒ローカル JOIN 窓）になる時刻列。閉じた式。
  if o1.e != 0.0 or o2.e != 0.0:
    raise newException(ValueError,
      "conjunctions requires circular orbits; use nextArrival for e > 0")
  let rate = TAU * (1.0 / o1.period - 1.0 / o2.period)
  if rate == 0.0:
    raise newException(ValueError,
      "conjunctions is undefined for equal orbital periods")
  # φ₁ + 2π·t/T₁ = φ₂ + 2π·t/T₂ + 2π·k を t について解く
  let dphi = o2.phi - o1.phi
  let tEnd = fromT + horizon
  let kA = (rate * fromT - dphi) / TAU
  let kB = (rate * tEnd - dphi) / TAU
  result = @[]
  for k in int(ceil(min(kA, kB))) .. int(floor(max(kA, kB))):
    result.add (dphi + TAU * float(k)) / rate
  result.sort()

proc conjunctionWindow*(tbl: ArcTable, o1, o2: Orbit): float =
  ## 会合を挟んで両者が同一弧に留まる連続時間。
  ## 導出: 会合点を含む弧を速い方が通過する時間に等しく、会合点の弧内位置に依らない
  ##   window = 弧幅 / max(ω₁, ω₂)
  tbl.arcWidth / max(TAU / o1.period, TAU / o2.period)
