## koutend - KoutenDB node server (design section 14: scale-out)
##
## usage: koutend --id=0 --peers=127.0.0.1:7301,127.0.0.1:7302,127.0.0.1:7303 [--data=DIR]
##   - Stable physical ownership is derived from a ring key and a persisted
##     topology epoch. Logical orbital time does not move durable records.
##   - Topology changes create a bounded startup migration plan. A source copy
##     remains authoritative until the destination acknowledges the same
##     mutation version under the expected topology.
##   - --data enables WAL persistence. Recovery rebuilds only the migration
##     work required by the active topology instead of periodically rescanning
##     every record.

import std/[algorithm, math, selectors, net, os, strutils, times, monotimes,
            json, tables, parseopt, hashes, atomics, heapqueue]
when not defined(windows):
  import std/posix
import kouten/[core, store, select, wire, field, auth, vector_backend]
import kouten/maintenance_window
from koutendb import KoutenSegmentMaintenancePolicy,
  defaultSegmentMaintenancePolicy, validateSegmentMaintenancePolicy,
  runSegmentMaintenance, recoverInterruptedSegmentMaintenance

const
  Grace = 1.0       # [s] 転送 ACK 後も尾流コピーを残す猶予
  TickMs = 100      # ハンドオフ判定の周期
  DefaultSlowTickSec = 10.0
  DefaultAutoPackIntervalSec = 300.0
  MaxTransfersPerTick = 256   # cheap queue submissions; worker provides backpressure
  HandoffQueueCapacity = 1024
  HandoffTimeoutMs = 500      # worker-only timeout; never blocks foreground reads
  DefaultPlacementEpoch = 1'u32
  DefaultVirtualArcsPerNode = 64
  TombstoneQueueDrainGraceSec =
    when defined(koutenTestFastTombstoneGc): 0.2
    else:
      2.0 * float(HandoffQueueCapacity * HandoffTimeoutMs) / 1000.0 +
      2.0 * Grace
  MaxPreparedSelections = 1024
  MaxPreparedSelectionSourceBytes = 64 * 1024
  MaxPreparedSelectionCacheBytes = 1024 * 1024
  DefaultPeriod = 60.0
  MaxWireBodyBytes = 64 * 1024 * 1024
  MaxWireVectorDim = MaxWireBodyBytes div sizeof(float32)
  MaxWireJsonDepth = 128
  SocketReadTimeoutMs =
    when defined(koutenTestBackpressure): 250
    else: 10_000
  SocketWriteTimeoutMs =
    when defined(koutenTestBackpressure): 250
    else: 10_000
  MaxActiveConnections =
    when defined(koutenTestBackpressure): 8
    else: 1024
  MaxListRingItems =
    when defined(koutenTestBackpressure): 32
    else: 10_000
  MaxRetrieveBudget =
    when defined(koutenTestSmallLimits): 4
    else: 1024
  MaxRetrieveScan =
    when defined(koutenTestSmallLimits): 3
    else: 1_000_000

type
  AutoPackConfig = object
    enabled: bool
    intervalSec: float
    window: MaintenanceWindow
    windowText: string
    policy: KoutenSegmentMaintenancePolicy

  HandoffTaskKind = enum
    htkTransfer, htkStop

  HandoffTask = object
    kind: HandoffTaskKind
    attempt: uint64
    target: int
    parent: uint64
    seq: uint32
    period: float
    head: float
    tWrite: float
    payload: string
    codec: PayloadCodec
    vec: seq[float32]
    version: MutationVersion
    deleted: bool
    acknowledgedNodes: seq[uint16]
    reclaimAfter: float
    migration: bool
    migrationMetadata: string

  HandoffResult = object
    attempt: uint64
    target: int
    parent: uint64
    seq: uint32
    applied: bool

  HandoffWorkerConfig = object
    peers: seq[Peer]
    username: string
    password: string
    secretKey: string
    tls: bool
    tlsCaFile: string
    tlsServerName: string
    tlsInsecureSkipVerify: bool
    placementEpoch: uint32
    placementNodes: uint16
    virtualArcsPerNode: int

  PendingHandoff = object
    attempt: uint64
    target: int
    period: float
    head: float
    tWrite: float
    payload: string
    codec: PayloadCodec
    vec: seq[float32]
    version: MutationVersion
    deleted: bool
    acknowledgedNodes: seq[uint16]
    reclaimAfter: float
    queuedAt: float
    retries: int
    migration: bool

  HandoffWork = object
    parent: uint64
    seq: uint32
    target: int
    deleted: bool
    queuedAt: float
    notBefore: float
    retries: int
    migration: bool

  TombstoneReclaim = object
    due: float
    parent: uint64
    seq: uint32
    version: MutationVersion

  UserRole = enum
    roleReader, roleWriter, roleAdmin

  UserRule = object
    password: string
    role: UserRole
    prefixes: seq[string]

  Server = ref object
    myId: int
    peers: seq[Peer]
    tbl: ArcTable
    virtualArcsPerNode: int
    st: Store
    dataDir: string
    fs: FieldState
    peerLink: ClusterClient
    pendingHandoffs: Table[(uint64, uint32), PendingHandoff]
    handoffWork: seq[HandoffWork]
    handoffWorkHead: int
    scheduledHandoffs: Table[(uint64, uint32, int, bool), bool]
    migrationRings: seq[uint64]
    migrationRingIndex: int
    migrationItemIndex: int
    migrationRemaining: int
    migrationStartedAt: float
    tombstoneStartupKeys: seq[(uint64, uint32)]
    tombstoneStartupIndex: int
    tombstoneCompletionSent: Table[(uint64, uint32, int), bool]
    tombstoneReclaims: HeapQueue[TombstoneReclaim]
    nextHandoffAttempt: uint64
    handoffQueued: uint64
    handoffApplied: uint64
    handoffFailed: uint64
    handoffStaleAck: uint64
    handoffQueueFull: uint64
    tombstonesReclaimed: uint64
    slowTickSec: float
    autoPack: AutoPackConfig
    autoPackLastAttempt: float
    autoPackAttempts: uint64
    autoPackCompleted: uint64
    autoPackPartial: uint64
    autoPackInterrupted: uint64
    autoPackFailed: uint64
    autoPackNoWork: uint64
    autoPackRings: uint64
    autoPackBytes: uint64
    autoPackLastElapsedMs: int64
    running: bool
    draining: bool
    drainStartedAt: float
    authUser: string
    authPassword: string
    authSecretKey: string
    tlsEnabled: bool
    tlsCertFile: string
    tlsKeyFile: string
    tlsCaFile: string
    tlsServerName: string
    tlsInsecureSkipVerify: bool
    when defined(ssl):
      tlsContext: SslContext
    users: Table[string, UserRule]
    galaxy: string
    allowedRingPrefixes: seq[string]
    authed: Table[int, bool]
    authedUsers: Table[int, string]
    authChallenges: Table[int, string]
    startedAt: float
    requestCount: uint64
    errorResponses: uint64
    authFailures: uint64
    authzDenied: uint64
    drainRejectedWrites: uint64
    connectionsAccepted: uint64
    connectionsRejected: uint64
    activeConnections: int
    universeApplyApplied: uint64
    universeApplySkipped: uint64
    universeApplyErrors: uint64
    universeApplyForwarded: uint64
    universeApplyLastOk: float
    universeApplyLastError: float
    retrieveRequests: uint64
    retrieveScopedRequests: uint64
    retrieveGlobalRequests: uint64
    retrievePhysicalVisited: uint64
    retrieveCandidatesScored: uint64
    preparedSelections: Table[string, Selection]
    preparedSelectionLru: seq[string]
    preparedSelectionBytes: int
    codecMetadata: Table[int, bool]

proc `<`(a, b: TombstoneReclaim): bool =
  a.due < b.due

var
  handoffTasks: Channel[HandoffTask]
  handoffResults: Channel[HandoffResult]
  handoffStopping: Atomic[bool]

proc handoffWorker(config: HandoffWorkerConfig) {.thread.} =
  let client = newClusterClient(config.peers,
                                username = config.username,
                                password = config.password,
                                secretKey = config.secretKey,
                                tls = config.tls,
                                tlsCaFile = config.tlsCaFile,
                                tlsServerName = config.tlsServerName,
                                tlsInsecureSkipVerify =
                                  config.tlsInsecureSkipVerify)
  var migratedRingMetadata = initTable[(int, uint64), bool]()
  try:
    while true:
      let task = handoffTasks.recv()
      if task.kind == htkStop or handoffStopping.load():
        break
      var applied = false
      try:
        let remoteTopology = client.topologyReq(task.target)
        if remoteTopology.epoch != config.placementEpoch or
            remoteTopology.nNodes != config.placementNodes or
            remoteTopology.arcs.len !=
              int(config.placementNodes) * config.virtualArcsPerNode:
          raise newException(IOError,
            "handoff destination has incompatible placement topology")
        let metadataKey = (task.target, task.parent)
        if task.migration and task.migrationMetadata.len > 0 and
            not migratedRingMetadata.getOrDefault(metadataKey, false):
          client.migrationMetadataReq(
            task.target, task.migrationMetadata, config.placementEpoch,
            config.placementNodes, config.virtualArcsPerNode)
          migratedRingMetadata[metadataKey] = true
        if task.deleted:
          client.transferDeleteReq(task.target, task.parent, task.seq,
                                   task.period, task.head, task.tWrite,
                                   task.version,
                                   acknowledgedNodes = task.acknowledgedNodes,
                                   reclaimAfter = task.reclaimAfter,
                                   expectedPlacementEpoch =
                                     config.placementEpoch,
                                   expectedPlacementNodes =
                                     config.placementNodes,
                                   expectedVirtualArcs =
                                     config.virtualArcsPerNode,
                                   maintenanceMigration = task.migration,
                                   timeoutMs = HandoffTimeoutMs)
        else:
          client.transferReq(task.target, task.parent, task.seq, task.period,
                             task.head, task.tWrite, task.payload, task.vec,
                             task.codec, task.version,
                             expectedPlacementEpoch = config.placementEpoch,
                             expectedPlacementNodes = config.placementNodes,
                             expectedVirtualArcs =
                               config.virtualArcsPerNode,
                             maintenanceMigration = task.migration,
                             timeoutMs = HandoffTimeoutMs)
        applied = true
      except CatchableError:
        discard
      handoffResults.send HandoffResult(
        attempt: task.attempt,
        target: task.target,
        parent: task.parent,
        seq: task.seq,
        applied: applied)
  finally:
    client.close()

proc stableErrorCode(e: ref Exception): string =
  ## Remote clients get stable protocol categories, not internal exception text.
  if e of ValueError or e of JsonParsingError or e of KeyError:
    "bad-request"
  elif e of IOError or e of OSError:
    "io-error"
  else:
    "internal"

proc sendStableError(sock: Socket, e: ref Exception) =
  sock.sendFrame("ERR " & stableErrorCode(e))

proc audit(sv: Server, event: string; ok = true; user = ""; ring = "";
           ringKey = ""; message = ""; extra: JsonNode = nil) =
  if sv.dataDir.len == 0:
    return
  var node = %*{
    "timestamp": epochTime(),
    "event": event,
    "ok": ok,
    "user": user,
    "ring": ring,
    "ringKey": ringKey,
    "message": message
  }
  if not extra.isNil:
    node["extra"] = extra
  try:
    var f = open(sv.dataDir / "kouten.audit.jsonl", fmAppend)
    try:
      f.writeLine($node)
    finally:
      f.close()
  except CatchableError:
    discard

proc readSecretFile(path, label: string): string =
  if path.len == 0:
    return ""
  result = readFile(path).strip()
  if result.len == 0:
    raise newException(ValueError, label & " file is empty")

proc compiledSelection(sv: Server, source: string): Selection =
  if source in sv.preparedSelections:
    for i in countdown(sv.preparedSelectionLru.len - 1, 0):
      if sv.preparedSelectionLru[i] == source:
        sv.preparedSelectionLru.delete(i)
        break
    sv.preparedSelectionLru.add source
    return sv.preparedSelections[source]
  if source.len > MaxPreparedSelectionSourceBytes:
    raise newException(ValueError,
      "selection exceeds max source bytes " & $MaxPreparedSelectionSourceBytes)
  result = parseSelection(source)
  if source.len > MaxPreparedSelectionCacheBytes:
    return
  while sv.preparedSelections.len >= MaxPreparedSelections or
      sv.preparedSelectionBytes + source.len > MaxPreparedSelectionCacheBytes:
    if sv.preparedSelectionLru.len == 0:
      break
    let victim = sv.preparedSelectionLru[0]
    sv.preparedSelectionLru.delete(0)
    if victim in sv.preparedSelections:
      sv.preparedSelections.del victim
      sv.preparedSelectionBytes = max(0, sv.preparedSelectionBytes - victim.len)
  if sv.preparedSelections.len < MaxPreparedSelections and
      sv.preparedSelectionBytes + source.len <= MaxPreparedSelectionCacheBytes:
    sv.preparedSelections[source] = result
    sv.preparedSelectionLru.add source
    inc sv.preparedSelectionBytes, source.len

proc projectPayload(sv: Server, payload: string, codec: PayloadCodec,
                    selection: string): string =
  if not codec.supportsJsonProjection:
    raise newException(ValueError,
      "payload codec " & codec.payloadCodecName & " does not support JSON projection")
  $applySelection(sv.compiledSelection(selection), parseJson(payload))

proc codecSuffix(sv: Server, sock: Socket, codec: PayloadCodec): string =
  if sv.codecMetadata.getOrDefault(sock.getFd.int, false):
    " " & codec.payloadCodecName
  else:
    ""

proc prepareTombstoneForNode(sv: Server, tombstone: Tombstone,
                             now: float): Tombstone =
  result = tombstone
  for node in result.acknowledgedNodes:
    if int(node) >= sv.peers.len:
      raise newException(ValueError,
        "tombstone acknowledgement references an unknown node")
  let wasComplete =
    result.acknowledgedNodes.acknowledgesAllNodes(sv.peers.len)
  discard result.acknowledgedNodes.acknowledgeNode(uint16(sv.myId))
  if not wasComplete and
      result.acknowledgedNodes.acknowledgesAllNodes(sv.peers.len):
    # Physical placement no longer follows the logical orbit. Keep guards
    # through the bounded handoff drain window instead of waiting for an orbit.
    result.reclaimAfter =
      max(result.reclaimAfter, now + TombstoneQueueDrainGraceSec)

proc reclaimReadyTombstones(sv: Server, now: float) =
  while sv.tombstoneReclaims.len > 0 and sv.tombstoneReclaims[0].due <= now:
    let entry = sv.tombstoneReclaims.pop()
    let k = (entry.parent, entry.seq)
    if k notin sv.st.tombstones:
      continue
    let tombstone = sv.st.tombstones[k]
    if tombstone.version != entry.version or
        tombstone.reclaimAfter <= 0 or tombstone.reclaimAfter > now or
        not tombstone.acknowledgedNodes.acknowledgesAllNodes(sv.peers.len):
      continue
    var fanoutComplete = true
    for target in 0 ..< sv.peers.len:
      if target != sv.myId and
          not sv.tombstoneCompletionSent.getOrDefault(
            (entry.parent, entry.seq, target), false):
        fanoutComplete = false
        break
    if fanoutComplete and sv.st.reclaimTombstone(entry.parent, entry.seq):
      inc sv.tombstonesReclaimed
    elif not fanoutComplete:
      var retry = entry
      retry.due = now + Grace
      sv.tombstoneReclaims.push retry

