import std/[json, os]
import ../src/koutendb

if paramCount() != 1:
  quit("usage: tauto_pack_fixture DATA_DIR", 2)

var db = open(dataDir = paramStr(1), diskBacked = true)
let hot = db.put(%*{"value": 0}, ring = "maintenance/hot")
discard db.put(%*{"value": 0}, ring = "maintenance/cold")
for i in 1 .. 16:
  db.update(hot, %*{"value": i})

var paged: seq[KoutenId] = @[]
for i in 0 ..< 700:
  paged.add db.put(%*{"n": i, "revision": 0}, ring = "pagination/paged")
discard db.packDiskBackedRing("pagination/paged")
for i in 0 ..< 200:
  db.update(paged[i], %*{"n": i, "revision": 1})
for i in countup(0, 680, 17):
  db.remove(paged[i])
db.close()
