## Process-crash recovery helper used by scripts/disk_backed_recovery_smoke.sh.

import std/[parseopt, strformat, tables]
import ../src/kouten/store

proc usage() =
  quit("usage: disk_backed_recovery_matrix --mode=worker|verify --data=DIR --ready=FILE", 2)

proc worker(dataDir, readyPath: string) =
  var store = openStore(dataDir, durability = durStrong, diskBacked = true)
  var batch = 0'u32
  while true:
    let tx = store.beginTxn()
    tx.upsert Particle(parent: 101'u64, seq: batch, period: 60.0,
                       head: 0.0, tWrite: float(batch),
                       payload: "left-" & $batch)
    tx.upsert Particle(parent: 102'u64, seq: batch, period: 60.0,
                       head: 0.0, tWrite: float(batch),
                       payload: "right-" & $batch)
    tx.commit()
    if batch == 100'u32:
      writeFile(readyPath, "ready\n")
    inc batch

proc assertPaired(store: Store): int =
  let left = store.itemsByRing.getOrDefault(101'u64, @[])
  let right = store.itemsByRing.getOrDefault(102'u64, @[])
  if left.len != right.len:
    raise newException(AssertionDefect,
      &"transaction rings diverged: left={left.len} right={right.len}")
  for k in left:
    if not store.contains(102'u64, k[1]):
      raise newException(AssertionDefect,
        "committed transaction is missing right record " & $k[1])
    let a = store.getParticle(101'u64, k[1]).payload
    let b = store.getParticle(102'u64, k[1]).payload
    if a != "left-" & $k[1] or b != "right-" & $k[1]:
      raise newException(AssertionDefect,
        "transaction payload mismatch at " & $k[1])
  left.len

proc verify(dataDir: string) =
  let backupDir = dataDir & "-backup"
  let restoredDir = dataDir & "-restored"
  var store = openStore(dataDir, durability = durStrong, diskBacked = true)
  let recovered = store.assertPaired()
  if recovered < 101:
    raise newException(AssertionDefect,
      "worker did not commit the recovery baseline")
  discard store.packRingSegment(101'u64)
  discard store.packRingSegment(102'u64)
  if store.assertPaired() != recovered:
    raise newException(AssertionDefect, "ring pack changed the logical result")
  discard store.compact()
  if store.assertPaired() != recovered:
    raise newException(AssertionDefect, "compact changed the logical result")
  discard store.backup(backupDir)
  store.close()

  discard restoreBackup(backupDir, restoredDir)
  var restored = openStore(restoredDir, durability = durStrong,
                           diskBacked = true)
  if restored.assertPaired() != recovered:
    raise newException(AssertionDefect, "backup/restore changed the logical result")
  restored.close()
  echo &"recovery-matrix OK pairedRecords={recovered}"

proc main() =
  var mode = ""
  var dataDir = ""
  var readyPath = ""
  for kind, key, val in getopt():
    if kind != cmdLongOption:
      continue
    case key
    of "mode": mode = val
    of "data": dataDir = val
    of "ready": readyPath = val
    else: usage()
  if dataDir.len == 0:
    usage()
  case mode
  of "worker":
    if readyPath.len == 0: usage()
    worker(dataDir, readyPath)
  of "verify": verify(dataDir)
  else: usage()

when isMainModule:
  main()