proc ringInfo(sv: Server, name: string): tuple[key: uint64, period, head: float] =
  if name == "halo":
    result = (key: HaloKey, period: HaloPeriod, head: 0.0)
  else:
    let key = uint64(hash(name)) or 1'u64
    result = (key: key, period: DefaultPeriod, head: float(key mod 628) / 100.0)
  if result.key notin sv.st.ringMeta:
    sv.st.putRingMeta(result.key, result.period, result.head)
  if result.key notin sv.st.ringNames or sv.st.ringNames[result.key] != name:
    sv.st.putRingName(result.key, name)

proc authzEnabled(sv: Server): bool =
  sv.allowedRingPrefixes.len > 0 or sv.users.len > 0

proc parseRole(s: string): UserRole =
  case s.toLowerAscii()
  of "reader", "read": roleReader
  of "writer", "write": roleWriter
  of "admin": roleAdmin
  else:
    raise newException(ValueError, "role must be reader, writer, or admin")

proc roleAllowed(role: UserRole, need: UserRole): bool =
  case need
  of roleReader: true
  of roleWriter: role in {roleWriter, roleAdmin}
  of roleAdmin: role == roleAdmin

proc parsePrefixes(s: string): seq[string] =
  for part in s.split(','):
    let prefix = part.strip()
    if prefix.len > 0:
      result.add prefix

proc parseStringList(node: JsonNode, key: string): seq[string] =
  if node.kind != JObject or not node.hasKey(key):
    return @[]
  let value = node[key]
  case value.kind
  of JString:
    result = parsePrefixes(value.getStr())
  of JArray:
    for item in value:
      if item.kind != JString:
        raise newException(ValueError, "config " & key & " entries must be strings")
      let part = item.getStr().strip()
      if part.len > 0:
        result.add part
  else:
    raise newException(ValueError, "config " & key & " must be a string or array")

proc jsonStringOpt(node: JsonNode, key, default: string): string =
  if node.kind == JObject and node.hasKey(key):
    if node[key].kind != JString:
      raise newException(ValueError, "config " & key & " must be a string")
    node[key].getStr()
  else:
    default

proc jsonIntOpt(node: JsonNode, key: string, default: int): int =
  if node.kind == JObject and node.hasKey(key):
    node[key].getInt().int
  else:
    default

proc jsonInt64Opt(node: JsonNode, key: string, default: int64): int64 =
  if node.kind == JObject and node.hasKey(key):
    node[key].getBiggestInt().int64
  else:
    default

proc jsonFloatOpt(node: JsonNode, key: string, default: float): float =
  if node.kind == JObject and node.hasKey(key):
    node[key].getFloat()
  else:
    default

proc jsonBoolOpt(node: JsonNode, key: string, default: bool): bool =
  if node.kind == JObject and node.hasKey(key):
    node[key].getBool()
  else:
    default

proc jsonPeersOpt(node: JsonNode, default: string): string =
  if node.kind != JObject or not node.hasKey("peers"):
    return default
  let peersNode = node["peers"]
  case peersNode.kind
  of JString:
    peersNode.getStr()
  of JArray:
    var parts: seq[string] = @[]
    for item in peersNode:
      if item.kind != JString:
        raise newException(ValueError, "config peers entries must be strings")
      parts.add item.getStr()
    parts.join(",")
  else:
    raise newException(ValueError, "config peers must be a string or array")

proc parseDurabilityValue(value: string): StoreDurability =
  case value
  of "buffered": durBuffered
  of "strong": durStrong
  else:
    raise newException(ValueError,
      "--durability must be 'buffered' or 'strong'")

proc parseUserRule(spec: string): tuple[user: string, rule: UserRule] =
  let parts = spec.split(':', maxsplit = 3)
  if parts.len < 3:
    raise newException(ValueError,
      "--role must be user:password:role[:prefix1,prefix2]")
  result.user = parts[0]
  result.rule = UserRule(password: parts[1],
                         role: parseRole(parts[2]),
                         prefixes: if parts.len >= 4: parsePrefixes(parts[3]) else: @[])
  if result.user.len == 0:
    raise newException(ValueError, "--role user must not be empty")

proc parseUserRule(node: JsonNode): tuple[user: string, rule: UserRule] =
  if node.kind == JString:
    return parseUserRule(node.getStr())
  if node.kind != JObject:
    raise newException(ValueError, "config roles entries must be strings or objects")
  result.user = jsonStringOpt(node, "user", jsonStringOpt(node, "username", ""))
  let passwordFile = jsonStringOpt(node, "passwordFile",
                                   jsonStringOpt(node, "password-file", ""))
  let password =
    if passwordFile.len > 0: readSecretFile(passwordFile, "role password")
    else: jsonStringOpt(node, "password", "")
  result.rule = UserRule(
    password: password,
    role: parseRole(jsonStringOpt(node, "role", "")),
    prefixes: parseStringList(node, "prefixes"))
  if result.user.len == 0:
    raise newException(ValueError, "config role user must not be empty")
  if result.rule.password.len == 0:
    raise newException(ValueError, "config role password must not be empty")

proc loadServerConfig(path: string, id: var int, peersStr, dataDir: var string,
                      slowTickSec: var float, diskBacked: var bool,
                      autoPack: var AutoPackConfig,
                      authUser, authPassword,
                      authPasswordFile, authTokenFile, authSecretKey,
                      authSecretKeyFile, tlsCertFile, tlsKeyFile, tlsCaFile,
                      tlsServerName: var string,
                      tlsInsecureSkipVerify: var bool,
                      users: var Table[string, UserRule], galaxy: var string,
                      allowedRingPrefixes: var seq[string],
                      durability: var StoreDurability,
                      placementEpoch: var uint32,
                      virtualArcsPerNode: var int,
                      startDrained: var bool) =
  let cfg = parseFile(path)
  if cfg.kind != JObject:
    raise newException(ValueError, "server config file must contain a JSON object")
  id = jsonIntOpt(cfg, "id", id)
  peersStr = jsonPeersOpt(cfg, peersStr)
  dataDir = jsonStringOpt(cfg, "data", dataDir)
  dataDir = jsonStringOpt(cfg, "dataDir", dataDir)
  slowTickSec = jsonFloatOpt(cfg, "slowTick", slowTickSec)
  slowTickSec = jsonFloatOpt(cfg, "slow-tick", slowTickSec)
  diskBacked = jsonBoolOpt(cfg, "diskBacked", diskBacked)
  diskBacked = jsonBoolOpt(cfg, "disk-backed", diskBacked)
  autoPack.enabled = jsonBoolOpt(cfg, "autoPack", autoPack.enabled)
  autoPack.enabled = jsonBoolOpt(cfg, "auto-pack", autoPack.enabled)
  autoPack.intervalSec = jsonFloatOpt(cfg, "autoPackInterval",
                                      autoPack.intervalSec)
  autoPack.intervalSec = jsonFloatOpt(cfg, "auto-pack-interval",
                                      autoPack.intervalSec)
  autoPack.windowText = jsonStringOpt(cfg, "autoPackWindow",
                                      autoPack.windowText)
  autoPack.windowText = jsonStringOpt(cfg, "auto-pack-window",
                                      autoPack.windowText)
  autoPack.policy.staleRatioThreshold = jsonFloatOpt(
    cfg, "autoPackStaleRatio", autoPack.policy.staleRatioThreshold)
  autoPack.policy.staleRatioThreshold = jsonFloatOpt(
    cfg, "auto-pack-stale-ratio", autoPack.policy.staleRatioThreshold)
  autoPack.policy.minStaleRecords = jsonIntOpt(
    cfg, "autoPackMinStaleRecords", autoPack.policy.minStaleRecords)
  autoPack.policy.minStaleRecords = jsonIntOpt(
    cfg, "auto-pack-min-stale-records", autoPack.policy.minStaleRecords)
  autoPack.policy.maxRings = jsonIntOpt(
    cfg, "autoPackMaxRings", autoPack.policy.maxRings)
  autoPack.policy.maxRings = jsonIntOpt(
    cfg, "auto-pack-max-rings", autoPack.policy.maxRings)
  autoPack.policy.maxBytes = jsonInt64Opt(
    cfg, "autoPackMaxBytes", autoPack.policy.maxBytes)
  autoPack.policy.maxBytes = jsonInt64Opt(
    cfg, "auto-pack-max-bytes", autoPack.policy.maxBytes)
  autoPack.policy.maxElapsedMs = jsonInt64Opt(
    cfg, "autoPackMaxElapsedMs", autoPack.policy.maxElapsedMs)
  autoPack.policy.maxElapsedMs = jsonInt64Opt(
    cfg, "auto-pack-max-elapsed-ms", autoPack.policy.maxElapsedMs)
  autoPack.window = parseMaintenanceWindow(autoPack.windowText)
  authUser = jsonStringOpt(cfg, "user", authUser)
  authUser = jsonStringOpt(cfg, "username", authUser)
  authPassword = jsonStringOpt(cfg, "password", authPassword)
  authPasswordFile = jsonStringOpt(cfg, "passwordFile", authPasswordFile)
  authPasswordFile = jsonStringOpt(cfg, "password-file", authPasswordFile)
  authSecretKey = jsonStringOpt(cfg, "secretKey", authSecretKey)
  authSecretKey = jsonStringOpt(cfg, "secret-key", authSecretKey)
  authSecretKeyFile = jsonStringOpt(cfg, "secretKeyFile", authSecretKeyFile)
  authSecretKeyFile = jsonStringOpt(cfg, "secret-key-file", authSecretKeyFile)
  tlsCertFile = jsonStringOpt(cfg, "tlsCertFile", tlsCertFile)
  tlsCertFile = jsonStringOpt(cfg, "tls-cert", tlsCertFile)
  tlsKeyFile = jsonStringOpt(cfg, "tlsKeyFile", tlsKeyFile)
  tlsKeyFile = jsonStringOpt(cfg, "tls-key", tlsKeyFile)
  tlsCaFile = jsonStringOpt(cfg, "tlsCaFile", tlsCaFile)
  tlsCaFile = jsonStringOpt(cfg, "tls-ca", tlsCaFile)
  tlsServerName = jsonStringOpt(cfg, "tlsServerName", tlsServerName)
  tlsServerName = jsonStringOpt(cfg, "tls-server-name", tlsServerName)
  tlsInsecureSkipVerify = jsonBoolOpt(cfg, "tlsInsecureSkipVerify",
                                      tlsInsecureSkipVerify)
  tlsInsecureSkipVerify = jsonBoolOpt(cfg, "tls-insecure-skip-verify",
                                      tlsInsecureSkipVerify)
  galaxy = jsonStringOpt(cfg, "galaxy", galaxy)
  for prefix in parseStringList(cfg, "allowRing"):
    allowedRingPrefixes.add prefix
  for prefix in parseStringList(cfg, "allow-ring"):
    allowedRingPrefixes.add prefix
  if cfg.hasKey("durability"):
    durability = parseDurabilityValue(cfg["durability"].getStr())
  let configuredEpoch =
    jsonIntOpt(cfg, "placementEpoch",
      jsonIntOpt(cfg, "placement-epoch", int(placementEpoch)))
  if configuredEpoch <= 0:
    raise newException(ValueError, "placementEpoch must be positive")
  placementEpoch = uint32(configuredEpoch)
  virtualArcsPerNode =
    jsonIntOpt(cfg, "virtualArcsPerNode",
      jsonIntOpt(cfg, "virtual-arcs-per-node", virtualArcsPerNode))
  startDrained = jsonBoolOpt(cfg, "startDrained",
                             jsonBoolOpt(cfg, "start-drained", startDrained))
  if cfg.hasKey("authToken"):
    authUser = "token"
    authPassword = cfg["authToken"].getStr()
  if cfg.hasKey("auth-token"):
    authUser = "token"
    authPassword = cfg["auth-token"].getStr()
  authTokenFile = jsonStringOpt(cfg, "authTokenFile", authTokenFile)
  authTokenFile = jsonStringOpt(cfg, "auth-token-file", authTokenFile)
  if cfg.hasKey("roles"):
    if cfg["roles"].kind != JArray:
      raise newException(ValueError, "config roles must be an array")
    for item in cfg["roles"]:
      let parsed = parseUserRule(item)
      users[parsed.user] = parsed.rule
      if authUser.len == 0:
        authUser = parsed.user
        authPassword = parsed.rule.password
  if cfg.hasKey("role"):
    let parsed = parseUserRule(cfg["role"])
    users[parsed.user] = parsed.rule
    if authUser.len == 0:
      authUser = parsed.user
      authPassword = parsed.rule.password

proc currentUser(sv: Server, sock: Socket): string =
  sv.authedUsers.getOrDefault(sock.getFd.int, sv.authUser)

proc userRule(sv: Server, user: string): UserRule =
  if user.len > 0 and user in sv.users:
    return sv.users[user]
  if sv.users.len > 0:
    return UserRule(password: "", role: roleReader, prefixes: @["__no-access__"])
  UserRule(password: sv.authPassword,
           role: roleAdmin,
           prefixes: sv.allowedRingPrefixes)

proc ringNameAllowed(sv: Server, name: string, user = ""): bool =
  if not sv.authzEnabled:
    return true
  let prefixes =
    if sv.users.len > 0: sv.userRule(user).prefixes
    else: sv.allowedRingPrefixes
  if prefixes.len == 0:
    return true
  for prefix in prefixes:
    if name == prefix or name.startsWith(prefix & "/"):
      return true
  false

proc ringKeyAllowed(sv: Server, ringKey: uint64, user = ""): bool =
  if not sv.authzEnabled:
    return true
  let name = sv.st.ringNames.getOrDefault(ringKey, "")
  name.len > 0 and sv.ringNameAllowed(name, user)

proc ringNameAllowed(sv: Server, sock: Socket, name: string): bool =
  sv.ringNameAllowed(name, sv.currentUser(sock))

proc ringKeyAllowed(sv: Server, sock: Socket, ringKey: uint64): bool =
  sv.ringKeyAllowed(ringKey, sv.currentUser(sock))

proc requireRole(sv: Server, sock: Socket, need: UserRole): bool =
  if sv.users.len == 0:
    return true
  let user = sv.currentUser(sock)
  let rule = sv.userRule(user)
  if roleAllowed(rule.role, need):
    return true
  inc sv.authzDenied
  inc sv.errorResponses
  sv.audit("authz-denied", ok = false, user = user,
           message = "role " & $rule.role & " cannot perform required operation")
  sock.sendFrame("ERR authz-denied role=" & $rule.role)
  false

proc rolePermitted(sv: Server, sock: Socket, need: UserRole): bool =
  if sv.users.len == 0:
    return true
  roleAllowed(sv.userRule(sv.currentUser(sock)).role, need)

proc requireRingKey(sv: Server, sock: Socket, ringKey: uint64): bool =
  if sv.ringKeyAllowed(ringKey, sv.currentUser(sock)):
    return true
  inc sv.authzDenied
  inc sv.errorResponses
  sv.audit("authz-denied", ok = false, user = sv.currentUser(sock),
           ringKey = $ringKey, message = "ring key is outside authorization boundary")
  sock.sendFrame("ERR authz-denied ringKey=" & $ringKey)
  false

proc drainBytes(sock: Socket, n: int) =
  if n > 0:
    discard sock.readExact(n)

