import std/[json, os]
import ../src/koutendb

if paramCount() != 1:
  quit("usage: tauto_pack_fixture DATA_DIR", 2)

var db = open(dataDir = paramStr(1), diskBacked = true)
let hot = db.put(%*{"value": 0}, ring = "maintenance/hot")
discard db.put(%*{"value": 0}, ring = "maintenance/cold")
for i in 1 .. 16:
  db.update(hot, %*{"value": i})
db.close()
