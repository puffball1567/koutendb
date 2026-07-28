## 手動結合テスト: koutend 3ノード起動後に実行する。

import std/[json, os, unittest]
import ../src/koutendb

suite "cluster transaction":
  test "landing intent commit 後に owner へ apply される":
    let peers = getEnv("KOUTEN_TEST_PEERS", "127.0.0.1:7411,127.0.0.1:7412,127.0.0.1:7413")
    var db = connect(peers)
    let tx = db.beginTransaction()
    let id = tx.put("cluster tx value", ring = "cluster-tx", vec = @[1.0'f32, 0.0'f32])
    tx.commit(wamApplied)

    check db.get(id) == "cluster tx value"
    db.close()

  test "ring-scoped cluster retrieve は owner の候補だけを評価する":
    let peers = getEnv("KOUTEN_TEST_PEERS", "127.0.0.1:7411,127.0.0.1:7412,127.0.0.1:7413")
    var db = connect(peers)
    discard db.put("ret-ai-1", ring = "ret-ai", vec = @[0.0'f32, 1.0'f32])
    discard db.put("ret-ai-2", ring = "ret-ai", vec = @[0.1'f32, 0.9'f32])
    discard db.put("ret-db-1", ring = "ret-db", vec = @[1.0'f32, 0.0'f32])

    var hits: seq[KoutenHit] = @[]
    for _ in 0 ..< 30:
      hits = db.retrieve(@[0.0'f32, 1.0'f32], ring = "ret-ai", budget = 2)
      if hits.len == 2:
        break
      sleep(100)
    check hits.len == 2
    check hits[0].payload == "ret-ai-1"
    let st = db.retrieveStats(@[0.0'f32, 1.0'f32], ring = "ret-ai", budget = 2)
    check st.scanned >= 2
    check st.returned == 2
    check st.fanoutNodes == 1

    let rings = db.ringSummaries(@[0.0'f32, 1.0'f32])
    check rings.len >= 2
    check rings[0].count >= 2
    let narrowed = db.retrieve(@[0.0'f32, 1.0'f32], budget = 2, topRings = 1)
    check narrowed.len == 2
    check narrowed[0].payload == "ret-ai-1"
    db.close()

  test "cluster transaction preserves payload codec through owner apply":
    let peers = getEnv("KOUTEN_TEST_PEERS", "127.0.0.1:7411,127.0.0.1:7412,127.0.0.1:7413")
    var db = connect(peers)
    let tx = db.beginTransaction()
    let id = tx.put(encodedPayload("(object (kind artifact))", pcNif),
                    ring = "cluster-codec", vec = @[0.0'f32, 1.0'f32])
    tx.commit(wamApplied)
    check db.getEncoded(id) == encodedPayload("(object (kind artifact))", pcNif)
    let hits = db.retrieve(@[0.0'f32, 1.0'f32], ring = "cluster-codec", budget = 1)
    check hits.len == 1
    check hits[0].codec == pcNif
    db.close()

  test "cluster update/delete/list/count は landing intent 経由で反映される":
    let peers = getEnv("KOUTEN_TEST_PEERS", "127.0.0.1:7411,127.0.0.1:7412,127.0.0.1:7413")
    var db = connect(peers)
    let a = db.put(%*{"name": "a"}, ring = "cluster-crud")
    let b = db.put(%*{"name": "b"}, ring = "cluster-crud")

    db.configureRingWriteAckMode("cluster-crud", wamApplied)
    db.update(a, %*{"name": "a2"})
    check db.query(a, "{ name }") == %*{"name": "a2"}
    check db.batchGet(@[a])[0] == $(%*{"name": "a2"})

    var listed = false
    for _ in 0 ..< 40:
      let page = db.listByRing("cluster-crud", limit = 10)
      if page.items.len >= 2 and db.countByRing("cluster-crud") >= 2:
        listed = true
        break
      sleep(100)
    check listed

    db.deleteById(b)
    expect KeyError:
      discard db.batchGet(@[b])
    var gone = false
    for _ in 0 ..< 40:
      try:
        discard db.get(b)
      except KeyError:
        gone = true
        break
      sleep(100)
    check gone

    var counted = false
    for _ in 0 ..< 40:
      if db.countByRing("cluster-crud") == 1:
        counted = true
        break
      sleep(100)
    check counted
    db.close()