proc checkedWireLen(n: int, label: string): int =
  if n < 0:
    raise newException(ValueError, label & " must be non-negative")
  if n > MaxWireBodyBytes:
    raise newException(ValueError, label & " exceeds max wire body bytes")
  n

proc checkedVecBytes(vecDim: int): int =
  if vecDim < 0:
    raise newException(ValueError, "vecDim must be non-negative")
  if vecDim > MaxWireVectorDim:
    raise newException(ValueError, "vecDim exceeds max wire vector dim")
  vecDim * sizeof(float32)

proc checkedFrameBytes(payloadLen, vecDim: int, extra = 0): int =
  let payloadBytes = checkedWireLen(payloadLen, "payloadLen")
  let vectorBytes = checkedVecBytes(vecDim)
  if extra < 0:
    raise newException(ValueError, "extra frame bytes must be non-negative")
  if payloadBytes > MaxWireBodyBytes - vectorBytes or
      payloadBytes + vectorBytes > MaxWireBodyBytes - extra:
    raise newException(ValueError, "frame body exceeds max wire body bytes")
  payloadBytes + vectorBytes + extra

proc requireParts(parts: seq[string], op: string, minLen: int) =
  if parts.len < minLen:
    raise newException(ValueError,
      op & " requires at least " & $minLen & " header fields")

proc validateJsonDepth(raw: string, maxDepth: int) =
  var depth = 0
  var inString = false
  var escaped = false
  for ch in raw:
    if inString:
      if escaped:
        escaped = false
      elif ch == '\\':
        escaped = true
      elif ch == '"':
        inString = false
    else:
      case ch
      of '"':
        inString = true
      of '{', '[':
        inc depth
        if depth > maxDepth:
          raise newException(ValueError,
            "JSON maximum depth " & $maxDepth & " exceeded")
      of '}', ']':
        if depth > 0:
          dec depth
      else:
        discard

proc setSocketTimeouts(sock: Socket, readTimeoutMs, writeTimeoutMs: int) =
  when defined(windows):
    discard
  else:
    var tv = posix.Timeval(tv_sec: posix.Time(readTimeoutMs div 1000),
                           tv_usec: posix.Suseconds(
                             (readTimeoutMs mod 1000) * 1000))
    discard posix.setsockopt(sock.getFd, SOL_SOCKET, SO_RCVTIMEO,
                             addr tv, SockLen(sizeof(tv)))
    tv = posix.Timeval(tv_sec: posix.Time(writeTimeoutMs div 1000),
                       tv_usec: posix.Suseconds(
                         (writeTimeoutMs mod 1000) * 1000))
    discard posix.setsockopt(sock.getFd, SOL_SOCKET, SO_SNDTIMEO,
                             addr tv, SockLen(sizeof(tv)))

proc denyRingName(sv: Server, sock: Socket, name: string) =
  sv.audit("authz-denied", ok = false, user = sv.currentUser(sock),
           ring = name, message = "ring is outside authorization boundary")
  sock.sendFrame("ERR authz-denied ring=" & name)

proc denyRingKey(sv: Server, sock: Socket, ringKey: uint64) =
  sv.audit("authz-denied", ok = false, user = sv.currentUser(sock),
           ringKey = $ringKey, message = "ring key is outside authorization boundary")
  sock.sendFrame("ERR authz-denied ringKey=" & $ringKey)

proc rejectDrainedWrite(sv: Server, sock: Socket, command: string) =
  inc sv.errorResponses
  inc sv.drainRejectedWrites
  sv.audit("write-denied", ok = false, user = sv.currentUser(sock),
           message = "server is draining; command=" & command)
  sock.sendFrame("ERR draining")

proc rejectIfDraining(sv: Server, sock: Socket, command: string): bool =
  if not sv.draining:
    return false
  sv.rejectDrainedWrite(sock, command)
  true

proc drainTxCommitOps(sock: Socket, nOps: int) =
  for _ in 0 ..< nOps:
    let h = sock.readHeader()
    let data = if h[0] == "P" or h[0] == "D": 1 else: 0
    requireParts(h, "TXCOMMIT op", data + 7)
    let payloadLen = parseInt(h[data + 5])
    let vecDim = parseInt(h[data + 6])
    sock.drainBytes(checkedFrameBytes(payloadLen, vecDim, extra = 1))

proc jsonFloat32Seq(node: JsonNode): seq[float32] =
  if node.isNil or node.kind != JArray:
    return @[]
  for item in node.items:
    case item.kind
    of JInt:
      result.add float32(item.getInt())
    of JFloat:
      result.add float32(item.getFloat())
    else:
      discard

proc applyUniverseEvent(sv: Server, event: JsonNode, now: float): string =
  if event.kind != JObject:
    raise newException(ValueError, "universe event must be an object")
  let eventKey = event{"eventKey"}.getStr()
  let ringName = event{"ring"}.getStr()
  let op = event{"op"}.getStr("put")
  if eventKey.len == 0:
    raise newException(ValueError, "universe event key is empty")
  if ringName.len == 0:
    raise newException(ValueError, "universe event ring is empty")
  if op != "put":
    raise newException(ValueError, "only put universe events are supported")
  if sv.st.isUniverseSyncEventApplied(eventKey):
    return "SKIPPED"
  let applyAfter = event{"applyAfter"}.getFloat()
  if applyAfter > now:
    return "DELAYED"
  let payload = event{"payload"}.getStr()
  let codec = parsePayloadCodec(event{"codec"}.getStr("raw"))
  let vec = jsonFloat32Seq(event{"vec"}).normalize()
  let ri = sv.ringInfo(ringName)
  let seq = sv.st.nextSeq(ri.key)
  let tWrite = event{"timestamp"}.getFloat(now)
  sv.st.upsert Particle(parent: ri.key, seq: seq, period: ri.period,
                        head: ri.head, tWrite: tWrite, payload: payload,
                        codec: codec, vec: vec, lastHere: now)
  if ri.key != HaloKey:
    sv.fs.observeRingPut(ri.key, vec)
  sv.st.markUniverseSyncEventApplied(eventKey)
  "APPLIED"

proc ownerOf(sv: Server, parent: uint64, seq: uint32, period, head,
             tWrite: float): int =
  ## Physical ownership is stable for a placement epoch. The remaining
  ## arguments stay in the wire signature for protocol compatibility.
  discard seq
  discard period
  discard head
  discard tWrite
  int(sv.tbl.placementOwner(parent))

proc queueHandoffWork(sv: Server, parent: uint64, seq: uint32, target: int,
                      deleted: bool, queuedAt = 0.0,
                      migration = false): bool =
  if target < 0 or target >= sv.peers.len or target == sv.myId:
    return false
  let workKey = (parent, seq, target, deleted)
  if sv.scheduledHandoffs.getOrDefault(workKey, false):
    return true
  let now = if queuedAt > 0: queuedAt else: epochTime()
  sv.scheduledHandoffs[workKey] = true
  sv.handoffWork.add HandoffWork(
    parent: parent, seq: seq, target: target, deleted: deleted,
    queuedAt: now, notBefore: now, migration: migration)
  true

proc queueTombstonePropagation(sv: Server, k: (uint64, uint32),
                               migration = false) =
  if k notin sv.st.tombstones:
    return
  let tombstone = sv.st.tombstones[k]
  if sv.peers.len <= 1:
    if tombstone.reclaimAfter > 0:
      sv.tombstoneReclaims.push TombstoneReclaim(
        due: tombstone.reclaimAfter, parent: k[0], seq: k[1],
        version: tombstone.version)
    return
  if not tombstone.acknowledgedNodes.acknowledgesAllNodes(sv.peers.len):
    for target in 0 ..< sv.peers.len:
      if target != sv.myId and
          uint16(target) notin tombstone.acknowledgedNodes:
        discard sv.queueHandoffWork(k[0], k[1], target, true,
                                    migration = migration)
        return
  else:
    for target in 0 ..< sv.peers.len:
      if target != sv.myId and
          not sv.tombstoneCompletionSent.getOrDefault(
            (k[0], k[1], target), false):
        discard sv.queueHandoffWork(k[0], k[1], target, true,
                                    migration = migration)
    if tombstone.reclaimAfter > 0:
      sv.tombstoneReclaims.push TombstoneReclaim(
        due: tombstone.reclaimAfter, parent: k[0], seq: k[1],
        version: tombstone.version)

proc preparePlacementMigration(sv: Server) =
  ## Build a ring-level cursor once at startup. Tick processing walks only this
  ## bounded migration plan; it never rescans the live store periodically.
  for ring, keys in sv.st.itemsByRing:
    if int(sv.tbl.placementOwner(ring)) != sv.myId:
      sv.migrationRings.add ring
      for k in keys:
        if sv.st.contains(k[0], k[1]):
          inc sv.migrationRemaining
  sv.migrationRings.sort()
  for k in sv.st.tombstones.keys:
    sv.tombstoneStartupKeys.add k
  sv.tombstoneStartupKeys.sort(proc(a, b: (uint64, uint32)): int =
    result = cmp(a[0], b[0])
    if result == 0:
      result = cmp(a[1], b[1]))
  sv.migrationStartedAt = epochTime()

proc ringMigrationMetadata(sv: Server, ring: uint64): string =
  if ring notin sv.st.ringMeta:
    return ""
  let meta = sv.st.ringMeta[ring]
  var node = %*{
    "kind": "ring",
    "key": $ring,
    "period": meta.period,
    "head": meta.head,
    "name": sv.st.ringNames.getOrDefault(ring, ""),
    "description": sv.st.ringDescriptions.getOrDefault(ring, "")
  }
  if ring in sv.st.ringPayloadProfiles:
    let profile = sv.st.ringPayloadProfiles[ring]
    node["payloadProfile"] = %*{
      "defaultCodec": profile.defaultCodec.payloadCodecName,
      "charset": profile.charset,
      "formatVersion": profile.formatVersion
    }
  if ring in sv.st.ringTimeOrbitProfiles:
    let profile = sv.st.ringTimeOrbitProfiles[ring]
    node["timeOrbitProfile"] = %*{
      "bits": profile.bits,
      "bucketMs": profile.bucketMs,
      "phase": $profile.phase,
      "salt": profile.salt
    }
  $node

proc fillPlacementWork(sv: Server, limit: int) =
  var added = 0
  while added < limit and sv.migrationRingIndex < sv.migrationRings.len:
    let ring = sv.migrationRings[sv.migrationRingIndex]
    let keys = sv.st.itemsByRing.getOrDefault(ring, @[])
    if sv.migrationItemIndex >= keys.len:
      inc sv.migrationRingIndex
      sv.migrationItemIndex = 0
      continue
    let k = keys[sv.migrationItemIndex]
    inc sv.migrationItemIndex
    if not sv.st.contains(k[0], k[1]):
      continue
    let target = int(sv.tbl.placementOwner(k[0]))
    if target == sv.myId:
      if sv.migrationRemaining > 0:
        dec sv.migrationRemaining
      continue
    if sv.queueHandoffWork(k[0], k[1], target, false, migration = true):
      inc added
  while added < limit and
      sv.tombstoneStartupIndex < sv.tombstoneStartupKeys.len:
    let k = sv.tombstoneStartupKeys[sv.tombstoneStartupIndex]
    inc sv.tombstoneStartupIndex
    sv.queueTombstonePropagation(k, migration = true)
    inc added

proc submitHandoff(sv: Server, work: HandoffWork): bool =
  let k = (work.parent, work.seq)
  if k in sv.pendingHandoffs:
    return false
  inc sv.nextHandoffAttempt
  let attempt = sv.nextHandoffAttempt
  var pending = PendingHandoff(
    attempt: attempt, target: work.target, deleted: work.deleted,
    queuedAt: work.queuedAt, retries: work.retries,
    migration: work.migration)
  var task = HandoffTask(kind: htkTransfer, attempt: attempt,
                         target: work.target, parent: work.parent,
                         seq: work.seq, deleted: work.deleted,
                         migration: work.migration)
  if work.migration:
    task.migrationMetadata = sv.ringMigrationMetadata(work.parent)
  if work.deleted:
    if k notin sv.st.tombstones:
      sv.scheduledHandoffs.del((work.parent, work.seq, work.target, true))
      return true
    let tombstone = sv.st.tombstones[k]
    pending.period = tombstone.period
    pending.head = tombstone.head
    pending.tWrite = tombstone.tWrite
    pending.version = tombstone.version
    pending.acknowledgedNodes = tombstone.acknowledgedNodes
    pending.reclaimAfter = tombstone.reclaimAfter
    task.period = tombstone.period
    task.head = tombstone.head
    task.tWrite = tombstone.tWrite
    task.version = tombstone.version
    task.acknowledgedNodes = tombstone.acknowledgedNodes
    task.reclaimAfter = tombstone.reclaimAfter
  else:
    if not sv.st.contains(k[0], k[1]):
      sv.scheduledHandoffs.del((work.parent, work.seq, work.target, false))
      if work.migration and sv.migrationRemaining > 0:
        dec sv.migrationRemaining
      return true
    let p = sv.st.getParticle(k[0], k[1])
    let owner = int(sv.tbl.placementOwner(p.parent))
    if owner == sv.myId or owner != work.target:
      sv.scheduledHandoffs.del((work.parent, work.seq, work.target, false))
      if work.migration and sv.migrationRemaining > 0:
        dec sv.migrationRemaining
      return true
    pending.period = p.period
    pending.head = p.head
    pending.tWrite = p.tWrite
    pending.payload = p.payload
    pending.codec = p.codec
    pending.vec = p.vec
    pending.version = p.version
    task.period = p.period
    task.head = p.head
    task.tWrite = p.tWrite
    task.payload = p.payload
    task.codec = p.codec
    task.vec = p.vec
    task.version = p.version
  if not handoffTasks.trySend(task):
    inc sv.handoffQueueFull
    return false
  sv.pendingHandoffs[k] = pending
  inc sv.handoffQueued
  true

