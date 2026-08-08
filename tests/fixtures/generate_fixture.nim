## Compile this file against a tagged KoutenDB source tree to regenerate an
## authentic upgrade fixture. See tests/fixtures/README.md for commands.

import std/[json, os]
import koutendb

if paramCount() != 2:
  quit("usage: generate_fixture DATA_DIR DUMP_PATH", 2)

let dataDir = paramStr(1)
let dumpPath = paramStr(2)
var db = open(nodes = 4, dataDir = dataDir, durability = durStrong,
              diskBacked = true)
db.setGalaxyDescription("upgrade compatibility fixture")
db.setRingDescription("users/123/profile", "Current user profile")
db.configureRingPayloadProfile("codecs/nif", RingPayloadProfile(
  defaultCodec: pcNif, charset: "UTF-8", formatVersion: "5"))
db.configureRingPayloadProfile("codecs/bif", RingPayloadProfile(
  defaultCodec: pcBif, charset: "binary", formatVersion: "5"))

let profile = db.put(%*{
  "kind": "profile", "userId": 123, "name": "Ada", "active": true
}, ring = "users/123/profile", vec = @[0.1'f32, 0.2'f32, 0.3'f32])
db.advance(0.25)
db.update(profile, encodedPayload($( %*{
  "kind": "profile", "userId": 123, "name": "Ada Lovelace",
  "active": true
}), pcJson), vec = @[0.2'f32, 0.3'f32, 0.4'f32])

db.advance(0.25)
discard db.put(%*{
  "kind": "order", "orderId": "A-100", "amount": 1250,
  "status": "paid"
}, ring = "users/123/orders", vec = @[0.9'f32, 0.1'f32])
db.advance(0.25)
let removed = db.put(%*{
  "kind": "order", "orderId": "A-101", "amount": 50,
  "status": "cancelled"
}, ring = "users/123/orders")
db.remove(removed)

var tx = db.beginTransaction()
discard tx.put(%*{
  "kind": "notification", "message": "first", "read": false
}, ring = "users/123/notifications")
discard tx.put(%*{
  "kind": "notification", "message": "second", "read": true
}, ring = "users/123/notifications")
tx.commit()

discard db.put(encodedPayload("raw\0payload", pcRaw), ring = "codecs/raw")
discard db.put(encodedPayload("(object (title \"NIF fixture\"))", pcNif),
               ring = "codecs/nif")
discard db.put(encodedPayload("BIF\0fixture\x01\x7f", pcBif),
               ring = "codecs/bif")

var deletedEvent: KoutenId
for i in 0 ..< 20:
  db.advance(0.01)
  let event = db.put(%*{
    "kind": "event", "sequence": i, "source": "upgrade-fixture"
  }, ring = "events/2026/08")
  if i == 5:
    deletedEvent = event
db.remove(deletedEvent)

discard db.packDiskBackedSegments()
when defined(koutenManifestFixture):
  for ring in ["users/123/profile", "users/123/orders",
               "users/123/notifications", "codecs/raw", "codecs/nif",
               "codecs/bif", "events/2026/08"]:
    discard db.packDiskBackedRing(ring)
discard db.dump(dumpPath)
db.close()
