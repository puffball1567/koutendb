import std/[json, os, sets, tempfiles, unittest]
import ../src/koutendb

suite "read boundary regressions":
  for diskBacked in [false, true]:
    test "filtered cursor preserves the complete ID set, disk=" & $diskBacked:
      let dir = createTempDir("kouten-read-boundary-", "")
      defer: removeDir(dir)
      var db = open(dataDir = dir, diskBacked = diskBacked)
      defer: db.close()
      var expected = initHashSet[string]()
      var ids: seq[KoutenId]
      for i in 0 ..< 237:
        let id = db.put(%*{"n": i, "group": i mod 3}, ring = "records")
        ids.add id
        if i mod 3 == 1: expected.incl $id
      for stage in 0 .. 3:
        if stage == 1:
          db.remove(ids[1])
          expected.excl $ids[1]
          db.update(ids[4], %*{"n": 4, "group": 2})
          expected.excl $ids[4]
          db.update(ids[0], %*{"n": 0, "group": 1})
          expected.incl $ids[0]
        if stage == 2:
          discard db.compact()
          if diskBacked: discard db.packDiskBackedSegments()
        if stage == 3:
          db.close()
          db = open(dataDir = dir, diskBacked = diskBacked)
        for limit in [1, 7, 99, 100, 101, 300]:
          var opts = defaultReadOptions()
          opts.filter = %*{"group": 1}
          opts.limit = limit
          var actual = initHashSet[string]()
          for pageNumber in 0 .. 238:
            let page = db.readRing("records", opts)
            check page.items.len <= limit
            for item in page.items:
              check $item.id notin actual
              check parseJson(item.payload)["group"].getInt() == 1
              actual.incl $item.id
            if page.nextCursor.len == 0: break
            check page.nextCursor != opts.cursor
            opts.cursor = page.nextCursor
            check pageNumber < 238
          check actual == expected

  test "malformed filters fail even on an empty ring":
    var db = open()
    defer: db.close()
    discard db.put(%*{"a": 1, "b": 2}, ring = "records")
    for ring in ["records", "missing"]:
      for invalid in [newJArray(), newJNull(), %true, %7, %*{"id": 42}]:
        var opts = defaultReadOptions()
        opts.filter = invalid
        expect ValueError:
          discard db.readRing(ring, opts)
        var stellarOpts = defaultStellarOptions()
        stellarOpts.filter = invalid
        expect ValueError:
          discard db.readStellar(ring, stellarOpts)

  test "pagination rejects overflow before reading":
    var db = open()
    defer: db.close()
    var opts = defaultReadOptions()
    opts.pagination = rpOn
    opts.page = high(int)
    opts.pageLimit = 2
    expect ValueError:
      discard db.readRing("missing", opts)

  test "multi-field filtering preserves nested JSON equality":
    var db = open()
    defer: db.close()
    discard db.put(%*{"a": 1, "b": {"c": [1, 2]}, "d": true}, ring = "records")
    discard db.put(%*{"a": 1, "b": {"c": [1, 3]}, "d": true}, ring = "records")
    discard db.put("not-json", ring = "records")
    var opts = defaultReadOptions()
    opts.filter = %*{"a": 1, "b": {"c": [1, 2]}, "d": true}
    let page = db.readRing("records", opts)
    check page.count == 1
    check parseJson(page.items[0].payload)["b"]["c"][1].getInt() == 2

  for diskBacked in [false, true]:
    test "time range is checked before limit and projection, disk=" & $diskBacked:
      let dir = createTempDir("kouten-time-boundary-", "")
      defer: removeDir(dir)
      var db = open(dataDir = dir, diskBacked = diskBacked)
      defer: db.close()
      db.configureTimeOrbitProfile("logs", TimeOrbitProfile(
        bits: 60, bucketMs: 1000, phase: 0, salt: "logs"))
      discard db.putTime(%*{"name": "early"}, "logs", 1100)
      let expected = db.putTime(%*{"name": "wanted"}, "logs", 1500)
      discard db.putTime(%*{"name": "late"}, "logs", 1900)
      for selection in ["", "{ name }"]:
        for limit in [1, 10]:
          var opts = defaultReadOptions()
          opts.limit = limit
          opts.selection = selection
          let page = db.readTime("logs", 1400, 1600, opts)
          check page.count == 1
          if page.count == 1:
            check page.items[0].id == expected
