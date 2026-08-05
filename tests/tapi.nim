## 公開 API（src/koutendb.nim）のテスト

import std/[json, os, sequtils, strutils, tempfiles, tables, times, unittest]
import ../src/koutendb

suite "public api":
  test "put/get の往復":
    var db = open()
    let id = db.put("hello")
    check db.get(id) == "hello"
    check id in db
    db.close()

  test "payload codecs are selectable and JSON projection is format-aware":
    var db = open()
    let rawId = db.put(encodedPayload("raw\0bytes", pcRaw))
    let jsonId = db.put(%*{"title": "KoutenDB", "private": true})
    let nifId = db.put(encodedPayload("(object (title KoutenDB))", pcNif))
    let bifId = db.put(encodedPayload("\x01\x00\x00\x00", pcBif))

    check db.getEncoded(rawId) == encodedPayload("raw\0bytes", pcRaw)
    check db.getEncoded(jsonId).codec == pcJson
    check db.getEncoded(nifId).codec == pcNif
    check db.getEncoded(bifId).codec == pcBif

    let prepared = prepareSelection("{ title }")
    check db.query(jsonId, prepared) == %*{"title": "KoutenDB"}
    expect ValueError:
      discard db.query(nifId, prepared)
    expect ValueError:
      discard db.query(bifId, prepared)
    db.close()

  test "ring payload profile persists and can drive explicit writes":
    let dir = createTempDir("koutendb", "ring-profile")
    var db = open(dataDir = dir)
    let profile = RingPayloadProfile(defaultCodec: pcBif,
      charset: "", formatVersion: "1")
    db.configureRingPayloadProfile("artifacts", profile)
    check db.ringPayloadProfile("artifacts") == profile
    let id = db.putUsingRingProfile("\x01\x02\x03", ring = "artifacts")
    check db.getEncoded(id) == encodedPayload("\x01\x02\x03", pcBif)
    db.close()

    var reopened = open(dataDir = dir)
    check reopened.ringPayloadProfile("artifacts") == profile
    check reopened.getEncoded(id).codec == pcBif
    discard reopened.compact()
    reopened.close()

    var compacted = open(dataDir = dir)
    check compacted.ringPayloadProfile("artifacts") == profile
    check compacted.getEncoded(id).codec == pcBif
    compacted.close()
    removeDir(dir)

  test "time orbit profile places and reads log records by calculated buckets":
    let dir = createTempDir("koutendb", "time-orbit")
    var db = open(dataDir = dir)
    let apiProfile = TimeOrbitProfile(bits: 60, bucketMs: 1000'i64,
                                      phase: 100'u64, salt: "api")
    let auditProfile = TimeOrbitProfile(bits: 60, bucketMs: 1000'i64,
                                        phase: 10000'u64, salt: "audit")
    db.configureTimeOrbitProfile("logs/api", apiProfile)
    db.configureTimeOrbitProfile("logs/audit", auditProfile)
    check db.timeOrbitProfile("logs/api") == apiProfile
    check timeOrbitRing("logs/api", apiProfile, 2500) == "logs/api/@time/102"
    check timeOrbitRing("logs/audit", auditProfile, 2500) == "logs/audit/@time/10002"

    discard db.putTime(%*{"level": "info", "message": "boot"}, "logs/api", 1200)
    discard db.putTime(%*{"level": "error", "message": "timeout"}, "logs/api", 2500)
    discard db.putTime(%*{"level": "error", "message": "too-late"}, "logs/api", 4200)
    discard db.putTime(%*{"level": "error", "message": "audit"}, "logs/audit", 2500)

    let page = db.readTime("logs/api", 1000, 3000, KoutenReadOptions(
      filter: %*{"level": "error"},
      selection: "{ level message eventTimeMs }",
      limit: 10,
      sortField: "time",
      sortDirection: rsAsc))
    check page.bucketsVisited == 3
    check page.rings == @["logs/api/@time/101", "logs/api/@time/102", "logs/api/@time/103"]
    check page.count == 1
    check parseJson(page.items[0].payload) == %*{
      "level": "error",
      "message": "timeout",
      "eventTimeMs": 2500
    }
    db.close()

    var reopened = open(dataDir = dir)
    check reopened.timeOrbitProfile("logs/api") == apiProfile
    check reopened.readTime("logs/api", 1000, 3000, KoutenReadOptions(
      filter: %*{"level": "error"},
      limit: 10,
      sortField: "time",
      sortDirection: rsAsc)).count == 1
    reopened.close()
    removeDir(dir)

  test "locate は決定論的で、未来も計算できる":
    var db = open(nodes = 8)
    let id = db.put("x", ring = "logs")
    let n0 = db.locate(id)
    check n0 == db.locate(id, at = 0.0)
    # 時計を進めても、過去に計算した未来位置と一致する（ephemeris の核）
    let predicted = db.locate(id, at = 42.0)
    db.advance(42.0)
    check db.locate(id) == predicted
    db.close()

  test "半周期後には反対側のノードにいる":
    var db = open(nodes = 8)
    db.configureRing("r", 60.0)
    let id = db.put("x", ring = "r")
    let n0 = db.locate(id, at = 0.0)
    let nHalf = db.locate(id, at = 30.0)
    check (n0 + 4) mod 8 == nHalf
    db.close()

  test "nextVisit の時刻に本当に到着する":
    var db = open(nodes = 8)
    let id = db.put("x")
    let target = (db.locate(id) + 3) mod 8
    let ta = db.nextVisit(id, target)
    check ta >= db.now
    check db.locate(id, at = ta + 1e-6) == target
    db.close()

  test "nextJoin: 1:2 共鳴の2件が同一ノードで会合する":
    var db = open(nodes = 8)
    db.configureRing("docs", 30.0)
    db.configureRing("logs", 60.0)
    let a = db.put("doc", ring = "docs")
    let b = db.put("log", ring = "logs")
    let tj = db.nextJoin(a, b)
    check tj >= 0.0
    check db.locate(a, at = tj) == db.locate(b, at = tj)
    db.close()

  test "nextJoin: 同周期・非同居は -1":
    var db = open(nodes = 8)
    db.configureRing("p", 60.0)
    db.configureRing("q", 60.0)
    let a = db.put("x", ring = "p")
    let b = db.put("y", ring = "q")
    let tj = db.nextJoin(a, b)
    if db.locate(a) == db.locate(b):
      check tj == db.now
    else:
      check tj == -1.0
    db.close()

  test "環は自動作成され、別環は別ヘッド角を持つ":
    var db = open(nodes = 8)
    let a = db.put("1", ring = "alpha")
    let b = db.put("2", ring = "beta")
    check db.get(a) == "1"
    check db.get(b) == "2"
    db.close()

  test "write ack mode は DB 全体と ring 単位で設定できる":
    var db = open()
    db.configureWriteAckMode(wamAccepted)
    db.configureRingWriteAckMode("profile", wamApplied)
    let id = db.put("p", ring = "profile")
    check db.get(id) == "p"
    db.close()

  test "write guardrails reject unsafe payload, vector, ring, and ring-count growth":
    var db = open()
    expect KoutenValidationError:
      db.configureGuardrails(KoutenGuardrails(maxPayloadBytes: -1))
    expect ValueError:
      db.configureGuardrails(KoutenGuardrails(maxPayloadBytes: -1))

    db.configureGuardrails(KoutenGuardrails(maxPayloadBytes: 4,
                                           maxVectorDim: 2,
                                           maxRingCount: 2,
                                           maxRecordsPerRing: 2))
    check db.guardrails().maxPayloadBytes == 4
    discard db.put("ok", ring = "a", vec = @[1.0'f32, 0.0'f32])
    discard db.put("ok", ring = "b")

    expect KoutenGuardrailError:
      discard db.put("large", ring = "a")
    expect ValueError:
      discard db.put("large", ring = "a")
    expect ValueError:
      discard db.put("ok", ring = "a", vec = @[1.0'f32, 0.0'f32, 0.0'f32])
    expect ValueError:
      discard db.put("ok", ring = "c")

    discard db.put("ok", ring = "a")
    expect ValueError:
      discard db.put("ok", ring = "a")

    let ids = db.listByRing("a").items
    check ids.len == 2
    expect ValueError:
      db.update(ids[0].id, "large")
    db.close()

  test "write guardrails cover transaction and atomic batch staging":
    var db = open()
    db.configureGuardrails(KoutenGuardrails(maxPayloadBytes: 8,
                                           maxRecordsPerRing: 1))

    expect ValueError:
      discard db.batchPutAtomic(@["one", "two"], ring = "guarded")
    check db.countByRing("guarded") == 0

    let tx = db.beginTransaction()
    try:
      discard tx.put("one", ring = "guarded")
      expect ValueError:
        discard tx.put("two", ring = "guarded")
      tx.rollback()
    except CatchableError:
      tx.rollback()
      raise
    check db.countByRing("guarded") == 0
    db.close()

  test "halo は予約リングとして使える":
    var db = open(nodes = 8)
    let id = db.put("stray", ring = "halo", vec = @[3.0'f32, 4.0'f32])
    check db.get(id) == "stray"
    check db.locate(id, at = 0.0) >= 0
    db.close()

  test "ORM 下地 API: list/count/update/patch/delete/batch":
    var db = open()
    let ids = db.batchPut(@[
      %*{"name": "a", "meta": {"n": 1}},
      %*{"name": "b", "meta": {"n": 2}},
      %*{"name": "c", "meta": {"n": 3}}
    ], ring = "users")
    check ids.len == 3
    check db.countByRing("users") == 3

    let page1 = db.listByRing("users", limit = 2)
    check page1.items.len == 2
    check page1.items[0].payload.contains("\"name\":\"a\"")
    check page1.nextCursor.len > 0
    let page2 = db.listByRing("users", limit = 2, cursor = page1.nextCursor)
    check page2.items.len == 1
    check page2.items[0].payload.contains("\"name\":\"c\"")
    check page2.nextCursor.len == 0

    let read1 = db.readRing("users", KoutenReadOptions(
      filter: %*{"name": "b"},
      selection: "{ name }",
      limit: 10,
      sortField: "id",
      sortDirection: rsAsc))
    check read1.count == 1
    check read1.items.len == 1
    check parseJson(read1.items[0].payload) == %*{"name": "b"}

    let readLimited = db.readRing("users", KoutenReadOptions(
      filter: newJObject(),
      limit: 10,
      sortField: "id",
      sortDirection: rsAsc))
    check readLimited.items.len == 3
    check readLimited.count == 3

    let readPaged = db.readRing("users", KoutenReadOptions(
      filter: newJObject(),
      pagination: rpOn,
      page: 2,
      pageLimit: 2,
      sortField: "id",
      sortDirection: rsAsc))
    check readPaged.items.len == 1
    check readPaged.count == 1
    check readPaged.pagination == rpOn
    check readPaged.page == 2
    check readPaged.pageLimit == 2

    let raw0 = ids[0].toRaw()
    let raw0Text = $raw0.parent & ":" & $raw0.epoch & ":" &
      $raw0.seq & ":" & $raw0.tWrite
    let readById = db.readRing("users", KoutenReadOptions(
      filter: %*{"id": raw0Text},
      limit: 10))
    check readById.count == 1
    check readById.items[0].id == ids[0]

    let readMissing = db.readRing("users", KoutenReadOptions(
      filter: %*{"name": "missing"},
      limit: 10))
    check readMissing.count == 0
    check readMissing.items.len == 0

    let readAlias = db.readRing("users", KoutenReadOptions(
      filter: newJObject(),
      limit: 2,
      sortField: "write",
      sortDirection: rsDesc))
    check readAlias.sortField == "time"
    check readAlias.sortDirection == rsDesc
    check readAlias.items.len == 2

    let readDefaulted = db.readRing("users", KoutenReadOptions(
      filter: newJObject(),
      limit: 0,
      pageLimit: 0,
      page: 0))
    check readDefaulted.page == 1
    check readDefaulted.pageLimit == 100
    check readDefaulted.items.len == 3

    expect ValueError:
      discard db.readRing("users", KoutenReadOptions(
        filter: newJObject(),
        limit: 10,
        sortField: "unsupported"))

    let bifDoc = db.put(encodedPayload("\x01\x02\x03", pcBif), ring = "binary")
    check db.getEncoded(bifDoc).codec == pcBif
    expect ValueError:
      discard db.readRing("binary", KoutenReadOptions(
        selection: "{ title }",
        limit: 1))

    let baseFilter = koutenFilter().eq("name", "a")
    let extendedFilter = baseFilter.eq("meta", %*{"n": 1})
    check baseFilter.toJson() == %*{"name": "a"}
    check extendedFilter.toJson() == %*{"name": "a", "meta": {"n": 1}}

    let builtRead = db.readRing("users", defaultReadOptions().withFilter(
      koutenFilter().eq("name", "b").eq("meta", %*{"n": 2})))
    check builtRead.count == 1
    check parseJson(builtRead.items[0].payload)["name"].getStr() == "b"

    let typedBool = db.put(%*{"name": "flagged", "active": true, "age": 7},
                           ring = "typed")
    let typedRead = db.readRing("typed", KoutenReadOptions(
      filter: koutenFilter().eq("active", true).eq("age", 7).toJson(),
      limit: 10,
      sortField: "id",
      sortDirection: rsAsc))
    check typedRead.count == 1
    check typedRead.items[0].id == typedBool

    let byBuilderId = db.readRing("users", defaultReadOptions().withFilter(
      koutenFilter().id(ids[1])))
    check byBuilderId.count == 1
    check byBuilderId.items[0].id == ids[1]

    expect ValueError:
      discard koutenFilter().eq("", "bad")

    db.update(ids[0], %*{"name": "a2", "meta": {"n": 10}})
    check db.query(ids[0], "{ name }") == %*{"name": "a2"}
    let patched = db.patch(ids[0], %*{"meta": {"ok": true}, "name": nil})
    check patched == %*{"meta": {"n": 10, "ok": true}}

    check db.exists(ids[1])
    db.deleteById(ids[1])
    check not db.exists(ids[1])
    check db.countByRing("users") == 2

    db.batchDelete(@[ids[0], ids[2]])
    check db.countByRing("users") == 0
    db.close()

  test "stellar neighborhood reads nearby rings from either side":
    var db = open()
    let profile = db.put(%*{"kind": "user", "name": "alice"}, ring = "users/123")
    let order = db.putNear("users/123", %*{"kind": "order", "orderNo": "A-001"},
                           ring = "orders")
    let billing = db.putNear("users/123", %*{"kind": "billing", "plan": "pro"},
                             ring = "billing")
    let distant = db.put(%*{"kind": "order", "orderNo": "B-999"}, ring = "users/999/orders")

    let stellar = db.readStellar("users/123", KoutenStellarOptions(
      filter: newJObject(),
      selection: "{ kind }",
      limitPerRing: 10,
      maxDepth: 1,
      includeRoot: true,
      sortField: "id",
      sortDirection: rsAsc))
    check stellar.count == 3
    var sawRoot = false
    var sawOrders = false
    var sawBilling = false
    var sawDistant = false
    for ringPage in stellar.rings:
      if ringPage.ring == "users/123": sawRoot = true
      if ringPage.ring == "users/123/orders": sawOrders = true
      if ringPage.ring == "users/123/billing": sawBilling = true
      if ringPage.ring == "users/999/orders": sawDistant = true
    check sawRoot
    check sawOrders
    check sawBilling
    check not sawDistant

    let fromOrders = db.readStellar("users/123/orders", KoutenStellarOptions(
      filter: newJObject(),
      selection: "{ kind }",
      limitPerRing: 10,
      maxDepth: 1,
      includeRoot: true,
      sortField: "id",
      sortDirection: rsAsc))
    var ordersSawUser = false
    var ordersSawOrder = false
    var ordersSawDistant = false
    for ringPage in fromOrders.rings:
      if ringPage.ring == "users/123": ordersSawUser = true
      if ringPage.ring == "users/123/orders": ordersSawOrder = true
      if ringPage.ring == "users/999/orders": ordersSawDistant = true
    check ordersSawUser
    check ordersSawOrder
    check not ordersSawDistant

    let onlyOrders = db.readStellar("users/123", KoutenStellarOptions(
      filter: newJObject(),
      limitPerRing: 10,
      maxDepth: 1,
      subrings: @["orders"],
      includeRoot: false,
      sortField: "id",
      sortDirection: rsAsc))
    check onlyOrders.count == 1
    check onlyOrders.rings.len == 1
    check onlyOrders.rings[0].ring == "users/123/orders"
    check onlyOrders.rings[0].items[0].id == order
    check profile.toRaw().parent != order.toRaw().parent
    check nearRing("users/123", "orders") == "users/123/orders"
    check billing.toRaw().parent != distant.toRaw().parent

    discard db.putNear("users/123", %*{"kind": "order", "orderNo": "A-002"},
                       ring = "orders")
    discard db.putNear("users/123", %*{"kind": "order", "orderNo": "A-003"},
                       ring = "orders")
    discard db.putNear("users/123", %*{"kind": "billing", "plan": "team"},
                       ring = "billing")
    var perSubringLimits = initTable[string, int]()
    perSubringLimits["orders"] = 2
    perSubringLimits["billing"] = 1
    var perSubringSort = initTable[string, string]()
    perSubringSort["orders"] = "id"
    var perSubringSortDirections = initTable[string, KoutenReadSortDirection]()
    perSubringSortDirections["orders"] = rsAsc
    let tunedSubrings = db.readStellar("users/123", KoutenStellarOptions(
      filter: newJObject(),
      limitPerRing: 10,
      subringLimits: perSubringLimits,
      subringSortFields: perSubringSort,
      subringSortDirections: perSubringSortDirections,
      maxDepth: 1,
      subrings: @["orders", "billing"],
      includeRoot: false,
      sortField: "time",
      sortDirection: rsDesc))
    var tunedOrders = 0
    var tunedBilling = 0
    for ringPage in tunedSubrings.rings:
      if ringPage.ring == "users/123/orders":
        tunedOrders = ringPage.items.len
        check ringPage.items[0].id == order
      if ringPage.ring == "users/123/billing":
        tunedBilling = ringPage.items.len
    check tunedOrders == 2
    check tunedBilling == 1
    var latestLimit = initTable[string, int]()
    latestLimit["orders"] = 1
    var latestSort = initTable[string, string]()
    latestSort["orders"] = "time"
    var latestSortDirections = initTable[string, KoutenReadSortDirection]()
    latestSortDirections["orders"] = rsDesc
    let latestOrder = db.readStellar("users/123", KoutenStellarOptions(
      filter: newJObject(),
      limitPerRing: 10,
      subringLimits: latestLimit,
      subringSortFields: latestSort,
      subringSortDirections: latestSortDirections,
      maxDepth: 1,
      subrings: @["orders"],
      includeRoot: false,
      sortField: "id",
      sortDirection: rsAsc))
    check latestOrder.count == 1
    check parseJson(latestOrder.rings[0].items[0].payload)["orderNo"].getStr() == "A-003"
    db.close()

  test "stellar attach/detach links existing coordinates without copying data":
    let dir = createTempDir("koutendb", "stellar")
    var db = open(dataDir = dir)
    discard db.put(%*{"kind": "user", "id": "123"}, ring = "users/123")
    discard db.put(%*{"kind": "shop", "id": "1123"}, ring = "shops/1123")
    discard db.put(%*{"kind": "order", "id": "A-001", "userId": "123", "shopId": "1123"},
                   ring = "orders/A-001")

    db.attachStellar("commerce/order/A-001", "users/123")
    db.attachStellar("commerce/order/A-001", "shops/1123")
    db.attachStellar("commerce/order/A-001", "orders/A-001")
    check db.stellarMembers("commerce/order/A-001").len == 3

    let fromStellar = db.readStellar("commerce/order/A-001", KoutenStellarOptions(
      filter: newJObject(),
      limitPerRing: 10,
      maxDepth: 1,
      includeRoot: true,
      sortField: "id",
      sortDirection: rsAsc))
    check fromStellar.count == 3

    let fromShop = db.readStellar("shops/1123", defaultStellarOptions().withFilter(
      koutenFilter().eq("kind", "user")))
    check fromShop.count == 1
    check fromShop.rings[0].ring == "users/123"

    let usersOnly = db.readStellar("commerce/order/A-001", KoutenStellarOptions(
      filter: newJObject(),
      limitPerRing: 10,
      maxDepth: 1,
      subrings: @["users"],
      includeRoot: false,
      sortField: "id",
      sortDirection: rsAsc))
    check usersOnly.count == 1
    check usersOnly.rings[0].ring == "users/123"
    db.close()

    var reopened = open(dataDir = dir)
    check reopened.stellarMembers("commerce/order/A-001").len == 3
    reopened.detachStellar("commerce/order/A-001", "users/123")
    let afterDetach = reopened.readStellar("shops/1123", KoutenStellarOptions(
      filter: %*{"kind": "user"},
      limitPerRing: 10,
      maxDepth: 1,
      includeRoot: true,
      sortField: "id",
      sortDirection: rsAsc))
    check afterDetach.count == 0
    reopened.close()
    removeDir(dir)

  test "warp は小惑星帯のように登録順で少しずつ patch を落とす":
    var db = open()
    let a1 = db.put(%*{"orderId": "o1", "status": "paid"},
                    ring = "orders/2026/07/06")
    let a2 = db.put(%*{"orderId": "o2", "status": "paid"},
                    ring = "orders/2026/07/06")
    let b1 = db.put(%*{"orderId": "o1", "status": "paid"},
                    ring = "users/u1/orders")

    let jobId = db.enqueueWarp(
      @["orders/2026/07/06", "users/u1/orders"],
      "orderId",
      %"o1",
      %*{"status": "refunded"})
    let queued = db.warpStatus(jobId)
    check queued.status == wsPending
    check queued.maxAttempts == 8
    check queued.attempts == 0
    check not queued.acknowledged

    let first = db.warpStep(jobId, maxRecords = 1)
    check first.status == wsRunning
    check first.scanned == 1
    check first.updated == 1
    check db.query(a1, "{ status }") == %*{"status": "refunded"}
    check db.query(a2, "{ status }") == %*{"status": "paid"}
    check db.query(b1, "{ status }") == %*{"status": "paid"}

    let done = db.warpDrain(jobId, maxRecordsPerStep = 1)
    check done.status == wsDone
    check done.scanned == 3
    check done.updated == 2
    check db.query(a1, "{ status }") == %*{"status": "refunded"}
    check db.query(a2, "{ status }") == %*{"status": "paid"}
    check db.query(b1, "{ status }") == %*{"status": "refunded"}

    let duplicateJob = db.enqueueWarp(
      @["orders/2026/07/06", "users/u1/orders"],
      "orderId",
      %"o1",
      %*{"status": "refunded"})
    let duplicate = db.warpDrain(duplicateJob, maxRecordsPerStep = 10)
    check duplicate.status == wsDone
    check duplicate.matched == 2
    check duplicate.updated == 0

    let acked = db.ackWarp(jobId)
    check acked.acknowledged
    db.close()

  test "warp job は WAL から進捗と ack 状態を復元する":
    let dir = createTempDir("kouten-warp", "persist")
    var db = open(dataDir = dir)
    let a1 = db.put(%*{"orderId": "o1", "status": "paid"},
                    ring = "orders/2026/07/06")
    let a2 = db.put(%*{"orderId": "o1", "status": "paid"},
                    ring = "users/u1/orders")
    let jobId = db.enqueueWarp(
      @["orders/2026/07/06", "users/u1/orders"],
      "orderId",
      %"o1",
      %*{"status": "refunded"},
      maxAttempts = 3)
    let first = db.warpStep(jobId, maxRecords = 1)
    check first.status == wsRunning
    check first.scanned == 1
    db.close()

    var reopened = open(dataDir = dir)
    let resumed = reopened.warpStatus(jobId)
    check resumed.status == wsRunning
    check resumed.scanned == 1
    check resumed.maxAttempts == 3
    check not resumed.acknowledged
    let done = reopened.warpDrain(jobId, maxRecordsPerStep = 1)
    check done.status == wsDone
    check done.updated == 2
    check reopened.query(a1, "{ status }") == %*{"status": "refunded"}
    check reopened.query(a2, "{ status }") == %*{"status": "refunded"}
    discard reopened.ackWarp(jobId)
    reopened.close()

    var reopened2 = open(dataDir = dir)
    check reopened2.warpStatus(jobId).acknowledged
    check reopened2.pruneAckedWarpJobs() == 1
    expect KeyError:
      discard reopened2.warpStatus(jobId)
    reopened2.close()

    var reopened3 = open(dataDir = dir)
    expect KeyError:
      discard reopened3.warpStatus(jobId)
    reopened3.close()
    removeDir(dir)

  test "universe sync event は WAL で復元され idempotent に適用できる":
    let srcDir = createTempDir("kouten-universe", "src")
    let dstDir = createTempDir("kouten-universe", "dst")

    var src = open(dataDir = srcDir)
    let eventId = src.enqueueUniverseSyncEvent(
      sourceUniverse = "tokyo",
      sourceGalaxy = "social",
      ring = "posts/u1",
      payload = """{"post":"hello","createdAt":"2026-07-07T00:00:00Z"}""",
      logicalKey = "post-1")
    check src.universeSyncEvents().len == 1
    src.close()

    var resumed = open(dataDir = srcDir)
    let events = resumed.universeSyncEvents()
    check events.len == 1
    check events[0].id == eventId
    check events[0].ring == "posts/u1"

    var dst = open(dataDir = dstDir)
    check dst.applyUniverseSyncEvent(events[0])
    check not dst.applyUniverseSyncEvent(events[0])
    check dst.countByRing("posts/u1") == 1
    dst.close()

    discard resumed.ackUniverseSyncEvent(eventId)
    check resumed.pruneAckedUniverseSyncEvents() == 1
    resumed.close()

    var resumed2 = open(dataDir = srcDir)
    check resumed2.universeSyncEvents().len == 0
    resumed2.close()

    removeDir(srcDir)
    removeDir(dstDir)

  test "universe sync preserves an opaque payload codec":
    let srcDir = createTempDir("kouten-universe", "codec-src")
    let dstDir = createTempDir("kouten-universe", "codec-dst")
    var src = open(dataDir = srcDir)
    discard src.enqueueUniverseSyncEvent(
      sourceUniverse = "tokyo",
      sourceGalaxy = "models",
      ring = "artifacts/nif",
      payload = "(object (name KoutenDB))",
      codec = pcNif,
      logicalKey = "artifact-1")
    src.close()

    var resumed = open(dataDir = srcDir)
    let event = resumed.universeSyncEvents()[0]
    check event.codec == pcNif
    var dst = open(dataDir = dstDir)
    check dst.applyUniverseSyncEvent(event)
    let item = dst.listByRing("artifacts/nif", limit = 1).items[0]
    check item.codec == pcNif
    check item.payload == "(object (name KoutenDB))"
    resumed.close()
    dst.close()
    removeDir(srcDir)
    removeDir(dstDir)

  test "syncUniverseOnce は source outbox から target へ配送して ack/prune できる":
    let srcDir = createTempDir("kouten-universe", "sync-src")
    let dstDir = createTempDir("kouten-universe", "sync-dst")

    var src = open(dataDir = srcDir)
    var dst = open(dataDir = dstDir)
    discard src.enqueueUniverseSyncEvent(
      sourceUniverse = "tokyo",
      sourceGalaxy = "repo",
      ring = "issues/repo-1",
      payload = """{"issue":1,"title":"sync me"}""",
      logicalKey = "issue-1")

    let stats = syncUniverseOnce(src, dst, pruneAcked = true)
    check stats.read == 1
    check stats.applied == 1
    check stats.acked == 1
    check stats.pruned == 1
    check stats.errors == 0
    check src.universeSyncEvents().len == 0
    check dst.countByRing("issues/repo-1") == 1

    let stats2 = syncUniverseOnce(src, dst, pruneAcked = true)
    check stats2.read == 0
    check stats2.applied == 0
    src.close()
    dst.close()

    removeDir(srcDir)
    removeDir(dstDir)

  test "putSynced は local put と universe outbox 登録を同時に行う":
    let dir = createTempDir("kouten-universe", "putsynced")
    var db = open(dataDir = dir)
    let id = db.putSynced("""{"name":"Ada"}""",
                          sourceUniverse = "tokyo",
                          sourceGalaxy = "users",
                          ring = "users/u1",
                          logicalKey = "user:u1")
    check db.get(id) == """{"name":"Ada"}"""
    let events = db.universeSyncEvents()
    check events.len == 1
    check events[0].ring == "users/u1"
    check events[0].logicalKey == "user:u1"
    db.close()
    removeDir(dir)

  test "putSynced は prune と再起動後も universe event id を再利用しない":
    let srcDir = createTempDir("kouten-universe", "putsynced-seq-src")
    let dstDir = createTempDir("kouten-universe", "putsynced-seq-dst")
    var src = open(dataDir = srcDir)
    var dst = open(dataDir = dstDir)
    discard src.putSynced("""{"name":"Ada"}""",
                          sourceUniverse = "tokyo",
                          sourceGalaxy = "users",
                          ring = "users/u1",
                          logicalKey = "user:u1")
    let stats = syncUniverseOnce(src, dst, pruneAcked = true)
    check stats.applied == 1
    check stats.pruned == 1
    check src.universeSyncEvents().len == 0
    src.close()
    dst.close()

    src = open(dataDir = srcDir)
    discard src.putSynced("""{"name":"Grace"}""",
                          sourceUniverse = "tokyo",
                          sourceGalaxy = "users",
                          ring = "users/u2",
                          logicalKey = "user:u2")
    let events = src.universeSyncEvents()
    check events.len == 1
    check events[0].id == 2'u64
    src.close()
    removeDir(srcDir)
    removeDir(dstDir)

  test "putSynced latest-only coalesce は local write と outbox replacement を同時に commit する":
    let dir = createTempDir("kouten-universe", "putsynced-latest")
    var db = open(dataDir = dir)
    db.configureRingApplyPolicy("profiles/u1",
      RingApplyPolicy(mode: ramLatestOnly, historyKeep: 1, delayMs: 0))
    discard db.putSynced("""{"name":"old"}""",
                         sourceUniverse = "tokyo",
                         sourceGalaxy = "users",
                         ring = "profiles/u1",
                         logicalKey = "profile:u1")
    discard db.putSynced("""{"name":"new"}""",
                         sourceUniverse = "tokyo",
                         sourceGalaxy = "users",
                         ring = "profiles/u1",
                         logicalKey = "profile:u1")
    check db.countByRing("profiles/u1") == 2
    var events = db.universeSyncEvents()
    check events.len == 1
    check events[0].id == 2'u64
    check events[0].payload == """{"name":"new"}"""
    db.close()

    db = open(dataDir = dir)
    events = db.universeSyncEvents()
    check db.countByRing("profiles/u1") == 2
    check events.len == 1
    check events[0].id == 2'u64
    check events[0].payload == """{"name":"new"}"""
    db.close()
    removeDir(dir)

  test "latest-only ring policy は未配送 outbox を logical key で畳み込む":
    let srcDir = createTempDir("kouten-universe", "latest-src")
    let dstDir = createTempDir("kouten-universe", "latest-dst")

    var src = open(dataDir = srcDir)
    src.configureRingApplyPolicy("profiles/u1",
      RingApplyPolicy(mode: ramLatestOnly, historyKeep: 1, delayMs: 0))
    discard src.enqueueUniverseSyncEvent(
      sourceUniverse = "tokyo",
      sourceGalaxy = "users",
      ring = "profiles/u1",
      payload = """{"name":"old"}""",
      logicalKey = "profile:u1",
      timestamp = 1.0)
    discard src.enqueueUniverseSyncEvent(
      sourceUniverse = "tokyo",
      sourceGalaxy = "users",
      ring = "profiles/u1",
      payload = """{"name":"new"}""",
      logicalKey = "profile:u1",
      timestamp = 2.0)
    check src.universeSyncEvents().len == 1

    var dst = open(dataDir = dstDir)
    let stats = syncUniverseOnce(src, dst, pruneAcked = true)
    check stats.read == 1
    check stats.applied == 1
    check dst.countByRing("profiles/u1") == 1
    let page = dst.listByRing("profiles/u1", limit = 10)
    check page.items[0].payload == """{"name":"new"}"""
    src.close()
    dst.close()

    removeDir(srcDir)
    removeDir(dstDir)

  test "delayed timestamp ring policy は ready になるまで ack しない":
    let srcDir = createTempDir("kouten-universe", "delay-src")
    let dstDir = createTempDir("kouten-universe", "delay-dst")

    var src = open(dataDir = srcDir)
    var dst = open(dataDir = dstDir)
    dst.configureRingApplyPolicy("audit/u1",
      RingApplyPolicy(mode: ramDelayedTimestamp, historyKeep: 1, delayMs: 60_000))
    discard src.enqueueUniverseSyncEvent(
      sourceUniverse = "tokyo",
      sourceGalaxy = "audit",
      ring = "audit/u1",
      payload = """{"event":"login"}""",
      logicalKey = "audit:u1:1")

    let delayed = syncUniverseOnce(src, dst, pruneAcked = true)
    check delayed.read == 1
    check delayed.skipped == 1
    check delayed.acked == 0
    check delayed.pruned == 0
    check src.universeSyncEvents().len == 1
    check dst.countByRing("audit/u1") == 0

    dst.configureRingApplyPolicy("audit/u1",
      RingApplyPolicy(mode: ramDelayedTimestamp, historyKeep: 1, delayMs: 0))
    let applied = syncUniverseOnce(src, dst, pruneAcked = true)
    check applied.read == 1
    check applied.applied == 1
    check applied.acked == 1
    check applied.pruned == 1
    check src.universeSyncEvents().len == 0
    check dst.countByRing("audit/u1") == 1
    src.close()
    dst.close()

    removeDir(srcDir)
    removeDir(dstDir)

  test "universe sync retry accounting gates dispatch and dead-letters":
    let srcDir = createTempDir("kouten-universe", "retry-src")
    let dstDir = createTempDir("kouten-universe", "retry-dst")

    var src = open(dataDir = srcDir)
    var dst = open(dataDir = dstDir)
    let eventId = src.enqueueUniverseSyncEvent(
      sourceUniverse = "tokyo",
      sourceGalaxy = "audit",
      ring = "audit/u1",
      payload = """{"event":"retry"}""",
      logicalKey = "audit:u1:retry")

    let firstFailure = src.markUniverseSyncFailure(eventId, "target down")
    check firstFailure.attempts == 1
    check firstFailure.retryAt > epochTime()
    check not firstFailure.deadLetter
    check not universeSyncDispatchable(firstFailure)

    let waiting = syncUniverseOnce(src, dst, pruneAcked = true)
    check waiting.read == 1
    check waiting.skipped == 1
    check waiting.applied == 0
    check src.universeSyncEvents().len == 1
    check dst.countByRing("audit/u1") == 0

    for _ in 0 ..< 7:
      discard src.markUniverseSyncFailure(eventId, "target still down")
    let dead = src.universeSyncEvents(includeDeadLetter = true)[0]
    check dead.attempts == dead.maxAttempts
    check dead.deadLetter
    check not universeSyncDispatchable(dead)
    check src.universeSyncEvents(includeDeadLetter = false).len == 0

    let afterDead = syncUniverseOnce(src, dst, pruneAcked = true)
    check afterDead.read == 0
    check afterDead.applied == 0
    check src.universeSyncEvents(includeDeadLetter = true).len == 1
    src.close()
    dst.close()

    var reopened = open(dataDir = srcDir)
    let restored = reopened.universeSyncEvents(includeDeadLetter = true)[0]
    check restored.deadLetter
    check restored.attempts == restored.maxAttempts
    reopened.close()

    removeDir(srcDir)
    removeDir(dstDir)

suite "query (GraphQL 風選択取得)":
  test "選択した形だけ返る":
    var db = open()
    let id = db.put(%*{"title": "t", "author": {"name": "n", "org": "o"}})
    check db.query(id, "{ title }") == %*{"title": "t"}
    check db.query(id, "{ author { name } }") == %*{"author": {"name": "n"}}
    db.close()

suite "retrieve":
  test "ring 指定で探索幅を狭める":
    var db = open()
    discard db.put("ai-1", ring = "ai", vec = @[1.0'f32, 0.0'f32])
    discard db.put("ai-2", ring = "ai", vec = @[0.9'f32, 0.1'f32])
    discard db.put("db-1", ring = "db", vec = @[0.0'f32, 1.0'f32])
    discard db.put("db-2", ring = "db", vec = @[0.1'f32, 0.9'f32])

    let allHits = db.retrieve(@[1.0'f32, 0.0'f32], budget = 2)
    check allHits.len == 2
    check allHits[0].payload == "ai-1"

    let scoped = db.retrieve(@[1.0'f32, 0.0'f32], ring = "ai", budget = 2)
    check scoped.len == 2
    check scoped[0].payload == "ai-1"
    check scoped[1].payload == "ai-2"

    let globalStats = db.retrieveStats(@[1.0'f32, 0.0'f32], budget = 2)
    let scopedStats = db.retrieveStats(@[1.0'f32, 0.0'f32], ring = "ai", budget = 2)
    check globalStats.totalVectors == 4
    check globalStats.scanned == 4
    check globalStats.skippedVectors == 0
    check globalStats.ringsTouched == 2
    check globalStats.candidateReduction == 0.0
    check globalStats.payloadBytes == "ai-1".len + "ai-2".len
    check globalStats.estimatedTokens >= 1
    check scopedStats.totalVectors == 4
    check scopedStats.scanned == 2
    check scopedStats.skippedVectors == 2
    check scopedStats.ringsTouched == 1
    check scopedStats.candidateReduction == 0.5
    check scopedStats.fanoutNodes == 1
    db.close()

  test "ringMetrics はまとまりを返す":
    var db = open()
    discard db.put("a", ring = "coherent", vec = @[1.0'f32, 0.0'f32])
    discard db.put("b", ring = "coherent", vec = @[0.95'f32, 0.05'f32])
    let ms = db.ringMetrics()
    check ms.len == 1
    check ms[0].count == 2
    check ms[0].coherence > 0.95
    db.close()

  test "focus は 1..100 を topRings 2..500 に写像する":
    check focusToTopRings(1) == 2
    check focusToTopRings(10) > focusToTopRings(1)
    check focusToTopRings(50) > focusToTopRings(10)
    check focusToTopRings(100) == 500
    check focusToTopRings(999) == 500
    check clampTopRings(0) == 0
    check clampTopRings(1) == 2
    check clampTopRings(501) == 500

  test "dependency-free exact backend keeps retrieval ring-scoped":
    var db = open()
    let id = db.put("vec-a", ring = "v", vec = @[1.0'f32, 0.0'f32])
    discard db.put("vec-b", ring = "v", vec = @[0.0'f32, 1.0'f32])
    discard db.put("other", ring = "other", vec = @[1.0'f32, 0.0'f32])
    let hits = db.retrieve(@[1.0'f32, 0.0'f32], ring = "v", budget = 1)
    check hits.len == 1
    check hits[0].payload == "vec-a"
    let stats = db.retrieveStats(@[1.0'f32, 0.0'f32], ring = "v", budget = 1)
    check stats.totalVectors == 3
    check stats.scanned == 2
    check stats.skippedVectors == 1
    check stats.ringsTouched == 1

    db.update(id, "vec-a-updated", vec = @[0.0'f32, 1.0'f32])
    let updated = db.retrieve(@[0.0'f32, 1.0'f32], ring = "v", budget = 2)
    check updated.len == 2
    check updated.anyIt(it.payload == "vec-a-updated")
    check updated.allIt(it.payload != "vec-a")

    db.remove(id)
    let remaining = db.retrieve(@[0.0'f32, 1.0'f32],
                                ring = "v", budget = 2)
    let afterRemove = db.retrieveStats(@[0.0'f32, 1.0'f32],
                                       ring = "v", budget = 2)
    check afterRemove.totalVectors == 2
    check afterRemove.scanned == 1
    check remaining.allIt(it.payload != "vec-a-updated")
    db.close()

  test "PlannerBackend は deterministic heuristic を明示選択できる":
    var db = open()
    db.configurePlannerBackend(pbHeuristic)
    discard db.put("tokyo", ring = "japan/tokyo", vec = @[1.0'f32, 0.0'f32])
    discard db.put("osaka", ring = "japan/osaka", vec = @[0.9'f32, 0.1'f32])
    db.configureSearchProfile("near",
      SearchProfile(amount: raMany, scope: ssNear, depth: sdShallow))
    let env = db.retrievalEnvelopeTuned(@[1.0'f32, 0.0'f32],
                                        ring = "japan/tokyo",
                                        profile = "near")
    check env["plan"]["selectedRings"].len == 2
    check env["plan"]["ringFeatures"].len == 2
    check env["plan"]["ringFeatures"][0]["isBase"].getBool()
    check env["plan"]["ringFeatures"][0]["centroidScore"].getFloat() > 0.9
    check env["plan"]["ringFeatures"][0]["utility"].getFloat() > 0.0
    db.close()

  test "retrievalPlan は SQL tuning のように探索幅を説明する":
    let global = retrievalPlan(budget = 8)
    check global.strategy == "global"
    check global.effectiveTopRings == 0

    let focused = searchPlan(amount = raNormal, scope = ssNear)
    check focused.strategy == "top-rings"
    check focused.scope == "ssNear"
    check focused.effectiveTopRings == focusToTopRings(15)

    let scoped = searchPlan(ring = "japan", amount = raNormal,
                            scope = ssTight, depth = sdVeryDeep)
    check scoped.strategy == "hierarchical-ring"
    check scoped.ringScoped
    check scoped.selectedRings == @["japan"]
    check scoped.scope == "ssTight"
    check scoped.depth == "sdVeryDeep"
    check scoped.maxDepth == 4
    check scoped.branchBudget == 8

  test "retrieval tuning profile で探索計画を切り替えられる":
    var db = open()
    db.configureSearchProfile("short",
      SearchProfile(amount: raFew, scope: ssTight, depth: sdShallow,
                    note: "short answer"))
    db.configureSearchProfile("wide",
      SearchProfile(amount: raMany, scope: ssWide, depth: sdDeep,
                    note: "wider answer"))

    let shortPlan = db.tunedRetrievalPlan(profile = "short")
    check shortPlan.profile == "short"
    check shortPlan.budget == 3
    check shortPlan.strategy == "global"

    let widePlan = db.tunedRetrievalPlan(ring = "japan", profile = "wide")
    check widePlan.profile == "wide"
    check widePlan.budget == 16
    check widePlan.focus == 45
    check widePlan.includeChildren
    check widePlan.maxDepth == 2
    check widePlan.branchBudget == 4
    check widePlan.strategy == "hierarchical-ring"

    discard db.put("ai-a", ring = "ai", vec = @[1.0'f32, 0.0'f32])
    discard db.put("ai-b", ring = "ai", vec = @[0.9'f32, 0.1'f32])
    let env = db.retrievalEnvelopeTuned(@[1.0'f32, 0.0'f32],
                                        ring = "ai", profile = "short")
    check env["plan"]["profile"].getStr() == "short"
    check env["plan"]["budget"].getInt() == 3
    check env["chunks"].len == 2
    db.close()

  test "depth 指定で階層 ring の子を検索対象にできる":
    var db = open()
    discard db.put("root", ring = "japan", vec = @[0.0'f32, 1.0'f32])
    discard db.put("tokyo", ring = "japan/tokyo", vec = @[1.0'f32, 0.0'f32])
    discard db.put("osaka", ring = "japan/osaka", vec = @[0.9'f32, 0.1'f32])

    let shallow = db.retrieve(@[1.0'f32, 0.0'f32], ring = "japan", budget = 3)
    check shallow.len == 1
    check shallow[0].payload == "root"

    db.configureSearchProfile("deep",
      SearchProfile(amount: raMany, scope: ssTight, depth: sdDeep,
                    note: "descend children"))
    let deep = db.retrieveTuned(@[1.0'f32, 0.0'f32],
                                ring = "japan", profile = "deep")
    check deep.len == 3
    check deep[0].payload == "tokyo"

    let env = db.retrievalEnvelopeTuned(@[1.0'f32, 0.0'f32],
                                        ring = "japan", profile = "deep")
    check env["plan"]["strategy"].getStr() == "hierarchical-ring"
    check env["plan"]["selectedRings"].len == 3
    check env["stats"]["scanned"].getInt() == 3
    db.close()

  test "scope 指定で同じ親を持つ兄弟 ring を検索対象にできる":
    var db = open()
    discard db.put("tokyo", ring = "japan/tokyo", vec = @[1.0'f32, 0.0'f32])
    discard db.put("osaka", ring = "japan/osaka", vec = @[0.9'f32, 0.1'f32])
    discard db.put("history", ring = "japan/history", vec = @[0.0'f32, 1.0'f32])
    discard db.put("korea", ring = "korea/seoul", vec = @[1.0'f32, 0.0'f32])

    let tight = db.retrieve(@[0.9'f32, 0.1'f32],
                            ring = "japan/tokyo", budget = 4)
    check tight.len == 1
    check tight[0].payload == "tokyo"

    db.configureSearchProfile("near",
      SearchProfile(amount: raMany, scope: ssNear, depth: sdShallow,
                    note: "include siblings"))
    let near = db.retrieveTuned(@[0.9'f32, 0.1'f32],
                                ring = "japan/tokyo", profile = "near")
    check near.len == 3
    check near[0].payload == "osaka"

    let env = db.retrievalEnvelopeTuned(@[0.9'f32, 0.1'f32],
                                        ring = "japan/tokyo",
                                        profile = "near")
    check env["plan"]["selectedRings"].len == 3
    check env["plan"]["ringFeatures"].len == 3
    check env["plan"]["ringFeatures"][0]["ring"].getStr() == "japan/tokyo"
    check env["plan"]["ringFeatures"][0]["ringCount"].getInt() == 1
    check env["plan"]["ringFeatures"][1]["centroidScore"].getFloat() >
      env["plan"]["ringFeatures"][2]["centroidScore"].getFloat()
    check env["stats"]["scanned"].getInt() == 3
    db.close()

  test "retrievalEnvelope は Shelfer などの RAG source が使う統計を含む":
    var db = open()
    discard db.put("ai-a", ring = "ai", vec = @[1.0'f32, 0.0'f32])
    discard db.put("ai-b", ring = "ai", vec = @[0.9'f32, 0.1'f32])
    discard db.put("db-a", ring = "db", vec = @[0.0'f32, 1.0'f32])

    let env = db.retrievalEnvelope(@[1.0'f32, 0.0'f32], ring = "ai", budget = 2)
    check env["schema"].getStr() == RetrievalEnvelopeSchema
    check env["version"].getInt() == RetrievalEnvelopeVersion
    check env["source"]["provider"].getStr() == "koutendb"
    check env["source"]["ring"].getStr() == "ai"
    check env["source"]["sourceType"].getStr() == "document"
    check env["query"]["ringScoped"].getBool() == true
    check env["plan"]["strategy"].getStr() == "ring-scoped"
    check env["plan"]["baseRing"].getStr() == "ai"
    check env["plan"]["budget"].getInt() == 2
    check env["plan"]["ringFeatures"].len == 1
    check env["plan"]["ringFeatures"][0]["centroidScore"].getFloat() > 0.9
    check env["plan"]["ringFeatures"][0]["utility"].getFloat() > 0.0
    check env["chunks"].len == 2
    check env["chunks"][0]["payload"].getStr() == "ai-a"
    check env["stats"]["totalVectors"].getInt() == 3
    check env["stats"]["scanned"].getInt() == 2
    check env["stats"]["skippedVectors"].getInt() == 1
    check env["stats"]["candidateReduction"].getFloat() > 0.3
    check env["policyHints"]["resourceKind"].getStr() == "rag"
    check env["policyHints"]["resourceScope"].getStr() == "topic"
    check env.isValidRetrievalEnvelope()
    check retrievalEnvelopeValidationErrors(env).len == 0
    env["schema"] = %"bad.schema"
    check not env.isValidRetrievalEnvelope()
    db.close()

  test "atlas は LLM が読む galaxy/ring map を返す":
    var db = open()
    db.setGalaxyDescription("Japan knowledge galaxy")
    db.setRingDescription("japan", "Top-level information about Japan.")
    db.setRingDescription("japan/tokyo", "Tokyo-specific local facts.")
    discard db.put("root", ring = "japan", vec = @[0.0'f32, 1.0'f32])
    discard db.put("tokyo", ring = "japan/tokyo", vec = @[1.0'f32, 0.0'f32])
    discard db.put("osaka", ring = "japan/osaka", vec = @[0.9'f32, 0.1'f32])

    let a = db.atlas(@[1.0'f32, 0.0'f32])
    check a["schema"].getStr() == AtlasSchema
    check a["version"].getInt() == AtlasVersion
    check a["galaxyMap"]["mode"].getStr() == "embedded"
    check a["galaxyMap"]["description"].getStr() == "Japan knowledge galaxy"
    check a["galaxyMap"]["rings"].getInt() == 3
    check a["galaxyMap"]["documents"].getInt() == 3
    check a["usage"]["memory"].getStr().len > 0

    var tokyo: JsonNode = nil
    var japan: JsonNode = nil
    for r in a["ringMap"].items:
      if r["name"].getStr() == "japan/tokyo":
        tokyo = r
      if r["name"].getStr() == "japan":
        japan = r
    check tokyo != nil
    check tokyo["description"].getStr() == "Tokyo-specific local facts."
    check tokyo["parent"].getStr() == "japan"
    check tokyo["documents"].getInt() == 1
    check tokyo["vectorDocuments"].getInt() == 1
    check tokyo["coherence"].getFloat() >= 0.0
    check tokyo["massG"].getFloat() >= 0.0
    check tokyo["centroidPreview"].len == 2
    check japan != nil
    check japan["description"].getStr() == "Top-level information about Japan."
    check japan["children"].len == 2
    db.close()

suite "永続化":
  test "再オープンで中身・環設定・時計が戻る":
    let dir = createTempDir("koutendb", "test")
    var db = open(dataDir = dir)
    db.setGalaxyDescription("Persistent galaxy description")
    db.configureRing("r", 30.0)
    db.setRingDescription("r", "Persistent ring description")
    let id = db.put("persist me", ring = "r")
    db.advance(5.0)
    let n5 = db.locate(id)
    db.close()

    var db2 = open(dataDir = dir)
    check db2.getGalaxyDescription() == "Persistent galaxy description"
    check db2.getRingDescription("r") == "Persistent ring description"
    check db2.atlas()["ringMap"][0]["description"].getStr() == "Persistent ring description"
    check db2.get(id) == "persist me"
    check db2.locate(id, at = 5.0) == n5     # 軌道が同じ = 環設定が復元されている
    let id2 = db2.put("more", ring = "r")    # seq 採番も継続する
    check db2.get(id2) == "more"
    db2.close()
    removeDir(dir)

  test "階層 ring 名は再オープン後も復元される":
    let dir = createTempDir("koutendb", "rings")
    var db = open(dataDir = dir)
    discard db.put("tokyo", ring = "japan/tokyo", vec = @[1.0'f32, 0.0'f32])
    db.close()

    var db2 = open(dataDir = dir)
    db2.configureSearchProfile("deep",
      SearchProfile(amount: raMany, scope: ssTight, depth: sdDeep))
    let hits = db2.retrieveTuned(@[1.0'f32, 0.0'f32],
                                 ring = "japan", profile = "deep")
    check hits.len == 1
    check hits[0].payload == "tokyo"
    db2.close()
    removeDir(dir)

  test "compact 後も生存データと ring 階層が復元される":
    let dir = createTempDir("koutendb", "compact")
    var db = open(dataDir = dir)
    let oldId = db.put("old", ring = "japan/tokyo",
                       vec = @[0.0'f32, 1.0'f32])
    let liveId = db.put("live", ring = "japan/tokyo",
                        vec = @[1.0'f32, 0.0'f32])
    let tx = db.beginTransaction()
    tx.remove(oldId)
    tx.commit()
    let stats = db.compact()
    check stats.items == 1
    check stats.beforeBytes > stats.afterBytes
    db.close()

    var db2 = open(dataDir = dir)
    check not (oldId in db2)
    check db2.get(liveId) == "live"
    db2.configureSearchProfile("deep",
      SearchProfile(amount: raMany, scope: ssTight, depth: sdDeep))
    let hits = db2.retrieveTuned(@[1.0'f32, 0.0'f32],
                                 ring = "japan", profile = "deep")
    check hits.len == 1
    check hits[0].payload == "live"
    db2.close()
    removeDir(dir)

  test "backup/restore で別 dataDir に復元できる":
    let dir = createTempDir("koutendb", "backup-src")
    let backupDir = createTempDir("koutendb", "backup")
    let restoredDir = createTempDir("koutendb", "restore")
    var db = open(dataDir = dir)
    let oldId = db.put("old", ring = "docs/ai",
                       vec = @[0.0'f32, 1.0'f32])
    let liveId = db.put("live", ring = "docs/ai",
                        vec = @[1.0'f32, 0.0'f32])
    db.transaction(proc(tx: KoutenTx) =
      tx.remove(oldId)
    )
    let backupStats = db.backup(backupDir)
    check backupStats.items == 1
    let verifyStats = verifyBackup(backupDir)
    check verifyStats.items == 1
    db.close()

    removeDir(restoredDir)
    let restoreStats = restoreBackup(backupDir, restoredDir)
    check restoreStats.items == 1
    var restored = open(dataDir = restoredDir)
    check not (oldId in restored)
    check restored.get(liveId) == "live"
    restored.configureSearchProfile("deep",
      SearchProfile(amount: raMany, scope: ssTight, depth: sdDeep))
    let hits = restored.retrieveTuned(@[1.0'f32, 0.0'f32],
                                      ring = "docs", profile = "deep")
    check hits.len == 1
    check hits[0].payload == "live"
    restored.close()
    removeDir(dir)
    removeDir(backupDir)
    removeDir(restoredDir)

  test "persistent stores append operational audit JSONL":
    let root = createTempDir("koutendb", "audit-jsonl")
    let dir = root / "db"
    let backupDir = root / "backup"
    let restoredDir = root / "restored"
    try:
      var db = open(dataDir = dir)
      db.configureGuardrails(KoutenGuardrails(maxPayloadBytes: 16))
      let id = db.put(%*{"n": 1}, ring = "audit/r")
      db.update(id, %*{"n": 2})
      db.remove(id)
      expect ValueError:
        discard db.put("this-payload-is-too-large", ring = "audit/r")
      discard db.backup(backupDir)
      discard db.compact()
      let path = db.auditLogPath()
      check path == auditLogPath(dir)
      db.close()

      discard restoreBackup(backupDir, restoredDir)

      let lines = readFile(path).strip().splitLines()
      var events: seq[string] = @[]
      var sawDenied = false
      for line in lines:
        let node = parseJson(line)
        events.add node["event"].getStr()
        if node["event"].getStr() == "guardrail-denied":
          sawDenied = true
          check not node["ok"].getBool()
      check "put" in events
      check "update" in events
      check "delete" in events
      check "backup" in events
      check "compact" in events
      check sawDenied

      let restoreLines = readFile(auditLogPath(restoredDir)).strip().splitLines()
      check parseJson(restoreLines[^1])["event"].getStr() == "restore"
    finally:
      removeDir(root)

  test "transaction-created ring names survive reopen":
    let dir = createTempDir("koutendb", "tx-ring-name")
    var db = open(dataDir = dir)
    db.transaction(proc(tx: KoutenTx) =
      discard tx.put("tx-live", ring = "events/tx-only")
    )
    let before = db.readRing("events/tx-only")
    check before.items.len == 1
    db.close()

    var reopened = open(dataDir = dir)
    let after = reopened.readRing("events/tx-only")
    check after.items.len == 1
    check after.items[0].payload == "tx-live"
    reopened.close()
    removeDir(dir)

  test "open は strong durability を指定できる":
    let dir = createTempDir("koutendb", "strong")
    var db = open(dataDir = dir, durability = durStrong)
    let id = db.put("durable", ring = "ops/strong")
    db.close()

    var reopened = open(dataDir = dir, durability = durStrong)
    check reopened.get(id) == "durable"
    reopened.close()
    removeDir(dir)

  test "encrypted backup/restore で別 dataDir に復元できる":
    let dir = createTempDir("koutendb", "enc-backup-src")
    let backupDir = createTempDir("koutendb", "enc-backup")
    let restoredDir = createTempDir("koutendb", "enc-restore")
    var db = open(dataDir = dir)
    let id = db.put("classified", ring = "secure/docs",
                    vec = @[1.0'f32, 0.0'f32])
    let backupStats = db.backupEncrypted(backupDir, "passphrase")
    check backupStats.items == 1
    let verifyStats = verifyEncryptedBackup(backupDir, "passphrase")
    check verifyStats.items == 1
    db.close()

    removeDir(restoredDir)
    expect CatchableError:
      discard restoreEncryptedBackup(backupDir, restoredDir, "bad-passphrase")
    let restoreStats = restoreEncryptedBackup(backupDir, restoredDir,
                                              "passphrase")
    check restoreStats.items == 1
    var restored = open(dataDir = restoredDir)
    check restored.get(id) == "classified"
    restored.close()
    removeDir(dir)
    removeDir(backupDir)
    removeDir(restoredDir)

  test "dump は JSONL で ring と document を出力できる":
    let dir = createTempDir("koutendb", "dump")
    let outPath = dir / "dump.jsonl"
    var db = open(dataDir = dir)
    discard db.put("hello", ring = "docs/ai", vec = @[1.0'f32, 0.0'f32])
    let stats = db.dump(outPath)
    check stats.records >= 4
    check stats.documents == 1
    check stats.rings >= 2
    db.close()

    let lines = readFile(outPath).strip().splitLines()
    check parseJson(lines[0])["type"].getStr() == "meta"
    var sawDoc = false
    var sawVec = false
    for line in lines:
      let node = parseJson(line)
      if node["type"].getStr() == "document":
        sawDoc = true
        check node["ring"].getStr() == "docs/ai"
        check node["payload"].getStr() == "hello"
        sawVec = node.hasKey("vec")
    check sawDoc
    check sawVec

    var db2 = open(dataDir = dir)
    let noVecPath = dir / "dump-no-vec.jsonl"
    discard db2.dump(noVecPath, includeVectors = false)
    db2.close()
    for line in readFile(noVecPath).strip().splitLines():
      let node = parseJson(line)
      if node["type"].getStr() == "document":
        check not node.hasKey("vec")
    removeDir(dir)

  test "dump JSONL は別 dataDir に import できる移行境界になる":
    let root = createTempDir("koutendb", "dump-roundtrip")
    let srcDir = root / "src"
    let dstDir = root / "dst"
    let outPath = root / "dump.jsonl"

    var src = open(dataDir = srcDir)
    discard src.put(%*{"title": "alpha", "status": "published"},
                    ring = "docs/json", vec = @[1.0'f32, 0.0'f32])
    discard src.put(encodedPayload("(object (title beta))", pcNif),
                    ring = "docs/nif", vec = @[0.0'f32, 1.0'f32])
    let dumpStats = src.dump(outPath)
    check dumpStats.documents == 2
    src.close()

    var dst = open(dataDir = dstDir)
    let importStats = dst.importJsonl(outPath)
    check importStats.read == dumpStats.records
    check importStats.imported == 2
    check importStats.skipped >= 1
    check dst.countByRing("docs/json") == 1
    check dst.countByRing("docs/nif") == 1

    let jsonPage = dst.listByRing("docs/json")
    check jsonPage.items.len == 1
    check dst.getEncoded(jsonPage.items[0].id).codec == pcJson
    check parseJson(jsonPage.items[0].payload)["title"].getStr() == "alpha"

    let nifPage = dst.listByRing("docs/nif")
    check nifPage.items.len == 1
    check dst.getEncoded(nifPage.items[0].id) ==
      encodedPayload("(object (title beta))", pcNif)

    let hits = dst.retrieve(@[0.0'f32, 1.0'f32], ring = "docs/nif", budget = 1)
    check hits.len == 1
    check hits[0].payload == "(object (title beta))"
    dst.close()
    removeDir(root)

  test "disk-backed mode keeps payloads in WAL while preserving public reads":
    let root = createTempDir("koutendb", "disk-backed")
    let dir = root / "db"
    let importPath = root / "input.jsonl"
    try:
      var db = open(dataDir = dir, diskBacked = true)
      let a = db.put(%*{"title": "alpha", "kind": "doc"}, ring = "docs/a",
                     vec = @[1.0'f32, 0.0'f32])
      let b = db.put(encodedPayload("(object (title beta))", pcNif), ring = "docs/a",
                     vec = @[0.8'f32, 0.2'f32])
      discard db.put(%*{"title": "gamma", "kind": "note"}, ring = "docs/b",
                     vec = @[0.0'f32, 1.0'f32])

      check db.get(a).contains("alpha")
      check db.getEncoded(b).codec == pcNif
      check db.countByRing("docs/a") == 2
      db.packDiskBackedSegments()
      check dirExists(dir / "segments")
      let page = db.listByRing("docs/a", limit = 10)
      check page.items.len == 2
      check page.items[1].codec == pcNif
      let rr = db.retrieveWithStats(@[1.0'f32, 0.0'f32], ring = "docs/a", budget = 2)
      check rr.hits.len == 2
      check rr.stats.totalVectors == 3
      check rr.stats.scanned == 2

      let postPack = db.put(%*{"title": "post-pack"}, ring = "docs/a",
                            vec = @[0.7'f32, 0.3'f32])
      db.update(a, %*{"title": "alpha-updated", "kind": "doc"},
                vec = @[1.0'f32, 0.0'f32])
      let afterPackWrite = db.retrieveWithStats(
        @[1.0'f32, 0.0'f32], ring = "docs/a", budget = 3)
      check afterPackWrite.hits.len == 3
      check afterPackWrite.stats.scanned == 3
      check afterPackWrite.hits.anyIt(it.payload.contains("alpha-updated"))
      check afterPackWrite.hits.anyIt(it.payload.contains("post-pack"))
      check db.get(a).contains("alpha-updated")
      check db.get(postPack).contains("post-pack")
      db.close()

      var reopened = open(dataDir = dir, diskBacked = true)
      check reopened.get(a).contains("alpha-updated")
      check dirExists(dir / "segments")
      check reopened.getEncoded(b).codec == pcNif
      check reopened.countByRing("docs/a") == 3
      let reopenedRead = reopened.retrieveWithStats(@[1.0'f32, 0.0'f32],
                                                    ring = "docs/a", budget = 3)
      check reopenedRead.hits.len == 3
      check reopenedRead.stats.scanned == 3
      check reopenedRead.hits.anyIt(it.payload.contains("alpha-updated"))
      check reopenedRead.hits.anyIt(it.payload.contains("post-pack"))

      writeFile(importPath,
        "{\"ring\":\"imports/a\",\"payload\":{\"title\":\"one\"},\"vec\":[1,0]}\n" &
        "{\"ring\":\"imports/a\",\"payload\":{\"title\":\"two\"},\"vec\":[0.9,0.1]}\n" &
        "{\"ring\":\"imports/b\",\"payload\":{\"title\":\"three\"},\"vec\":[0,1]}\n")
      let stats = reopened.importJsonl(importPath, ringField = "ring",
                                       payloadField = "payload", vecField = "vec",
                                       batchSize = 2)
      check stats.imported == 3
      check stats.batches == 2
      check reopened.countByRing("imports/a") == 2
      check reopened.retrieveWithStats(@[1.0'f32, 0.0'f32],
                                       ring = "imports/a", budget = 2).stats.scanned == 2
      reopened.close()
    finally:
      removeDir(root)

  test "disk-backed segment pack keeps every ring on the local read path":
    let root = createTempDir("koutendb", "disk-backed-segment-threshold")
    let dir = root / "db"
    try:
      var db = open(dataDir = dir, diskBacked = true)
      let tiny = db.put(%*{"title": "tiny"}, ring = "users/user-00000001")
      for i in 0 ..< 16:
        discard db.put(%*{"title": "large", "n": i}, ring = "docs/large")

      let packed = db.packDiskBackedSegments()
      check packed.records == 17
      check packed.rings == 2
      check db.readRing("users/user-00000001").items.len == 1
      check db.get(tiny).contains("tiny")
      check db.readRing("docs/large", KoutenReadOptions(
        filter: newJObject(),
        selection: "",
        limit: 20,
        cursor: "",
        pagination: rpOff,
        page: 1,
        pageLimit: 20,
        sortField: "time",
        sortDirection: rsDesc)).items.len == 16
      db.close()

      var reopened = open(dataDir = dir, diskBacked = true)
      check reopened.readRing("users/user-00000001").items.len == 1
      check reopened.readRing("docs/large", KoutenReadOptions(
        filter: newJObject(),
        selection: "",
        limit: 20,
        cursor: "",
        pagination: rpOff,
        page: 1,
        pageLimit: 20,
        sortField: "time",
        sortDirection: rsDesc)).items.len == 16
      reopened.close()
    finally:
      removeDir(root)

  test "disk-backed public ring windows preserve bounded and complete read semantics":
    let root = createTempDir("koutendb", "disk-backed-public-window")
    let dir = root / "db"
    try:
      var db = open(dataDir = dir, diskBacked = true)
      var ids: seq[KoutenId] = @[]
      for i in 0 ..< 8:
        ids.add db.put(%*{"n": i, "keep": true}, ring = "docs/window")
      discard db.packDiskBackedRing("docs/window")

      var asc = defaultReadOptions()
      asc.limit = 3
      asc.sortField = "id"
      asc.sortDirection = rsAsc
      check db.readRing("docs/window", asc).items.mapIt(it.id.toRaw.seq) ==
        @[ids[0].toRaw.seq, ids[1].toRaw.seq, ids[2].toRaw.seq]

      var desc = asc
      desc.sortDirection = rsDesc
      check db.readRing("docs/window", desc).items.mapIt(it.id.toRaw.seq) ==
        @[ids[7].toRaw.seq, ids[6].toRaw.seq, ids[5].toRaw.seq]

      db.update(ids[0], %*{"n": 100, "keep": true})
      db.remove(ids[1])
      var complete = defaultReadOptions()
      complete.limit = 100
      complete.sortField = "id"
      complete.sortDirection = rsAsc
      complete.selection = "{ n }"
      let page = db.readRing("docs/window", complete)
      check page.items.len == 7
      check page.items[0].id.toRaw.seq == ids[0].toRaw.seq
      check parseJson(page.items[0].payload) == %*{"n": 100}
      check page.items.allIt(it.id.toRaw.seq != ids[1].toRaw.seq)
      check db.segmentStatus().segmentHits > 0
      db.close()

      var reopened = open(dataDir = dir, diskBacked = true)
      let reopenedPage = reopened.readRing("docs/window", complete)
      check reopenedPage.items.mapIt(it.id.toRaw.seq) ==
        page.items.mapIt(it.id.toRaw.seq)
      check reopenedPage.items.mapIt(it.payload) == page.items.mapIt(it.payload)
      reopened.close()
    finally:
      removeDir(root)

  test "operationalVerify opens WAL and reports segment/locality health":
    let root = createTempDir("koutendb", "operational-verify")
    let dir = root / "db"
    try:
      var db = open(dataDir = dir, diskBacked = true)
      discard db.put(%*{"name": "a"}, ring = "ops/a")
      discard db.put(%*{"name": "b"}, ring = "ops/b")
      for i in 0 ..< 16:
        discard db.put(%*{"i": i}, ring = "ops/packed")
      db.close()

      let report = operationalVerify(dir, verifySegments = true)
      check report.ok
      check report.dataDir == dir
      check report.walExists
      check report.walBytes > 0
      check report.items == 18
      check report.rings >= 2
      check report.locality.persistent
      check report.locality.totalParticleRecords == 18
      check report.locality.liveParticleRecords == 18
      check report.locality.deadParticleRecords == 0
      check report.locality.ringCount == 3
      check report.locality.ringRuns == 3
      check report.locality.localityScore == 1.0
      check report.segmentDirExists
      check report.segmentStatus.rings.len == 3
      check report.segmentStatus.totalSegmentBytes > 0
      check report.checks.len >= 4
      check report.checks.anyIt(it.name == "open-replay-lock" and it.ok)
      check report.checks.anyIt(it.name == "segments" and it.ok)

      let cappedWal = operationalVerify(dir, maxWalBytes = 1)
      check not cappedWal.ok
      check cappedWal.checks.anyIt(it.name == "wal-bytes-limit" and not it.ok)

      let cappedItems = operationalVerify(dir, maxItems = 1)
      check not cappedItems.ok
      check cappedItems.checks.anyIt(it.name == "items-limit" and not it.ok)

      let cappedRings = operationalVerify(dir, maxRings = 1)
      check not cappedRings.ok
      check cappedRings.checks.anyIt(it.name == "rings-limit" and not it.ok)

      let cappedSegments = operationalVerify(dir, verifySegments = true,
                                             maxSegmentFiles = 0)
      check not cappedSegments.ok
      check cappedSegments.checks.anyIt(it.name == "segment-files-limit" and not it.ok)

      let cappedSegmentBytes = operationalVerify(dir, maxSegmentBytes = 1)
      check not cappedSegmentBytes.ok
      check cappedSegmentBytes.checks.anyIt(
        it.name == "segment-bytes-limit" and not it.ok)

      let cappedGeneration = operationalVerify(dir,
                                                maxSegmentGeneration = 0)
      check cappedGeneration.ok
    finally:
      removeDir(root)

  test "segment status and recommended packing are explicit and ring-local":
    let root = createTempDir("koutendb", "segment-recommended-pack")
    let dir = root / "db"
    try:
      var db = open(dataDir = dir, diskBacked = true)
      let hot = db.put(%*{"value": 0}, ring = "ops/hot")
      let warm = db.put(%*{"value": 0}, ring = "ops/warm")
      discard db.put(%*{"value": 0}, ring = "ops/cold")
      for i in 1 .. 8:
        db.update(hot, %*{"value": i})
        db.update(warm, %*{"value": i})
      let before = db.segmentStatus(staleRatioThreshold = 0.5,
                                    minStaleRecords = 4)
      check before.recommendedRings == 2
      check before.rings.anyIt(it.ring == "ops/hot" and it.packRecommended)
      check before.rings.anyIt(it.ring == "ops/warm" and it.packRecommended)
      check before.rings.anyIt(it.ring == "ops/cold" and not it.packRecommended)
      expect ValueError:
        discard db.packRecommendedDiskBackedRings(maxRings = -1)

      let packed = db.packRecommendedDiskBackedRings(
        staleRatioThreshold = 0.5, minStaleRecords = 4, maxRings = 1)
      check packed.rings == 1
      check packed.records == 1
      let limited = db.segmentStatus(staleRatioThreshold = 0.5,
                                     minStaleRecords = 4)
      check limited.recommendedRings == 1
      check limited.rings.countIt(it.packRecommended) == 1
      check limited.rings.anyIt(it.ring == "ops/cold" and it.generation == 0)

      let remainder = db.packRecommendedDiskBackedRings(
        staleRatioThreshold = 0.5, minStaleRecords = 4)
      check remainder.rings == 1
      check remainder.records == 1
      let after = db.segmentStatus(staleRatioThreshold = 0.5,
                                   minStaleRecords = 4)
      check after.recommendedRings == 0
      check after.rings.anyIt(it.ring == "ops/hot" and it.generation == 1)
      check after.rings.anyIt(it.ring == "ops/warm" and it.generation == 1)
      check after.rings.anyIt(it.ring == "ops/cold" and it.generation == 0)
      check db.get(hot).contains("\"value\":8")
      check db.get(warm).contains("\"value\":8")
      check db.segmentStatus().segmentHits > 0
      db.close()

      let deadCapped = operationalVerify(dir, maxDeadRecords = 0)
      check not deadCapped.ok
      check deadCapped.checks.anyIt(
        it.name == "dead-records-limit" and not it.ok)
      let ratioCapped = operationalVerify(dir, maxDeadRatio = 0.0)
      check not ratioCapped.ok
      check ratioCapped.checks.anyIt(
        it.name == "dead-record-ratio-limit" and not it.ok)
      let generationCapped = operationalVerify(dir,
                                                maxSegmentGeneration = 0)
      check not generationCapped.ok
      check generationCapped.checks.anyIt(
        it.name == "segment-generation-limit" and not it.ok)
      let uncapped = operationalVerify(dir)
      let exact = operationalVerify(
        dir,
        maxSegmentBytes = uncapped.segmentStatus.totalSegmentBytes +
          uncapped.segmentStatus.totalIndexBytes,
        maxDeadRecords = uncapped.locality.deadParticleRecords,
        maxDeadRatio = float(uncapped.locality.deadParticleRecords) /
          float(uncapped.locality.totalParticleRecords),
        maxSegmentGeneration = uncapped.segmentStatus.maxGeneration.int64)
      check exact.ok
    finally:
      removeDir(root)

  test "bounded segment maintenance shares planning execution and restart status":
    let root = createTempDir("koutendb", "bounded-segment-maintenance")
    let dir = root / "db"
    try:
      var db = open(dataDir = dir, diskBacked = true)
      var ids: seq[KoutenId] = @[]
      for ring in ["maintenance/a", "maintenance/b"]:
        let id = db.put(%*{"ring": ring, "value": 0}, ring = ring)
        ids.add id
        for i in 1 .. 6:
          db.update(id, %*{"ring": ring, "value": i})
      discard db.put(%*{"value": 0}, ring = "maintenance/cold")

      var policy = defaultSegmentMaintenancePolicy()
      policy.staleRatioThreshold = 0.5
      policy.minStaleRecords = 4
      policy.maxRings = 1
      policy.maxBytes = 0
      policy.maxElapsedMs = 0
      let plan = db.planSegmentMaintenance(policy)
      check plan.dryRun
      check plan.outcome == "dry-run"
      check plan.recommendedRings == 2
      check plan.selectedRings == 1
      check plan.decisions.countIt(it.selected and it.reason == "selected") == 1
      check plan.decisions.countIt(it.reason == "ring-budget-exhausted") == 1
      check plan.decisions.anyIt(
        it.ring == "maintenance/cold" and
        it.reason == "stale-records-below-minimum")

      var bytePolicy = policy
      bytePolicy.maxRings = 0
      bytePolicy.maxBytes = plan.decisions.filterIt(it.selected)[0].estimatedBytes
      let exactBytePlan = db.planSegmentMaintenance(bytePolicy)
      check exactBytePlan.selectedRings >= 1
      var firstRecommended = -1
      for i, decision in exactBytePlan.decisions:
        if decision.recommended:
          firstRecommended = i
          break
      check firstRecommended >= 0
      check exactBytePlan.decisions[firstRecommended].selected
      bytePolicy.maxBytes =
        exactBytePlan.decisions[firstRecommended].estimatedBytes - 1
      let belowBytePlan = db.planSegmentMaintenance(bytePolicy)
      check belowBytePlan.decisions[firstRecommended].reason ==
        "byte-budget-exhausted"

      let dryRun = db.runSegmentMaintenance(policy, dryRun = true)
      check dryRun.dryRun
      check db.segmentStatus(0.5, 4).recommendedRings == 2

      let run = db.runSegmentMaintenance(policy)
      check not run.dryRun
      check run.outcome == "completed"
      check run.packedRings == 1
      check run.recordsRewritten == 1
      check run.bytesRewritten > 0
      check db.segmentStatus(0.5, 4).recommendedRings == 1
      let status = db.segmentMaintenanceStatus()
      check status["schema"].getStr() == "koutendb.segment-maintenance.v1"
      check status["outcome"].getStr() == "completed"
      check status["packedRings"].getInt() == 1

      expect KoutenValidationError:
        discard db.planSegmentMaintenance(KoutenSegmentMaintenancePolicy(
          staleRatioThreshold: 1.01, minStaleRecords: 0,
          maxRings: 0, maxBytes: 0, maxElapsedMs: 0))
      expect KoutenValidationError:
        discard db.planSegmentMaintenance(KoutenSegmentMaintenancePolicy(
          staleRatioThreshold: 0, minStaleRecords: 0,
          maxRings: -1, maxBytes: 0, maxElapsedMs: 0))
      expect KoutenValidationError:
        discard db.planSegmentMaintenance(KoutenSegmentMaintenancePolicy(
          staleRatioThreshold: 0, minStaleRecords: 0,
          maxRings: 0, maxBytes: -1, maxElapsedMs: 0))
      expect KoutenValidationError:
        discard db.planSegmentMaintenance(KoutenSegmentMaintenancePolicy(
          staleRatioThreshold: 0, minStaleRecords: 0,
          maxRings: 0, maxBytes: 0, maxElapsedMs: -1))
      db.close()

      var interrupted = parseJson(readFile(dir / "segment-maintenance.json"))
      interrupted["outcome"] = %"running"
      interrupted["finishedAt"] = %0
      writeFile(dir / "segment-maintenance.json", pretty(interrupted))

      var reopened = open(dataDir = dir, diskBacked = true)
      check reopened.recoverInterruptedSegmentMaintenance()
      let recoveredStatus = reopened.segmentMaintenanceStatus()
      check recoveredStatus["outcome"].getStr() == "interrupted"
      check recoveredStatus["stopReason"].getStr() == "process-terminated"
      check not reopened.recoverInterruptedSegmentMaintenance()
      for id in ids:
        check reopened.get(id).contains("\"value\":6")
      reopened.close()
    finally:
      removeDir(root)

  test "segment maintenance rejects stores without the persistent ring layout":
    var memoryDb = open()
    expect KoutenValidationError:
      discard memoryDb.planSegmentMaintenance()
    memoryDb.close()

    let root = createTempDir("koutendb", "maintenance-no-segments")
    try:
      var walOnly = open(dataDir = root)
      expect KoutenValidationError:
        discard walOnly.runSegmentMaintenance()
      walOnly.close()
    finally:
      removeDir(root)

  test "segment maintenance status fails closed when its sidecar is malformed":
    let root = createTempDir("koutendb", "maintenance-invalid-status")
    try:
      var db = open(dataDir = root, diskBacked = true)
      writeFile(root / "segment-maintenance.json", "{not-json")
      expect KoutenOperationError:
        discard db.segmentMaintenanceStatus()
      expect KoutenOperationError:
        discard db.recoverInterruptedSegmentMaintenance()
      check readFile(root / "segment-maintenance.json") == "{not-json"
      writeFile(root / "segment-maintenance.json",
                """{"schema":"unknown","outcome":"running"}""")
      expect KoutenOperationError:
        discard db.segmentMaintenanceStatus()
      writeFile(root / "segment-maintenance.json",
                """{"schema":"koutendb.segment-maintenance.v1","outcome":"unknown"}""")
      expect KoutenOperationError:
        discard db.segmentMaintenanceStatus()
      db.close()
    finally:
      removeDir(root)

  test "segment maintenance packs a fully deleted ring into an empty generation":
    let root = createTempDir("koutendb", "maintenance-deleted-ring")
    let dir = root / "db"
    try:
      var db = open(dataDir = dir, diskBacked = true)
      let id = db.put(%*{"value": 0}, ring = "maintenance/deleted")
      for value in 1 .. 3:
        db.update(id, %*{"value": value})
      db.remove(id)

      let before = db.segmentStatus(staleRatioThreshold = 0.5,
                                    minStaleRecords = 1)
      let deletedBefore = before.rings.filterIt(
        it.ring == "maintenance/deleted")
      check deletedBefore.len == 1
      check deletedBefore[0].liveRecords == 0
      check deletedBefore[0].staleRecords >= 1
      check deletedBefore[0].packRecommended
      let oldGeneration = deletedBefore[0].generation

      var policy = defaultSegmentMaintenancePolicy()
      policy.staleRatioThreshold = 0.5
      policy.minStaleRecords = 1
      policy.maxRings = 1
      policy.maxBytes = 0
      policy.maxElapsedMs = 0
      let plan = db.planSegmentMaintenance(policy)
      check plan.selectedRings == 1
      check plan.decisions.anyIt(
        it.ring == "maintenance/deleted" and it.selected)

      let run = db.runSegmentMaintenance(policy)
      check run.outcome == "completed"
      check run.packedRings == 1
      check run.recordsRewritten == 0
      let after = db.segmentStatus(staleRatioThreshold = 0.5,
                                   minStaleRecords = 1)
      let deletedAfter = after.rings.filterIt(
        it.ring == "maintenance/deleted")
      check deletedAfter.len == 1
      check deletedAfter[0].generation == oldGeneration + 1
      check deletedAfter[0].liveRecords == 0
      check deletedAfter[0].segmentRecords == 0
      check deletedAfter[0].staleRecords == 0
      check not deletedAfter[0].packRecommended
      check db.readRing("maintenance/deleted").count == 0
      db.close()

      var reopened = open(dataDir = dir, diskBacked = true)
      check id notin reopened
      check reopened.readRing("maintenance/deleted").count == 0
      let reopenedStatus = reopened.segmentStatus(0.5, 1)
      check reopenedStatus.rings.anyIt(
        it.ring == "maintenance/deleted" and
        it.generation == oldGeneration + 1 and
        it.segmentRecords == 0 and
        not it.packRecommended)
      reopened.close()
    finally:
      removeDir(root)

  test "operationalVerify rejects a corrupted versioned WAL":
    let root = createTempDir("koutendb", "operational-verify-corrupt")
    let dir = root / "db"
    try:
      var db = open(dataDir = dir, diskBacked = true)
      discard db.put("checksum", ring = "ops/corrupt")
      db.close()

      let walPath = dir / "kouten.log"
      writeFile(walPath, readFile(walPath).replace("checksum", "checksux"))
      expect IOError:
        discard operationalVerify(dir, diskBacked = true)
    finally:
      removeDir(root)

  test "importJsonl は外部 NoSQL JSONL を ring に割り振って保存できる":
    let dir = createTempDir("koutendb", "import-jsonl")
    let input = dir / "mongo-export.jsonl"
    writeFile(input,
      """{"tenant":"a","kind":"article","body":{"title":"alpha"},"embedding":[1.0,0.0]}""" & "\n" &
      """{"tenant":"b","kind":"article","body":{"title":"beta"},"embedding":[0.0,1.0]}""" & "\n" &
      """{"kind":"fallback","body":"plain text","embedding":[1.0,0.0]}""" & "\n")
    var db = open(dataDir = dir)
    let stats = db.importJsonl(input, defaultRing = "misc",
                               ringField = "tenant",
                               ringPrefix = "tenant/",
                               payloadField = "body",
                               vecField = "embedding",
                               batchSize = 2)
    check stats.read == 3
    check stats.imported == 3
    check stats.rings == 3
    check stats.batches == 2
    check stats.batchSize == 2

    let aHits = db.retrieve(@[1.0'f32, 0.0'f32],
                            ring = "tenant/a", budget = 2)
    check aHits.len == 1
    check parseJson(aHits[0].payload)["title"].getStr() == "alpha"

    let fallbackHits = db.retrieve(@[1.0'f32, 0.0'f32],
                                   ring = "tenant/misc", budget = 2)
    check fallbackHits.len == 1
    check fallbackHits[0].payload == "plain text"
    db.close()
    removeDir(dir)

suite "transaction":
  test "commit まで書き込みは見えず、commit 後に永続化される":
    let dir = createTempDir("koutendb", "tx")
    var db = open(dataDir = dir)
    let tx = db.beginTransaction()
    let id = tx.put("inside tx", ring = "tx-ring")
    check not (id in db)
    tx.commit()
    check id in db
    check db.get(id) == "inside tx"
    db.close()

    var db2 = open(dataDir = dir)
    check db2.get(id) == "inside tx"
    db2.close()
    removeDir(dir)

  test "transaction preserves payload codec across WAL replay":
    let dir = createTempDir("koutendb", "tx-codec")
    var db = open(dataDir = dir)
    let tx = db.beginTransaction()
    let id = tx.put(encodedPayload("\x01\x02\x03", pcBif), ring = "binary")
    tx.commit()
    check db.getEncoded(id).codec == pcBif
    db.close()

    var reopened = open(dataDir = dir)
    check reopened.getEncoded(id) == encodedPayload("\x01\x02\x03", pcBif)
    reopened.close()
    removeDir(dir)

  test "rollback した書き込みは見えない":
    var db = open()
    let tx = db.beginTransaction()
    let id = tx.put("rolled back")
    tx.rollback()
    check not (id in db)
    db.close()

  test "rollback-created ring names do not survive reopen":
    let dir = createTempDir("koutendb", "tx-ring-rollback")
    var db = open(dataDir = dir)
    let tx = db.beginTransaction()
    discard tx.put("hidden", ring = "events/rolled-back")
    tx.rollback()
    db.close()

    var reopened = open(dataDir = dir)
    check reopened.readRing("events/rolled-back").items.len == 0
    check reopened.ringMetrics().len == 0
    reopened.close()
    removeDir(dir)

  test "transaction 内の削除は commit 後に反映される":
    var db = open()
    let id = db.put("delete me")
    let tx = db.beginTransaction()
    tx.remove(id)
    check id in db
    tx.commit()
    check not (id in db)
    db.close()

  test "transaction helper は例外時 rollback":
    var db = open()
    var id: KoutenId
    expect ValueError:
      db.transaction(proc(tx: KoutenTx) =
        id = tx.put("never")
        raise newException(ValueError, "boom")
      )
    check not (id in db)
    db.close()

  test "atomic batch put rolls back every staged write on failure":
    var db = open()
    var ids: seq[KoutenId] = @[]
    expect ValueError:
      db.transaction(proc(tx: KoutenTx) =
        ids.add tx.put("a", ring = "bulk")
        ids.add tx.put("b", ring = "bulk")
        raise newException(ValueError, "bulk validation failed")
      )
    check ids.len == 2
    check not (ids[0] in db)
    check not (ids[1] in db)
    db.close()

  test "batchUpdateAtomic rolls back earlier staged updates when one id fails":
    var db = open()
    let id = db.put("before", ring = "bulk")
    let missing = fromRaw(id.toRaw().parent, id.toRaw().epoch,
                          id.toRaw().seq + 100'u32, id.toRaw().tWrite)
    expect KeyError:
      db.batchUpdateAtomic(@[id, missing], @["after", "missing"])
    check db.get(id) == "before"
    db.close()

  test "batchPutAtomic commits all writes together":
    var db = open()
    let ids = db.batchPutAtomic(@["a", "b", "c"], ring = "bulk")
    check ids.len == 3
    check db.get(ids[0]) == "a"
    check db.get(ids[1]) == "b"
    check db.get(ids[2]) == "c"
    db.close()

  test "ring and stellar locks are opt-in cooperative guards":
    var db = open()
    discard db.put("user", ring = "users/123")
    discard db.put("order", ring = "orders/A-001")
    db.attachStellar("commerce/order/A-001", "users/123")
    db.attachStellar("commerce/order/A-001", "orders/A-001")

    let stellarLock = db.acquireStellarLock("commerce/order/A-001", ttlSeconds = 5)
    expect KoutenConflictError:
      discard db.acquireRingLock("users/123", ttlSeconds = 5)
    expect IOError:
      discard db.acquireRingLock("users/123", ttlSeconds = 5)
    db.releaseLock(stellarLock)

    let ringLock = db.acquireRingLock("users/123", ttlSeconds = 5)
    expect IOError:
      discard db.acquireStellarLock("commerce/order/A-001", ttlSeconds = 5)
    db.releaseLock(ringLock)

    var ran = false
    db.withRingLock("users/123", proc() =
      ran = true
      db.transaction(proc(tx: KoutenTx) =
        discard tx.put("audit", ring = "users/123/audit")
      )
    )
    check ran
    check db.readRing("users/123/audit").count == 1
    db.close()

  test "atomic batch matrix covers commit, rollback, mismatch, delete, and replay":
    let dir = createTempDir("koutendb", "atomic-matrix")
    var db = open(dataDir = dir)

    block putSuccess:
      let ids = db.batchPutAtomic(@["a", "b"], ring = "matrix")
      check ids.len == 2
      check db.get(ids[0]) == "a"
      check db.get(ids[1]) == "b"

    block updateLengthMismatch:
      let id = db.put("unchanged", ring = "matrix")
      expect KoutenValidationError:
        db.batchUpdateAtomic(@[id], @["x", "extra"])
      expect ValueError:
        db.batchUpdateAtomic(@[id], @["x", "extra"])
      check db.get(id) == "unchanged"

    block updateMissingIdRollback:
      let first = db.put("first-before", ring = "matrix")
      let second = db.put("second-before", ring = "matrix")
      let raw = second.toRaw()
      let missing = fromRaw(raw.parent, raw.epoch, raw.seq + 999'u32, raw.tWrite)
      expect KeyError:
        db.batchUpdateAtomic(@[first, missing], @["first-after", "missing"])
      check db.get(first) == "first-before"
      check db.get(second) == "second-before"

    block deleteMissingIdRollback:
      let keepA = db.put("keep-a", ring = "matrix")
      let keepB = db.put("keep-b", ring = "matrix")
      let raw = keepB.toRaw()
      let missing = fromRaw(raw.parent, raw.epoch, raw.seq + 999'u32, raw.tWrite)
      expect KeyError:
        db.batchDeleteAtomic(@[keepA, missing])
      check keepA in db
      check keepB in db
      check db.get(keepA) == "keep-a"
      check db.get(keepB) == "keep-b"

    block deleteSuccess:
      let goneA = db.put("gone-a", ring = "matrix")
      let goneB = db.put("gone-b", ring = "matrix")
      db.batchDeleteAtomic(@[goneA, goneB])
      check not (goneA in db)
      check not (goneB in db)

    block replay:
      let persisted = db.batchPutAtomic(@["persist-a", "persist-b"], ring = "matrix")
      db.close()
      var reopened = open(dataDir = dir)
      check reopened.get(persisted[0]) == "persist-a"
      check reopened.get(persisted[1]) == "persist-b"
      reopened.close()
      removeDir(dir)

  test "coordinate lock conflict matrix covers overlap, disjoint, ttl, and finally release":
    var db = open()
    discard db.put("user", ring = "users/123")
    discard db.put("order", ring = "orders/A-001")
    discard db.put("shop", ring = "shops/1123")
    db.attachStellar("commerce/order/A-001", "users/123")
    db.attachStellar("commerce/order/A-001", "orders/A-001")
    db.attachStellar("commerce/order/A-001", "shops/1123")

    block sameRingConflicts:
      let lock = db.acquireRingLock("users/123", ttlSeconds = 5)
      check db.lockActive(lock)
      expect IOError:
        discard db.acquireRingLock("users/123", ttlSeconds = 5)
      db.releaseLock(lock)
      check not db.lockActive(lock)

    block disjointRingsDoNotConflict:
      let a = db.acquireRingLock("users/123", ttlSeconds = 5)
      let b = db.acquireRingLock("products/9", ttlSeconds = 5)
      check db.lockActive(a)
      check db.lockActive(b)
      db.releaseLock(a)
      db.releaseLock(b)

    block stellarConflictsWithMemberRings:
      let stellar = db.acquireStellarLock("commerce/order/A-001", ttlSeconds = 5)
      for ring in ["users/123", "orders/A-001", "shops/1123"]:
        expect IOError:
          discard db.acquireRingLock(ring, ttlSeconds = 5)
      db.releaseLock(stellar)

    block memberRingConflictsWithStellar:
      let orderLock = db.acquireRingLock("orders/A-001", ttlSeconds = 5)
      expect IOError:
        discard db.acquireStellarLock("commerce/order/A-001", ttlSeconds = 5)
      db.releaseLock(orderLock)

    block unrelatedStellarDoesNotConflict:
      let one = db.acquireStellarLock("commerce/order/A-001", ttlSeconds = 5)
      let other = db.acquireStellarLock("support/ticket/T-001", ttlSeconds = 5)
      check db.lockActive(one)
      check db.lockActive(other)
      db.releaseLock(one)
      db.releaseLock(other)

    block ttlExpiryReleasesLock:
      let short = db.acquireRingLock("users/123", ttlSeconds = 0.01)
      sleep(30)
      check not db.lockActive(short)
      let next = db.acquireRingLock("users/123", ttlSeconds = 5)
      check db.lockActive(next)
      check next.fence > short.fence
      check next.token != short.token
      db.releaseLock(next)

    block finallyReleaseOnException:
      expect ValueError:
        db.withStellarLock("commerce/order/A-001", proc() =
          raise newException(ValueError, "workflow failed")
        )
      let after = db.acquireRingLock("users/123", ttlSeconds = 5)
      check db.lockActive(after)
      db.releaseLock(after)

    db.close()

  test "coordinate lock edge cases are fail-closed and idempotent":
    var db = open()
    discard db.put("user", ring = "users/123")

    expect KoutenValidationError:
      discard db.acquireRingLock("")
    expect KoutenValidationError:
      discard db.acquireStellarLock("")
    expect KoutenValidationError:
      discard db.acquireRingLock("users/123", ttlSeconds = 0)

    let first = db.acquireRingLock("users/123", ttlSeconds = 0.01)
    sleep(30)
    let second = db.acquireRingLock("users/123", ttlSeconds = 5)
    check second.fence > first.fence
    check second.token != first.token

    db.releaseLock(first)
    check db.lockActive(second)
    db.releaseLock(second)
    db.releaseLock(second)
    check not db.lockActive(second)

    let third = db.acquireRingLock("users/123", ttlSeconds = 5)
    check db.lockActive(third)
    db.releaseLock(KoutenLockToken(scope: third.scope,
                                  coordinate: third.coordinate,
                                  token: third.token & "-stale",
                                  fence: third.fence,
                                  expiresAt: third.expiresAt,
                                  keys: third.keys))
    check db.lockActive(third)
    db.releaseLock(third)
    db.close()

suite "galaxy router":
  test "コードから複数銀河を別 DB として扱える":
    let dirA = createTempDir("koutendb", "galaxy-a")
    let dirB = createTempDir("koutendb", "galaxy-b")
    var a = open(dataDir = dirA)
    var b = open(dataDir = dirB)
    let ida = a.put("A data", ring = "docs")
    let idb = b.put("B data", ring = "docs")
    check a.get(ida) == "A data"
    check b.get(idb) == "B data"
    a.close()
    b.close()
    removeDir(dirA)
    removeDir(dirB)