proc handoffTick(sv: Server) =
  let now = epochTime()
  sv.reclaimReadyTombstones(now)

  while true:
    let completed = handoffResults.tryRecv()
    if not completed.dataAvailable:
      break
    let r = completed.msg
    let k = (r.parent, r.seq)
    if k notin sv.pendingHandoffs:
      continue
    let pending = sv.pendingHandoffs[k]
    if pending.attempt != r.attempt:
      continue
    sv.pendingHandoffs.del k
    let workKey = (r.parent, r.seq, r.target, pending.deleted)
    if not r.applied:
      inc sv.handoffFailed
      var retry = HandoffWork(
        parent: r.parent, seq: r.seq, target: r.target,
        deleted: pending.deleted, queuedAt: pending.queuedAt,
        retries: pending.retries + 1, migration: pending.migration)
      retry.notBefore = now + min(5.0, 0.1 * float(1 shl min(5, retry.retries)))
      sv.handoffWork.add retry
      continue

    if pending.deleted:
      if k notin sv.st.tombstones or
          sv.st.tombstones[k].version != pending.version:
        sv.scheduledHandoffs.del workKey
        inc sv.handoffStaleAck
        continue
      var updated = sv.st.tombstones[k]
      let sentComplete =
        pending.acknowledgedNodes.acknowledgesAllNodes(sv.peers.len)
      discard updated.acknowledgedNodes.acknowledgeNode(uint16(r.target))
      updated = sv.prepareTombstoneForNode(updated, now)
      discard sv.st.applyTombstone(updated)
      if sentComplete:
        sv.tombstoneCompletionSent[(k[0], k[1], r.target)] = true
      sv.scheduledHandoffs.del workKey
      sv.queueTombstonePropagation(k, migration = pending.migration)
      inc sv.handoffApplied
      continue

    if not sv.st.contains(k[0], k[1]):
      sv.scheduledHandoffs.del workKey
      inc sv.handoffStaleAck
      continue
    let current = sv.st.getParticle(k[0], k[1])
    let unchanged =
      current.period == pending.period and current.head == pending.head and
      current.tWrite == pending.tWrite and current.payload == pending.payload and
      current.codec == pending.codec and current.vec == pending.vec and
      current.version == pending.version
    if not unchanged or
        int(sv.tbl.placementOwner(current.parent)) != r.target:
      sv.scheduledHandoffs.del workKey
      let owner = int(sv.tbl.placementOwner(current.parent))
      if owner != sv.myId:
        discard sv.queueHandoffWork(k[0], k[1], owner, false,
                                    queuedAt = pending.queuedAt,
                                    migration = pending.migration)
      inc sv.handoffStaleAck
      continue
    sv.st.evict(k[0], k[1])
    sv.scheduledHandoffs.del workKey
    if pending.migration and sv.migrationRemaining > 0:
      dec sv.migrationRemaining
    inc sv.handoffApplied

  if sv.peers.len <= 1:
    return
  sv.fillPlacementWork(MaxTransfersPerTick)
  var budget = MaxTransfersPerTick
  var inspected = 0
  let available = sv.handoffWork.len - sv.handoffWorkHead
  while budget > 0 and inspected < available and
      sv.handoffWorkHead < sv.handoffWork.len:
    let work = sv.handoffWork[sv.handoffWorkHead]
    inc sv.handoffWorkHead
    inc inspected
    if work.notBefore > now or (work.parent, work.seq) in sv.pendingHandoffs:
      sv.handoffWork.add work
      continue
    if sv.submitHandoff(work):
      dec budget
    else:
      sv.handoffWork.add work
      break
  if sv.handoffWorkHead > 4096 and
      sv.handoffWorkHead * 2 > sv.handoffWork.len:
    if sv.handoffWorkHead >= sv.handoffWork.len:
      sv.handoffWork.setLen(0)
    else:
      sv.handoffWork = sv.handoffWork[sv.handoffWorkHead .. ^1]
    sv.handoffWorkHead = 0

proc rebuildFieldState(sv: Server) =
  sv.fs.forwarders = sv.st.forwarders
  for _, p in sv.st.items:
    if p.parent != HaloKey and p.vec.len > 0:
      sv.fs.observeRingPut(p.parent, p.vec)

proc slowTick(sv: Server) =
  sv.fs.clusterTick(sv.st)
  discard sv.fs.captureTick(sv.st, epochTime())

proc autoPackTick(sv: Server) =
  if not sv.autoPack.enabled or not sv.autoPack.window.isOpenNow():
    return
  let current = epochTime()
  if sv.autoPackLastAttempt > 0 and
      current - sv.autoPackLastAttempt < sv.autoPack.intervalSec:
    return
  sv.autoPackLastAttempt = current
  inc sv.autoPackAttempts
  try:
    discard sv.st.recoverInterruptedSegmentMaintenance()
    let maintenance = sv.st.runSegmentMaintenance(sv.autoPack.policy)
    sv.autoPackLastElapsedMs = maintenance.elapsedMs
    sv.autoPackRings += maintenance.packedRings.uint64
    sv.autoPackBytes += maintenance.bytesRewritten.uint64
    case maintenance.outcome
    of "completed": inc sv.autoPackCompleted
    of "partial": inc sv.autoPackPartial
    of "interrupted": inc sv.autoPackInterrupted
    of "failed": inc sv.autoPackFailed
    of "no-work": inc sv.autoPackNoWork
    else: discard
  except CatchableError:
    inc sv.autoPackFailed
    inc sv.errorResponses

proc visibleVectorCount(sv: Server, sock: Socket): int =
  if not sv.authzEnabled:
    return sv.st.vectorCount
  for ring, count in sv.st.vectorCountByRing:
    if sv.ringKeyAllowed(sock, ring):
      result += count

proc handleRetrieve(sv: Server, sock: Socket, parts: seq[string]) =
  requireParts(parts, "RETRIEVE", 5)
  let hasRing = parts[1] == "1"
  let ringKey = parseBiggestUInt(parts[2]).uint64
  let budget = parseInt(parts[3])
  let vecDim = parseInt(parts[4])
  let q = sock.readExact(checkedVecBytes(vecDim)).bytesVec(vecDim).normalize()
  if budget < 0 or budget > MaxRetrieveBudget:
    sv.audit("retrieve-denied", ok = false, user = sv.currentUser(sock),
             ringKey = (if hasRing: $ringKey else: ""),
             message = "retrieve budget exceeds configured maximum",
             extra = %*{"budget": budget, "maxBudget": MaxRetrieveBudget})
    raise newException(ValueError,
      "RETRIEVE budget exceeds max " & $MaxRetrieveBudget)

  var hits: seq[VectorCandidate] = @[]
  var totalVectors = 0
  var scanned = 0
  var physicalVisited = 0
  defer:
    sv.retrievePhysicalVisited += uint64(physicalVisited)
    sv.retrieveCandidatesScored += uint64(scanned)
  var rings = initTable[uint64, bool]()
  inc sv.retrieveRequests
  if hasRing:
    inc sv.retrieveScopedRequests
  else:
    inc sv.retrieveGlobalRequests
  if q.len > 0 and budget > 0:
    template scoreParticle(p: Particle) =
      inc physicalVisited
      if p.vec.len == 0:
        continue
      if not sv.ringKeyAllowed(sock, p.parent):
        continue
      inc scanned
      if scanned > MaxRetrieveScan:
        sv.audit("broad-scan-denied", ok = false, user = sv.currentUser(sock),
                 ringKey = (if hasRing: $ringKey else: ""),
                 message = "retrieve scan exceeds configured maximum",
                 extra = %*{"scanned": scanned, "maxScan": MaxRetrieveScan,
                            "hasRing": hasRing})
        raise newException(ValueError,
          "RETRIEVE scan exceeds max " & $MaxRetrieveScan &
          "; use a ring-scoped query or narrower retrieval plan")
      rings[p.parent] = true
      hits.addTopCandidate(p.exactCandidate(q), budget)
    totalVectors = sv.visibleVectorCount(sock)
    if hasRing:
      for p in sv.st.particlesByRing(ringKey):
        scoreParticle(p)
    else:
      for p in sv.st.allParticles():
        scoreParticle(p)
    hits.sort(proc(a, b: VectorCandidate): int = cmp(b.score, a.score))
  var payloadBytes = 0
  for h in hits:
    payloadBytes += h.payload.len
  sock.sendFrame("RHIT " & $scanned & " " & $rings.len & " " & $hits.len &
                 " " & $totalVectors & " " & $payloadBytes)
  for h in hits:
    sock.sendFrame("HIT " & $h.parent & " " & $h.seq & " " & $h.tWrite & " " &
                   $h.score & " " & $h.payload.len & sv.codecSuffix(sock, h.codec),
                   h.payload)

