## kouten/core の単体テスト（設計書 §12 Step 1 の完了条件を含む）

import std/[unittest, math]
import ../src/kouten/core

suite "wrap / angDist":
  test "正規化":
    check abs(wrap(-0.1) - (TAU - 0.1)) < 1e-12
    check abs(wrap(TAU + 0.2) - 0.2) < 1e-12
    check wrap(0.0) == 0.0
  test "円周距離":
    check abs(angDist(0.1, TAU - 0.1) - 0.2) < 1e-12

suite "theta / owner (fast 層)":
  test "円軌道の位置":
    let o = circular(1.0, 10.0)
    check abs(o.theta(2.5) - wrap(1.0 + TAU / 4.0)) < 1e-12
  test "弧の所有":
    let tbl = ArcTable(epoch: 1, nNodes: 8)
    check tbl.owner(0.0) == 0
    check tbl.owner(TAU - 1e-9) == 7
    check tbl.owner(PI) == 4
    check tbl.owner(PI - 1e-9) == 3
  test "明示 ArcTable でも弧境界と wrap が安定する":
    let tbl = ArcTable(
      epoch: 1,
      nNodes: 2,
      arcs: @[ArcOwner(start: 0.0, node: 0'u16),
              ArcOwner(start: PI, node: 1'u16)])
    tbl.validateArcTable()
    check tbl.owner(0.0) == 0
    check tbl.owner(PI - 1e-9) == 0
    check tbl.owner(PI) == 1
    check tbl.owner(TAU - 1e-9) == 1
    check tbl.owner(-0.1) == 1
  test "weightedArcTable は重みに応じた連続弧を作る":
    let tbl = weightedArcTable(1, [1, 3])
    check tbl.nNodes == 2
    check tbl.arcs.len == 2
    check abs(tbl.arcs[0].start - 0.0) < 1e-12
    check abs(tbl.arcs[1].start - TAU * 0.25) < 1e-12
    check tbl.owner(TAU * 0.24) == 0
    check tbl.owner(TAU * 0.26) == 1
    expect ValueError:
      discard weightedArcTable(1, [0, 0])
    expect ValueError:
      discard weightedArcTable(1, [1, -1])
  test "virtualArcTable はノード追加時の再配置率を等分割より下げる":
    let equal8 = equalArcTable(1, 8)
    let equal9 = equalArcTable(2, 9)
    let virt8 = virtualArcTable(1, 8, 64)
    let virt9 = virtualArcTable(2, 9, 64)
    check virt8.arcs.len == 8 * 64
    check virt9.arcs.len == 9 * 64
    virt8.validateArcTable()
    virt9.validateArcTable()
    let equalMoved = remapFraction(equal8, equal9, samples = 8192)
    let virtualMoved = remapFraction(virt8, virt9, samples = 8192)
    check equalMoved > 0.4
    check virtualMoved < 0.25
    check virtualMoved < equalMoved
  test "physical placement is stable while logical orbit advances":
    let tbl = virtualArcTable(7, 3, 64)
    let parent = 0x1234_5678_9abc_def0'u64
    let owner = tbl.placementOwner(parent)
    check placementAngle(parent) >= 0.0
    check placementAngle(parent) < TAU
    for t in [0.0, 60.0, 86_400.0, 1_000_000_000.0]:
      let orbit = OrbitalId(parent: parent, epoch: 7, tWrite: 1.0, seq: 9)
        .ringOrbit(60.0, 0.2)
      discard tbl.node(orbit, t)
      check tbl.placementOwner(parent) == owner
    check tbl.placementOwner(parent) ==
      virtualArcTable(7, 3, 64).placementOwner(parent)
  test "ArcTable validators reject malformed topology":
    expect ValueError:
      discard equalArcTable(1, 0)
    expect ValueError:
      discard virtualArcTable(1, 0)
    expect ValueError:
      discard virtualArcTable(1, 2, 0)
    expect ValueError:
      ArcTable(epoch: 1, nNodes: 2,
               arcs: @[ArcOwner(start: 0.2, node: 0'u16),
                       ArcOwner(start: 0.1, node: 1'u16)]).validateArcTable()
    expect ValueError:
      ArcTable(epoch: 1, nNodes: 2,
               arcs: @[ArcOwner(start: 0.0, node: 2'u16)]).validateArcTable()
    expect ValueError:
      discard remapFraction(equalArcTable(1, 1), equalArcTable(2, 1), samples = 0)
  test "e>0 でも単調（EMax の根拠）":
    let o = Orbit(a: 1.0, phi: 0.0, period: 10.0, e: EMax, pomega: 1.0)
    var prev = -1.0
    var unwrapped = 0.0
    var last = o.theta(0.0)
    for i in 1 .. 1000:
      let th = o.theta(float(i) * 0.005)
      var d = th - last
      if d < -PI: d += TAU
      unwrapped += d
      last = th
      check unwrapped > prev
      prev = unwrapped

suite "meanAtTheta / nextArrival (境界予測)":
  test "逆算の往復誤差 < 1e-9（e = 0 / 0.1 / 0.3）":
    for e in [0.0, 0.1, 0.3]:
      let o = Orbit(a: 1.0, phi: 0.0, period: 10.0, e: e, pomega: 1.2)
      for i in 0 ..< 100:
        let m = float(i) / 100.0 * TAU
        let th = wrap(m + 2.0 * e * sin(m - o.pomega))
        check angDist(o.meanAtTheta(th), m) < 1e-9
  test "到着時刻: 円軌道の厳密解":
    let o = circular(0.0, 10.0)
    check abs(o.nextArrival(PI, 1.0) - 5.0) < 1e-9
  test "到着時刻: e=0.3 でも θ(t_arr) = target":
    let o = Orbit(a: 1.0, phi: 0.4, period: 10.0, e: 0.3, pomega: 2.0)
    let target = 2.0
    let ta = o.nextArrival(target, 3.7)
    check ta >= 3.7
    check angDist(o.theta(ta), target) < 1e-9

suite "OrbitalId (自己記述ID)":
  test "書き込み時はヘッド位置、1回転後にヘッドへ戻る":
    let id = OrbitalId(parent: 1, epoch: 1, tWrite: 12.3, seq: 0)
    let head = 0.9
    let o = id.ringOrbit(60.0, head)
    check angDist(o.theta(12.3), head) < 1e-9
    check angDist(o.theta(12.3 + 60.0), head) < 1e-9
    check angDist(o.theta(12.3 + 30.0), wrap(head + PI)) < 1e-9

suite "会合 (§8)":
  test "会合周期":
    check abs(synodicPeriod(30.0, 60.0) - 60.0) < 1e-12
  test "1:2 共鳴の会合時刻列と同一ノード性":
    let o1 = circular(0.0, 1.0)
    let o2 = circular(0.0, 2.0)
    let ts = conjunctions(o1, o2, 0.0, 5.0)
    check ts == @[0.0, 2.0, 4.0]
    let tbl = ArcTable(epoch: 1, nNodes: 8)
    for t in ts:
      check tbl.node(o1, t) == tbl.node(o2, t)
      check angDist(o1.theta(t), o2.theta(t)) < 1e-9
  test "位相差ありでも一致":
    let o1 = circular(0.3, 30.0)
    let o2 = circular(5.5, 60.0)
    let tbl = ArcTable(epoch: 1, nNodes: 8)
    let ts = conjunctions(o1, o2, 0.0, 240.0)
    check ts.len == 4   # T_syn = 60s
    for t in ts:
      check tbl.node(o1, t) == tbl.node(o2, t)