proc applyClusterTxOp(sv: Server, op: ClusterTxOp,
                      observedAt: float): bool =
  if op.kind == ctxDelete:
    var tombstone = sv.prepareTombstoneForNode(Tombstone(
      parent: op.parent, seq: op.seq, period: op.period, head: op.head,
      tWrite: op.tWrite, version: op.version, lastHere: observedAt), observedAt)
    result = sv.st.applyTombstone(tombstone)
    if result:
      sv.queueTombstonePropagation((op.parent, op.seq))
    return

  var p = Particle(parent: op.parent, seq: op.seq, period: op.period,
                   head: op.head, tWrite: op.tWrite, payload: op.payload,
                   codec: op.codec, vec: op.vec, version: op.version,
                   lastHere: observedAt)
  if p.parent notin sv.st.ringMeta:
    sv.st.putRingMeta(p.parent, p.period, p.head)
  if p.seq >= sv.st.seqs.getOrDefault(p.parent, 0'u32):
    sv.st.seqs[p.parent] = p.seq + 1
  if sv.st.contains(p.parent, p.seq) and p.vec.len == 0:
    p.vec = sv.st.getParticle(p.parent, p.seq).vec
  result = sv.st.upsert(p, origin = uint32(sv.myId + 1),
                        preserveVersion = true)
  if result and p.parent != HaloKey:
    sv.fs.observeRingPut(p.parent, p.vec)

proc applyClusterTxTick(sv: Server) =
  ## node0 が landing zone。commit intent は全 op の apply ACK まで残す。
  if sv.myId != 0:
    return
  var done: seq[uint64] = @[]
  for txid, intent in sv.st.clusterTx:
    if intent.applied or not intent.committed:
      continue
    var allApplied = true
    for op in intent.ops:
      let node = int(sv.tbl.placementOwner(op.parent))
      try:
        if node == sv.myId:
          if sv.draining:
            allApplied = false
            continue
          discard sv.applyClusterTxOp(op, epochTime())
        else:
          sv.peerLink.applyTxReq(node, txid,
            TxWireOp(delete: op.kind == ctxDelete,
                     parent: op.parent, seq: op.seq, period: op.period,
                     head: op.head, tWrite: op.tWrite,
                     payload: op.payload, codec: op.codec, vec: op.vec,
                     version: op.version),
            timeoutMs = 500)
      except CatchableError:
        allApplied = false
    if allApplied:
      done.add txid
  for txid in done:
    sv.st.markClusterTxApplied(txid)

proc migrationPendingCount(sv: Server): int =
  result = max(0, sv.migrationRemaining)
  result += max(0, sv.tombstoneStartupKeys.len - sv.tombstoneStartupIndex)
  for _, pending in sv.pendingHandoffs:
    if pending.migration:
      inc result
  for i in sv.handoffWorkHead ..< sv.handoffWork.len:
    if sv.handoffWork[i].migration:
      inc result

proc activationState(sv: Server): tuple[state: string, pending: int] =
  result.pending = sv.migrationPendingCount()
  if not sv.draining:
    result.state = "ACTIVE"
  elif result.pending == 0:
    result.state = "READY"
  else:
    result.state = "BLOCKED"

proc clusterActivationReady(sv: Server): tuple[ok: bool, reason: string] =
  let local = sv.activationState()
  if local.state notin ["READY", "ACTIVE"] or local.pending != 0:
    return (false, "local-migration-pending=" & $local.pending)
  for node in 0 ..< sv.peers.len:
    if node == sv.myId:
      continue
    try:
      let topology = sv.peerLink.topologyReq(node)
      if topology.epoch != sv.tbl.epoch or topology.nNodes != sv.tbl.nNodes or
          topology.arcs.len != sv.tbl.arcs.len:
        return (false, "node-" & $node & "-topology-mismatch")
      let activation = sv.peerLink.activationReq(node)
      if activation.epoch != sv.tbl.epoch or
          activation.nodes != sv.tbl.nNodes or
          activation.virtualArcs != sv.virtualArcsPerNode:
        return (false, "node-" & $node & "-activation-topology-mismatch")
      if activation.state notin ["READY", "ACTIVE"] or
          activation.migrationPending != 0:
        return (false, "node-" & $node & "-migration-pending=" &
          $activation.migrationPending)
    except CatchableError:
      return (false, "node-" & $node & "-unreachable")
  (true, "")

proc handleFrame(sv: Server, sock: Socket): bool =
  ## 1フレーム処理。false = 接続を閉じる。
  var parts: seq[string]
  try:
    parts = sock.readHeader()
  except IOError, OSError, TimeoutError:
    return false
  inc sv.requestCount
  let now = epochTime()
  let fd = sock.getFd.int
  if (sv.authUser.len > 0 or sv.users.len > 0 or sv.authSecretKey.len > 0) and
      not sv.authed.getOrDefault(fd, false):
    if sv.users.len > 0:
      if parts[0] == "AUTH" and parts.len >= 3 and parts[1] in sv.users and
          secureEqual(sv.users[parts[1]].password, parts[2]):
        sv.authed[fd] = true
        sv.authedUsers[fd] = parts[1]
        sv.audit("auth-success", user = parts[1])
        sock.sendFrame("OK auth")
        return true
    elif sv.authSecretKey.len > 0:
      if parts[0] == "AUTHCHAL" and parts.len >= 2 and parts[1] == sv.authUser:
        let challenge = newChallengeHex()
        sv.authChallenges[fd] = challenge
        sock.sendFrame("CHAL " & challenge)
        return true
      if parts[0] == "AUTHRESP" and parts.len >= 2 and fd in sv.authChallenges:
        let challenge = sv.authChallenges[fd]
        if verifySecretResponse(sv.authUser, sv.authPassword, challenge,
                                parts[1], sv.authSecretKey):
          sv.authChallenges.del fd
          sv.authed[fd] = true
          sv.authedUsers[fd] = sv.authUser
          sv.audit("auth-success", user = sv.authUser)
          sock.sendFrame("OK auth")
          sock.enableSecure(sv.authSecretKey, challenge)
          return true
    else:
      if parts[0] == "AUTH" and parts.len >= 3 and
          secureEqual(parts[1], sv.authUser) and
          secureEqual(parts[2], sv.authPassword):
        sv.authed[fd] = true
        sv.authedUsers[fd] = sv.authUser
        sv.audit("auth-success", user = sv.authUser)
        sock.sendFrame("OK auth")
        return true
    inc sv.authFailures
    inc sv.errorResponses
    sv.audit("auth-failure", ok = false,
             user = (if parts.len >= 2: parts[1] else: ""),
             message = "authentication failed or required")
    sock.sendFrame("ERR auth-required")
    return false
  case parts[0]
  of "AUTH":
    sock.sendFrame("OK auth")
  of "HELLO":
    if parts.len < 2:
      inc sv.errorResponses
      sock.sendFrame("ERR galaxy-required")
    elif parts[1] != sv.galaxy:
      inc sv.errorResponses
      sock.sendFrame("ERR wrong-galaxy expected=" & sv.galaxy)
    else:
      sock.sendFrame("OK galaxy=" & sv.galaxy)
  of "TXBEGIN":
    if not sv.requireRole(sock, roleWriter):
      return true
    if sv.rejectIfDraining(sock, "TXBEGIN"):
      return true
    doAssert sv.myId == 0, "TXBEGIN は node0 の landing zone で処理する"
    let txid = sv.st.reserveTxId()
    sock.sendFrame("OK " & $txid)
  of "TXRESERVE":
    if not sv.requireRole(sock, roleWriter):
      return true
    if sv.rejectIfDraining(sock, "TXRESERVE"):
      return true
    doAssert sv.myId == 0, "TXRESERVE は node0 の landing zone で処理する"
    requireParts(parts, "TXRESERVE", 5)
    let ringKey = parseBiggestUInt(parts[2]).uint64
    if not sv.requireRingKey(sock, ringKey):
      return true
    let period = parseFloat(parts[3])
    let head = parseFloat(parts[4])
    if ringKey notin sv.st.ringMeta:
      sv.st.putRingMeta(ringKey, period, head)
    let seq = sv.st.nextSeq(ringKey)
    sock.sendFrame("OK " & $seq & " " & $now)
  of "TXCOMMIT":
    if not sv.requireRole(sock, roleWriter):
      return false
    doAssert sv.myId == 0, "TXCOMMIT は node0 の landing zone で処理する"
    requireParts(parts, "TXCOMMIT", 3)
    let txid = parseBiggestUInt(parts[1]).uint64
    let nOps = parseInt(parts[2])
    if sv.draining:
      sock.drainTxCommitOps(nOps)
      sv.rejectDrainedWrite(sock, "TXCOMMIT")
      return true
    var ops: seq[ClusterTxOp] = @[]
    for _ in 0 ..< nOps:
      let h = sock.readHeader()
      let isDelete = h[0] == "D"
      let data = if h[0] == "P" or h[0] == "D": 1 else: 0
      requireParts(h, "TXCOMMIT op", data + 7)
      var op = ClusterTxOp(kind: if isDelete: ctxDelete else: ctxPut,
                           parent: parseBiggestUInt(h[data]).uint64,
                           seq: parseUInt(h[data + 1]).uint32,
                           period: parseFloat(h[data + 2]),
                           head: parseFloat(h[data + 3]),
                           tWrite: parseFloat(h[data + 4]))
      let payloadLen = parseInt(h[data + 5])
      let vecDim = parseInt(h[data + 6])
      op.codec = if h.len > data + 7: parsePayloadCodec(h[data + 7]) else: pcRaw
      if h.len >= data + 11:
        op.version = parseMutationVersion(h, data + 8, op.tWrite)
      let bodyBytes = checkedFrameBytes(payloadLen, vecDim, extra = 1)
      if not sv.ringKeyAllowed(sock, op.parent):
        sock.drainBytes(bodyBytes)
        sock.drainTxCommitOps(nOps - ops.len - 1)
        sv.denyRingKey(sock, op.parent)
        return true
      op.payload = sock.readExact(payloadLen)
      op.vec =
        if vecDim == 0: @[]
        else: sock.readExact(checkedVecBytes(vecDim)).bytesVec(vecDim).normalize()
      discard sock.readExact(1) # op 区切りの '\n'
      ops.add op
    sv.st.putClusterTxIntent ClusterTxIntent(id: txid, ops: ops, committed: true)
    sock.sendFrame("OK")
  of "TXSTATUS":
    if not sv.requireRole(sock, roleWriter):
      return true
    doAssert sv.myId == 0, "TXSTATUS は node0 の landing zone で処理する"
    requireParts(parts, "TXSTATUS", 2)
    let txid = parseBiggestUInt(parts[1]).uint64
    if sv.st.isClusterTxApplied(txid):
      sock.sendFrame("OK APPLIED")
    elif sv.st.hasClusterTxIntent(txid):
      sock.sendFrame("OK PENDING")
    else:
      sock.sendFrame("OK UNKNOWN")
  of "UAPPLY":
    if not sv.requireRole(sock, roleWriter):
      return false
    try:
      requireParts(parts, "UAPPLY", 2)
      let bodyLen = parseInt(parts[1])
      discard checkedWireLen(bodyLen, "bodyLen")
      if sv.draining:
        sock.drainBytes(bodyLen)
        sv.rejectDrainedWrite(sock, "UAPPLY")
        return true
      let body = sock.readExact(bodyLen)
      validateJsonDepth(body, MaxWireJsonDepth)
      let event = parseJson(body)
      let ringName = event{"ring"}.getStr()
      if not sv.ringNameAllowed(sock, ringName):
        sv.denyRingName(sock, ringName)
        return true
      let ri = sv.ringInfo(ringName)
      let owner = int(sv.tbl.placementOwner(ri.key))
      if owner != sv.myId:
        let status = sv.peerLink.universeApplyReq(owner, body)
        inc sv.universeApplyForwarded
        sv.universeApplyLastOk = now
        sock.sendFrame("UOK " & status)
        return true
      let status = sv.applyUniverseEvent(event, now)
      if status == "APPLIED":
        inc sv.universeApplyApplied
      elif status == "DELAYED":
        discard
      else:
        inc sv.universeApplySkipped
      sv.universeApplyLastOk = now
      sock.sendFrame("UOK " & status)
    except CatchableError:
      inc sv.universeApplyErrors
      sv.universeApplyLastError = now
      raise
  of "USTATUS":
    if not sv.requireRole(sock, roleAdmin):
      return true
    sock.sendFrame("USTATUS " & $sv.st.universeSyncEvents.len & " " &
                   $sv.st.appliedUniverseSyncEvents.len & " " &
                   $sv.universeApplyApplied & " " &
                   $sv.universeApplySkipped & " " &
                   $sv.universeApplyErrors & " " &
                   $sv.universeApplyForwarded & " " &
                   $(int(sv.universeApplyLastOk)) & " " &
                   $(int(sv.universeApplyLastError)))
  of "WIREVER":
    sock.sendFrame("WIREVER " & $WireProtocolVersion)
  of "TOPOLOGY":
    sock.sendFrame("TOPOLOGY " & $sv.tbl.epoch & " " & $sv.tbl.nNodes & " " &
                   $sv.virtualArcsPerNode)
  of "ACTIVATION":
    if not sv.requireRole(sock, roleAdmin):
      return true
    let activation = sv.activationState()
    sock.sendFrame("ACTIVATION " & activation.state & " " & $sv.tbl.epoch &
                   " " & $sv.tbl.nNodes & " " & $sv.virtualArcsPerNode &
                   " " & $activation.pending)
  of "MIGMETA":
    if not sv.requireRole(sock, roleAdmin):
      return false
    requireParts(parts, "MIGMETA", 5)
    if parts.len != 5:
      raise newException(ValueError,
        "MIGMETA requires topology fence and payload length")
    let expectedEpoch = parseUInt(parts[1])
    let expectedNodes = parseUInt(parts[2])
    let expectedVirtualArcs = parseInt(parts[3])
    let payloadLen = parseInt(parts[4])
    let bodyBytes = checkedFrameBytes(payloadLen, 0)
    if expectedEpoch != uint64(sv.tbl.epoch) or
        expectedNodes != uint64(sv.tbl.nNodes) or
        expectedVirtualArcs != sv.virtualArcsPerNode:
      sock.drainBytes(bodyBytes)
      sock.sendFrame("ERR topology-mismatch")
      return true
    let body = sock.readExact(payloadLen)
    validateJsonDepth(body, MaxWireJsonDepth)
    let metadata = parseJson(body)
    if metadata.kind != JObject:
      raise newException(ValueError,
        "migration metadata must be a JSON object")
    case metadata{"kind"}.getStr()
    of "global":
      let sourceGalaxy = metadata{"galaxy"}.getStr()
      if sourceGalaxy.len > 0:
        sv.st.setGalaxy(sourceGalaxy)
      let description = metadata{"description"}.getStr()
      if description.len > 0:
        sv.st.putGalaxyDescription(description)
    of "ring":
      let ringKey = parseBiggestUInt(metadata["key"].getStr()).uint64
      if not sv.ringKeyAllowed(sock, ringKey):
        sv.denyRingKey(sock, ringKey)
        return true
      sv.st.putRingMeta(ringKey, metadata{"period"}.getFloat(),
                        metadata{"head"}.getFloat())
      sv.st.putRingName(ringKey, metadata{"name"}.getStr())
      sv.st.putRingDescription(ringKey, metadata{"description"}.getStr())
      if metadata.hasKey("payloadProfile"):
        let profile = metadata["payloadProfile"]
        sv.st.putRingPayloadProfile(ringKey, RingPayloadProfile(
          defaultCodec:
            parsePayloadCodec(profile{"defaultCodec"}.getStr("raw")),
          charset: profile{"charset"}.getStr(),
          formatVersion: profile{"formatVersion"}.getStr()))
      if metadata.hasKey("timeOrbitProfile"):
        let profile = metadata["timeOrbitProfile"]
        sv.st.putTimeOrbitProfile(ringKey, TimeOrbitProfile(
          bits: profile{"bits"}.getInt(60),
          bucketMs: profile{"bucketMs"}.getBiggestInt(60_000).int64,
          phase:
            parseBiggestUInt(profile{"phase"}.getStr("0")).uint64,
          salt: profile{"salt"}.getStr()))
    of "stellar":
      sv.st.putStellarMap(metadata["stellar"].getStr(),
                          metadata["blob"].getStr())
    of "forwarder":
      let oldParent =
        parseBiggestUInt(metadata["oldParent"].getStr()).uint64
      if not sv.ringKeyAllowed(sock, oldParent):
        sv.denyRingKey(sock, oldParent)
        return true
      sv.st.putForwarder(
        oldParent, metadata{"oldSeq"}.getBiggestInt().uint32,
        Forwarder(
          newParent:
            parseBiggestUInt(metadata["newParent"].getStr()).uint64,
          newSeq: metadata{"newSeq"}.getBiggestInt().uint32,
          newTWrite: metadata{"newTWrite"}.getFloat(),
          expiresAt: metadata{"expiresAt"}.getFloat()))
    else:
      raise newException(ValueError, "unknown migration metadata kind")
    sock.sendFrame("OK APPLIED")
  of "MIGMETAVERIFY":
    if not sv.requireRole(sock, roleAdmin):
      return false
    requireParts(parts, "MIGMETAVERIFY", 5)
    if parts.len != 5:
      raise newException(ValueError,
        "MIGMETAVERIFY requires topology fence and payload length")
    let expectedEpoch = parseUInt(parts[1])
    let expectedNodes = parseUInt(parts[2])
    let expectedVirtualArcs = parseInt(parts[3])
    let payloadLen = parseInt(parts[4])
    let bodyBytes = checkedFrameBytes(payloadLen, 0)
    if expectedEpoch != uint64(sv.tbl.epoch) or
        expectedNodes != uint64(sv.tbl.nNodes) or
        expectedVirtualArcs != sv.virtualArcsPerNode:
      sock.drainBytes(bodyBytes)
      sock.sendFrame("ERR topology-mismatch")
      return true
    let body = sock.readExact(payloadLen)
    validateJsonDepth(body, MaxWireJsonDepth)
    let metadata = parseJson(body)
    if metadata.kind != JObject:
      raise newException(ValueError,
        "migration metadata must be a JSON object")
    var matches = false
    case metadata{"kind"}.getStr()
    of "global":
      let sourceGalaxy = metadata{"galaxy"}.getStr()
      let description = metadata{"description"}.getStr()
      matches =
        (sourceGalaxy.len == 0 or sv.st.galaxy == sourceGalaxy) and
        (description.len == 0 or sv.st.galaxyDescription == description)
    of "ring":
      let ringKey = parseBiggestUInt(metadata["key"].getStr()).uint64
      if not sv.ringKeyAllowed(sock, ringKey):
        sv.denyRingKey(sock, ringKey)
        return true
      let expectedMeta = (
        period: metadata{"period"}.getFloat(),
        head: metadata{"head"}.getFloat())
      matches =
        ringKey in sv.st.ringMeta and
        sv.st.ringMeta[ringKey] == expectedMeta and
        sv.st.ringNames.getOrDefault(ringKey, "") ==
          metadata{"name"}.getStr() and
        sv.st.ringDescriptions.getOrDefault(ringKey, "") ==
          metadata{"description"}.getStr()
      if matches and metadata.hasKey("payloadProfile"):
        let profile = metadata["payloadProfile"]
        let expectedProfile = RingPayloadProfile(
          defaultCodec:
            parsePayloadCodec(profile{"defaultCodec"}.getStr("raw")),
          charset: profile{"charset"}.getStr(),
          formatVersion: profile{"formatVersion"}.getStr())
        matches =
          ringKey in sv.st.ringPayloadProfiles and
          sv.st.ringPayloadProfiles[ringKey] == expectedProfile
      elif matches:
        matches = ringKey notin sv.st.ringPayloadProfiles
      if matches and metadata.hasKey("timeOrbitProfile"):
        let profile = metadata["timeOrbitProfile"]
        let expectedProfile = TimeOrbitProfile(
          bits: profile{"bits"}.getInt(60),
          bucketMs: profile{"bucketMs"}.getBiggestInt(60_000).int64,
          phase:
            parseBiggestUInt(profile{"phase"}.getStr("0")).uint64,
          salt: profile{"salt"}.getStr())
        matches =
          ringKey in sv.st.ringTimeOrbitProfiles and
          sv.st.ringTimeOrbitProfiles[ringKey] == expectedProfile
      elif matches:
        matches = ringKey notin sv.st.ringTimeOrbitProfiles
    of "stellar":
      let stellar = metadata["stellar"].getStr()
      matches =
        sv.st.stellarMaps.getOrDefault(stellar, "") ==
          metadata["blob"].getStr()
    of "forwarder":
      let oldParent =
        parseBiggestUInt(metadata["oldParent"].getStr()).uint64
      if not sv.ringKeyAllowed(sock, oldParent):
        sv.denyRingKey(sock, oldParent)
        return true
      let oldSeq = metadata{"oldSeq"}.getBiggestInt().uint32
      let expectedForwarder = Forwarder(
        newParent:
          parseBiggestUInt(metadata["newParent"].getStr()).uint64,
        newSeq: metadata{"newSeq"}.getBiggestInt().uint32,
        newTWrite: metadata{"newTWrite"}.getFloat(),
        expiresAt: metadata{"expiresAt"}.getFloat())
      matches =
        (oldParent, oldSeq) in sv.st.forwarders and
        sv.st.forwarders[(oldParent, oldSeq)] == expectedForwarder
    else:
      raise newException(ValueError, "unknown migration metadata kind")
    if matches:
      sock.sendFrame("MIGRATION MATCH")
    else:
      sock.sendFrame("ERR migration-metadata-mismatch")
  of "MIGVERIFY":
    if not sv.requireRole(sock, roleAdmin):
      return true
    requireParts(parts, "MIGVERIFY", 7)
    if parts.len != 7 or parts[6] notin ["0", "1"]:
      raise newException(ValueError,
        "MIGVERIFY requires parent seq version and deleted flag")
    let parent = parseBiggestUInt(parts[1]).uint64
    let seq = parseUInt(parts[2]).uint32
    let expected = parseMutationVersion(parts, 3, 0.0)
    if expected.isZero:
      raise newException(ValueError,
        "MIGVERIFY requires a non-zero mutation version")
    let expectedDeleted = parts[6] == "1"
    let state = sv.st.mutationState(parent, seq)
    if not state.found:
      sock.sendFrame("ERR migration-missing")
    elif state.version < expected:
      sock.sendFrame("ERR migration-behind")
    elif state.version == expected and state.deleted != expectedDeleted:
      sock.sendFrame("ERR migration-kind-mismatch")
    else:
      sock.sendFrame("MIGRATION " &
        (if state.version == expected: "MATCH " else: "AHEAD ") &
        (if state.deleted: "DELETED" else: "LIVE"))
  of "CODECS":
    sock.sendFrame("CODECS raw json nif bif")
  of "CODECMETA":
    if parts.len != 2 or parts[1] != "ON":
      sock.sendFrame("ERR CODECMETA requires ON")
    else:
      sv.codecMetadata[sock.getFd.int] = true
      sock.sendFrame("OK codec-metadata")
  of "APPLYTX":
    if not sv.requireRole(sock, roleWriter):
      return false
    requireParts(parts, "APPLYTX", 9)
    let txid = parseBiggestUInt(parts[1]).uint64
    let isDelete = parts[2] == "D"
    let data = if parts[2] == "P" or parts[2] == "D": 3 else: 2
    requireParts(parts, "APPLYTX", data + 7)
    let parent = parseBiggestUInt(parts[data]).uint64
    let seq = parseUInt(parts[data + 1]).uint32
    let payloadLen = parseInt(parts[data + 5])
    let vecDim = parseInt(parts[data + 6])
    let codec = if parts.len > data + 7: parsePayloadCodec(parts[data + 7]) else: pcRaw
    let bodyBytes = checkedFrameBytes(payloadLen, vecDim)
    if sv.draining:
      sock.drainBytes(bodyBytes)
      sv.rejectDrainedWrite(sock, "APPLYTX")
      return true
    if not sv.ringKeyAllowed(sock, parent):
      sock.drainBytes(bodyBytes)
      sv.denyRingKey(sock, parent)
      return true
    if sv.st.appliedClusterTx.getOrDefault(txid, false):
      sock.drainBytes(bodyBytes)
      sock.sendFrame("OK")
      return true
    var op = ClusterTxOp(
      kind: if isDelete: ctxDelete else: ctxPut,
      parent: parent, seq: seq,
      period: parseFloat(parts[data + 2]),
      head: parseFloat(parts[data + 3]),
      tWrite: parseFloat(parts[data + 4]),
      codec: codec)
    op.version = parseMutationVersion(parts, data + 8, op.tWrite)
    op.payload = sock.readExact(payloadLen)
    op.vec =
      if vecDim == 0: @[]
      else: sock.readExact(checkedVecBytes(vecDim)).bytesVec(vecDim).normalize()
    let applied = sv.applyClusterTxOp(op, now)
    sock.sendFrame("OK " & (if applied: "APPLIED" else: "SKIPPED"))
  of "TXGETID", "TXQRYID":
    doAssert sv.myId == 0, "TXGETID/TXQRYID は node0 の landing zone で処理する"
    requireParts(parts, parts[0], if parts[0] == "TXQRYID": 8 else: 7)
    let parent = parseBiggestUInt(parts[1]).uint64
    let seq = parseUInt(parts[3]).uint32
    var selection = ""
    if parts[0] == "TXQRYID":
      let selectionLen = parseInt(parts[7])
      discard checkedWireLen(selectionLen, "selectionLen")
      if not sv.ringKeyAllowed(sock, parent):
        sock.drainBytes(selectionLen)
        sv.denyRingKey(sock, parent)
        return true
      selection = sock.readExact(selectionLen)
    elif not sv.requireRingKey(sock, parent):
      return true
    var found = false
    var bestTxid = 0'u64
    var best: ClusterTxOp
    for txid, intent in sv.st.clusterTx:
      if intent.committed and not intent.applied:
        for op in intent.ops:
          if op.parent == parent and op.seq == seq and (not found or txid > bestTxid):
            found = true
            bestTxid = txid
            best = op
    if found:
      if best.kind == ctxDelete:
        sock.sendFrame("GONE")
        return true
      var value = best.payload
      if parts[0] == "TXQRYID":
        try:
          value = sv.projectPayload(value, best.codec, selection)
        except ValueError, JsonParsingError:
          sock.sendStableError(getCurrentException())
          return true
      let codec = if parts[0] == "TXQRYID": pcJson else: best.codec
      sock.sendFrame("VAL 0 " & $value.len & sv.codecSuffix(sock, codec), value)
      return true
    sock.sendFrame("MISS")
  of "RETRIEVE":
    requireParts(parts, "RETRIEVE", 5)
    let retrieveBodyBytes = checkedVecBytes(parseInt(parts[4]))
    if parts[1] == "1":
      let ringKey = parseBiggestUInt(parts[2]).uint64
      if not sv.ringKeyAllowed(sock, ringKey):
        sock.drainBytes(retrieveBodyBytes)
        sv.denyRingKey(sock, ringKey)
        return true
    if sv.draining:
      sock.drainBytes(retrieveBodyBytes)
      inc sv.errorResponses
      sv.audit("retrieve-denied", ok = false, user = sv.currentUser(sock),
               ringKey = (if parts[1] == "1": parts[2] else: ""),
               message = "server is draining; retrieval is not authoritative")
      sock.sendFrame("ERR draining")
      return true
    sv.handleRetrieve(sock, parts)
  of "RINGS":
    var allowedCount = 0
    for ring, rc in sv.fs.ringCentroid:
      if sv.ringKeyAllowed(sock, ring):
        inc allowedCount
    sock.sendFrame("RINGS " & $allowedCount)
    for ring, rc in sv.fs.ringCentroid:
      if not sv.ringKeyAllowed(sock, ring):
        continue
      sock.sendFrame("RING " & $ring & " " & $rc.n & " " & $rc.c.len,
                     rc.c.vecBytes)
  of "PUTR":
    if not sv.requireRole(sock, roleWriter):
      return false
    requireParts(parts, "PUTR", 3)
    let ringLen = parseInt(parts[1])
    let payloadLen = parseInt(parts[2])
    let vecDim = if parts.len >= 4: parseInt(parts[3]) else: 0
    let codec = if parts.len >= 5: parsePayloadCodec(parts[4]) else: pcRaw
    discard checkedWireLen(ringLen, "ringLen")
    let bodyBytes = checkedFrameBytes(payloadLen, vecDim)
    if sv.draining:
      sock.drainBytes(ringLen + bodyBytes)
      sv.rejectDrainedWrite(sock, "PUTR")
      return true
    let ringName = sock.readExact(ringLen)
    if not sv.ringNameAllowed(sock, ringName):
      sock.drainBytes(bodyBytes)
      sv.denyRingName(sock, ringName)
      return true
    let payload = sock.readExact(payloadLen)
    let vec =
      if vecDim == 0: @[]
      else: sock.readExact(checkedVecBytes(vecDim)).bytesVec(vecDim).normalize()
    let ri = sv.ringInfo(ringName)
    let owner = int(sv.tbl.placementOwner(ri.key))
    if owner != sv.myId:
      let id = sv.peerLink.putRingReq(owner, ringName, payload, vec, codec)
      sock.sendFrame("ID " & $id.parent & " " & $id.epoch & " " & $id.seq & " " &
                     $id.tWrite & " " & $id.period & " " & $id.head)
    else:
      let seq = sv.st.nextSeq(ri.key)
      sv.st.upsert Particle(parent: ri.key, seq: seq, period: ri.period,
                            head: ri.head, tWrite: now, payload: payload,
                            codec: codec, vec: vec, lastHere: now)
      if ri.key != HaloKey:
        sv.fs.observeRingPut(ri.key, vec)
      sock.sendFrame("ID " & $ri.key & " 1 " & $seq & " " & $now & " " &
                     $ri.period & " " & $ri.head)
  of "PUT":
    if not sv.requireRole(sock, roleWriter):
      return false
    requireParts(parts, "PUT", 5)
    let ringKey = parseBiggestUInt(parts[1]).uint64
    let period = parseFloat(parts[2])
    let head = parseFloat(parts[3])
    let payloadLen = parseInt(parts[4])
    let vecDim = if parts.len >= 6: parseInt(parts[5]) else: 0
    let codec = if parts.len >= 7: parsePayloadCodec(parts[6]) else: pcRaw
    let bodyBytes = checkedFrameBytes(payloadLen, vecDim)
    if sv.draining:
      sock.drainBytes(bodyBytes)
      sv.rejectDrainedWrite(sock, "PUT")
      return true
    if not sv.ringKeyAllowed(sock, ringKey):
      sock.drainBytes(bodyBytes)
      sv.denyRingKey(sock, ringKey)
      return true
    let payload = sock.readExact(payloadLen)
    let vec =
      if vecDim == 0: @[]
      else: sock.readExact(checkedVecBytes(vecDim)).bytesVec(vecDim).normalize()
    let owner = int(sv.tbl.placementOwner(ringKey))
    if owner != sv.myId:
      let placed = sv.peerLink.putReq(owner, ringKey, period, head, payload,
                                      vec, codec)
      sock.sendFrame("OK " & $placed.seq & " " & $placed.tWrite)
      return true
    let seq = sv.st.nextSeq(ringKey)
    if ringKey notin sv.st.ringMeta:
      sv.st.putRingMeta(ringKey, period, head)
    sv.st.upsert Particle(parent: ringKey, seq: seq, period: period, head: head,
                          tWrite: now, payload: payload, codec: codec,
                          vec: vec, lastHere: now)
    if ringKey != HaloKey:
      sv.fs.observeRingPut(ringKey, vec)
    sock.sendFrame("OK " & $seq & " " & $now)
  of "COUNTR":
    requireParts(parts, "COUNTR", 2)
    let ringKey = parseBiggestUInt(parts[1]).uint64
    if not sv.requireRingKey(sock, ringKey):
      return true
    sock.sendFrame("COUNT " & $sv.st.ringLiveCount(ringKey))
  of "LISTR":
    requireParts(parts, "LISTR", 4)
    let ringKey = parseBiggestUInt(parts[1]).uint64
    let limit = parseInt(parts[2])
    let cursorLen = parseInt(parts[3])
    discard checkedWireLen(cursorLen, "cursorLen")
    if limit < 0 or limit > MaxListRingItems:
      sock.drainBytes(cursorLen)
      raise newException(ValueError,
        "LISTR limit must be between 0 and " & $MaxListRingItems)
    if not sv.ringKeyAllowed(sock, ringKey):
      sock.drainBytes(cursorLen)
      sv.denyRingKey(sock, ringKey)
      return true
    let cursor = sock.readExact(cursorLen)
    let afterSeq = if cursor.len == 0: -1'i64 else: int64(parseBiggestInt(cursor))
    var rows: seq[Particle] = @[]
    var nextCursor = "_"
    if limit > 0:
      let page = sv.st.itemKeysByRingPage(ringKey, afterSeq, limit)
      for k in page.items:
        rows.add sv.st.getParticle(k[0], k[1])
      if page.hasMore and rows.len > 0:
        nextCursor = $(rows[^1].seq)
    sock.sendFrame("LVAL " & $rows.len & " " & nextCursor)
    for p in rows:
      sock.sendFrame("ITEM " & $p.seq & " " & $p.tWrite & " " & $p.parent & " " &
                     $p.payload.len & sv.codecSuffix(sock, p.codec), p.payload)
  of "GETID", "QRYID":
    requireParts(parts, parts[0], if parts[0] == "QRYID": 8 else: 7)
    let parent = parseBiggestUInt(parts[1]).uint64
    let epoch = parseUInt(parts[2]).uint32
    let seq = parseUInt(parts[3]).uint32
    let tWrite = parseFloat(parts[4])
    let period = parseFloat(parts[5])
    let head = parseFloat(parts[6])
    var selection = ""
    if parts[0] == "QRYID":
      let selectionLen = parseInt(parts[7])
      discard checkedWireLen(selectionLen, "selectionLen")
      if not sv.ringKeyAllowed(sock, parent):
        sock.drainBytes(selectionLen)
        sv.denyRingKey(sock, parent)
        return true
      selection = sock.readExact(selectionLen)
    elif not sv.requireRingKey(sock, parent):
      return true
    let owner = sv.ownerOf(parent, seq, period, head, tWrite)
    if owner != sv.myId:
      # Keep read routing non-blocking at the server layer. Synchronous
      # server-to-server read forwarding can deadlock two single-loop nodes
      # that ask each other for ownership resolution at the same time.
      sock.sendFrame("FWD " & $parent & " " & $epoch & " " & $seq & " " &
                     $tWrite & " " & $period & " " & $head & " " & $owner)
      return true
    if not sv.st.contains(parent, seq):
      let localKey = (parent, seq)
      if localKey in sv.st.forwarders and sv.st.forwarders[localKey].expiresAt >= now:
        let f = sv.st.forwarders[localKey]
        sock.sendFrame("FWD " & $f.newParent & " " & $epoch & " " & $f.newSeq & " " &
                       $f.newTWrite & " " & $period & " " & $head)
      else:
        sock.sendFrame("MISS")
    else:
      let item = sv.st.getParticle(parent, seq)
      var value = item.payload
      var codec = item.codec
      if parts[0] == "QRYID":
        try:
          value = sv.projectPayload(value, codec, selection)
          codec = pcJson
        except ValueError, JsonParsingError:
          sock.sendStableError(getCurrentException())
          return true
      sock.sendFrame("VAL " & $sv.myId & " " & $value.len &
                     sv.codecSuffix(sock, codec), value)
  of "GET", "QRY":
    requireParts(parts, parts[0], if parts[0] == "QRY": 7 else: 6)
    if parts.len != (if parts[0] == "QRY": 7 else: 6):
      raise newException(ValueError, parts[0] & " has unexpected trailing fields")
    let parent = parseBiggestUInt(parts[1]).uint64
    let seq = parseUInt(parts[2]).uint32
    let period = parseFloat(parts[3])
    let head = parseFloat(parts[4])
    let tWrite = parseFloat(parts[5])
    var selection = ""
    if parts[0] == "QRY":
      let selectionLen = parseInt(parts[6])
      discard checkedWireLen(selectionLen, "selectionLen")
      if not sv.ringKeyAllowed(sock, parent):
        sock.drainBytes(selectionLen)
        sv.denyRingKey(sock, parent)
        return true
      selection = sock.readExact(selectionLen)
    elif not sv.requireRingKey(sock, parent):
      return true
    let owner = sv.ownerOf(parent, seq, period, head, tWrite)
    if owner != sv.myId:
      sock.sendFrame("FWD " & $parent & " " & $seq & " " & $tWrite & " " & $owner)
      return true
    if not sv.st.contains(parent, seq):
      let localKey = (parent, seq)
      if localKey in sv.st.forwarders and sv.st.forwarders[localKey].expiresAt >= now:
        let f = sv.st.forwarders[localKey]
        sock.sendFrame("FWD " & $f.newParent & " " & $f.newSeq & " " &
                       $f.newTWrite)
      else:
        sock.sendFrame("MISS")
    else:
      let item = sv.st.getParticle(parent, seq)
      var value = item.payload
      var codec = item.codec
      if parts[0] == "QRY":
        try:
          value = sv.projectPayload(value, codec, selection)
          codec = pcJson
        except ValueError, JsonParsingError:
          sock.sendStableError(getCurrentException())
          return true
      sock.sendFrame("VAL " & $sv.myId & " " & $value.len &
                     sv.codecSuffix(sock, codec), value)
  of "BGET":
    requireParts(parts, "BGET", 3)
    let n = parseInt(parts[1])
    let bodyLen = parseInt(parts[2])
    discard checkedWireLen(bodyLen, "bodyLen")
    let body = sock.readExact(bodyLen)
    var payload = ""
    var pos = 0
    for _ in 0 ..< n:
      let nl = body.find('\n', pos)
      if nl < 0:
        break
      let h = body[pos ..< nl].split(' ')
      pos = nl + 1
      if h.len < 5:
        payload.add "0\n"
        continue
      let parent = parseBiggestUInt(h[0]).uint64
      if not sv.ringKeyAllowed(sock, parent):
        payload.add "0\n"
        continue
      let seq = parseUInt(h[1]).uint32
      if sv.st.contains(parent, seq):
        let value = sv.st.getParticle(parent, seq).payload
        payload.add $value.len & "\n"
        payload.add value
      else:
        payload.add "0\n"
    sock.sendFrame("BVAL " & $n & " " & $payload.len, payload)
  of "TRF":
    if not sv.requireRole(sock, roleWriter):
      return false
    requireParts(parts, "TRF", 7)
    var p = Particle(parent: parseBiggestUInt(parts[1]).uint64,
                     seq: parseUInt(parts[2]).uint32,
                     period: parseFloat(parts[3]),
                     head: parseFloat(parts[4]),
                     tWrite: parseFloat(parts[5]),
                     lastHere: now)
    let payloadLen = parseInt(parts[6])
    let vecDim = if parts.len >= 8: parseInt(parts[7]) else: 0
    p.codec = if parts.len >= 9: parsePayloadCodec(parts[8]) else: pcRaw
    p.version = parseMutationVersion(parts, 9, p.tWrite)
    let bodyBytes = checkedFrameBytes(payloadLen, vecDim)
    let hasPlacementFence = parts.len in [15, 16]
    let maintenanceMigration =
      parts.len == 16 and parts[15] == "MIGRATION"
    if parts.len notin [9, 12, 15, 16] or
        (parts.len == 16 and not maintenanceMigration):
      sock.drainBytes(bodyBytes)
      sock.sendFrame("ERR invalid-TRF-frame")
      return true
    if hasPlacementFence:
      let expectedEpoch = parseUInt(parts[12])
      let expectedNodes = parseUInt(parts[13])
      let expectedVirtualArcs = parseInt(parts[14])
      if expectedEpoch != uint64(sv.tbl.epoch) or
          expectedNodes != uint64(sv.tbl.nNodes) or
          expectedVirtualArcs != sv.virtualArcsPerNode:
        sock.drainBytes(bodyBytes)
        sock.sendFrame("ERR topology-mismatch")
        return true
    if sv.draining:
      if not maintenanceMigration or not hasPlacementFence or
          not sv.rolePermitted(sock, roleAdmin):
        sock.drainBytes(bodyBytes)
        sv.rejectDrainedWrite(sock, "TRF")
        return true
    if not sv.ringKeyAllowed(sock, p.parent):
      sock.drainBytes(bodyBytes)
      sv.denyRingKey(sock, p.parent)
      return true
    p.payload = sock.readExact(payloadLen)
    p.vec =
      if vecDim == 0: @[]
      else: sock.readExact(checkedVecBytes(vecDim)).bytesVec(vecDim).normalize()
    if p.parent notin sv.st.ringMeta:
      sv.st.putRingMeta(p.parent, p.period, p.head)
    # 追い越し対策: 相手起点の seq 採番と衝突しないよう max を取る
    if p.seq >= sv.st.seqs.getOrDefault(p.parent, 0'u32):
      sv.st.seqs[p.parent] = p.seq + 1
    let applied = sv.st.upsert(p, origin = uint32(sv.myId + 1),
                               preserveVersion = true)
    if applied and p.parent != HaloKey:
      sv.fs.observeRingPut(p.parent, p.vec)
    if applied:
      let owner = sv.ownerOf(p.parent, p.seq, p.period, p.head, p.tWrite)
      if owner != sv.myId:
        discard sv.queueHandoffWork(p.parent, p.seq, owner, false)
    sock.sendFrame("OK " & (if applied: "APPLIED" else: "SKIPPED"))
  of "TRFD":
    if not sv.requireRole(sock, roleWriter):
      return false
    requireParts(parts, "TRFD", 9)
    var tombstone = Tombstone(
      parent: parseBiggestUInt(parts[1]).uint64,
      seq: parseUInt(parts[2]).uint32,
      period: parseFloat(parts[3]),
      head: parseFloat(parts[4]),
      tWrite: parseFloat(parts[5]),
      version: parseMutationVersion(parts, 6, parseFloat(parts[5])),
      lastHere: now)
    if parts.len > 9:
      tombstone.acknowledgedNodes = parseAcknowledgedNodes(parts[9])
    if parts.len > 10:
      tombstone.reclaimAfter = parseFloat(parts[10])
      if tombstone.reclaimAfter < 0 or
          tombstone.reclaimAfter.classify in {fcNan, fcInf, fcNegInf}:
        raise newException(ValueError,
          "tombstone reclaimAfter must be finite and non-negative")
    let hasPlacementFence = parts.len in [14, 15]
    let maintenanceMigration =
      parts.len == 15 and parts[14] == "MIGRATION"
    if parts.len notin [9, 10, 11, 14, 15] or
        (parts.len == 15 and not maintenanceMigration):
      sock.sendFrame("ERR invalid-TRFD-frame")
      return true
    if hasPlacementFence:
      let expectedEpoch = parseUInt(parts[11])
      let expectedNodes = parseUInt(parts[12])
      let expectedVirtualArcs = parseInt(parts[13])
      if expectedEpoch != uint64(sv.tbl.epoch) or
          expectedNodes != uint64(sv.tbl.nNodes) or
          expectedVirtualArcs != sv.virtualArcsPerNode:
        sock.sendFrame("ERR topology-mismatch")
        return true
    if sv.draining:
      if not maintenanceMigration or not hasPlacementFence or
          not sv.rolePermitted(sock, roleAdmin):
        sv.rejectDrainedWrite(sock, "TRFD")
        return true
    if not sv.requireRingKey(sock, tombstone.parent):
      return true
    var effective = sv.prepareTombstoneForNode(tombstone, now)
    let applied = sv.st.applyTombstone(effective)
    if applied or (effective.parent, effective.seq) in sv.st.tombstones:
      sv.queueTombstonePropagation((effective.parent, effective.seq),
                                   migration = maintenanceMigration)
    sock.sendFrame("OK " & (if applied: "APPLIED" else: "SKIPPED"))
  of "STATS":
    sock.sendFrame("OK " & $sv.myId & " " & $sv.st.count)
  of "HEALTH":
    if sv.users.len > 0 and not roleAllowed(sv.userRule(sv.currentUser(sock)).role,
                                            roleAdmin):
      sock.sendFrame("OK node=" & $sv.myId)
    else:
      sock.sendFrame("OK node=" & $sv.myId & " items=" & $sv.st.count &
                     " pendingTx=" & $sv.st.clusterTxPending)
  of "METRICS":
    if not sv.requireRole(sock, roleAdmin):
      return true
    let segment = sv.st.segmentMetrics()
    sock.sendFrame("OK " &
                   "node " & $sv.myId & " " &
                   "uptimeSec " & $(int(epochTime() - sv.startedAt)) & " " &
                   "requests " & $sv.requestCount & " " &
                   "errors " & $sv.errorResponses & " " &
                   "authFailures " & $sv.authFailures & " " &
                   "authzDenied " & $sv.authzDenied & " " &
                   "draining " & $(if sv.draining: 1 else: 0) & " " &
                   "drainRejectedWrites " & $sv.drainRejectedWrites & " " &
                   "drainStartedAt " & $(int(sv.drainStartedAt)) & " " &
                   "connectionsAccepted " & $sv.connectionsAccepted & " " &
                   "connectionsRejected " & $sv.connectionsRejected & " " &
                   "activeConnections " & $sv.activeConnections & " " &
                   "items " & $sv.st.count & " " &
                   "tombstones " & $sv.st.tombstones.len & " " &
                   "tombstonesReclaimed " & $sv.tombstonesReclaimed & " " &
                   "rings " & $sv.st.ringMeta.len & " " &
                   "forwarders " & $sv.st.forwarders.len & " " &
                   "handoffPending " & $sv.pendingHandoffs.len & " " &
                   "handoffQueueDepth " & $handoffTasks.peek & " " &
                   "handoffWorkDepth " &
                     $(sv.handoffWork.len - sv.handoffWorkHead) & " " &
                   "migrationRemaining " & $sv.migrationRemaining & " " &
                   "migrationLagSec " &
                     $(if sv.migrationRemaining > 0:
                         int(epochTime() - sv.migrationStartedAt)
                       else: 0) & " " &
                   "activationMigrationPending " &
                     $sv.migrationPendingCount() & " " &
                   "placementEpoch " & $sv.tbl.epoch & " " &
                   "placementVirtualArcs " & $sv.virtualArcsPerNode & " " &
                   "handoffQueued " & $sv.handoffQueued & " " &
                   "handoffApplied " & $sv.handoffApplied & " " &
                   "handoffFailed " & $sv.handoffFailed & " " &
                   "handoffStaleAck " & $sv.handoffStaleAck & " " &
                   "handoffQueueFull " & $sv.handoffQueueFull & " " &
                   "walBytes " & $sv.st.logSize & " " &
                   "warpJobs " & $sv.st.warpJobs.len & " " &
                   "universeSyncEvents " & $sv.st.universeSyncEvents.len & " " &
                   "universeSyncApplied " &
                     $sv.st.appliedUniverseSyncEvents.len & " " &
                   "universeApplyApplied " & $sv.universeApplyApplied & " " &
                   "universeApplySkipped " & $sv.universeApplySkipped & " " &
                   "universeApplyErrors " & $sv.universeApplyErrors & " " &
                   "universeApplyForwarded " & $sv.universeApplyForwarded & " " &
                   "universeApplyLastOk " &
                     $(int(sv.universeApplyLastOk)) & " " &
                   "universeApplyLastError " &
                     $(int(sv.universeApplyLastError)) & " " &
                   "retrieveRequests " & $sv.retrieveRequests & " " &
                   "retrieveScopedRequests " & $sv.retrieveScopedRequests & " " &
                   "retrieveGlobalRequests " & $sv.retrieveGlobalRequests & " " &
                   "retrievePhysicalVisited " & $sv.retrievePhysicalVisited & " " &
                   "retrieveCandidatesScored " & $sv.retrieveCandidatesScored & " " &
                   "autoPackEnabled " & $(if sv.autoPack.enabled: 1 else: 0) & " " &
                   "autoPackAttempts " & $sv.autoPackAttempts & " " &
                   "autoPackCompleted " & $sv.autoPackCompleted & " " &
                   "autoPackPartial " & $sv.autoPackPartial & " " &
                   "autoPackInterrupted " & $sv.autoPackInterrupted & " " &
                   "autoPackFailed " & $sv.autoPackFailed & " " &
                   "autoPackNoWork " & $sv.autoPackNoWork & " " &
                   "autoPackRings " & $sv.autoPackRings & " " &
                   "autoPackBytes " & $sv.autoPackBytes & " " &
                   "autoPackLastElapsedMs " & $sv.autoPackLastElapsedMs & " " &
                   "segmentHits " & $segment.hits & " " &
                   "segmentWalFallbacks " & $segment.walFallbacks & " " &
                   "segmentWalFallbackPointRead " &
                     $segment.walFallbackReasons[ssfrPointRead] & " " &
                   "segmentWalFallbackRingScan " &
                     $segment.walFallbackReasons[ssfrRingScan] & " " &
                   "segmentWalFallbackWindowRead " &
                     $segment.walFallbackReasons[ssfrWindowRead] & " " &
                   "segmentBytes " & $segment.segmentBytes & " " &
                   "segmentIndexBytes " & $segment.indexBytes & " " &
                   "segmentActiveGenerations " &
                     $segment.activeGenerations & " " &
                   "segmentStaleRecords " & $segment.staleRecords & " " &
                   "segmentRecommendedRings " &
                     $segment.recommendedRings & " " &
                   "persistent " & $(if sv.st.isPersistent: 1 else: 0) & " " &
                   "durabilityStrong " &
                     $(if sv.st.durability == durStrong: 1 else: 0) & " " &
                   "clusterTxCommitted " & $sv.st.clusterTxCommitted & " " &
                   "clusterTxApplied " & $sv.st.clusterTxApplied & " " &
                   "clusterTxPending " & $sv.st.clusterTxPending & " " &
                   "clumps " & $sv.fs.clumps.len)
  of "DRAIN":
    if not sv.requireRole(sock, roleAdmin):
      return true
    sv.st.setMaintenanceDrained(true)
    sv.draining = true
    sv.drainStartedAt = epochTime()
    sv.audit("drain", user = sv.currentUser(sock),
             message = "server entered drain mode")
    sock.sendFrame("OK draining")
  of "RESUME":
    if not sv.requireRole(sock, roleAdmin):
      return true
    if not sv.draining:
      sock.sendFrame("OK active")
      return true
    let activation = sv.clusterActivationReady()
    if not activation.ok:
      inc sv.errorResponses
      sv.audit("resume-denied", ok = false, user = sv.currentUser(sock),
               message = "topology activation is not ready: " &
                 activation.reason)
      sock.sendFrame("ERR activation-not-ready " & activation.reason)
      return true
    sv.st.setMaintenanceDrained(false)
    sv.draining = false
    sv.drainStartedAt = 0.0
    sv.audit("resume", user = sv.currentUser(sock),
             message = "server left drain mode")
    sock.sendFrame("OK resumed")
  of "SNAPSHOT":
    if not sv.requireRole(sock, roleAdmin):
      return true
    sv.st.sync()
    sv.audit("snapshot-barrier", user = sv.currentUser(sock),
             message = "server flushed snapshot barrier")
    sock.sendFrame("SNAPSHOT " &
                   "draining " & $(if sv.draining: 1 else: 0) & " " &
                   "items " & $sv.st.count & " " &
                   "rings " & $sv.st.ringMeta.len & " " &
                   "pendingTx " & $sv.st.clusterTxPending & " " &
                   "walBytes " & $sv.st.logSize & " " &
                   "activeConnections " & $sv.activeConnections)
  of "SHUTDOWN":
    if not sv.requireRole(sock, roleAdmin):
      return true
    sv.st.sync()
    sock.sendFrame("OK shutting-down")
    sv.running = false
  else:
    inc sv.errorResponses
    sock.sendFrame("ERR unknown")
  true

proc printUsage() =
  echo "KoutenDB node server"
  echo ""
  echo "Usage:"
  echo "  koutend --id=N --peers=host:port[,host:port...] [options]"
  echo "  koutend --config=server.json [options]"
  echo ""
  echo "Options:"
  echo "  --config=FILE                 Load server defaults from JSON"
  echo "  --data=DIR                    Enable WAL-backed persistence"
  echo "  --disk-backed                 Enable ring-local segment read layout"
  echo "  --slow-tick=SECONDS           Background maintenance interval"
  echo "  --auto-pack                   Enable bounded automatic ring packing"
  echo "  --auto-pack-interval=SECONDS  Minimum time between maintenance runs (default 300)"
  echo "  --auto-pack-window=HH:MM-HH:MM UTC maintenance window"
  echo "  --auto-pack-stale-ratio=F     Stale ratio threshold (default 0.25)"
  echo "  --auto-pack-min-stale-records=N  Minimum stale records (default 256)"
  echo "  --auto-pack-max-rings=N       Maximum rings per run (default 1)"
  echo "  --auto-pack-max-bytes=N       Maximum rewritten bytes per run (default 67108864)"
  echo "  --auto-pack-max-elapsed-ms=N  Maximum elapsed time per run (default 1000)"
  echo "  --placement-epoch=N           Monotonic physical placement topology epoch"
  echo "  --virtual-arcs-per-node=N     Virtual arcs per node (default 64)"
  echo "  --start-drained               Persist read-only drain before activation"
  echo "  --durability=buffered|strong  Buffered WAL or fsync-on-write durability"
  echo "  --user=NAME                   Username for cluster auth"
  echo "  --password=TEXT               Password for cluster auth"
  echo "  --password-file=FILE          Read password from file"
  echo "  --auth-token=TEXT             Token-style auth shortcut"
  echo "  --auth-token-file=FILE        Read token-style auth value from file"
  echo "  --secret-key=TEXT             Additional secret-key gate"
  echo "  --secret-key-file=FILE        Read secret-key gate value from file"
  echo "  --tls-cert=FILE               Enable TLS with certificate PEM (requires -d:ssl)"
  echo "  --tls-key=FILE                TLS private key PEM (requires -d:ssl)"
  echo "  --tls-ca=FILE                 CA/self-signed PEM for peer TLS verification"
  echo "  --tls-server-name=NAME        Override peer TLS hostname verification / SNI"
  echo "  --tls-insecure-skip-verify    Skip peer certificate verification for local smoke only"
  echo "  --galaxy=NAME                 Expected galaxy name"
  echo "  --allow-ring=PREFIX[,PREFIX]  Ring-prefix authorization"
  echo "  --role=user:password:role[:prefixes]"
  echo "                                Role entry: reader, writer, or admin"
  echo "  -h, --help                    Show this help"
  echo ""
  echo "Example:"
  echo "  koutend --id=0 --peers=127.0.0.1:7301 --data=/var/lib/kouten"

proc main() =
  for arg in commandLineParams():
    if arg == "--help" or arg == "-h":
      printUsage()
      return

  var configPath = getEnv("KOUTEN_SERVER_CONFIG")
  var id = -1
  var peersStr = ""
  var dataDir = ""
  var slowTickSec = DefaultSlowTickSec
  var diskBacked = false
  var autoPack = AutoPackConfig(
    intervalSec: DefaultAutoPackIntervalSec,
    policy: defaultSegmentMaintenancePolicy())
  var authUser = ""
  var authPassword = ""
  var authPasswordFile = ""
  var authTokenFile = ""
  var authSecretKey = ""
  var authSecretKeyFile = ""
  var tlsCertFile = ""
  var tlsKeyFile = ""
  var tlsCaFile = ""
  var tlsServerName = ""
  var tlsInsecureSkipVerify = false
  var users = initTable[string, UserRule]()
  var galaxy = ""
  var allowedRingPrefixes: seq[string] = @[]
  var durability = durBuffered
  var placementEpoch = DefaultPlacementEpoch
  var virtualArcsPerNode = DefaultVirtualArcsPerNode
  var startDrained = false
  for kind, key, val in getopt():
    if kind == cmdLongOption:
      case key
      of "config": configPath = val
      else: discard

  if configPath.len > 0:
    loadServerConfig(configPath, id, peersStr, dataDir, slowTickSec,
                     diskBacked, autoPack,
                     authUser, authPassword, authPasswordFile, authTokenFile,
                     authSecretKey, authSecretKeyFile, tlsCertFile, tlsKeyFile,
                     tlsCaFile, tlsServerName, tlsInsecureSkipVerify, users,
                     galaxy, allowedRingPrefixes, durability, placementEpoch,
                     virtualArcsPerNode, startDrained)

  for kind, key, val in getopt():
    if kind == cmdLongOption:
      case key
      of "config": discard
      of "id": id = parseInt(val)
      of "peers": peersStr = val
      of "data": dataDir = val
      of "slow-tick": slowTickSec = parseFloat(val)
      of "disk-backed": diskBacked = true
      of "auto-pack": autoPack.enabled = true
      of "auto-pack-interval": autoPack.intervalSec = parseFloat(val)
      of "auto-pack-window":
        autoPack.windowText = val
        autoPack.window = parseMaintenanceWindow(val)
      of "auto-pack-stale-ratio":
        autoPack.policy.staleRatioThreshold = parseFloat(val)
      of "auto-pack-min-stale-records":
        autoPack.policy.minStaleRecords = parseInt(val)
      of "auto-pack-max-rings": autoPack.policy.maxRings = parseInt(val)
      of "auto-pack-max-bytes":
        autoPack.policy.maxBytes = parseBiggestInt(val).int64
      of "auto-pack-max-elapsed-ms":
        autoPack.policy.maxElapsedMs = parseBiggestInt(val).int64
      of "user": authUser = val
      of "password": authPassword = val
      of "password-file": authPasswordFile = val
      of "secret-key": authSecretKey = val
      of "secret-key-file": authSecretKeyFile = val
      of "tls-cert": tlsCertFile = val
      of "tls-key": tlsKeyFile = val
      of "tls-ca": tlsCaFile = val
      of "tls-server-name": tlsServerName = val
      of "tls-insecure-skip-verify": tlsInsecureSkipVerify = true
      of "galaxy": galaxy = val
      of "role":
        let parsed = parseUserRule(val)
        users[parsed.user] = parsed.rule
        if authUser.len == 0:
          authUser = parsed.user
          authPassword = parsed.rule.password
      of "allow-ring":
        for part in val.split(','):
          let prefix = part.strip()
          if prefix.len > 0:
            allowedRingPrefixes.add prefix
      of "durability":
        durability = parseDurabilityValue(val)
      of "placement-epoch":
        let parsed = parseInt(val)
        if parsed <= 0:
          raise newException(ValueError, "--placement-epoch must be positive")
        placementEpoch = uint32(parsed)
      of "virtual-arcs-per-node":
        virtualArcsPerNode = parseInt(val)
      of "start-drained":
        startDrained = true
      of "auth-token":
        authUser = "token"
        authPassword = val
      of "auth-token-file":
        authTokenFile = val
  if authPasswordFile.len > 0:
    authPassword = readSecretFile(authPasswordFile, "password")
  if authSecretKeyFile.len > 0:
    authSecretKey = readSecretFile(authSecretKeyFile, "secret-key")
  if authTokenFile.len > 0:
    authUser = "token"
    authPassword = readSecretFile(authTokenFile, "auth-token")
  if authUser.len == 0:
    authUser = getEnv("KOUTEN_USER")
  if authPassword.len == 0:
    authPassword = getEnv("KOUTEN_PASSWORD")
  if authUser.len == 0 and authPassword.len == 0 and getEnv("KOUTEN_AUTH_TOKEN").len > 0:
    authUser = "token"
    authPassword = getEnv("KOUTEN_AUTH_TOKEN")
  if authSecretKey.len == 0:
    authSecretKey = getEnv("KOUTEN_SECRET_KEY")
  if authPassword.len > 0 and authUser.len == 0:
    raise newException(ValueError, "--password requires --user")
  if authUser.len > 0 and authPassword.len == 0:
    raise newException(ValueError, "--user requires --password")
  if authSecretKey.len > 0 and (authUser.len == 0 or authPassword.len == 0):
    raise newException(ValueError,
      "--secret-key requires --user and --password")
  if tlsCertFile.len > 0 or tlsKeyFile.len > 0:
    if tlsCertFile.len == 0 or tlsKeyFile.len == 0:
      raise newException(ValueError, "--tls-cert and --tls-key must be provided together")
    when not defined(ssl):
      raise newException(ValueError, "TLS support requires building koutend with -d:ssl")
  let peers = parsePeers(peersStr)
  doAssert id >= 0 and id < peers.len, "--id と --peers を指定（id は peers 内の自分の位置）"
  if virtualArcsPerNode <= 0:
    raise newException(ValueError, "--virtual-arcs-per-node must be positive")
  if slowTickSec <= 0:
    raise newException(ValueError, "--slow-tick must be positive")
  if autoPack.intervalSec <= 0:
    raise newException(ValueError, "--auto-pack-interval must be positive")
  validateSegmentMaintenancePolicy(autoPack.policy)
  if autoPack.enabled and dataDir.len == 0:
    raise newException(ValueError, "--auto-pack requires --data")
  if autoPack.enabled and not diskBacked:
    raise newException(ValueError, "--auto-pack requires --disk-backed")
  if autoPack.enabled and (autoPack.policy.maxRings <= 0 or
      autoPack.policy.maxBytes <= 0 or autoPack.policy.maxElapsedMs <= 0):
    raise newException(ValueError,
      "automatic packing requires positive ring, byte, and elapsed limits")

  let sv = Server(myId: id, peers: peers,
                  tbl: virtualArcTable(placementEpoch, uint16(peers.len),
                                       virtualArcsPerNode),
                  virtualArcsPerNode: virtualArcsPerNode,
                  st: openStore(dataDir, durability = durability,
                                diskBacked = diskBacked,
                                mutationOrigin = uint32(id + 1)),
                  dataDir: dataDir,
                  fs: newFieldState(),
                  peerLink: newClusterClient(peers, username = authUser,
                                             password = authPassword,
                                             secretKey = authSecretKey,
                                             tls = tlsCertFile.len > 0,
                                             tlsCaFile = tlsCaFile,
                                             tlsServerName = tlsServerName,
                                             tlsInsecureSkipVerify = tlsInsecureSkipVerify),
                  slowTickSec: slowTickSec,
                  autoPack: autoPack,
                  running: true,
                  authUser: authUser,
                  authPassword: authPassword,
                  authSecretKey: authSecretKey,
                  tlsEnabled: tlsCertFile.len > 0,
                  tlsCertFile: tlsCertFile,
                  tlsKeyFile: tlsKeyFile,
                  tlsCaFile: tlsCaFile,
                  tlsServerName: tlsServerName,
                  tlsInsecureSkipVerify: tlsInsecureSkipVerify,
                  users: users,
                  galaxy: galaxy,
                  allowedRingPrefixes: allowedRingPrefixes,
                  pendingHandoffs:
                    initTable[(uint64, uint32), PendingHandoff](),
                  scheduledHandoffs:
                    initTable[(uint64, uint32, int, bool), bool](),
                  tombstoneCompletionSent:
                    initTable[(uint64, uint32, int), bool](),
                  tombstoneReclaims: initHeapQueue[TombstoneReclaim](),
                  preparedSelections: initTable[string, Selection](),
                  preparedSelectionLru: @[],
                  preparedSelectionBytes: 0,
                  codecMetadata: initTable[int, bool](),
                  startedAt: epochTime())
  when defined(ssl):
    if sv.tlsEnabled:
      sv.tlsContext = newContext(verifyMode = CVerifyNone,
                                 certFile = sv.tlsCertFile,
                                 keyFile = sv.tlsKeyFile)
  sv.st.setGalaxy(galaxy)
  if diskBacked:
    discard sv.st.recoverInterruptedSegmentMaintenance()
  if startDrained or
      (sv.st.placementEpoch == 0 and placementEpoch > 1 and peers.len > 1):
    sv.st.setMaintenanceDrained(true)
  sv.st.configurePlacement(placementEpoch, uint16(peers.len),
                           virtualArcsPerNode)
  sv.draining = sv.st.maintenanceDrained
  if sv.draining:
    sv.drainStartedAt = epochTime()
  sv.rebuildFieldState()
  sv.preparePlacementMigration()

  handoffTasks.open(HandoffQueueCapacity)
  handoffResults.open()
  handoffStopping.store(false)
  var handoffThread: Thread[HandoffWorkerConfig]
  createThread(handoffThread, handoffWorker, HandoffWorkerConfig(
    peers: peers,
    username: authUser,
    password: authPassword,
    secretKey: authSecretKey,
    tls: tlsCertFile.len > 0,
    tlsCaFile: tlsCaFile,
    tlsServerName: tlsServerName,
    tlsInsecureSkipVerify: tlsInsecureSkipVerify,
    placementEpoch: placementEpoch,
    placementNodes: uint16(peers.len),
    virtualArcsPerNode: virtualArcsPerNode))

  let listener = newSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(peers[id].port), peers[id].host)
  listener.listen()
  echo "koutend node", id, " listening on ", peers[id].host, ":", peers[id].port,
       (if dataDir.len > 0: " data=" & dataDir else: " (memory)"),
       " placementEpoch=", sv.tbl.epoch,
       " placementNodes=", sv.tbl.nNodes,
       " virtualArcsPerNode=", sv.virtualArcsPerNode,
       " restored=", sv.st.count,
       " slowTick=", sv.slowTickSec, "s",
       " durability=", (if durability == durStrong: "strong" else: "buffered"),
       (if diskBacked: " diskBacked=on" else: " diskBacked=off"),
       (if autoPack.enabled:
          " autoPack=on interval=" & $autoPack.intervalSec & "s" &
          (if autoPack.windowText.len > 0:
             " window=" & autoPack.windowText & "Z"
           else: " window=all-day")
        else: " autoPack=off"),
       (if galaxy.len > 0: " galaxy=" & galaxy else: " galaxy=<none>"),
       (if users.len > 0: " authz=role-ring-prefix"
        elif allowedRingPrefixes.len > 0: " authz=ring-prefix"
        else: " authz=off"),
       (if authUser.len > 0:
          " auth=on user=" & authUser &
          (if authSecretKey.len > 0: " secret=on" else: " secret=off")
        else: " auth=off"),
       (if tlsCertFile.len > 0: " tls=on" else: " tls=off")

  var sel = newSelector[int]()
  let listenerFd = listener.getFd
  let listenerFdInt = listenerFd.int
  sel.registerHandle(listenerFd, {Event.Read}, 0)
  var conns = initTable[int, Socket]()

  var lastTick = getMonoTime()
  var lastSlowTick = getMonoTime()
  while sv.running:
    for ev in sel.select(TickMs):
      if ev.errorCode.int != 0:
        continue
      let fd = ev.fd
      if fd == listenerFdInt:
        var client: Socket
        listener.accept(client)
        if conns.len >= MaxActiveConnections:
          inc sv.errorResponses
          inc sv.connectionsRejected
          if not sv.tlsEnabled:
            try:
              client.sendFrame("ERR overloaded")
            except CatchableError:
              discard
          client.close()
          continue
        client.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)
        client.setSocketTimeouts(SocketReadTimeoutMs, SocketWriteTimeoutMs)
        when defined(ssl):
          if sv.tlsEnabled:
            try:
              sv.tlsContext.wrapConnectedSocket(client, handshakeAsServer)
            except CatchableError:
              inc sv.errorResponses
              client.close()
              continue
        conns[client.getFd.int] = client
        inc sv.connectionsAccepted
        sv.activeConnections = conns.len
        if sv.authUser.len == 0:
          sv.authed[client.getFd.int] = true
        sel.registerHandle(client.getFd, {Event.Read}, 0)
      else:
        let sock = conns[fd]
        var keep = false
        try:
          keep = sv.handleFrame(sock)
        except Exception:
          inc sv.errorResponses
          try:
            sock.sendStableError(getCurrentException())
          except Exception:
            discard
          keep = false
        if not keep:
          sel.unregister(fd)
          conns.del fd
          sv.activeConnections = conns.len
          sv.authed.del fd
          sv.authedUsers.del fd
          sv.codecMetadata.del fd
          sv.authChallenges.del fd
          sock.disableSecure()
          sock.close()
    # Run bounded migration, retry, and tombstone work at the maintenance
    # cadence. This path does not periodically scan every live record.
    let nowM = getMonoTime()
    if (nowM - lastTick).inMilliseconds >= TickMs:
      sv.handoffTick()
      sv.st.sync()
      lastTick = nowM
    if float((nowM - lastSlowTick).inMilliseconds) / 1000.0 >= sv.slowTickSec:
      sv.slowTick()
      sv.applyClusterTxTick()
      sv.autoPackTick()
      sv.st.sync()
      lastSlowTick = nowM
  sv.st.sync()
  handoffStopping.store(true)
  handoffTasks.send HandoffTask(kind: htkStop)
  handoffThread.joinThread()
  handoffTasks.close()
  handoffResults.close()
  sv.st.close()
  sv.peerLink.close()

when isMainModule:
  main()
