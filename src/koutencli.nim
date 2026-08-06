## kouten - KoutenDB command-line client
##
## usage:
##   kouten put [--data=DIR | --peers=host:port,...] --ring=RING [--near=BASE_RING] [--payload=TEXT | --in=FILE] [--codec=raw|json|nif|bif]
##   kouten get [--data=DIR | --peers=host:port,...] [--ring=RING | --stellar=RING] [--subring=orders,billing] [--subring-limit=orders:10] [--filter='{"id":"RAW_ID"}'] [--selection=SEL] [--sort=id|time] [--rsort=id|time]
##   kouten query [--data=DIR | --peers=host:port,...] --ring=RING [--filter='{"id":"RAW_ID"}' | --id=RAW_ID] --selection=SEL
##   kouten list-ring [--data=DIR | --peers=host:port,...] --ring=RING [--limit=N] [--cursor=CURSOR]
##   kouten count-ring [--data=DIR | --peers=host:port,...] --ring=RING
##   kouten health|metrics|drain|snapshot|resume --peers=host:port,...
##   kouten atlas [--data=DIR | --peers=host:port,...]
##   kouten driver list|info|install [LANG] [--manifest-path=FILE] [--execute]
##   kouten doctor

import std/[algorithm, base64, os, osproc, strutils, strformat, json, times, monotimes,
            parseopt, net, tempfiles, tables]
import nimsodium/hash
import koutendb
import kouten/[scale_in, wire]

const
  RagTopics = 8
  RagGoldSlots = 128

type
  DriverInfo = object
    name: string
    status: string
    mode: string
    repository: string
    packageName: string
    installHint: string
    notes: string

proc driverRegistry(): seq[DriverInfo] =
  @[
    DriverInfo(
      name: "rust",
      status: "published",
      mode: "C ABI wrapper first; native wire later",
      repository: "https://github.com/puffball1567/koutendb-rust",
      packageName: "koutendb",
      installHint: "cargo add koutendb",
      notes: "Published on crates.io as koutendb v0.1.5. Wraps the KoutenDB C ABI."
    ),
    DriverInfo(
      name: "node",
      status: "published",
      mode: "Node-API C ABI wrapper, TypeScript API",
      repository: "https://github.com/puffball1567/koutendb-js",
      packageName: "koutendb",
      installHint: "npm install koutendb",
      notes: "Published on npm as koutendb v0.1.3. Bun compatibility is tested on the Node-API path, but remains experimental."
    ),
    DriverInfo(
      name: "php",
      status: "published",
      mode: "FFI / C ABI wrapper",
      repository: "https://github.com/puffball1567/koutendb-php",
      packageName: "koutendb/koutendb",
      installHint: "composer require koutendb/koutendb",
      notes: "Published on Packagist as koutendb/koutendb v0.1.2. Wraps the KoutenDB C ABI through PHP FFI."
    ),
    DriverInfo(
      name: "cpp",
      status: "repository-released",
      mode: "C++17 C ABI wrapper",
      repository: "https://github.com/puffball1567/koutendb-cpp",
      packageName: "koutendb-cpp",
      installHint: "git clone https://github.com/puffball1567/koutendb-cpp.git",
      notes: "Released as koutendb-cpp v0.1.1. CMake smoke passes in CI; Conan/vcpkg publication is future work."
    ),
    DriverInfo(
      name: "python",
      status: "published",
      mode: "native TCP wire driver",
      repository: "https://github.com/puffball1567/koutendb-python",
      packageName: "koutendb",
      installHint: "python3 -m pip install koutendb",
      notes: "Published on PyPI as koutendb v0.1.3. Pure Python TCP driver."
    ),
    DriverInfo(
      name: "go",
      status: "repository-local",
      mode: "C ABI wrapper",
      repository: "drivers/go",
      packageName: "github.com/koutendb/koutendb-go",
      installHint: "go get github.com/koutendb/koutendb-go",
      notes: "Repository-local foundation. Package publication is future work."
    )
  ]

proc findDriver(name: string): DriverInfo =
  for driver in driverRegistry():
    if driver.name == name.toLowerAscii():
      return driver
  raise newException(ValueError, "unknown driver: " & name)

proc shellQuote(s: string): string =
  if s.len == 0:
    return "''"
  for ch in s:
    if not (ch.isAlphaNumeric or ch in {'_', '-', '.', '/', ':', '@'}):
      return "'" & s.replace("'", "'\\''") & "'"
  s

proc cargoManifestPath(manifestPath, projectDir: string): string =
  if manifestPath.len > 0:
    return manifestPath
  let envManifest = getEnv("KOUTEN_DRIVER_MANIFEST")
  if envManifest.len > 0:
    return envManifest
  var dir = projectDir
  if dir.len == 0:
    dir = getEnv("KOUTEN_DRIVER_PROJECT")
  if dir.len > 0:
    return dir / "Cargo.toml"
  if fileExists("Cargo.toml"):
    return "Cargo.toml"
  ""

proc printCargoAdd(driver: DriverInfo, manifestPath, projectDir: string,
                   executeInstall: bool) =
  let manifest = cargoManifestPath(manifestPath, projectDir)
  var cargoArgs = @["add", driver.packageName]
  if manifest.len > 0:
    cargoArgs.add "--manifest-path"
    cargoArgs.add manifest

  var printableArgs: seq[string] = @[]
  for arg in cargoArgs:
    printableArgs.add shellQuote(arg)
  echo "command: cargo ", printableArgs.join(" ")
  if manifest.len == 0:
    echo "target: no Cargo.toml found"
    echo "hint: run from a Rust project, pass --manifest-path=FILE, or set KOUTEN_DRIVER_MANIFEST"
  else:
    echo "target: ", manifest

  if not executeInstall:
    echo "execute: false"
    echo "hint: add --execute to run cargo"
    return

  if driver.status != "published":
    raise newException(ValueError,
      "driver package is not published yet; refusing to execute cargo")
  if manifest.len == 0:
    raise newException(ValueError, "cannot execute without Cargo.toml")
  if not fileExists(manifest):
    raise newException(ValueError, "Cargo.toml not found: " & manifest)
  if findExe("cargo").len == 0:
    raise newException(ValueError, "cargo is not installed or not on PATH")

  let p = startProcess("cargo", args = cargoArgs, options = {poUsePath})
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(OSError, "cargo failed with exit code " & $code)

proc runDriver(args: seq[string], manifestPath = "", projectDir = "",
               executeInstall = false) =
  if args.len == 0 or args[0] in ["help", "--help", "-h"]:
    echo "Usage:"
    echo "  kouten driver list"
    echo "  kouten driver info LANG"
    echo "  kouten driver install LANG [--manifest-path=FILE] [--project-dir=DIR] [--execute]"
    echo ""
    echo "The install command prints official package/repository metadata and the"
    echo "package-manager command. For Rust, it can target Cargo.toml via"
    echo "--manifest-path, --project-dir, KOUTEN_DRIVER_MANIFEST, or KOUTEN_DRIVER_PROJECT."
    echo "It does not execute package-manager commands unless --execute is passed."
    return

  case args[0]
  of "list":
    echo "language\tstatus\tmode"
    for driver in driverRegistry():
      echo driver.name, "\t", driver.status, "\t", driver.mode
  of "info", "install":
    if args.len < 2:
      raise newException(ValueError, "requires LANG")
    let driver = findDriver(args[1])
    echo "name: ", driver.name
    echo "status: ", driver.status
    echo "mode: ", driver.mode
    echo "repository: ", driver.repository
    echo "package: ", driver.packageName
    echo "install: ", driver.installHint
    echo "notes: ", driver.notes
    if args[0] == "install":
      echo ""
      if driver.name == "rust":
        printCargoAdd(driver, manifestPath, projectDir, executeInstall)
      else:
        echo "Next steps:"
        if driver.status == "repository-local":
          echo "  Use the repository-local driver path until package publication."
        elif driver.status == "published":
          echo "  Run the printed package-manager command in your target project."
        elif driver.status == "repository-released":
          echo "  Use the printed repository URL and the setup notes in docs/driver-installation.md."
        else:
          echo "  Use the package command after the driver package is published."
        echo "  Run the driver smoke test described in docs/driver-installation.md."
  else:
    raise newException(ValueError, "unknown driver command: " & args[0])

proc ringVec(ring, ringCount: int): seq[float32] =
  result = newSeq[float32](ringCount)
  result[ring mod ringCount] = 1.0'f32

proc topicVec(topic: int, goldSlot = -1): seq[float32] =
  result = newSeq[float32](RagTopics + RagGoldSlots)
  result[topic mod RagTopics] = 1.0'f32
  if goldSlot >= 0:
    result[RagTopics + (goldSlot mod RagGoldSlots)] = 0.5'f32

proc distractorVec(topic: int): seq[float32] =
  result = newSeq[float32](RagTopics + RagGoldSlots)
  result[topic mod RagTopics] = 0.92'f32
  result[(topic + 1) mod RagTopics] = 0.08'f32

proc tokenEstimate(payloads: seq[string]): int =
  var bytes = 0
  for p in payloads:
    bytes += p.len
  (bytes + 3) div 4

proc approxCandidateBytes(scanned, payloadBytes, vectorDim: int): int =
  ## Estimated working-set bytes if downstream ANN/rerank/LLM preprocessing
  ## keeps candidates in memory. 64B is a conservative estimate for candidate
  ## metadata such as ID, score, reference, and allocator overhead.
  scanned * (payloadBytes + vectorDim * sizeof(float32) + 64)

proc parseHostPort(endpoint: string): tuple[host: string, port: int] =
  let p = endpoint.rsplit(":", maxsplit = 1)
  if p.len == 2:
    (host: p[0], port: parseInt(p[1]))
  else:
    (host: endpoint, port: 6379)

proc openCliDb(dataDir, peers, username, password, authToken, secretKey,
               galaxy: string, tls: bool = false, tlsCaFile: string = "",
               tlsServerName: string = "",
               tlsInsecureSkipVerify: bool = false): KoutenDb =
  if peers.len > 0:
    connect(peers, username = username, password = password,
            authToken = authToken, secretKey = secretKey, galaxy = galaxy,
            tls = tls, tlsCaFile = tlsCaFile, tlsServerName = tlsServerName,
            tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  else:
    open(dataDir = dataDir)

proc defaultDataDir(): string =
  let envData = getEnv("KOUTEN_DATA")
  if envData.len > 0:
    envData
  else:
    "data"

proc resolveDataDir(dataDir, peers: string): string =
  if peers.len > 0:
    dataDir
  elif dataDir.len > 0:
    dataDir
  else:
    defaultDataDir()

proc jsonStringOpt(node: JsonNode, key, default: string): string =
  if node.kind == JObject and node.hasKey(key):
    node[key].getStr()
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
      parts.add item.getStr()
    parts.join(",")
  else:
    raise newException(ValueError, "config peers must be a string or array")

proc jsonStringListOpt(node: JsonNode, key: string): seq[string] =
  if node.kind != JObject or not node.hasKey(key):
    return @[]
  let value = node[key]
  case value.kind
  of JString:
    for part in value.getStr().split(','):
      let item = part.strip()
      if item.len > 0:
        result.add item
  of JArray:
    for item in value:
      if item.kind != JString:
        raise newException(ValueError, "config " & key & " entries must be strings")
      let value = item.getStr().strip()
      if value.len > 0:
        result.add value
  else:
    raise newException(ValueError, "config " & key & " must be a string or array")

proc configSecretValue(cfg: JsonNode, plainKey, fileKey, fileAlias: string): tuple[
    hasValue: bool, source: string] =
  let filePath = jsonStringOpt(cfg, fileKey, jsonStringOpt(cfg, fileAlias, ""))
  if filePath.len > 0:
    if not fileExists(filePath):
      return (false, fileAlias & " missing: " & filePath)
    if readFile(filePath).strip().len == 0:
      return (false, fileAlias & " empty: " & filePath)
    return (true, fileAlias)
  if jsonStringOpt(cfg, plainKey, "").len > 0:
    return (true, plainKey)
  (false, "")

proc requireCliTarget(dataDir, peers: string): string =
  resolveDataDir(dataDir, peers)

proc cliPayload(payload, inPath: string): string =
  if payload.len > 0:
    return payload
  if inPath.len > 0 and inPath != "-":
    return readFile(inPath)
  if inPath == "-":
    return stdin.readAll()
  raise newException(ValueError, "requires --payload=TEXT or --in=FILE")

proc cliId(idArg: string): KoutenId =
  if idArg.len == 0:
    raise newException(ValueError, "requires --id=ID")
  let parts = idArg.split(":")
  if parts.len == 2:
    return fromRaw(parseBiggestUInt(parts[0]).uint64, 1'u32,
                   parseUInt(parts[1]).uint32, 0.0)
  if parts.len == 4:
    return fromRaw(parseBiggestUInt(parts[0]).uint64,
                   parseUInt(parts[1]).uint32,
                   parseUInt(parts[2]).uint32,
                   parseFloat(parts[3]))
  raise newException(ValueError,
    "--id must be parent:seq or parent:epoch:seq:tWrite")

proc cliIdString(id: KoutenId): string =
  let raw = id.toRaw()
  $raw.parent & ":" & $raw.epoch & ":" & $raw.seq & ":" & $raw.tWrite

proc effectiveFilter(filterArg, whereArg: string): string =
  if filterArg.len > 0:
    filterArg
  else:
    whereArg

proc parseFilter(filterArg: string): JsonNode =
  if filterArg.len == 0:
    return newJObject()
  try:
    result = parseJson(filterArg)
    if result.kind != JObject:
      raise newException(ValueError, "filter must be a JSON object")
  except JsonParsingError as e:
    raise newException(ValueError, "invalid --filter JSON: " & e.msg)

proc idFromFilter(filterArg: string): string =
  if filterArg.len == 0:
    return ""
  let node = parseFilter(filterArg)
  if node.hasKey("id"):
    result = node["id"].getStr()
    if result.len == 0:
      raise newException(ValueError, "filter.id must not be empty")

proc resolveIdArg(idArg, filterArg: string): string =
  if idArg.len > 0:
    idArg
  else:
    idFromFilter(filterArg)

proc filterWithId(filterNode: JsonNode, idArg: string): JsonNode =
  if filterNode.isNil:
    result = newJObject()
  else:
    result = filterNode.copy()
  if idArg.len == 0:
    return
  if result.hasKey("id") and result["id"].getStr() != idArg:
    raise newException(ValueError, "--id and --filter.id must refer to the same record")
  result["id"] = %idArg

proc sortDirectionName(direction: KoutenReadSortDirection): string =
  case direction
  of rsAsc: "asc"
  of rsDesc: "desc"

proc paginationName(mode: KoutenPaginationMode): string =
  case mode
  of rpOff: "off"
  of rpOn: "on"

proc runDoctorSetup() =
  echo "KoutenDB setup doctor"
  echo "ok   vector retrieval: dependency-free ring-scoped exact search"
  echo "status: ready"

proc printOperationalReport(report: KoutenOperationalVerifyReport;
                            metricsFormat, jsonFormat: bool) =
  if metricsFormat:
    echo &"verifyOk {int(report.ok)}"
    echo &"verifyWalExists {int(report.walExists)}"
    echo &"verifyWalBytes {report.walBytes}"
    echo &"verifyItems {report.items}"
    echo &"verifyRings {report.rings}"
    echo &"verifyRingNames {report.ringNames}"
    echo &"verifyVectors {report.vectors}"
    echo &"verifyDiskBacked {int(report.diskBacked)}"
    echo &"verifySegmentDirExists {int(report.segmentDirExists)}"
    echo &"verifySegmentFiles {report.segmentFiles}"
    echo &"verifySegmentPackRecords {report.segmentPackRecords}"
    echo &"verifySegmentBytes {report.segmentStatus.totalSegmentBytes}"
    echo &"verifySegmentIndexBytes {report.segmentStatus.totalIndexBytes}"
    echo &"verifySegmentRecommendedRings {report.segmentStatus.recommendedRings}"
    echo &"verifySegmentMaxGeneration {report.segmentStatus.maxGeneration}"
    echo &"verifyLocalityRingRuns {report.locality.ringRuns}"
    echo &"verifyLocalityScore {report.locality.localityScore:.6f}"
    for check in report.checks:
      echo &"verifyCheck{{name=\"{check.name}\"}} {int(check.ok)}"
    return

  if jsonFormat:
    var checks = newJArray()
    for check in report.checks:
      checks.add %*{
        "name": check.name,
        "ok": check.ok,
        "message": check.message
      }
    echo pretty(%*{
      "ok": report.ok,
      "kind": "data",
      "dataDir": report.dataDir,
      "persistent": report.persistent,
      "diskBacked": report.diskBacked,
      "wal": {
        "path": report.walPath,
        "exists": report.walExists,
        "bytes": report.walBytes
      },
      "store": {
        "items": report.items,
        "rings": report.rings,
        "ringNames": report.ringNames,
        "vectors": report.vectors,
        "galaxy": report.galaxy
      },
      "segments": {
        "path": report.segmentDir,
        "exists": report.segmentDirExists,
        "files": report.segmentFiles,
        "rebuiltRecords": report.segmentPackRecords,
        "bytes": report.segmentStatus.totalSegmentBytes,
        "indexBytes": report.segmentStatus.totalIndexBytes,
        "recommendedRings": report.segmentStatus.recommendedRings,
        "maxGeneration": $report.segmentStatus.maxGeneration
      },
      "locality": {
        "persistent": report.locality.persistent,
        "walBytes": report.locality.walBytes,
        "totalParticleRecords": report.locality.totalParticleRecords,
        "liveParticleRecords": report.locality.liveParticleRecords,
        "deadParticleRecords": report.locality.deadParticleRecords,
        "ringCount": report.locality.ringCount,
        "ringRuns": report.locality.ringRuns,
        "fragmentedRings": report.locality.fragmentedRings,
        "avgRunRecords": report.locality.avgRunRecords,
        "maxRunRecords": report.locality.maxRunRecords,
        "localityScore": report.locality.localityScore
      },
      "checks": checks
    })
    return

  let statusName = if report.ok: "ok" else: "failed"
  let galaxyName = if report.galaxy.len > 0: report.galaxy else: "<none>"
  echo &"verify status: {statusName}"
  echo &"data: {report.dataDir}"
  echo &"wal: exists={report.walExists} bytes={report.walBytes} path={report.walPath}"
  echo &"store: items={report.items} rings={report.rings} ringNames={report.ringNames} vectors={report.vectors} galaxy={galaxyName}"
  echo &"segments: diskBacked={report.diskBacked} exists={report.segmentDirExists} files={report.segmentFiles} rebuiltRecords={report.segmentPackRecords} bytes={report.segmentStatus.totalSegmentBytes} indexBytes={report.segmentStatus.totalIndexBytes} recommended={report.segmentStatus.recommendedRings} maxGeneration={report.segmentStatus.maxGeneration}"
  echo &"locality: ringRuns={report.locality.ringRuns} fragmentedRings={report.locality.fragmentedRings} score={report.locality.localityScore:.6f}"
  for check in report.checks:
    let prefix = if check.ok: "ok  " else: "fail"
    echo &"{prefix} {check.name}: {check.message}"

proc printBackupVerifyStats(stats: BackupStats; encrypted: bool;
                            metricsFormat, jsonFormat: bool) =
  if metricsFormat:
    echo "verifyOk 1"
    echo "verifyBackup 1"
    echo &"verifyBackupEncrypted {int(encrypted)}"
    echo &"verifyBackupBytes {stats.bytes}"
    echo &"verifyBackupItems {stats.items}"
    echo &"verifyBackupTombstones {stats.tombstones}"
    echo &"verifyBackupForwarders {stats.forwarders}"
    echo &"verifyBackupRings {stats.ringMeta}"
    echo &"verifyBackupRingNames {stats.ringNames}"
    echo &"verifyBackupClusterTx {stats.clusterTx}"
    echo &"verifyBackupAppliedClusterTx {stats.appliedClusterTx}"
    echo &"verifyBackupWarpJobs {stats.warpJobs}"
    echo &"verifyBackupUniverseSyncEvents {stats.universeSyncEvents}"
    return

  if jsonFormat:
    echo pretty(%*{
      "ok": true,
      "kind": "backup",
      "encrypted": encrypted,
      "bytes": stats.bytes,
      "items": stats.items,
      "tombstones": stats.tombstones,
      "forwarders": stats.forwarders,
      "rings": stats.ringMeta,
      "ringNames": stats.ringNames,
      "clusterTx": stats.clusterTx,
      "appliedClusterTx": stats.appliedClusterTx,
      "warpJobs": stats.warpJobs,
      "universeSyncEvents": stats.universeSyncEvents,
      "source": stats.source,
      "destination": stats.destination
    })
    return

  let kind = if encrypted: "encrypted backup" else: "backup"
  echo &"verify status: ok"
  echo &"{kind}: bytes={stats.bytes} items={stats.items} tombstones={stats.tombstones} rings={stats.ringMeta} names={stats.ringNames} source={stats.source} destination={stats.destination}"

proc addConfigCheck(checks: var seq[KoutenOperationalCheck], name: string,
                    ok: bool, message: string) =
  checks.add KoutenOperationalCheck(name: name, ok: ok, message: message)

proc jsonIntOpt(node: JsonNode, key: string, default: int): int =
  if node.kind == JObject and node.hasKey(key):
    node[key].getInt().int
  else:
    default

proc verifyServerConfigFile(path: string): tuple[ok: bool,
    checks: seq[KoutenOperationalCheck]] =
  result.ok = true
  try:
    let cfg = parseFile(path)
    if cfg.kind != JObject:
      result.checks.addConfigCheck("server-config", false,
        "server config must contain a JSON object")
      result.ok = false
      return

    result.checks.addConfigCheck("server-config", true, "parsed JSON object")

    let id =
      if cfg.hasKey("id"): cfg["id"].getInt().int
      else: -1
    let peers = jsonPeersOpt(cfg, "")
    let peerCount =
      if peers.len == 0: 0
      else: peers.split(',').len
    let idOk = id >= 0 and peerCount > 0 and id < peerCount
    result.checks.addConfigCheck("node-id-peers", idOk,
      if idOk: &"id={id} peers={peerCount}"
      else: "server config requires id within peers")

    let dataDir = jsonStringOpt(cfg, "dataDir", jsonStringOpt(cfg, "data", ""))
    result.checks.addConfigCheck("persistence", dataDir.len > 0,
      if dataDir.len > 0: "dataDir configured: " & dataDir
      else: "dataDir is empty; server would run memory-only")

    let user = jsonStringOpt(cfg, "user", jsonStringOpt(cfg, "username", ""))
    let password = configSecretValue(cfg, "password", "passwordFile",
                                     "password-file")
    let token = configSecretValue(cfg, "authToken", "authTokenFile",
                                  "auth-token-file")
    let secretKey = configSecretValue(cfg, "secretKey", "secretKeyFile",
                                      "secret-key-file")
    let hasUserPassword = user.len > 0 and password.hasValue
    let hasToken = token.hasValue
    let secretSourceOk = (password.source.len == 0 or password.hasValue) and
                         (token.source.len == 0 or token.hasValue) and
                         (secretKey.source.len == 0 or secretKey.hasValue)
    let authOk = secretSourceOk and
                 ((user.len == 0 and not password.hasValue and
                   not secretKey.hasValue and not token.hasValue) or
                  hasUserPassword or hasToken)
    result.checks.addConfigCheck("auth", authOk,
      if hasToken: "auth token configured via " & token.source
      elif hasUserPassword: "username/password configured; password source=" & password.source
      elif user.len == 0 and not password.hasValue and not secretKey.hasValue:
        "auth disabled"
      elif user.len == 0: "password or secret-key requires user"
      else: "user requires password or passwordFile")
    result.checks.addConfigCheck("secret-key-gate",
      secretKey.source.len == 0 or hasUserPassword or hasToken,
      if secretKey.source.len == 0: "secret-key gate disabled"
      elif secretKey.hasValue: "secret-key gate configured via " & secretKey.source
      else: secretKey.source)

    var roleOk = true
    var roleCount = 0
    if cfg.hasKey("roles"):
      if cfg["roles"].kind != JArray:
        roleOk = false
      else:
        for item in cfg["roles"]:
          inc roleCount
          if item.kind == JString:
            let parts = item.getStr().split(':', maxsplit = 3)
            if parts.len < 3 or parts[0].len == 0 or parts[1].len == 0:
              roleOk = false
          elif item.kind == JObject:
            let roleUser = jsonStringOpt(item, "user",
              jsonStringOpt(item, "username", ""))
            let rolePassword = configSecretValue(item, "password",
              "passwordFile", "password-file")
            if roleUser.len == 0 or not rolePassword.hasValue or
                jsonStringOpt(item, "role", "").len == 0:
              roleOk = false
          else:
            roleOk = false
    result.checks.addConfigCheck("roles", roleOk,
      if roleOk: &"roles={roleCount}"
      else: "roles must be strings or objects with user/password/role")

    let prefixes = jsonStringListOpt(cfg, "allowRing") &
                   jsonStringListOpt(cfg, "allow-ring")
    result.checks.addConfigCheck("ring-prefix-authz", true,
      if prefixes.len > 0: &"prefixes={prefixes.len}"
      else: "no ring-prefix boundary configured")

    let placementEpoch = jsonIntOpt(cfg, "placementEpoch",
      jsonIntOpt(cfg, "placement-epoch", 1))
    let virtualArcs = jsonIntOpt(cfg, "virtualArcsPerNode",
      jsonIntOpt(cfg, "virtual-arcs-per-node", 64))
    let placementOk = placementEpoch > 0 and virtualArcs > 0
    result.checks.addConfigCheck("physical-placement", placementOk,
      if placementOk:
        &"epoch={placementEpoch} nodes={peerCount} virtualArcsPerNode={virtualArcs}"
      else:
        "placementEpoch and virtualArcsPerNode must be positive")

    let tlsCert = jsonStringOpt(cfg, "tlsCertFile", jsonStringOpt(cfg, "tls-cert", ""))
    let tlsKey = jsonStringOpt(cfg, "tlsKeyFile", jsonStringOpt(cfg, "tls-key", ""))
    let tlsCa = jsonStringOpt(cfg, "tlsCaFile", jsonStringOpt(cfg, "tls-ca", ""))
    let tlsInsecure = jsonBoolOpt(cfg, "tlsInsecureSkipVerify",
      jsonBoolOpt(cfg, "tls-insecure-skip-verify", false))
    let tlsPairOk = (tlsCert.len == 0 and tlsKey.len == 0) or
                    (tlsCert.len > 0 and tlsKey.len > 0)
    result.checks.addConfigCheck("tls-cert-key", tlsPairOk,
      if tlsPairOk and tlsCert.len > 0: "TLS listener certificate/key configured"
      elif tlsPairOk: "TLS listener disabled"
      else: "tlsCertFile and tlsKeyFile must be provided together")
    if tlsCert.len > 0:
      result.checks.addConfigCheck("tls-cert-file", fileExists(tlsCert), tlsCert)
    if tlsKey.len > 0:
      result.checks.addConfigCheck("tls-key-file", fileExists(tlsKey), tlsKey)
    if tlsCa.len > 0:
      result.checks.addConfigCheck("tls-ca-file", fileExists(tlsCa), tlsCa)
    result.checks.addConfigCheck("tls-verify", not tlsInsecure,
      if tlsInsecure: "tls-insecure-skip-verify is enabled"
      else: "certificate verification is not explicitly disabled")

    for check in result.checks:
      if not check.ok:
        result.ok = false
  except CatchableError as e:
    result.ok = false
    result.checks.addConfigCheck("server-config", false, e.msg)

proc printServerConfigReport(path: string, metricsFormat, jsonFormat: bool) =
  let report = verifyServerConfigFile(path)
  if metricsFormat:
    echo &"verifyOk {int(report.ok)}"
    for check in report.checks:
      echo &"verifyCheck{{name=\"{check.name}\"}} {int(check.ok)}"
    if not report.ok:
      quit(1)
    return
  if jsonFormat:
    var checks = newJArray()
    for check in report.checks:
      checks.add %*{"name": check.name, "ok": check.ok,
                    "message": check.message}
    echo pretty(%*{"ok": report.ok, "kind": "server-config",
                   "path": path, "checks": checks})
    if not report.ok:
      quit(1)
    return
  let statusName = if report.ok: "ok" else: "failed"
  echo &"verify status: {statusName}"
  echo &"server-config: {path}"
  for check in report.checks:
    let prefix = if check.ok: "ok  " else: "fail"
    echo &"{prefix} {check.name}: {check.message}"
  if not report.ok:
    quit(1)

proc runOperationalVerify(dataDir, backupDir, serverConfigPath,
                          passphrase: string;
                          verifySegments, metricsFormat, jsonFormat: bool;
                          maxWalBytes: int64 = -1;
                          maxSegmentFiles = -1;
                          maxItems = -1;
                          maxRings = -1;
                          maxSegmentBytes: int64 = -1;
                          maxDeadRecords = -1;
                          maxDeadRatio = -1.0;
                          maxSegmentGeneration: int64 = -1;
                          staleRatio = 0.25;
                          minStaleRecords = 256) =
  if serverConfigPath.len > 0:
    printServerConfigReport(serverConfigPath, metricsFormat, jsonFormat)
    return

  if backupDir.len > 0:
    let stats =
      if passphrase.len > 0: verifyEncryptedBackup(backupDir, passphrase)
      else: verifyBackup(backupDir)
    printBackupVerifyStats(stats, passphrase.len > 0, metricsFormat,
                           jsonFormat)
    return

  if dataDir.len == 0:
    raise newException(ValueError, "verify requires --data=DIR or --backup=DIR")
  let report = operationalVerify(dataDir, diskBacked = true,
                                 verifySegments = verifySegments,
                                 maxWalBytes = maxWalBytes,
                                 maxSegmentFiles = maxSegmentFiles,
                                 maxItems = maxItems,
                                 maxRings = maxRings,
                                 maxSegmentBytes = maxSegmentBytes,
                                 maxDeadRecords = maxDeadRecords,
                                 maxDeadRatio = maxDeadRatio,
                                 maxSegmentGeneration = maxSegmentGeneration,
                                 staleRatioThreshold = staleRatio,
                                 minStaleRecords = minStaleRecords)
  printOperationalReport(report, metricsFormat, jsonFormat)
  if not report.ok:
    quit(1)

proc runDoctor(dataDir, backupDir, serverConfigPath, passphrase: string;
               verifySegments, metricsFormat, jsonFormat: bool;
               maxWalBytes: int64 = -1;
               maxSegmentFiles = -1;
               maxItems = -1;
               maxRings = -1;
               maxSegmentBytes: int64 = -1;
               maxDeadRecords = -1;
               maxDeadRatio = -1.0;
               maxSegmentGeneration: int64 = -1;
               staleRatio = 0.25;
               minStaleRecords = 256) =
  if dataDir.len > 0 or serverConfigPath.len > 0:
    runOperationalVerify(dataDir, backupDir, serverConfigPath, passphrase,
                         verifySegments, metricsFormat, jsonFormat,
                         maxWalBytes, maxSegmentFiles, maxItems, maxRings,
                         maxSegmentBytes, maxDeadRecords, maxDeadRatio,
                         maxSegmentGeneration, staleRatio, minStaleRecords)
  elif backupDir.len > 0:
    runOperationalVerify(dataDir, backupDir, serverConfigPath, passphrase,
                         verifySegments, metricsFormat, jsonFormat,
                         maxWalBytes, maxSegmentFiles, maxItems, maxRings,
                         maxSegmentBytes, maxDeadRecords, maxDeadRatio,
                         maxSegmentGeneration, staleRatio, minStaleRecords)
  else:
    runDoctorSetup()

proc redisBulk(parts: varargs[string]): string =
  result.add "*" & $parts.len & "\r\n"
  for part in parts:
    result.add "$" & $part.len & "\r\n" & part & "\r\n"

proc readRedisLine(sock: Socket): string =
  result = sock.recvLine()
  if result.endsWith("\r"):
    result.setLen(result.len - 1)

proc readRedisReply(sock: Socket): string =
  let line = sock.readRedisLine()
  if line.len == 0:
    raise newException(IOError, "empty Redis reply")
  case line[0]
  of '+':
    result = line[1 .. ^1]
  of '-':
    raise newException(IOError, "Redis error: " & line[1 .. ^1])
  of ':':
    result = line[1 .. ^1]
  of '$':
    let n = parseInt(line[1 .. ^1])
    if n < 0:
      return ""
    result = sock.recv(n)
    discard sock.recv(2)
  else:
    raise newException(IOError, "unsupported Redis reply: " & line)

proc sendRedis(sock: Socket, parts: varargs[string]): string =
  sock.send(redisBulk(parts))
  sock.readRedisReply()

proc redisPipeline(sock: Socket, commands: seq[seq[string]]): seq[string] =
  var payload = ""
  for cmd in commands:
    payload.add redisBulk(cmd)
  sock.send(payload)
  for _ in 0 ..< commands.len:
    result.add sock.readRedisReply()

proc runDemo(peers, username, password, authToken, secretKey, galaxy: string,
             tls: bool, tlsCaFile, tlsServerName: string,
             tlsInsecureSkipVerify: bool) =
  var db = connect(peers, username = username, password = password,
                   authToken = authToken, secretKey = secretKey, galaxy = galaxy,
                   tls = tls, tlsCaFile = tlsCaFile,
                   tlsServerName = tlsServerName,
                   tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  db.configureRing("docs", 12.0)   # short demo period: one orbit per 12 seconds
  let id = db.put(%*{
    "title": "ephemeris-based placement",
    "author": {"name": "holmes", "org": "oss"},
    "tags": ["distributed", "orbital"],
    "body": "...long body..."
  }, ring = "docs")

  echo "put complete. Server-side projection:"
  echo "  query {title author{name}} -> ", db.query(id, "{ title author { name } }")
  echo ""
  echo "A record orbits with a 12s period and moves between server processes:"
  let t0 = epochTime()
  for step in 0 .. 6:
    let node = db.locate(id)
    let v = db.query(id, "{ title }")
    var counts = ""
    for (n, c) in db.stats():
      counts.add &" node{n}={c}"
    echo &"  t={epochTime() - t0:5.1f}s  locate=node{node}  get=OK({v})  held:{counts}"
    if step < 6: sleep(2000)
  echo ""
  echo "Future location, computed locally with no lookup:"
  for dt in [5.0, 10.0, 20.0]:
    echo &"  after {dt:4.0f}s -> node", db.locate(id, at = epochTime() + dt)
  db.close()
  echo "OK"

proc pickStableRing(db: KoutenDb, horizon: float): string =
  ## Choose a ring that does not cross an arc boundary during the measurement,
  ## using only the public API. This works because future location is computed.
  for i in 0 .. 20:
    result = "bench" & $i
    db.configureRing(result, max(3600.0, horizon * 10.0))
    let probe = db.put("probe", ring = result)
    let t0 = epochTime()
    let node = db.locate(probe, at = t0)
    var stable = true
    for step in 1 .. 10:
      if db.locate(probe, at = t0 + horizon * float(step) / 10.0) != node:
        stable = false
        break
    if stable:
      return
  result = "bench"
  db.configureRing(result, max(3600.0, horizon * 10.0))

proc runBench(peers, username, password, authToken, secretKey, galaxy: string,
              tls: bool, tlsCaFile, tlsServerName: string,
              tlsInsecureSkipVerify: bool, n: int) =
  var db = connect(peers, username = username, password = password,
                   authToken = authToken, secretKey = secretKey, galaxy = galaxy,
                   tls = tls, tlsCaFile = tlsCaFile,
                   tlsServerName = tlsServerName,
                   tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  let ring = db.pickStableRing(horizon = 60.0)
  var payload = newString(100)
  for i in 0 ..< 100: payload[i] = char(ord('a') + i mod 26)
  var ids = newSeq[KoutenId](n)

  var t = getMonoTime()
  for i in 0 ..< n:
    ids[i] = db.put(payload, ring = ring)
  let putUs = float((getMonoTime() - t).inNanoseconds) / 1e3 / float(n)

  t = getMonoTime()
  var got = 0
  for i in 0 ..< n:
    got += db.get(ids[i]).len
  let getUs = float((getMonoTime() - t).inNanoseconds) / 1e3 / float(n)
  doAssert got == n * 100

  # Projection benchmark: store JSON and read only one field.
  let jid = db.put(%*{"a": 1, "big": payload}, ring = ring)
  t = getMonoTime()
  for i in 0 ..< n:
    discard db.query(jid, "{ a }")
  let qryUs = float((getMonoTime() - t).inNanoseconds) / 1e3 / float(n)

  echo &"  put  (TCP, persistent connection) {putUs:8.1f} µs/op  ({1e6 / putUs:8.0f} ops/s)"
  echo &"  get  (TCP, locate+1RTT)           {getUs:8.1f} µs/op  ({1e6 / getUs:8.0f} ops/s)"
  echo &"  query(server-side projection)     {qryUs:8.1f} µs/op  ({1e6 / qryUs:8.0f} ops/s)"
  db.close()

proc runHealth(peers, username, password, authToken, secretKey, galaxy: string,
               tls: bool, tlsCaFile, tlsServerName: string,
               tlsInsecureSkipVerify: bool) =
  var db = connect(peers, username = username, password = password,
                   authToken = authToken, secretKey = secretKey, galaxy = galaxy,
                   tls = tls, tlsCaFile = tlsCaFile,
                   tlsServerName = tlsServerName,
                   tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  for line in db.health():
    echo line
  db.close()

proc runMetrics(peers, username, password, authToken, secretKey, galaxy: string,
                tls: bool, tlsCaFile, tlsServerName: string,
                tlsInsecureSkipVerify: bool) =
  var db = connect(peers, username = username, password = password,
                   authToken = authToken, secretKey = secretKey, galaxy = galaxy,
                   tls = tls, tlsCaFile = tlsCaFile,
                   tlsServerName = tlsServerName,
                   tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  for line in db.metrics():
    echo line
  db.close()

proc runShutdown(peers, username, password, authToken, secretKey, galaxy: string,
                 tls: bool, tlsCaFile, tlsServerName: string,
                 tlsInsecureSkipVerify: bool) =
  var db = connect(peers, username = username, password = password,
                   authToken = authToken, secretKey = secretKey, galaxy = galaxy,
                   tls = tls, tlsCaFile = tlsCaFile,
                   tlsServerName = tlsServerName,
                   tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  for line in db.shutdownCluster():
    echo line
  db.close()

proc runDrain(peers, username, password, authToken, secretKey, galaxy: string,
              tls: bool, tlsCaFile, tlsServerName: string,
              tlsInsecureSkipVerify: bool) =
  var db = connect(peers, username = username, password = password,
                   authToken = authToken, secretKey = secretKey, galaxy = galaxy,
                   tls = tls, tlsCaFile = tlsCaFile,
                   tlsServerName = tlsServerName,
                   tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  for line in db.drainCluster():
    echo line
  db.close()

proc runResume(peers, username, password, authToken, secretKey, galaxy: string,
               tls: bool, tlsCaFile, tlsServerName: string,
               tlsInsecureSkipVerify: bool) =
  var db = connect(peers, username = username, password = password,
                   authToken = authToken, secretKey = secretKey, galaxy = galaxy,
                   tls = tls, tlsCaFile = tlsCaFile,
                   tlsServerName = tlsServerName,
                   tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  for line in db.resumeCluster():
    echo line
  db.close()

proc runSnapshot(peers, username, password, authToken, secretKey, galaxy: string,
                 tls: bool, tlsCaFile, tlsServerName: string,
                 tlsInsecureSkipVerify: bool) =
  var db = connect(peers, username = username, password = password,
                   authToken = authToken, secretKey = secretKey, galaxy = galaxy,
                   tls = tls, tlsCaFile = tlsCaFile,
                   tlsServerName = tlsServerName,
                   tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  for line in db.snapshotCluster():
    echo line
  db.close()

proc runRings(peers, username, password, authToken, secretKey, galaxy: string,
              tls: bool, tlsCaFile, tlsServerName: string,
              tlsInsecureSkipVerify: bool) =
  var db = connect(peers, username = username, password = password,
                   authToken = authToken, secretKey = secretKey, galaxy = galaxy,
                   tls = tls, tlsCaFile = tlsCaFile,
                   tlsServerName = tlsServerName,
                   tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  for rs in db.ringSummaries():
    echo &"ring={rs.ringKey} count={rs.count} score={rs.score:.4f}"
  db.close()

proc runAtlas(dataDir, peers, username, password, authToken, secretKey,
              galaxy: string, tls: bool, tlsCaFile, tlsServerName: string,
              tlsInsecureSkipVerify: bool) =
  var db =
    if peers.len > 0:
      connect(peers, username = username, password = password,
              authToken = authToken, secretKey = secretKey, galaxy = galaxy,
              tls = tls, tlsCaFile = tlsCaFile,
              tlsServerName = tlsServerName,
              tlsInsecureSkipVerify = tlsInsecureSkipVerify)
    else:
      open(dataDir = dataDir)
  echo db.atlas().pretty
  db.close()

proc runPut(dataDir, peers, username, password, authToken, secretKey,
            galaxy, ring, nearRingBase, payload, inPath, codecName: string,
            tls: bool, tlsCaFile, tlsServerName: string,
            tlsInsecureSkipVerify: bool) =
  let actualDataDir = requireCliTarget(dataDir, peers)
  if ring.len == 0:
    raise newException(ValueError, "put requires --ring=RING")
  var db = openCliDb(actualDataDir, peers, username, password, authToken, secretKey,
                     galaxy, tls = tls, tlsCaFile = tlsCaFile,
                     tlsServerName = tlsServerName,
                     tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  try:
    let targetRing =
      if nearRingBase.len > 0:
        nearRing(nearRingBase, ring)
      else:
        ring
    let codec =
      if codecName.toLowerAscii() == "auto":
        db.ringPayloadProfile(targetRing).defaultCodec
      else:
        parsePayloadCodec(codecName)
    let id = db.put(encodedPayload(cliPayload(payload, inPath), codec), ring = targetRing)
    echo &"put OK id={id} rawId={cliIdString(id)} ring={targetRing} codec={codec.payloadCodecName}"
  finally:
    db.close()

proc hexPayload(data: string): string =
  const Hex = "0123456789abcdef"
  result = newStringOfCap(data.len * 2)
  for c in data:
    let value = ord(c)
    result.add Hex[value shr 4]
    result.add Hex[value and 0x0f]

proc findNifAdapterTool(): string =
  let configured = getEnv("KOUTENDB_NIF_TOOL")
  if configured.len > 0:
    let resolved = findExe(configured)
    if resolved.len > 0:
      return resolved
    if fileExists(configured):
      return configured
    return configured

  for candidate in ["koutendb-nif", "nif_file_tool"]:
    let resolved = findExe(candidate)
    if resolved.len > 0:
      return resolved

proc tryDecodeBifWithAdapter(data: string): tuple[ok: bool, text: string] =
  let tool = findNifAdapterTool()
  if tool.len == 0:
    return (false, "")

  let (inputFile, inputPath) = createTempFile("koutendb-bif-", ".bif", getTempDir())
  let (outputFile, outputPath) = createTempFile("koutendb-nif-", ".nif", getTempDir())
  inputFile.write(data)
  inputFile.close()
  outputFile.close()

  try:
    let process = startProcess(tool,
      args = @["decode", "--in=" & inputPath, "--out=" & outputPath],
      options = {poUsePath})
    let code = process.waitForExit()
    process.close()
    if code == 0 and fileExists(outputPath):
      return (true, readFile(outputPath))
    return (false, "")
  except OSError:
    return (false, "")
  finally:
    try:
      removeFile(inputPath)
    except OSError:
      discard
    try:
      removeFile(outputPath)
    except OSError:
      discard

proc recordPayloadDisplay(item: KoutenRecord, view: string): JsonNode =
  let mode = view.toLowerAscii()
  case mode
  of "raw":
    %*{"encoding": "raw", "payload": item.payload}
  of "base64":
    %*{"encoding": "base64", "payload": base64.encode(item.payload)}
  of "hex":
    %*{"encoding": "hex", "payload": hexPayload(item.payload)}
  of "auto":
    if item.codec == pcBif:
      let decoded = tryDecodeBifWithAdapter(item.payload)
      if decoded.ok:
        return %*{"encoding": "nif", "adapter": "nif", "payload": decoded.text}
      return %*{"encoding": "base64", "payload": base64.encode(item.payload)}
    if item.codec.supportsJsonProjection:
      try:
        return %*{"encoding": "json", "payload": parseJson(item.payload)}
      except JsonParsingError:
        discard
    %*{"encoding": "text", "payload": item.payload}
  else:
    raise newException(ValueError, "get view must be raw, auto, base64, or hex")

proc readPageNode(page: KoutenReadPage, view: string): JsonNode =
  var items = newJArray()
  for item in page.items:
    let display = recordPayloadDisplay(item, view)
    var node = %*{
      "id": $item.id,
      "rawId": item.id.cliIdString(),
      "codec": item.codec.payloadCodecName,
      "encoding": display["encoding"].getStr(),
      "payload": display["payload"]
    }
    if display.hasKey("adapter"):
      node["adapter"] = display["adapter"]
    items.add node
  %*{
    "ring": page.ring,
    "count": page.count,
    "pagination": page.pagination.paginationName,
    "page": page.page,
    "pageLimit": page.pageLimit,
    "sort": page.sortField,
    "sortDirection": page.sortDirection.sortDirectionName,
    "items": items,
    "nextCursor": page.nextCursor
  }

proc timePageNode(page: KoutenTimeReadPage, view, sortField: string,
                  sortDirection: KoutenReadSortDirection): JsonNode =
  var items = newJArray()
  for item in page.items:
    let display = recordPayloadDisplay(item, view)
    var node = %*{
      "id": $item.id,
      "rawId": item.id.cliIdString(),
      "codec": item.codec.payloadCodecName,
      "encoding": display["encoding"].getStr(),
      "payload": display["payload"]
    }
    if display.hasKey("adapter"):
      node["adapter"] = display["adapter"]
    items.add node
  var rings = newJArray()
  for ring in page.rings:
    rings.add %ring
  %*{
    "ring": page.ring,
    "fromMs": page.fromMs,
    "toMs": page.toMs,
    "bucketsVisited": page.bucketsVisited,
    "count": page.count,
    "sort": sortField,
    "sortDirection": sortDirection.sortDirectionName,
    "rings": rings,
    "items": items
  }

proc stellarPageNode(page: KoutenStellarPage, view, sortField: string,
                     sortDirection: KoutenReadSortDirection): JsonNode =
  var rings = newJArray()
  var flatItems = newJArray()
  for ringPage in page.rings:
    var items = newJArray()
    for item in ringPage.items:
      let display = recordPayloadDisplay(item, view)
      var node = %*{
        "id": $item.id,
        "rawId": item.id.cliIdString(),
        "codec": item.codec.payloadCodecName,
        "encoding": display["encoding"].getStr(),
        "payload": display["payload"]
      }
      if display.hasKey("adapter"):
        node["adapter"] = display["adapter"]
      items.add node
      var flatNode = node.copy()
      flatNode["ring"] = %ringPage.ring
      flatItems.add flatNode
    rings.add %*{
      "ring": ringPage.ring,
      "count": ringPage.count,
      "items": items
    }
  %*{
    "root": page.root,
    "maxDepth": page.maxDepth,
    "branchBudget": page.branchBudget,
    "ringsVisited": page.ringsVisited,
    "count": page.count,
    "sort": sortField,
    "sortDirection": sortDirection.sortDirectionName,
    "items": flatItems,
    "rings": rings
  }

proc readSortOptions(sortArg, rsortArg: string): tuple[field: string, direction: KoutenReadSortDirection] =
  if sortArg.len > 0 and rsortArg.len > 0:
    raise newException(ValueError, "--sort and --rsort cannot be used together")
  if sortArg.len > 0:
    return (sortArg, rsAsc)
  if rsortArg.len > 0:
    return (rsortArg, rsDesc)
  ("time", rsDesc)

proc readPaginationMode(value: string): KoutenPaginationMode =
  case value.toLowerAscii()
  of "off", "false", "0", "no": rpOff
  of "on", "true", "1", "yes": rpOn
  else:
    raise newException(ValueError, "pagination must be on or off")

proc parseSubrings(value: string): seq[string] =
  if value.len == 0:
    return @[]
  for part in value.split(","):
    let clean = part.strip(chars = {' ', '\t', '\r', '\n', '/'})
    if clean.len > 0:
      result.add clean

proc parseNamedIntMap(value, optionName: string): Table[string, int] =
  result = initTable[string, int]()
  if value.len == 0:
    return
  for part in value.split(","):
    let cleanPart = part.strip()
    if cleanPart.len == 0:
      continue
    let sep = if cleanPart.find(':') >= 0: cleanPart.find(':') else: cleanPart.find('=')
    if sep <= 0 or sep >= cleanPart.high:
      raise newException(ValueError, optionName & " entries must be name:N")
    let name = cleanPart[0 ..< sep].strip(chars = {' ', '\t', '\r', '\n', '/'})
    let rawValue = cleanPart[sep + 1 .. ^1].strip()
    if name.len == 0:
      raise newException(ValueError, optionName & " subring name must not be empty")
    let parsed = parseInt(rawValue)
    if parsed <= 0:
      raise newException(ValueError, optionName & " values must be positive")
    result[name] = parsed

proc parseNamedSortMap(value, optionName: string): Table[string, string] =
  result = initTable[string, string]()
  if value.len == 0:
    return
  for part in value.split(","):
    let cleanPart = part.strip()
    if cleanPart.len == 0:
      continue
    let sep = if cleanPart.find(':') >= 0: cleanPart.find(':') else: cleanPart.find('=')
    if sep <= 0 or sep >= cleanPart.high:
      raise newException(ValueError, optionName & " entries must be name:id|time")
    let name = cleanPart[0 ..< sep].strip(chars = {' ', '\t', '\r', '\n', '/'})
    let field = cleanPart[sep + 1 .. ^1].strip()
    if name.len == 0:
      raise newException(ValueError, optionName & " subring name must not be empty")
    if field notin ["id", "time", "write"]:
      raise newException(ValueError, optionName & " fields must be id, time, or write")
    result[name] = field

proc runGet(dataDir, peers, username, password, authToken, secretKey,
            galaxy, idArg, filterArg, ring, subringArg, view, selection,
            cursor: string, limit, page, pageLimit, depth, branchBudget: int,
            subringLimitArg, subringSortArg, subringRsortArg: string,
            paginationArg, sortArg, rsortArg: string,
            tls: bool, tlsCaFile, tlsServerName: string,
            tlsInsecureSkipVerify: bool) =
  let actualDataDir = requireCliTarget(dataDir, peers)
  let filterNode = parseFilter(filterArg)
  let resolvedId = resolveIdArg(idArg, filterArg)
  let sortOptions = readSortOptions(sortArg, rsortArg)
  if ring.len == 0:
    raise newException(ValueError, "get requires --ring=RING")
  var db = openCliDb(actualDataDir, peers, username, password, authToken, secretKey,
                     galaxy, tls = tls, tlsCaFile = tlsCaFile,
                     tlsServerName = tlsServerName,
                     tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  try:
    db.configureRing(ring, 60.0)
    let subrings = parseSubrings(subringArg)
    let subringLimits = parseNamedIntMap(subringLimitArg, "--subring-limit")
    var subringSortFields = parseNamedSortMap(subringSortArg, "--subring-sort")
    let subringRsortFields = parseNamedSortMap(subringRsortArg, "--subring-rsort")
    var subringSortDirections = initTable[string, KoutenReadSortDirection]()
    for name in subringSortFields.keys:
      subringSortDirections[name] = rsAsc
    for name, field in subringRsortFields:
      if name in subringSortFields:
        raise newException(ValueError, "--subring-sort and --subring-rsort cannot target the same subring")
      subringSortFields[name] = field
      subringSortDirections[name] = rsDesc
    let options = KoutenReadOptions(
      filter: filterWithId(filterNode, resolvedId),
      selection: selection,
      limit: limit,
      cursor: cursor,
      pagination: readPaginationMode(paginationArg),
      page: page,
      pageLimit: pageLimit,
      sortField: sortOptions.field,
      sortDirection: sortOptions.direction)
    if subrings.len > 0 or resolvedId.len == 0:
      let stellar = db.readStellar(ring, KoutenStellarOptions(
        filter: options.filter,
        selection: selection,
        limitPerRing: limit,
        subringLimits: subringLimits,
        subringSortFields: subringSortFields,
        subringSortDirections: subringSortDirections,
        maxDepth: depth,
        branchBudget: branchBudget,
        subrings: subrings,
        includeRoot: true,
        sortField: sortOptions.field,
        sortDirection: sortOptions.direction))
      echo stellar.stellarPageNode(view, sortOptions.field, sortOptions.direction).pretty
    else:
      echo db.readRing(ring, options).readPageNode(view).pretty
  finally:
    db.close()

proc runQuery(dataDir, peers, username, password, authToken, secretKey,
              galaxy, idArg, whereArg, ring, selection: string,
              tls: bool, tlsCaFile, tlsServerName: string,
              tlsInsecureSkipVerify: bool) =
  let actualDataDir = requireCliTarget(dataDir, peers)
  let resolvedId = resolveIdArg(idArg, whereArg)
  if selection.len == 0:
    raise newException(ValueError, "query requires --selection=SEL")
  if peers.len > 0 and ring.len == 0:
    raise newException(ValueError, "cluster query requires --ring=RING")
  var db = openCliDb(actualDataDir, peers, username, password, authToken, secretKey,
                     galaxy, tls = tls, tlsCaFile = tlsCaFile,
                     tlsServerName = tlsServerName,
                     tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  try:
    if ring.len > 0:
      db.configureRing(ring, 60.0)
    echo db.query(cliId(resolvedId), selection).pretty
  finally:
    db.close()

proc runListRing(dataDir, peers, username, password, authToken, secretKey,
                 galaxy, ring, cursor: string, limit: int,
                 tls: bool, tlsCaFile, tlsServerName: string,
                 tlsInsecureSkipVerify: bool) =
  let actualDataDir = requireCliTarget(dataDir, peers)
  if ring.len == 0:
    raise newException(ValueError, "list-ring requires --ring=RING")
  var db = openCliDb(actualDataDir, peers, username, password, authToken, secretKey,
                     galaxy, tls = tls, tlsCaFile = tlsCaFile,
                     tlsServerName = tlsServerName,
                     tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  try:
    let page = db.listByRing(ring, limit = limit, cursor = cursor)
    var items = newJArray()
    for item in page.items:
      items.add %*{
        "id": $item.id,
        "rawId": item.id.cliIdString(),
        "payload": item.payload,
        "codec": item.codec.payloadCodecName
      }
    echo pretty(%*{"items": items, "nextCursor": page.nextCursor})
  finally:
    db.close()

proc runRingProfile(dataDir, peers, username, password, authToken, secretKey,
                    galaxy, ring, codecName, charset, formatVersion: string,
                    tls: bool, tlsCaFile, tlsServerName: string,
                    tlsInsecureSkipVerify: bool) =
  let actualDataDir = requireCliTarget(dataDir, peers)
  if ring.len == 0:
    raise newException(ValueError, "ring-profile requires --ring=RING")
  if peers.len > 0:
    raise newException(ValueError,
      "ring-profile is currently configured through the embedded store; remote profile administration is not available yet")
  var db = openCliDb(actualDataDir, peers, username, password, authToken, secretKey,
                     galaxy, tls = tls, tlsCaFile = tlsCaFile,
                     tlsServerName = tlsServerName,
                     tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  try:
    if codecName.toLowerAscii() != "auto" or charset.len > 0 or formatVersion.len > 0:
      let old = db.ringPayloadProfile(ring)
      let profile = RingPayloadProfile(
        defaultCodec: if codecName.toLowerAscii() == "auto": old.defaultCodec else: parsePayloadCodec(codecName),
        charset: if charset.len == 0: old.charset else: charset,
        formatVersion: if formatVersion.len == 0: old.formatVersion else: formatVersion)
      db.configureRingPayloadProfile(ring, profile)
    let profile = db.ringPayloadProfile(ring)
    echo (%*{
      "ring": ring,
      "defaultCodec": profile.defaultCodec.payloadCodecName,
      "charset": profile.charset,
      "formatVersion": profile.formatVersion
    }).pretty
  finally:
    db.close()

proc runTimeOrbit(dataDir, peers, username, password, authToken, secretKey,
                  galaxy, ring: string, bits: int, bitsSet: bool,
                  bucketMs: int64, bucketMsSet: bool,
                  phase: uint64, phaseSet: bool, salt: string, saltSet: bool,
                  tls: bool, tlsCaFile, tlsServerName: string,
                  tlsInsecureSkipVerify: bool) =
  let actualDataDir = requireCliTarget(dataDir, peers)
  if ring.len == 0:
    raise newException(ValueError, "time-orbit requires --ring=RING")
  if peers.len > 0:
    raise newException(ValueError,
      "time-orbit is currently configured through the embedded store; remote profile administration is not available yet")
  var db = openCliDb(actualDataDir, peers, username, password, authToken, secretKey,
                     galaxy, tls = tls, tlsCaFile = tlsCaFile,
                     tlsServerName = tlsServerName,
                     tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  try:
    if bitsSet or bucketMsSet or phaseSet or saltSet:
      let old = db.timeOrbitProfile(ring)
      db.configureTimeOrbitProfile(ring, TimeOrbitProfile(
        bits: if bitsSet: bits else: old.bits,
        bucketMs: if bucketMsSet: bucketMs else: old.bucketMs,
        phase: if phaseSet: phase else: old.phase,
        salt: if saltSet: salt else: old.salt))
    let profile = db.timeOrbitProfile(ring)
    echo (%*{
      "ring": ring,
      "bits": profile.bits,
      "bucketMs": profile.bucketMs,
      "phase": $profile.phase,
      "salt": profile.salt
    }).pretty
  finally:
    db.close()

proc runTimePut(dataDir, peers, username, password, authToken, secretKey,
                galaxy, ring, payload, inPath: string, timestampMs: int64,
                tls: bool, tlsCaFile, tlsServerName: string,
                tlsInsecureSkipVerify: bool) =
  let actualDataDir = requireCliTarget(dataDir, peers)
  if peers.len > 0:
    raise newException(ValueError,
      "time-put is currently embedded-only because time-orbit profiles are local metadata")
  if ring.len == 0:
    raise newException(ValueError, "time-put requires --ring=RING")
  if timestampMs < 0:
    raise newException(ValueError, "time-put requires --time-ms=N")
  var db = openCliDb(actualDataDir, peers, username, password, authToken, secretKey,
                     galaxy, tls = tls, tlsCaFile = tlsCaFile,
                     tlsServerName = tlsServerName,
                     tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  try:
    let id = db.putTime(cliPayload(payload, inPath), ring, timestampMs)
    let profile = db.timeOrbitProfile(ring)
    let targetRing = timeOrbitRing(ring, profile, timestampMs)
    echo &"time-put OK id={id} rawId={cliIdString(id)} ring={targetRing} baseRing={ring} timeMs={timestampMs}"
  finally:
    db.close()

proc runTimeGet(dataDir, peers, username, password, authToken, secretKey,
                galaxy, ring, filterArg, view, selection: string,
                fromMs, toMs: int64, limit: int, sortArg, rsortArg: string,
                tls: bool, tlsCaFile, tlsServerName: string,
                tlsInsecureSkipVerify: bool) =
  let actualDataDir = requireCliTarget(dataDir, peers)
  if peers.len > 0:
    raise newException(ValueError,
      "time-get is currently embedded-only because time-orbit profiles are local metadata")
  if ring.len == 0:
    raise newException(ValueError, "time-get requires --ring=RING")
  if fromMs < 0 or toMs < 0:
    raise newException(ValueError, "time-get requires --from-ms=N --to-ms=N")
  let sortOptions = readSortOptions(sortArg, rsortArg)
  var db = openCliDb(actualDataDir, peers, username, password, authToken, secretKey,
                     galaxy, tls = tls, tlsCaFile = tlsCaFile,
                     tlsServerName = tlsServerName,
                     tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  try:
    let page = db.readTime(ring, fromMs, toMs, KoutenReadOptions(
      filter: parseFilter(filterArg),
      selection: selection,
      limit: limit,
      sortField: sortOptions.field,
      sortDirection: sortOptions.direction))
    echo page.timePageNode(view, sortOptions.field, sortOptions.direction).pretty
  finally:
    db.close()

proc runStellar(dataDir, peers, username, password, authToken, secretKey,
                galaxy: string, args: seq[string], stellarName, ringName: string,
                tls: bool, tlsCaFile, tlsServerName: string,
                tlsInsecureSkipVerify: bool) =
  let actualDataDir = requireCliTarget(dataDir, peers)
  if args.len < 2:
    raise newException(ValueError, "stellar requires attach, detach, or list")
  let action = args[1]
  var db = openCliDb(actualDataDir, peers, username, password, authToken, secretKey,
                     galaxy, tls = tls, tlsCaFile = tlsCaFile,
                     tlsServerName = tlsServerName,
                     tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  try:
    case action
    of "attach":
      if stellarName.len == 0 or ringName.len == 0:
        raise newException(ValueError, "stellar attach requires --stellar=RING --ring=RING")
      db.attachStellar(stellarName, ringName)
      echo (%*{
        "status": "attached",
        "stellar": stellarName,
        "ring": ringName,
        "members": db.stellarMembers(stellarName)
      }).pretty
    of "detach":
      if stellarName.len == 0 or ringName.len == 0:
        raise newException(ValueError, "stellar detach requires --stellar=RING --ring=RING")
      db.detachStellar(stellarName, ringName)
      echo (%*{
        "status": "detached",
        "stellar": stellarName,
        "ring": ringName,
        "members": db.stellarMembers(stellarName)
      }).pretty
    of "list":
      if stellarName.len == 0:
        raise newException(ValueError, "stellar list requires --stellar=RING")
      echo (%*{
        "stellar": stellarName,
        "members": db.stellarMembers(stellarName)
      }).pretty
    else:
      raise newException(ValueError, "unknown stellar action: " & action)
  finally:
    db.close()

proc runCountRing(dataDir, peers, username, password, authToken, secretKey,
                  galaxy, ring: string, tls: bool, tlsCaFile,
                  tlsServerName: string, tlsInsecureSkipVerify: bool) =
  let actualDataDir = requireCliTarget(dataDir, peers)
  if ring.len == 0:
    raise newException(ValueError, "count-ring requires --ring=RING")
  var db = openCliDb(actualDataDir, peers, username, password, authToken, secretKey,
                     galaxy, tls = tls, tlsCaFile = tlsCaFile,
                     tlsServerName = tlsServerName,
                     tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  try:
    echo &"count-ring OK ring={ring} count={db.countByRing(ring)}"
  finally:
    db.close()

proc splitCommandRest(line: string): tuple[cmd, rest: string] =
  let s = line.strip()
  if s.len == 0:
    return ("", "")
  let sp = s.find(' ')
  if sp < 0:
    (s, "")
  else:
    (s[0 ..< sp], s[sp + 1 .. ^1].strip())

proc splitFirstRest(s: string): tuple[first, rest: string] =
  let t = s.strip()
  if t.len == 0:
    return ("", "")
  let sp = t.find(' ')
  if sp < 0:
    (t, "")
  else:
    (t[0 ..< sp], t[sp + 1 .. ^1].strip())

proc printShellHelp() =
  echo "Commands:"
  echo "  put RING PAYLOAD"
  echo "  get ID [RING]"
  echo "  query ID SELECTION"
  echo "  query ID RING SELECTION       # cluster mode"
  echo "  list RING [LIMIT]"
  echo "  count RING"
  echo "  atlas"
  echo "  help"
  echo "  exit"

proc runShell(dataDir, peers, username, password, authToken, secretKey,
              galaxy: string, tls: bool, tlsCaFile, tlsServerName: string,
              tlsInsecureSkipVerify: bool) =
  let actualDataDir = requireCliTarget(dataDir, peers)
  var db = openCliDb(actualDataDir, peers, username, password, authToken, secretKey,
                     galaxy, tls = tls, tlsCaFile = tlsCaFile,
                     tlsServerName = tlsServerName,
                     tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  try:
    echo "KoutenDB shell. Type help or exit."
    while true:
      stdout.write("kouten> ")
      stdout.flushFile()
      if stdin.endOfFile():
        break
      let line = stdin.readLine()
      let cr = splitCommandRest(line)
      let op = cr.cmd.toLowerAscii()
      if op.len == 0:
        continue
      try:
        case op
        of "exit", "quit":
          break
        of "help", "?":
          printShellHelp()
        of "put":
          let rp = splitFirstRest(cr.rest)
          if rp.first.len == 0 or rp.rest.len == 0:
            raise newException(ValueError, "usage: put RING PAYLOAD")
          let id = db.put(rp.rest, ring = rp.first)
          echo &"put OK id={id} rawId={cliIdString(id)} ring={rp.first}"
        of "get":
          let ir = splitFirstRest(cr.rest)
          if ir.first.len == 0:
            raise newException(ValueError, "usage: get ID [RING]")
          if peers.len > 0 and ir.rest.len == 0:
            raise newException(ValueError, "cluster get requires ring: get ID RING")
          if ir.rest.len > 0:
            db.configureRing(ir.rest, 60.0)
          echo db.get(cliId(ir.first))
        of "query":
          let ir = splitFirstRest(cr.rest)
          if ir.first.len == 0 or ir.rest.len == 0:
            raise newException(ValueError, "usage: query ID SELECTION")
          if peers.len > 0:
            let rs = splitFirstRest(ir.rest)
            if rs.first.len == 0 or rs.rest.len == 0:
              raise newException(ValueError, "cluster query requires: query ID RING SELECTION")
            db.configureRing(rs.first, 60.0)
            echo db.query(cliId(ir.first), rs.rest).pretty
          else:
            echo db.query(cliId(ir.first), ir.rest).pretty
        of "list", "list-ring":
          let rl = splitFirstRest(cr.rest)
          if rl.first.len == 0:
            raise newException(ValueError, "usage: list RING [LIMIT]")
          let lim = if rl.rest.len > 0: parseInt(rl.rest) else: 10
          let page = db.listByRing(rl.first, limit = lim)
          for item in page.items:
            echo &"{item.id.cliIdString()} {item.payload}"
          if page.nextCursor.len > 0:
            echo &"nextCursor={page.nextCursor}"
        of "count", "count-ring":
          if cr.rest.len == 0:
            raise newException(ValueError, "usage: count RING")
          echo &"count-ring OK ring={cr.rest} count={db.countByRing(cr.rest)}"
        of "atlas":
          echo db.atlas().pretty
        else:
          echo "ERR unknown command: " & cr.cmd
      except CatchableError:
        echo "ERR " & getCurrentExceptionMsg()
  finally:
    db.close()

proc runDescribeGalaxy(dataDir, description: string) =
  if dataDir.len == 0:
    quit "describe-galaxy requires --data=DIR", 1
  var db = open(dataDir = dataDir)
  db.setGalaxyDescription(description)
  db.close()
  echo "describe-galaxy OK"

proc runDescribeRing(dataDir, ring, description: string) =
  if dataDir.len == 0:
    quit "describe-ring requires --data=DIR", 1
  if ring.len == 0:
    quit "describe-ring requires --ring=RING", 1
  var db = open(dataDir = dataDir)
  db.setRingDescription(ring, description)
  db.close()
  echo "describe-ring OK ring=" & ring

proc runRetrieveBench(peers, username, password, authToken, secretKey, galaxy: string,
                      tls: bool, tlsCaFile, tlsServerName: string,
                      tlsInsecureSkipVerify: bool, n: int) =
  var db = connect(peers, username = username, password = password,
                   authToken = authToken, secretKey = secretKey, galaxy = galaxy,
                   tls = tls, tlsCaFile = tlsCaFile,
                   tlsServerName = tlsServerName,
                   tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  for i in 0 ..< n:
    let ring = if i mod 2 == 0: "ai" else: "logs"
    let v =
      if i mod 2 == 0:
        @[1.0'f32, float32(i mod 17) / 1000.0'f32]
      else:
        @[float32(i mod 17) / 1000.0'f32, 1.0'f32]
    discard db.put(%*{"i": i, "ring": ring, "body": "abcdefghijklmnopqrstuvwxyz"}, ring = ring, vec = v)

  let q = @[1.0'f32, 0.0'f32]
  var t = getMonoTime()
  let globalStats = db.retrieveStats(q, budget = 8)
  let globalHits = db.retrieve(q, budget = 8)
  let globalUs = float((getMonoTime() - t).inNanoseconds) / 1e3

  t = getMonoTime()
  let scopedStats = db.retrieveStats(q, ring = "ai", budget = 8)
  let scopedHits = db.retrieve(q, ring = "ai", budget = 8)
  let scopedUs = float((getMonoTime() - t).inNanoseconds) / 1e3

  echo &"  global retrieve       {globalUs:8.1f} µs  hits={globalHits.len} scanned={globalStats.scanned}/{globalStats.totalVectors} rings={globalStats.ringsTouched} tokens~={globalStats.estimatedTokens}"
  echo &"  ring-scoped retrieve  {scopedUs:8.1f} µs  hits={scopedHits.len} scanned={scopedStats.scanned}/{scopedStats.totalVectors} rings={scopedStats.ringsTouched} tokens~={scopedStats.estimatedTokens} reduction={scopedStats.candidateReduction * 100.0:5.1f}%"
  db.close()

proc runRedisBench(n, payloadBytes: int, redisEndpoint, peers, username,
                   password, authToken, secretKey, galaxy: string,
                   tls: bool, tlsCaFile, tlsServerName: string,
                   tlsInsecureSkipVerify: bool) =
  ## Simple KV comparison between localhost Redis GET and KoutenDB embedded get.
  ## The workload is favorable to Redis; the goal is to observe the latency band.
  let ep = parseHostPort(redisEndpoint)
  var payload = newString(max(1, payloadBytes))
  for i in 0 ..< payload.len:
    payload[i] = char(ord('a') + i mod 26)

  var db = open()
  var ids = newSeq[KoutenId](n)
  var t = getMonoTime()
  for i in 0 ..< n:
    ids[i] = db.put(payload, ring = "redis-bench")
  let koutenSetUs = float((getMonoTime() - t).inNanoseconds) / 1e3 / float(n)

  t = getMonoTime()
  var koutenGot = 0
  for i in 0 ..< n:
    koutenGot += db.get(ids[i]).len
  let koutenGetUs = float((getMonoTime() - t).inNanoseconds) / 1e3 / float(n)
  doAssert koutenGot == n * payload.len
  db.close()

  var koutenTcpPutUs = 0.0
  var koutenTcpGetUs = 0.0
  var koutenTcpBatchGetUs = 0.0
  const PipeBatch = 256
  if peers.len > 0:
    var tcp = connect(peers, username = username, password = password,
                      authToken = authToken, secretKey = secretKey,
                      galaxy = galaxy, tls = tls, tlsCaFile = tlsCaFile,
                      tlsServerName = tlsServerName,
                      tlsInsecureSkipVerify = tlsInsecureSkipVerify)
    var tcpIds = newSeq[KoutenId](n)
    t = getMonoTime()
    for i in 0 ..< n:
      tcpIds[i] = tcp.put(payload, ring = "redis-bench")
    koutenTcpPutUs = float((getMonoTime() - t).inNanoseconds) / 1e3 / float(n)

    t = getMonoTime()
    var tcpGot = 0
    for i in 0 ..< n:
      tcpGot += tcp.get(tcpIds[i]).len
    koutenTcpGetUs = float((getMonoTime() - t).inNanoseconds) / 1e3 / float(n)
    doAssert tcpGot == n * payload.len

    t = getMonoTime()
    var tcpBatchGot = 0
    var start = 0
    while start < n:
      let stop = min(n, start + PipeBatch)
      for value in tcp.batchGet(tcpIds[start ..< stop]):
        tcpBatchGot += value.len
      start = stop
    koutenTcpBatchGetUs = float((getMonoTime() - t).inNanoseconds) / 1e3 / float(n)
    doAssert tcpBatchGot == n * payload.len
    tcp.close()

  var sock = newSocket()
  sock.connect(ep.host, Port(ep.port))
  defer: sock.close()
  discard sock.sendRedis("PING")
  let prefix = "koutendb:bench:" & $epochTime() & ":"

  t = getMonoTime()
  for i in 0 ..< n:
    discard sock.sendRedis("SET", prefix & $i, payload)
  let redisSetUs = float((getMonoTime() - t).inNanoseconds) / 1e3 / float(n)

  t = getMonoTime()
  var redisGot = 0
  for i in 0 ..< n:
    redisGot += sock.sendRedis("GET", prefix & $i).len
  let redisGetUs = float((getMonoTime() - t).inNanoseconds) / 1e3 / float(n)
  doAssert redisGot == n * payload.len

  t = getMonoTime()
  var start = 0
  while start < n:
    let stop = min(n, start + PipeBatch)
    var cmds: seq[seq[string]] = @[]
    for i in start ..< stop:
      cmds.add @["SET", prefix & "pipe:" & $i, payload]
    discard sock.redisPipeline(cmds)
    start = stop
  let redisPipeSetUs = float((getMonoTime() - t).inNanoseconds) / 1e3 / float(n)

  t = getMonoTime()
  var redisPipeGot = 0
  start = 0
  while start < n:
    let stop = min(n, start + PipeBatch)
    var cmds: seq[seq[string]] = @[]
    for i in start ..< stop:
      cmds.add @["GET", prefix & "pipe:" & $i]
    for value in sock.redisPipeline(cmds):
      redisPipeGot += value.len
    start = stop
  let redisPipeGetUs = float((getMonoTime() - t).inNanoseconds) / 1e3 / float(n)
  doAssert redisPipeGot == n * payload.len

  for i in 0 ..< n:
    discard sock.sendRedis("DEL", prefix & $i)
    discard sock.sendRedis("DEL", prefix & "pipe:" & $i)

  echo &"  payload={payload.len}B n={n} redis={redisEndpoint}"
  echo &"  KoutenDB embedded put {koutenSetUs:8.2f} µs/op ({1e6 / koutenSetUs:9.0f} ops/s)"
  echo &"  KoutenDB embedded get {koutenGetUs:8.2f} µs/op ({1e6 / koutenGetUs:9.0f} ops/s)"
  if peers.len > 0:
    echo &"  KoutenDB TCP put      {koutenTcpPutUs:8.2f} µs/op ({1e6 / koutenTcpPutUs:9.0f} ops/s)"
    echo &"  KoutenDB TCP get      {koutenTcpGetUs:8.2f} µs/op ({1e6 / koutenTcpGetUs:9.0f} ops/s)"
    echo &"  KoutenDB TCP batch get{koutenTcpBatchGetUs:8.2f} µs/op ({1e6 / koutenTcpBatchGetUs:9.0f} ops/s)"
  echo &"  Redis TCP SET        {redisSetUs:8.2f} µs/op ({1e6 / redisSetUs:9.0f} ops/s)"
  echo &"  Redis TCP GET        {redisGetUs:8.2f} µs/op ({1e6 / redisGetUs:9.0f} ops/s)"
  echo &"  Redis pipeline SET   {redisPipeSetUs:8.2f} µs/op ({1e6 / redisPipeSetUs:9.0f} ops/s)"
  echo &"  Redis pipeline GET   {redisPipeGetUs:8.2f} µs/op ({1e6 / redisPipeGetUs:9.0f} ops/s)"
  if peers.len > 0:
    echo &"  get_ratio redis_tcp/kouten_tcp={redisGetUs / koutenTcpGetUs:6.2f}x redis_pipe/kouten_tcp={redisPipeGetUs / koutenTcpGetUs:6.2f}x"
    echo &"  batch_ratio redis_pipe/kouten_batch={redisPipeGetUs / koutenTcpBatchGetUs:6.2f}x"
  echo &"  get_ratio redis_tcp/kouten_embedded={redisGetUs / koutenGetUs:6.2f}x redis_pipe/kouten_embedded={redisPipeGetUs / koutenGetUs:6.2f}x"

proc runRagBench(n, queries, globalBudget, routedBudget: int) =
  ## Synthetic RAG benchmark without an LLM. Each query has one gold document;
  ## this checks whether routing keeps the gold document while reducing tokens.
  var db = open()
  let docsPerTopic = max(1, n div RagTopics)
  var goldIds: seq[string] = @[]

  for topic in 0 ..< RagTopics:
    let ring = "topic-" & $topic
    for i in 0 ..< docsPerTopic:
      let gold = i < queries
      let gid = "topic-" & $topic & "-gold-" & $i
      let body =
        if gold:
          gid & " " & repeat("relevant scientific medical water treatment evidence ", 20)
        else:
          "distractor-" & $topic & "-" & $i & " " & repeat("background unrelated archive material ", 20)
      discard db.put(body, ring = ring,
                     vec = (if gold: topicVec(topic, i) else: distractorVec(topic)))
      if gold:
        goldIds.add gid

  var globalHit = 0
  var routedHit = 0
  var wrongHit = 0
  var globalTokens = 0
  var routedTokens = 0
  var wrongTokens = 0
  var globalScanned = 0
  var routedScanned = 0
  var wrongScanned = 0

  let qn = min(queries, goldIds.len)
  for qi in 0 ..< qn:
    let topic = qi mod RagTopics
    let gold = "topic-" & $topic & "-gold-" & $(qi div RagTopics)
    let q = topicVec(topic, qi div RagTopics)

    let gh = db.retrieve(q, budget = globalBudget)
    let gs = db.retrieveStats(q, budget = globalBudget)
    var gp: seq[string] = @[]
    var gFound = false
    for h in gh:
      gp.add h.payload
      if gold in h.payload:
        gFound = true
    if gFound:
      inc globalHit
    globalTokens += tokenEstimate(gp)
    globalScanned += gs.scanned

    let rh = db.retrieve(q, ring = "topic-" & $topic, budget = routedBudget)
    let rs = db.retrieveStats(q, ring = "topic-" & $topic, budget = routedBudget)
    var rp: seq[string] = @[]
    var rFound = false
    for h in rh:
      rp.add h.payload
      if gold in h.payload:
        rFound = true
    if rFound:
      inc routedHit
    routedTokens += tokenEstimate(rp)
    routedScanned += rs.scanned

    let wrongRing = "topic-" & $((topic + 1) mod RagTopics)
    let wh = db.retrieve(q, ring = wrongRing, budget = routedBudget)
    let ws = db.retrieveStats(q, ring = wrongRing, budget = routedBudget)
    var wp: seq[string] = @[]
    var wFound = false
    for h in wh:
      wp.add h.payload
      if gold in h.payload:
        wFound = true
    if wFound:
      inc wrongHit
    wrongTokens += tokenEstimate(wp)
    wrongScanned += ws.scanned

  let gRecall = if qn == 0: 0.0 else: float(globalHit) / float(qn)
  let rRecall = if qn == 0: 0.0 else: float(routedHit) / float(qn)
  let wRecall = if qn == 0: 0.0 else: float(wrongHit) / float(qn)
  let tokenReduction =
    if globalTokens == 0: 0.0
    else: 1.0 - float(routedTokens) / float(globalTokens)
  let scanReduction =
    if globalScanned == 0: 0.0
    else: 1.0 - float(routedScanned) / float(globalScanned)

  echo &"  global      recall={gRecall:5.3f} scanned/query={float(globalScanned)/float(qn):8.1f} tokens/query~={float(globalTokens)/float(qn):8.1f} budget={globalBudget}"
  echo &"  routed      recall={rRecall:5.3f} scanned/query={float(routedScanned)/float(qn):8.1f} tokens/query~={float(routedTokens)/float(qn):8.1f} budget={routedBudget}"
  echo &"  wrong-ring  recall={wRecall:5.3f} scanned/query={float(wrongScanned)/float(qn):8.1f} tokens/query~={float(wrongTokens)/float(qn):8.1f}"
  echo &"  reduction   scanned={scanReduction * 100.0:5.1f}% tokens={tokenReduction * 100.0:5.1f}% quality_delta={rRecall - gRecall:6.3f}"
  db.close()

proc runWorkingSetBench(n, ringCount, queries, budget: int) =
  ## Minimal "full corpus vs semantic working set" benchmark for workloads
  ## where same-quality candidates are localized by ring.
  let rings = max(1, ringCount)
  var db = open()
  var payload = newString(96)
  for i in 0 ..< payload.len:
    payload[i] = char(ord('a') + i mod 26)

  for i in 0 ..< n:
    let r = i mod rings
    discard db.put(%*{"i": i, "ring": r, "body": payload},
                   ring = "bench/ring-" & $r,
                   vec = ringVec(r, rings))

  var globalScanned = 0
  var routedScanned = 0
  var globalTokens = 0
  var routedTokens = 0
  var globalNs = 0
  var routedNs = 0
  let qn = max(1, queries)
  for qi in 0 ..< qn:
    let r = qi mod rings
    let q = ringVec(r, rings)
    var t = getMonoTime()
    let gs = db.retrieveWithStats(q, budget = budget)
    globalNs += int((getMonoTime() - t).inNanoseconds)
    t = getMonoTime()
    let rs = db.retrieveWithStats(q, ring = "bench/ring-" & $r, budget = budget)
    routedNs += int((getMonoTime() - t).inNanoseconds)
    globalScanned += gs.stats.scanned
    routedScanned += rs.stats.scanned
    globalTokens += gs.stats.estimatedTokens
    routedTokens += rs.stats.estimatedTokens

  let scanReduction =
    if globalScanned == 0: 0.0
    else: 1.0 - float(routedScanned) / float(globalScanned)
  let tokenReduction =
    if globalTokens == 0: 0.0
    else: 1.0 - float(routedTokens) / float(globalTokens)
  let workset =
    if rings == 0: n else: (n + rings - 1) div rings
  let scanRatio =
    if routedScanned == 0: 0.0 else: float(globalScanned) / float(routedScanned)
  echo &"  corpus={n} rings={rings} working_set~={workset} budget={budget} queries={qn}"
  echo &"  global   scanned/query={float(globalScanned)/float(qn):10.1f} tokens/query~={float(globalTokens)/float(qn):8.1f} latency/query={float(globalNs)/1e3/float(qn):10.1f} µs"
  echo &"  routed   scanned/query={float(routedScanned)/float(qn):10.1f} tokens/query~={float(routedTokens)/float(qn):8.1f} latency/query={float(routedNs)/1e3/float(qn):10.1f} µs"
  echo &"  reduction scanned={scanReduction * 100.0:6.2f}% tokens={tokenReduction * 100.0:6.2f}% scan_ratio={scanRatio:8.1f}x"
  db.close()

proc runMemoryPressureBench(n, ringCount, queries, budget, payloadBytes: int) =
  ## Synthetic benchmark for the demand-side memory reduction hypothesis.
  ## Compares estimated candidate working-set bytes for full-corpus candidates
  ## and ring-routed semantic working-set candidates.
  let rings = max(1, ringCount)
  let docPayloadBytes = max(1, payloadBytes)
  var db = open()
  var payload = newString(docPayloadBytes)
  for i in 0 ..< payload.len:
    payload[i] = char(ord('a') + i mod 26)

  for i in 0 ..< n:
    let r = i mod rings
    discard db.put(%*{"i": i, "ring": r, "body": payload},
                   ring = "memory/ring-" & $r,
                   vec = ringVec(r, rings))

  var globalScanned = 0
  var routedScanned = 0
  var globalCandidateBytes = 0
  var routedCandidateBytes = 0
  var globalTokens = 0
  var routedTokens = 0
  var globalNs = 0
  var routedNs = 0
  let qn = max(1, queries)
  for qi in 0 ..< qn:
    let r = qi mod rings
    let q = ringVec(r, rings)

    var t = getMonoTime()
    let gs = db.retrieveWithStats(q, budget = budget)
    globalNs += int((getMonoTime() - t).inNanoseconds)

    t = getMonoTime()
    let rs = db.retrieveWithStats(q, ring = "memory/ring-" & $r, budget = budget)
    routedNs += int((getMonoTime() - t).inNanoseconds)

    globalScanned += gs.stats.scanned
    routedScanned += rs.stats.scanned
    globalTokens += gs.stats.estimatedTokens
    routedTokens += rs.stats.estimatedTokens
    globalCandidateBytes += approxCandidateBytes(gs.stats.scanned, docPayloadBytes, rings)
    routedCandidateBytes += approxCandidateBytes(rs.stats.scanned, docPayloadBytes, rings)

  let scanReduction =
    if globalScanned == 0: 0.0
    else: 1.0 - float(routedScanned) / float(globalScanned)
  let tokenReduction =
    if globalTokens == 0: 0.0
    else: 1.0 - float(routedTokens) / float(globalTokens)
  let memoryReduction =
    if globalCandidateBytes == 0: 0.0
    else: 1.0 - float(routedCandidateBytes) / float(globalCandidateBytes)
  let memoryRatio =
    if routedCandidateBytes == 0: 0.0
    else: float(globalCandidateBytes) / float(routedCandidateBytes)
  let workset =
    if rings == 0: n else: (n + rings - 1) div rings

  echo &"  corpus={n} rings={rings} working_set~={workset} payload={docPayloadBytes}B vector_dim={rings} budget={budget} queries={qn}"
  echo &"  global   scanned/query={float(globalScanned)/float(qn):10.1f} candidate_memory/query~={float(globalCandidateBytes)/1024.0/1024.0/float(qn):10.3f} MiB tokens/query~={float(globalTokens)/float(qn):8.1f} latency/query={float(globalNs)/1e3/float(qn):10.1f} µs"
  echo &"  routed   scanned/query={float(routedScanned)/float(qn):10.1f} candidate_memory/query~={float(routedCandidateBytes)/1024.0/1024.0/float(qn):10.3f} MiB tokens/query~={float(routedTokens)/float(qn):8.1f} latency/query={float(routedNs)/1e3/float(qn):10.1f} µs"
  echo &"  reduction scanned={scanReduction * 100.0:6.2f}% candidate_memory={memoryReduction * 100.0:6.2f}% tokens={tokenReduction * 100.0:6.2f}% memory_ratio={memoryRatio:8.1f}x"
  echo "  note      candidate_memory is estimated scanned working-set bytes, not whole-process RSS"
  db.close()

proc runCompact(dataDir: string, durability: KoutenDurability) =
  if dataDir.len == 0:
    raise newException(ValueError, "compact requires --data=DIR")
  var db = open(dataDir = dataDir, durability = durability, diskBacked = true)
  let stats = db.compact()
  db.close()
  echo &"compact OK before={stats.beforeBytes} after={stats.afterBytes} items={stats.items} tombstones={stats.tombstones} rings={stats.ringMeta} names={stats.ringNames} clusterTx={stats.clusterTx}"

proc runPackRing(dataDir, ring: string, durability: KoutenDurability) =
  if dataDir.len == 0 or ring.len == 0:
    raise newException(ValueError, "pack-ring requires --data=DIR --ring=RING")
  var db = open(dataDir = dataDir, durability = durability, diskBacked = true)
  let stats = db.packDiskBackedRing(ring)
  db.close()
  echo &"pack-ring OK ring={ring} records={stats.records} rings={stats.rings} bytes={stats.bytes} removedFiles={stats.removedFiles}"

proc runSegmentStatus(dataDir: string; staleRatio: float;
                      minStaleRecords: int; metricsFormat, jsonFormat: bool) =
  if dataDir.len == 0:
    raise newException(ValueError, "segment-status requires --data=DIR")
  var db = open(dataDir = dataDir, diskBacked = true)
  let report = db.segmentStatus(staleRatio, minStaleRecords)
  db.close()
  if metricsFormat:
    echo &"segmentRecommendedRings {report.recommendedRings}"
    echo &"segmentTotalBytes {report.totalSegmentBytes}"
    echo &"segmentIndexTotalBytes {report.totalIndexBytes}"
    echo &"segmentMaxGeneration {report.maxGeneration}"
    echo &"segmentReadHits {report.segmentHits}"
    echo &"segmentWalFallbacks {report.walFallbacks}"
    for ring in report.rings:
      echo &"segmentRingLiveRecords{{ringKey=\"{ring.ringKey}\"}} {ring.liveRecords}"
      echo &"segmentRingStaleRecords{{ringKey=\"{ring.ringKey}\"}} {ring.staleRecords}"
      echo &"segmentRingStaleRatio{{ringKey=\"{ring.ringKey}\"}} {ring.staleRatio:.6f}"
      echo &"segmentRingPackRecommended{{ringKey=\"{ring.ringKey}\"}} {int(ring.packRecommended)}"
    return
  if jsonFormat:
    echo pretty(segmentStatusJson(report))
    return
  echo &"segment-status OK recommended={report.recommendedRings} segmentBytes={report.totalSegmentBytes} indexBytes={report.totalIndexBytes} maxGeneration={report.maxGeneration}"
  for ring in report.rings:
    echo &"ring={ring.ring} generation={ring.generation} live={ring.liveRecords} covered={ring.coveredRecords} records={ring.segmentRecords} stale={ring.staleRecords} staleRatio={ring.staleRatio:.6f} bytes={ring.segmentBytes + ring.indexBytes} packRecommended={ring.packRecommended}"

proc runPackRecommended(dataDir: string; durability: KoutenDurability;
                        staleRatio: float; minStaleRecords, maxRings: int;
                        maxRingsSet: bool) =
  if dataDir.len == 0:
    raise newException(ValueError, "pack-recommended requires --data=DIR")
  let effectiveMaxRings = if maxRingsSet: maxRings else: 0
  var db = open(dataDir = dataDir, durability = durability, diskBacked = true)
  let stats = db.packRecommendedDiskBackedRings(staleRatio, minStaleRecords,
                                                effectiveMaxRings)
  db.close()
  echo &"pack-recommended OK records={stats.records} rings={stats.rings} bytes={stats.bytes} removedFiles={stats.removedFiles}"

proc printSegmentMaintenance(result: KoutenSegmentMaintenanceResult;
                             policy: KoutenSegmentMaintenancePolicy;
                             jsonFormat: bool) =
  if jsonFormat:
    echo pretty(segmentMaintenanceJson(result, policy))
    return
  echo &"segment-maintenance {result.outcome} selected={result.selectedRings} packed={result.packedRings} records={result.recordsRewritten} bytes={result.bytesRewritten} elapsedMs={result.elapsedMs} stopReason={result.stopReason}"
  for decision in result.decisions:
    echo &"ring={decision.ring} selected={decision.selected} recommended={decision.recommended} reason={decision.reason} stale={decision.staleRecords} staleRatio={decision.staleRatio:.6f} estimatedBytes={decision.estimatedBytes} rewrittenBytes={decision.bytesRewritten} error={decision.error}"

proc runSegmentMaintenance(dataDir: string; durability: KoutenDurability;
                           staleRatio: float; minStaleRecords, maxRings: int;
                           maxBytes, maxElapsedMs: int64; dryRun,
                           jsonFormat: bool) =
  if dataDir.len == 0:
    raise newException(ValueError,
      "segment maintenance requires --data=DIR")
  let policy = KoutenSegmentMaintenancePolicy(
    staleRatioThreshold: staleRatio,
    minStaleRecords: minStaleRecords,
    maxRings: maxRings,
    maxBytes: maxBytes,
    maxElapsedMs: maxElapsedMs)
  var db = open(dataDir = dataDir, durability = durability, diskBacked = true)
  var result: KoutenSegmentMaintenanceResult
  try:
    if not dryRun:
      discard db.recoverInterruptedSegmentMaintenance()
    result = db.runSegmentMaintenance(policy, dryRun = dryRun)
  finally:
    db.close()
  printSegmentMaintenance(result, policy, jsonFormat)

proc runSegmentMaintenanceStatus(dataDir: string; jsonFormat: bool) =
  if dataDir.len == 0:
    raise newException(ValueError, "maintenance-status requires --data=DIR")
  var db = open(dataDir = dataDir, diskBacked = true)
  var status: JsonNode
  try:
    discard db.recoverInterruptedSegmentMaintenance()
    status = db.segmentMaintenanceStatus()
  finally:
    db.close()
  if status.kind == JNull:
    if jsonFormat: echo "null"
    else: echo "maintenance-status no-record"
  elif jsonFormat:
    echo pretty(status)
  else:
    let outcome = status{"outcome"}.getStr()
    let startedAt = status{"startedAt"}.getFloat()
    let finishedAt = status{"finishedAt"}.getFloat()
    let packedRings = status{"packedRings"}.getInt()
    let stopReason = status{"stopReason"}.getStr()
    echo &"maintenance-status {outcome} startedAt={startedAt} finishedAt={finishedAt} packed={packedRings} stopReason={stopReason}"

proc printCheckpointStatus(status: CheckpointStatus; jsonFormat: bool) =
  if jsonFormat:
    echo pretty(checkpointStatusJson(status))
  else:
    echo &"checkpoint {status.reason} id={status.id} verified={status.verified} complete={status.complete} items={status.items} tombstones={status.tombstones} rings={status.rings} walHighWater={status.sourceWalHighWater} snapshotBytes={status.snapshotWalBytes} path={status.path}"

proc runCheckpointCreate(dataDir, checkpointRoot, checkpointId: string;
                         durability: KoutenDurability; jsonFormat: bool) =
  if dataDir.len == 0:
    raise newException(ValueError, "checkpoint-create requires --data=DIR")
  var db = open(dataDir = dataDir, durability = durability,
                diskBacked = true)
  var status: CheckpointStatus
  try:
    status = db.createCheckpoint(checkpointRoot, checkpointId)
  finally:
    db.close()
  printCheckpointStatus(status, jsonFormat)

proc runCheckpointStatus(checkpointPath: string; jsonFormat: bool) =
  if checkpointPath.len == 0:
    raise newException(ValueError,
      "checkpoint-status requires --checkpoint=DIR")
  printCheckpointStatus(checkpointStatus(checkpointPath), jsonFormat)

proc runCheckpointVerify(checkpointPath: string; jsonFormat: bool) =
  if checkpointPath.len == 0:
    raise newException(ValueError,
      "checkpoint-verify requires --checkpoint=DIR")
  printCheckpointStatus(verifyCheckpoint(checkpointPath), jsonFormat)

proc runCheckpointList(checkpointRoot: string; jsonFormat: bool) =
  if checkpointRoot.len == 0:
    raise newException(ValueError,
      "checkpoint-list requires --checkpoint-root=DIR")
  let statuses = listCheckpoints(checkpointRoot)
  if jsonFormat:
    echo pretty(checkpointListJson(checkpointRoot, statuses))
  else:
    echo &"checkpoint-list count={statuses.len} root={checkpointRoot}"
    for status in statuses:
      printCheckpointStatus(status, false)

proc runCheckpointCleanup(checkpointRoot: string; keep: int;
                          jsonFormat: bool) =
  if checkpointRoot.len == 0:
    raise newException(ValueError,
      "checkpoint-clean requires --checkpoint-root=DIR")
  let stats = cleanupCheckpoints(checkpointRoot, keep)
  if jsonFormat:
    echo pretty(checkpointCleanupJson(stats))
  else:
    echo &"checkpoint-clean kept={stats.kept} removed={stats.removed.len} invalid={stats.invalid.len} root={stats.root}"

proc runCheckpointRestore(checkpointPath, dataDir: string; overwrite: bool;
                          jsonFormat: bool) =
  if checkpointPath.len == 0 or dataDir.len == 0:
    raise newException(ValueError,
      "checkpoint-restore requires --checkpoint=DIR --data=DIR")
  let status = restoreCheckpoint(checkpointPath, dataDir,
                                 overwrite = overwrite)
  printCheckpointStatus(status, jsonFormat)

proc runLocality(dataDir: string, metricsFormat: bool) =
  if dataDir.len == 0:
    raise newException(ValueError, "locality requires --data=DIR")
  var db = open(dataDir = dataDir)
  let report = db.localityReport()
  db.close()
  if metricsFormat:
    echo &"localityPersistent {int(report.persistent)}"
    echo &"localityWalBytes {report.walBytes}"
    echo &"localityTotalParticleRecords {report.totalParticleRecords}"
    echo &"localityLiveParticleRecords {report.liveParticleRecords}"
    echo &"localityDeadParticleRecords {report.deadParticleRecords}"
    echo &"localityRingCount {report.ringCount}"
    echo &"localityRingRuns {report.ringRuns}"
    echo &"localityFragmentedRings {report.fragmentedRings}"
    echo &"localityAvgRunRecords {report.avgRunRecords:.3f}"
    echo &"localityMaxRunRecords {report.maxRunRecords}"
    echo &"localityScore {report.localityScore:.6f}"
  else:
    echo &"locality OK persistent={report.persistent} walBytes={report.walBytes} totalParticleRecords={report.totalParticleRecords} liveParticleRecords={report.liveParticleRecords} deadParticleRecords={report.deadParticleRecords} ringCount={report.ringCount} ringRuns={report.ringRuns} fragmentedRings={report.fragmentedRings} avgRunRecords={report.avgRunRecords:.3f} maxRunRecords={report.maxRunRecords} localityScore={report.localityScore:.6f}"

proc runBackup(dataDir, backupDir: string, durability: KoutenDurability) =
  if dataDir.len == 0 or backupDir.len == 0:
    raise newException(ValueError, "backup requires --data=DIR --backup=DIR")
  var db = open(dataDir = dataDir, durability = durability)
  let stats = db.backup(backupDir)
  db.close()
  echo &"backup OK bytes={stats.bytes} items={stats.items} tombstones={stats.tombstones} rings={stats.ringMeta} names={stats.ringNames} from={stats.source} to={stats.destination}"

proc runRestore(backupDir, dataDir: string, overwrite: bool,
                durability: KoutenDurability) =
  if dataDir.len == 0 or backupDir.len == 0:
    raise newException(ValueError, "restore requires --backup=DIR --data=DIR")
  let stats = restoreBackup(backupDir, dataDir, overwrite = overwrite,
                            durability = durability)
  echo &"restore OK bytes={stats.bytes} items={stats.items} tombstones={stats.tombstones} rings={stats.ringMeta} names={stats.ringNames} from={stats.source} to={stats.destination}"

proc runBackupEncrypted(dataDir, backupDir, passphrase: string,
                        durability: KoutenDurability) =
  if dataDir.len == 0 or backupDir.len == 0 or passphrase.len == 0:
    raise newException(ValueError,
      "backup-encrypted requires --data=DIR --backup=DIR --passphrase=TEXT")
  var db = open(dataDir = dataDir, durability = durability)
  let stats = db.backupEncrypted(backupDir, passphrase)
  db.close()
  echo &"backup-encrypted OK bytes={stats.bytes} items={stats.items} tombstones={stats.tombstones} rings={stats.ringMeta} names={stats.ringNames} from={stats.source} to={stats.destination}"

proc runRestoreEncrypted(backupDir, dataDir, passphrase: string,
                         overwrite: bool, durability: KoutenDurability) =
  if dataDir.len == 0 or backupDir.len == 0 or passphrase.len == 0:
    raise newException(ValueError,
      "restore-encrypted requires --backup=DIR --data=DIR --passphrase=TEXT")
  let stats = restoreEncryptedBackup(backupDir, dataDir, passphrase,
                                     overwrite = overwrite,
                                     durability = durability)
  echo &"restore-encrypted OK bytes={stats.bytes} items={stats.items} tombstones={stats.tombstones} rings={stats.ringMeta} names={stats.ringNames} from={stats.source} to={stats.destination}"

type
  RecoveryCandidate = object
    archive: string
    encrypted: bool
    readonly: bool
    priority: int
    snapshotSeq: BiggestInt
    stats: BackupStats

  RecoveryUniverseEntry = object
    archive: string
    universe: string
    galaxy: string
    location: string
    endpoint: string
    failureDomain: string
    authRef: string
    priority: int
    snapshotSeq: BiggestInt
    readonly: bool
    enabled: bool

  RecoveryUniverseStatus = object
    archive: string
    healthy: bool
    candidate: RecoveryCandidate
    error: string

  RecoveryUniverseConfig = object
    requiredHealthy: int
    universes: seq[RecoveryUniverseEntry]

proc artifactChecksum(path: string): string =
  genericHashHex(readFile(path))

proc manifestInt(manifest: JsonNode, key: string, default: int): int =
  if manifest.hasKey(key): manifest[key].getInt() else: default

proc manifestBiggestInt(manifest: JsonNode, key: string,
                        default: BiggestInt): BiggestInt =
  if manifest.hasKey(key): manifest[key].getBiggestInt() else: default

proc manifestBool(manifest: JsonNode, key: string, default: bool): bool =
  if manifest.hasKey(key): manifest[key].getBool() else: default

proc manifestStr(manifest: JsonNode, key, default: string): string =
  if manifest.hasKey(key): manifest[key].getStr() else: default

proc recoveryLocation(value: string): string =
  result = if value.len > 0: value else: "local"
  if result != "local" and result != "remote":
    raise newException(ValueError,
      "universe config location must be local or remote")

proc recoveryAuthRefs(root: JsonNode): seq[string] =
  if root.hasKey("authProfiles"):
    if root["authProfiles"].kind != JObject:
      raise newException(ValueError,
        "universe config authProfiles must be an object")
    for key, profile in root["authProfiles"].pairs:
      if profile.kind != JObject:
        raise newException(ValueError,
          "universe config authProfiles entries must be objects")
      if profile.hasKey("username") or profile.hasKey("password") or
          profile.hasKey("secretKey"):
        raise newException(ValueError,
          "universe config authProfiles must not contain credentials")
      let mode = manifestStr(profile, "mode", "user-password-secret-key")
      if mode != "user-password-secret-key":
        raise newException(ValueError,
          "universe config authProfiles mode must be user-password-secret-key")
      result.add key

proc validateAuthRef(refName: string, knownRefs: seq[string]) =
  if refName.len > 0 and knownRefs.len > 0 and refName notin knownRefs:
    raise newException(ValueError,
      "universe config authRef is not declared in authProfiles: " & refName)

proc galaxyNames(entries: seq[RecoveryUniverseEntry]): seq[string] =
  for entry in entries:
    result.add entry.galaxy
  result.sort()
  if result.len > 1:
    for idx in 1 ..< result.len:
      if result[idx] == result[idx - 1]:
        raise newException(ValueError,
          "universe config galaxy names must be unique per universe")

proc loadRecoveryUniverseConfig(path: string): RecoveryUniverseConfig =
  if path.len == 0:
    return
  let root = parseFile(path)
  if root.hasKey("requiredHealthy"):
    result.requiredHealthy = root["requiredHealthy"].getInt()
  let listKey =
    if root.hasKey("universes"): "universes"
    elif root.hasKey("lanes"): "lanes"
    else: ""
  if listKey.len == 0 or root[listKey].kind != JArray:
    raise newException(ValueError, "universe config requires universes array")
  var expectedGalaxies: seq[string] = @[]
  let knownAuthRefs = recoveryAuthRefs(root)
  for universeNode in root[listKey].items:
    if universeNode.kind != JObject:
      raise newException(ValueError, "universe config universe must be an object")
    let universeName = manifestStr(universeNode, "universe",
                       manifestStr(universeNode, "lane", ""))
    let location = recoveryLocation(manifestStr(universeNode, "location", ""))
    let endpoint = manifestStr(universeNode, "endpoint", "")
    let failureDomain = manifestStr(universeNode, "failureDomain", "")
    let universeAuthRef = manifestStr(universeNode, "authRef", "")
    validateAuthRef(universeAuthRef, knownAuthRefs)
    let priority = manifestInt(universeNode, "priority", 0)
    let snapshotSeq = manifestBiggestInt(universeNode, "snapshotSeq", 0)
    let universeReadonly = manifestBool(universeNode, "readonly",
                           manifestBool(universeNode, "readOnly", false))
    let universeEnabled = manifestBool(universeNode, "enabled", true)
    if location == "remote" and endpoint.len == 0:
      raise newException(ValueError,
        "universe config remote universe requires endpoint")
    var entries: seq[RecoveryUniverseEntry] = @[]
    if universeNode.hasKey("galaxies"):
      if universeNode["galaxies"].kind != JArray:
        raise newException(ValueError,
          "universe config universe galaxies must be an array")
      for galaxyNode in universeNode["galaxies"].items:
        if galaxyNode.kind != JObject:
          raise newException(ValueError,
            "universe config galaxy must be an object")
        let archive = manifestStr(galaxyNode, "archive",
                      manifestStr(galaxyNode, "mirror",
                      manifestStr(galaxyNode, "path", "")))
        if archive.len == 0:
          raise newException(ValueError,
            "universe config galaxy requires archive")
        let galaxyName = manifestStr(galaxyNode, "galaxy", "")
        if galaxyName.len == 0:
          raise newException(ValueError,
            "universe config galaxy requires galaxy")
        let authRef = manifestStr(galaxyNode, "authRef", universeAuthRef)
        validateAuthRef(authRef, knownAuthRefs)
        entries.add RecoveryUniverseEntry(
          archive: archive,
          universe: universeName,
          galaxy: galaxyName,
          location: location,
          endpoint: endpoint,
          failureDomain: failureDomain,
          authRef: authRef,
          priority: priority,
          snapshotSeq: snapshotSeq,
          readonly: manifestBool(galaxyNode, "readonly",
                    manifestBool(galaxyNode, "readOnly", universeReadonly)),
          enabled: universeEnabled and manifestBool(galaxyNode, "enabled", true)
        )
    else:
      let archive = manifestStr(universeNode, "archive",
                    manifestStr(universeNode, "mirror",
                    manifestStr(universeNode, "path", "")))
      if archive.len == 0:
        raise newException(ValueError, "universe config universe requires archive")
      let galaxyName = manifestStr(universeNode, "galaxy", "")
      if galaxyName.len == 0:
        raise newException(ValueError, "universe config universe requires galaxy")
      entries.add RecoveryUniverseEntry(
        archive: archive,
        universe: universeName,
        galaxy: galaxyName,
        location: location,
        endpoint: endpoint,
        failureDomain: failureDomain,
        authRef: universeAuthRef,
        priority: priority,
        snapshotSeq: snapshotSeq,
        readonly: universeReadonly,
        enabled: universeEnabled
      )
    let names = galaxyNames(entries)
    if names.len == 0:
      raise newException(ValueError,
        "universe config universe requires at least one galaxy")
    if expectedGalaxies.len == 0:
      expectedGalaxies = names
    elif names != expectedGalaxies:
      raise newException(ValueError,
        "universe config requires the same galaxies in every universe")
    for entry in entries:
      if entry.enabled:
        result.universes.add entry

proc recoveryUniversesFromArgs(mirrors: seq[string], universeName,
                               galaxy, location, failureDomain, authRef: string,
                               priority: int,
                               snapshotSeq: BiggestInt,
                               readonly: bool): seq[RecoveryUniverseEntry] =
  for mirror in mirrors:
    result.add RecoveryUniverseEntry(
      archive: mirror,
      universe: universeName,
      galaxy: galaxy,
      location: recoveryLocation(location),
      failureDomain: failureDomain,
      authRef: authRef,
      priority: priority,
      snapshotSeq: snapshotSeq,
      readonly: readonly,
      enabled: true
    )

proc recoveryUniversesFromInputs(mirrors: seq[string], configPath, universeName,
                                 galaxy, location, failureDomain,
                                 authRef: string,
                                 priority: int,
                                 snapshotSeq: BiggestInt,
                                 readonly: bool): RecoveryUniverseConfig =
  if configPath.len > 0:
    result = loadRecoveryUniverseConfig(configPath)
  result.universes.add recoveryUniversesFromArgs(mirrors, universeName,
                                                 galaxy, location,
                                                 failureDomain, authRef, priority,
                                                 snapshotSeq, readonly)

proc recoveryArchives(universes: seq[RecoveryUniverseEntry]): seq[string] =
  for universe in universes:
    result.add universe.archive

proc recoveryManifest(encrypted: bool, archive, backupFile, universeName,
                      galaxy, location, endpoint, failureDomain, authRef: string,
                      priority: int,
                      snapshotSeq: BiggestInt, readonly: bool,
                      stats: BackupStats): JsonNode =
  %*{
    "version": 1,
    "kind": "koutendb-recovery-mirror",
    "createdAt": $now(),
    "encrypted": encrypted,
    "eligibleForRestore": true,
    "readonly": readonly,
    "archive": archive,
    "mirror": archive,
    "universe": universeName,
    "galaxy": galaxy,
    "location": location,
    "endpoint": endpoint,
    "failureDomain": failureDomain,
    "authRef": authRef,
    "priority": priority,
    "snapshotSeq": snapshotSeq,
    "backupFile": backupFile,
    "checksumAlgorithm": "blake2b",
    "checksum": artifactChecksum(backupFile),
    "bytes": stats.bytes,
    "items": stats.items,
    "tombstones": stats.tombstones,
    "rings": stats.ringMeta,
    "names": stats.ringNames,
    "clusterTx": stats.clusterTx,
    "appliedClusterTx": stats.appliedClusterTx,
    "warpJobs": stats.warpJobs,
    "universeSyncEvents": stats.universeSyncEvents
  }

proc writeRecoveryManifest(mirror: string, manifest: JsonNode) =
  writeFile(mirror / "kouten.recovery.json", pretty(manifest))

proc runRecoveryBackup(dataDir: string, universes: seq[RecoveryUniverseEntry],
                       passphrase: string) =
  if dataDir.len == 0 or universes.len == 0:
    raise newException(ValueError,
      "recovery-backup requires --data=DIR and --mirror=DIR or --universe-config=FILE")
  var db = open(dataDir = dataDir)
  try:
    for universeConfig in universes:
      let archive = universeConfig.archive
      if universeConfig.readonly:
        echo &"recovery-backup SKIP archive={archive} universe={universeConfig.universe} readonly=true"
        continue
      let encrypted = passphrase.len > 0
      let stats =
        if encrypted: db.backupEncrypted(archive, passphrase)
        else: db.backup(archive)
      let verified =
        if encrypted: verifyEncryptedBackup(archive, passphrase)
        else: verifyBackup(archive)
      let backupFile = archive / (if encrypted: "kouten.backup" else: "kouten.log")
      let universeName =
        if universeConfig.universe.len > 0: universeConfig.universe
        else: lastPathPart(archive)
      writeRecoveryManifest(archive, recoveryManifest(encrypted, archive,
                                                    backupFile, universeName,
                                                    universeConfig.galaxy,
                                                    universeConfig.location,
                                                    universeConfig.endpoint,
                                                    universeConfig.failureDomain,
                                                    universeConfig.authRef,
                                                    universeConfig.priority,
                                                    universeConfig.snapshotSeq,
                                                    universeConfig.readonly,
                                                    verified))
      echo &"recovery-backup OK archive={archive} universe={universeName} encrypted={encrypted} bytes={verified.bytes} items={verified.items} source={stats.source}"
  finally:
    db.close()

proc verifyRecoveryMirror(archive, passphrase: string): RecoveryCandidate =
  if archive.len == 0:
    raise newException(ValueError, "recovery-verify requires --mirror=DIR")
  let encrypted = passphrase.len > 0
  let stats =
    if encrypted: verifyEncryptedBackup(archive, passphrase)
    else: verifyBackup(archive)
  let manifestPath = archive / "kouten.recovery.json"
  if fileExists(manifestPath):
    let manifest = parseFile(manifestPath)
    if manifest.hasKey("encrypted") and manifest["encrypted"].getBool() != encrypted:
      raise newException(IOError, "recovery manifest encryption mode mismatch")
    if manifestBool(manifest, "eligibleForRestore", true) == false:
      raise newException(IOError, "recovery mirror is not eligible for restore")
    if manifest.hasKey("bytes") and manifest["bytes"].getBiggestInt() != stats.bytes:
      raise newException(IOError, "recovery manifest byte count mismatch")
    let backupFile = archive / (if encrypted: "kouten.backup" else: "kouten.log")
    if manifest.hasKey("checksum") and
        manifest["checksum"].getStr() != artifactChecksum(backupFile):
      raise newException(IOError, "recovery manifest checksum mismatch")
    if manifest.hasKey("items") and manifest["items"].getInt() != stats.items:
      raise newException(IOError, "recovery manifest item count mismatch")
    if manifest.hasKey("tombstones") and
        manifest["tombstones"].getInt() != stats.tombstones:
      raise newException(IOError, "recovery manifest tombstone count mismatch")
    if manifest.hasKey("rings") and manifest["rings"].getInt() != stats.ringMeta:
      raise newException(IOError, "recovery manifest ring count mismatch")
    if manifest.hasKey("names") and manifest["names"].getInt() != stats.ringNames:
      raise newException(IOError, "recovery manifest ring name count mismatch")
    result.priority = manifestInt(manifest, "priority", 0)
    result.snapshotSeq = manifestBiggestInt(manifest, "snapshotSeq", 0)
    result.readonly = manifestBool(manifest, "readonly",
                      manifestBool(manifest, "readOnly", false))
  result.archive = archive
  result.encrypted = encrypted
  result.stats = stats

proc runRecoveryVerify(archive, passphrase: string, metricsFormat: bool) =
  let candidate = verifyRecoveryMirror(archive, passphrase)
  let stats = candidate.stats
  if metricsFormat:
    echo &"recoveryMirrorHealthy 1 recoveryMirrorEncrypted {int(candidate.encrypted)} recoveryMirrorReadonly {int(candidate.readonly)} recoveryMirrorBytes {stats.bytes} recoveryMirrorItems {stats.items} recoveryMirrorTombstones {stats.tombstones} recoveryMirrorRings {stats.ringMeta} recoveryMirrorNames {stats.ringNames} recoveryMirrorClusterTx {stats.clusterTx} recoveryMirrorWarpJobs {stats.warpJobs} recoveryMirrorUniverseSyncEvents {stats.universeSyncEvents} recoveryMirrorPriority {candidate.priority} recoveryMirrorSnapshotSeq {candidate.snapshotSeq}"
  else:
    echo &"recovery-verify OK archive={archive} encrypted={candidate.encrypted} readonly={candidate.readonly} bytes={stats.bytes} items={stats.items} tombstones={stats.tombstones} rings={stats.ringMeta} names={stats.ringNames} priority={candidate.priority} snapshotSeq={candidate.snapshotSeq}"

proc recoveryCandidateCmp(a, b: RecoveryCandidate): int =
  result = cmp(b.priority, a.priority)
  if result == 0:
    result = cmp(b.snapshotSeq, a.snapshotSeq)
  if result == 0:
    result = cmp(a.archive, b.archive)

proc runRecoveryStatus(archives: seq[string], passphrase: string,
                       requiredHealthy: int, metricsFormat: bool) =
  if archives.len == 0:
    raise newException(ValueError,
      "recovery-status requires --mirror=DIR [--mirror=DIR...]")
  if requiredHealthy < 1:
    raise newException(ValueError, "recovery-status requires --required-healthy >= 1")

  var statuses: seq[RecoveryUniverseStatus] = @[]
  var candidates: seq[RecoveryCandidate] = @[]
  for archive in archives:
    var universe = RecoveryUniverseStatus(archive: archive)
    try:
      universe.candidate = verifyRecoveryMirror(archive, passphrase)
      universe.healthy = true
      candidates.add universe.candidate
    except CatchableError:
      universe.error = getCurrentExceptionMsg()
    statuses.add universe

  candidates.sort(recoveryCandidateCmp)
  let healthy = candidates.len
  let failed = statuses.len - healthy
  let ok = healthy >= requiredHealthy
  let best =
    if candidates.len > 0: candidates[0]
    else: RecoveryCandidate()

  if metricsFormat:
    echo &"recoveryUniverseHealthy {int(ok)} recoveryHealthyUniverses {healthy} recoveryRequiredHealthyUniverses {requiredHealthy} recoveryFailedUniverses {failed} recoveryBestPriority {best.priority} recoveryBestSnapshotSeq {best.snapshotSeq} recoveryBestBytes {best.stats.bytes} recoveryBestItems {best.stats.items}"
  else:
    echo &"recovery-status {(if ok: \"OK\" else: \"FAIL\")} healthy={healthy} required={requiredHealthy} failed={failed} bestArchive={best.archive} priority={best.priority} snapshotSeq={best.snapshotSeq}"
    for universe in statuses:
      if universe.healthy:
        echo &"  universe OK archive={universe.archive} priority={universe.candidate.priority} snapshotSeq={universe.candidate.snapshotSeq} bytes={universe.candidate.stats.bytes} items={universe.candidate.stats.items}"
      else:
        echo &"  universe FAIL archive={universe.archive} error={universe.error}"

  if not ok:
    quit(1)

proc replaceRecoveryLog(stageDir, dataDir: string) =
  createDir(dataDir)
  let src = stageDir / "kouten.log"
  let dst = dataDir / "kouten.log"
  let tmp = dst & ".recovery-tmp"
  let bak = dst & ".recovery-bak"
  copyFile(src, tmp)
  try:
    if fileExists(dst):
      if fileExists(bak):
        removeFile(bak)
      moveFile(dst, bak)
    moveFile(tmp, dst)
    if fileExists(bak):
      removeFile(bak)
  except CatchableError:
    if fileExists(tmp):
      removeFile(tmp)
    if fileExists(bak) and not fileExists(dst):
      moveFile(bak, dst)
    raise

proc runRecoveryRestore(archives: seq[string], dataDir, passphrase: string,
                        overwrite: bool, durability: KoutenDurability) =
  if dataDir.len == 0 or archives.len == 0:
    raise newException(ValueError,
      "recovery-restore requires --mirror=DIR [--mirror=DIR...] --data=DIR")
  let dst = dataDir / "kouten.log"
  if fileExists(dst) and not overwrite:
    raise newException(IOError, "target kouten.log already exists: " & dst)

  var candidates: seq[RecoveryCandidate] = @[]
  var lastError = ""
  for archive in archives:
    try:
      candidates.add verifyRecoveryMirror(archive, passphrase)
    except CatchableError:
      lastError = archive & ": " & getCurrentExceptionMsg()

  if candidates.len == 0:
    raise newException(IOError, "no eligible recovery mirror" &
      (if lastError.len > 0: " (" & lastError & ")" else: ""))

  candidates.sort(recoveryCandidateCmp)
  let chosen = candidates[0]
  let stageDir = dataDir & ".recovery-stage"
  if dirExists(stageDir):
    removeDir(stageDir)
  try:
    if chosen.encrypted:
      discard restoreEncryptedBackup(chosen.archive, stageDir, passphrase,
                                     overwrite = true,
                                     durability = durability)
    else:
      discard restoreBackup(chosen.archive, stageDir, overwrite = true,
                            durability = durability)
    replaceRecoveryLog(stageDir, dataDir)
  finally:
    if dirExists(stageDir):
      removeDir(stageDir)
  echo &"recovery-restore OK archive={chosen.archive} data={dataDir} encrypted={chosen.encrypted} priority={chosen.priority} snapshotSeq={chosen.snapshotSeq} bytes={chosen.stats.bytes} items={chosen.stats.items}"

proc runDump(dataDir, outPath: string, includeVectors: bool) =
  if dataDir.len == 0:
    raise newException(ValueError, "dump requires --data=DIR")
  var db = open(dataDir = dataDir)
  let stats = db.dump(path = outPath, includeVectors = includeVectors)
  db.close()
  if outPath.len > 0 and outPath != "-":
    echo &"dump OK bytes={stats.bytes} records={stats.records} rings={stats.rings} documents={stats.documents} to={stats.destination}"

proc runImportJsonl(dataDir, inPath, defaultRing, ringField, ringPrefix,
                    payloadField, vecField: string, maxRecords,
                    batchSize: int) =
  if dataDir.len == 0 or inPath.len == 0:
    raise newException(ValueError, "import-jsonl requires --data=DIR --in=FILE")
  var db = open(dataDir = dataDir)
  let stats = db.importJsonl(inPath, defaultRing = defaultRing,
                             ringField = ringField, ringPrefix = ringPrefix,
                             payloadField = payloadField, vecField = vecField,
                             maxRecords = maxRecords,
                             batchSize = batchSize)
  db.close()
  echo &"import-jsonl OK read={stats.read} imported={stats.imported} skipped={stats.skipped} errors={stats.errors} rings={stats.rings} batches={stats.batches} batchSize={stats.batchSize} source={stats.source}"

proc scaleInClient(peers, username, password, authToken, secretKey, galaxy:
                   string; tls: bool; tlsCaFile, tlsServerName: string;
                   tlsInsecureSkipVerify: bool): ClusterClient =
  if peers.len == 0:
    raise newException(ValueError,
      "scale-in commands require --peers=TARGET_HOSTS")
  newClusterClient(parsePeers(peers), username = username, password = password,
                   authToken = authToken, secretKey = secretKey,
                   galaxy = galaxy, tls = tls, tlsCaFile = tlsCaFile,
                   tlsServerName = tlsServerName,
                   tlsInsecureSkipVerify = tlsInsecureSkipVerify)

proc scaleInPlanNode(plan: ScaleInPlan): JsonNode =
  %*{
    "source": {
      "epoch": plan.sourceEpoch,
      "nodes": plan.sourceNodes,
      "virtualArcsPerNode": plan.sourceVirtualArcs
    },
    "target": {
      "epoch": plan.targetEpoch,
      "nodes": plan.targetNodes,
      "virtualArcsPerNode": plan.targetVirtualArcs
    },
    "records": plan.records,
    "tombstones": plan.tombstones,
    "metadataObjects": plan.metadataObjects,
    "recordsByTarget": plan.recordsByTarget,
    "tombstonesByTarget": plan.tombstonesByTarget
  }

proc runScaleInPlan(dataDir, peers, username, password, authToken, secretKey,
                    galaxy: string; tls: bool; tlsCaFile, tlsServerName: string;
                    tlsInsecureSkipVerify, jsonFormat: bool) =
  var client = scaleInClient(peers, username, password, authToken, secretKey,
                             galaxy, tls, tlsCaFile, tlsServerName,
                             tlsInsecureSkipVerify)
  try:
    let plan = planScaleIn(dataDir, client)
    if jsonFormat:
      echo $plan.scaleInPlanNode
    else:
      echo &"scale-in-plan OK sourceEpoch={plan.sourceEpoch} sourceNodes={plan.sourceNodes} targetEpoch={plan.targetEpoch} targetNodes={plan.targetNodes} records={plan.records} tombstones={plan.tombstones} metadataObjects={plan.metadataObjects}"
      echo "recordsByTarget=" & $plan.recordsByTarget
      echo "tombstonesByTarget=" & $plan.tombstonesByTarget
  finally:
    client.close()

proc runScaleInMigrate(dataDir, peers, username, password, authToken,
                       secretKey, galaxy, checkpointPath: string;
                       checkpointEvery, retryLimit, retryDelayMs,
                       maxTransfers: int;
                       resetCheckpoint, tls: bool;
                       tlsCaFile, tlsServerName: string;
                       tlsInsecureSkipVerify, jsonFormat: bool) =
  var client = scaleInClient(peers, username, password, authToken, secretKey,
                             galaxy, tls, tlsCaFile, tlsServerName,
                             tlsInsecureSkipVerify)
  try:
    let stats = migrateScaleIn(
      dataDir, client, checkpointPath = checkpointPath,
      checkpointEvery = checkpointEvery, retryLimit = retryLimit,
      retryDelayMs = retryDelayMs, resetCheckpoint = resetCheckpoint,
      maxTransfers = maxTransfers)
    if jsonFormat:
      echo $(%*{
        "recordsAcked": stats.recordsAcked,
        "tombstonesAcked": stats.tombstonesAcked,
        "applied": stats.applied,
        "skipped": stats.skipped,
        "retries": stats.retries,
        "metadataObjects": stats.metadataObjects,
        "resumed": stats.resumed,
        "complete": stats.complete,
        "checkpoint": stats.checkpoint
      })
    else:
      echo &"scale-in-migrate OK recordsAcked={stats.recordsAcked} tombstonesAcked={stats.tombstonesAcked} metadataObjects={stats.metadataObjects} applied={stats.applied} skipped={stats.skipped} retries={stats.retries} resumed={stats.resumed} complete={stats.complete} checkpoint={stats.checkpoint}"
  finally:
    client.close()

proc runScaleInVerify(dataDir, peers, username, password, authToken,
                      secretKey, galaxy, checkpointPath: string;
                      retryLimit, retryDelayMs: int; tls: bool;
                      tlsCaFile, tlsServerName: string;
                      tlsInsecureSkipVerify, jsonFormat: bool) =
  var client = scaleInClient(peers, username, password, authToken, secretKey,
                             galaxy, tls, tlsCaFile, tlsServerName,
                             tlsInsecureSkipVerify)
  try:
    let stats = verifyScaleIn(
      dataDir, client, checkpointPath = checkpointPath,
      retryLimit = retryLimit, retryDelayMs = retryDelayMs)
    if jsonFormat:
      echo $(%*{
        "records": stats.records,
        "tombstones": stats.tombstones,
        "metadataObjects": stats.metadataObjects,
        "matching": stats.matching,
        "ahead": stats.ahead,
        "retries": stats.retries,
        "verified": true,
        "checkpoint": stats.checkpoint
      })
    else:
      echo &"scale-in-verify OK records={stats.records} tombstones={stats.tombstones} metadataObjects={stats.metadataObjects} matching={stats.matching} ahead={stats.ahead} retries={stats.retries} checkpoint={stats.checkpoint}"
  finally:
    client.close()

proc scaleInCheckpointNode(checkpoint: ScaleInCheckpoint): JsonNode =
  %*{
    "format": checkpoint.format,
    "phase": checkpoint.phase,
    "complete": checkpoint.complete,
    "verified": checkpoint.verified,
    "sourceEpoch": checkpoint.sourceEpoch,
    "sourceNodes": checkpoint.sourceNodes,
    "targetEpoch": checkpoint.targetEpoch,
    "targetNodes": checkpoint.targetNodes,
    "recordsAcked": checkpoint.recordsAcked,
    "tombstonesAcked": checkpoint.tombstonesAcked,
    "metadataTransferred": checkpoint.metadataTransferred,
    "ringIndex": checkpoint.ringIndex,
    "itemIndex": checkpoint.itemIndex,
    "tombstoneIndex": checkpoint.tombstoneIndex,
    "targetPeers": checkpoint.targetPeers
  }

proc runScaleInStatus(checkpointPath: string; jsonFormat: bool) =
  if checkpointPath.len == 0:
    raise newException(ValueError,
      "scale-in-status requires --checkpoint=FILE")
  let checkpoint = loadScaleInCheckpoint(checkpointPath)
  if jsonFormat:
    echo $checkpoint.scaleInCheckpointNode
  else:
    echo &"scale-in-status phase={checkpoint.phase} complete={checkpoint.complete} verified={checkpoint.verified} metadataTransferred={checkpoint.metadataTransferred} sourceEpoch={checkpoint.sourceEpoch} sourceNodes={checkpoint.sourceNodes} targetEpoch={checkpoint.targetEpoch} targetNodes={checkpoint.targetNodes} recordsAcked={checkpoint.recordsAcked} tombstonesAcked={checkpoint.tombstonesAcked} checkpoint={checkpointPath}"

proc universeSyncEventNode(event: UniverseSyncEvent): JsonNode =
  %*{
    "id": event.id,
    "eventKey": event.eventKey,
    "sourceUniverse": event.sourceUniverse,
    "sourceGalaxy": event.sourceGalaxy,
    "ring": event.ring,
    "op": event.op,
    "logicalKey": event.logicalKey,
    "payload": event.payload,
    "codec": event.codec.payloadCodecName,
    "vec": event.vec,
    "timestamp": event.timestamp,
    "applyAfter": event.applyAfter,
    "originSeq": event.originSeq,
    "attempts": event.attempts,
    "maxAttempts": event.maxAttempts,
    "retryAt": event.retryAt,
    "deadLetter": event.deadLetter,
    "acknowledged": event.acknowledged,
    "error": event.error
  }

proc parseUniverseSyncEvent(node: JsonNode): UniverseSyncEvent =
  if node.kind != JObject:
    raise newException(ValueError, "universe sync event must be an object")
  var vec: seq[float32] = @[]
  if node.hasKey("vec") and node["vec"].kind == JArray:
    for item in node["vec"]:
      case item.kind
      of JInt:
        vec.add float32(item.getInt())
      of JFloat:
        vec.add float32(item.getFloat())
      else:
        discard
  UniverseSyncEvent(
    id: node{"id"}.getBiggestInt().uint64,
    eventKey: node["eventKey"].getStr(),
    sourceUniverse: node{"sourceUniverse"}.getStr(),
    sourceGalaxy: node{"sourceGalaxy"}.getStr(),
    ring: node["ring"].getStr(),
    op: node{"op"}.getStr("put"),
    logicalKey: node{"logicalKey"}.getStr(),
    payload: node{"payload"}.getStr(),
    codec: parsePayloadCodec(node{"codec"}.getStr("raw")),
    vec: vec,
    timestamp: node{"timestamp"}.getFloat(),
    applyAfter: node{"applyAfter"}.getFloat(),
    originSeq: node{"originSeq"}.getBiggestInt().uint64,
    attempts: node{"attempts"}.getInt(),
    maxAttempts: node{"maxAttempts"}.getInt(8),
    retryAt: node{"retryAt"}.getFloat(),
    deadLetter: node{"deadLetter"}.getBool(),
    acknowledged: node{"acknowledged"}.getBool(),
    error: node{"error"}.getStr())

proc runUniverseExport(dataDir, outPath: string) =
  if dataDir.len == 0:
    raise newException(ValueError, "universe-export requires --data=DIR")
  var db = open(dataDir = dataDir)
  var outFile: File
  let toStdout = outPath.len == 0 or outPath == "-"
  if toStdout:
    outFile = stdout
  else:
    let parent = parentDir(outPath)
    if parent.len > 0:
      createDir(parent)
    outFile = open(outPath, fmWrite)
  var exported = 0
  try:
    for event in db.universeSyncEvents():
      outFile.write($event.universeSyncEventNode())
      outFile.write("\n")
      inc exported
  finally:
    if not toStdout:
      outFile.close()
    db.close()
  if not toStdout:
    echo &"universe-export OK events={exported} to={outPath}"

proc runUniverseApply(dataDir, inPath: string) =
  if dataDir.len == 0 or inPath.len == 0:
    raise newException(ValueError, "universe-apply requires --data=DIR --in=FILE")
  var db = open(dataDir = dataDir)
  var read = 0
  var applied = 0
  var skipped = 0
  var errors = 0
  try:
    for line in lines(inPath):
      let trimmed = line.strip()
      if trimmed.len == 0:
        inc skipped
        continue
      inc read
      try:
        if db.applyUniverseSyncEvent(parseUniverseSyncEvent(parseJson(trimmed))):
          inc applied
        else:
          inc skipped
      except CatchableError:
        inc errors
  finally:
    db.close()
  echo &"universe-apply OK read={read} applied={applied} skipped={skipped} errors={errors} source={inPath}"

proc runUniverseSync(dataDir, targetDataDir: string, pruneAcked: bool) =
  if dataDir.len == 0 or targetDataDir.len == 0:
    raise newException(ValueError,
      "universe-sync requires --data=SOURCE_DIR --target-data=TARGET_DIR")
  var source = open(dataDir = dataDir)
  var target = open(dataDir = targetDataDir)
  try:
    let stats = syncUniverseOnce(source, target, pruneAcked = pruneAcked)
    echo &"universe-sync OK read={stats.read} applied={stats.applied} skipped={stats.skipped} acked={stats.acked} pruned={stats.pruned} errors={stats.errors} deadLetter={stats.deadLetter} source={dataDir} target={targetDataDir}"
  finally:
    target.close()
    source.close()

proc runUniverseSyncRemote(dataDir, peers, username, password, authToken,
                           secretKey, galaxy: string, pruneAcked: bool,
                           tls: bool, tlsCaFile, tlsServerName: string,
                           tlsInsecureSkipVerify: bool) =
  if dataDir.len == 0 or peers.len == 0:
    raise newException(ValueError,
      "remote universe-sync requires --data=SOURCE_DIR --peers=host:port,...")
  var source = open(dataDir = dataDir)
  let client = newClusterClient(parsePeers(peers), username, password,
                                authToken, secretKey, galaxy,
                                tls = tls, tlsCaFile = tlsCaFile,
                                tlsServerName = tlsServerName,
                                tlsInsecureSkipVerify = tlsInsecureSkipVerify)
  var stats = UniverseSyncStats()
  try:
    for event in source.universeSyncEvents(includeDeadLetter = false):
      inc stats.read
      if not universeSyncDispatchable(event):
        inc stats.skipped
        continue
      try:
        let status = client.universeApplyReq(0, $event.universeSyncEventNode())
        if status == "APPLIED":
          inc stats.applied
        elif status == "SKIPPED":
          inc stats.skipped
        elif status == "DELAYED":
          inc stats.skipped
          continue
        else:
          raise newException(IOError, "invalid universe apply status: " & status)
        discard source.ackUniverseSyncEvent(event.id)
        inc stats.acked
      except CatchableError:
        inc stats.errors
        let updated = source.markUniverseSyncFailure(event.id, getCurrentExceptionMsg())
        if updated.deadLetter:
          inc stats.deadLetter
    if pruneAcked:
      stats.pruned = source.pruneAckedUniverseSyncEvents()
  finally:
    client.close()
    source.close()
  echo &"universe-sync OK read={stats.read} applied={stats.applied} skipped={stats.skipped} acked={stats.acked} pruned={stats.pruned} errors={stats.errors} deadLetter={stats.deadLetter} source={dataDir} targetPeers={peers}"

proc runUniverseStatus(dataDir, peers, username, password, authToken,
                       secretKey, galaxy: string, metricsFormat: bool,
                       tls: bool, tlsCaFile, tlsServerName: string,
                       tlsInsecureSkipVerify: bool) =
  if dataDir.len > 0:
    var db = open(dataDir = dataDir)
    var pending = 0
    var acked = 0
    var errors = 0
    var retrying = 0
    var dead = 0
    try:
      for event in db.universeSyncEvents(includeAcknowledged = true):
        if event.acknowledged:
          inc acked
        elif event.deadLetter:
          inc dead
        else:
          inc pending
          if event.retryAt > epochTime():
            inc retrying
        if event.error.len > 0:
          inc errors
    finally:
      db.close()
    if metricsFormat:
      echo &"universeSyncPending {pending}"
      echo &"universeSyncAcked {acked}"
      echo &"universeSyncRetrying {retrying}"
      echo &"universeSyncDeadLetter {dead}"
      echo &"universeSyncErrors {errors}"
    else:
      echo &"universe-status OK source=local pending={pending} acked={acked} retrying={retrying} deadLetter={dead} errors={errors} data={dataDir}"
  elif peers.len > 0:
    let parsedPeers = parsePeers(peers)
    let client = newClusterClient(parsedPeers, username, password,
                                  authToken, secretKey, galaxy,
                                  tls = tls, tlsCaFile = tlsCaFile,
                                  tlsServerName = tlsServerName,
                                  tlsInsecureSkipVerify = tlsInsecureSkipVerify)
    var pending = 0
    var applied = 0
    var appliedOps = 0
    var skippedOps = 0
    var errors = 0
    var forwarded = 0
    var lastOk = 0
    var lastError = 0
    try:
      for node in 0 ..< parsedPeers.len:
        let status = client.universeStatusReq(node)
        pending += status.pending
        applied += status.applied
        appliedOps += status.appliedOps
        skippedOps += status.skippedOps
        errors += status.errors
        forwarded += status.forwarded
        if status.lastOk > lastOk:
          lastOk = status.lastOk
        if status.lastError > lastError:
          lastError = status.lastError
      if metricsFormat:
        echo &"universeSyncPending {pending}"
        echo &"universeSyncApplied {applied}"
        echo &"universeApplyApplied {appliedOps}"
        echo &"universeApplySkipped {skippedOps}"
        echo &"universeApplyErrors {errors}"
        echo &"universeApplyForwarded {forwarded}"
        echo &"universeApplyLastOk {lastOk}"
        echo &"universeApplyLastError {lastError}"
      else:
        echo &"universe-status OK source=remote pending={pending} applied={applied} applyApplied={appliedOps} skipped={skippedOps} errors={errors} forwarded={forwarded} lastOk={lastOk} lastError={lastError} peers={peers}"
    finally:
      client.close()
  else:
    raise newException(ValueError,
      "universe-status requires --data=DIR or --peers=host:port,...")

proc parseDurability(value: string): KoutenDurability =
  case value
  of "buffered": durBuffered
  of "strong": durStrong
  else:
    raise newException(ValueError,
      "--durability must be 'buffered' or 'strong'")

proc readSecretFile(path, label: string): string =
  if path.len == 0:
    return ""
  result = readFile(path).strip()
  if result.len == 0:
    raise newException(ValueError, label & " file is empty")

proc printHelp() =
  echo "KoutenDB command-line client"
  echo ""
  echo "Usage:"
  echo "  kouten put [--data=DIR | --peers=host:port,...] --ring=RING [--near=BASE_RING] [--payload=TEXT | --in=FILE] [--codec=auto|raw|json|nif|bif]"
  echo "  kouten get [--data=DIR | --peers=host:port,...] [--ring=RING | --stellar=RING] [--subring=orders,billing] [--subring-limit=orders:10] [--subring-sort=orders:id] [--subring-rsort=billing:time] [--filter='{\"id\":\"RAW_ID\"}'] [--selection=SEL] [--limit=N] [--cursor=CURSOR] [--sort=id|time] [--rsort=id|time] [--pagination=on|off] [--page=N] [--pagelimit=N]"
  echo "  kouten stellar attach|detach|list --stellar=RING [--ring=RING]"
  echo "  kouten time-orbit --data=DIR --ring=RING [--bucket-ms=N] [--bits=60] [--phase=N] [--salt=TEXT]"
  echo "  kouten time-put --data=DIR --ring=RING --time-ms=N [--payload=TEXT | --in=FILE]"
  echo "  kouten time-get --data=DIR --ring=RING --from-ms=N --to-ms=N [--filter=JSON] [--selection=SEL] [--limit=N]"
  echo "  kouten query [--data=DIR | --peers=host:port,...] --ring=RING [--filter='{\"id\":\"RAW_ID\"}' | --id=RAW_ID] --selection=SEL"
  echo "  kouten list-ring [--data=DIR | --peers=host:port,...] --ring=RING [--limit=N] [--cursor=CURSOR]"
  echo "  kouten count-ring [--data=DIR | --peers=host:port,...] --ring=RING"
  echo "  kouten ring-profile --data=DIR --ring=RING [--codec=raw|json|nif|bif] [--charset=UTF-8] [--format-version=VERSION]"
  echo "  kouten shell [--data=DIR | --peers=host:port,...]"
  echo "  kouten atlas [--data=DIR | --peers=host:port,...]"
  echo "  kouten health|metrics|rings|drain|resume|snapshot --peers=host:port,..."
  echo "  kouten driver list|info|install [LANG] [--manifest-path=FILE] [--execute]"
  echo "  kouten compact --data=DIR"
  echo "  kouten pack-ring --data=DIR --ring=RING [--durability=buffered|strong]"
  echo "  kouten segment-status --data=DIR [--stale-ratio=0.25] [--min-stale-records=256] [--metrics|--json]"
  echo "  kouten pack-recommended --data=DIR [--stale-ratio=0.25] [--min-stale-records=256] [--max-rings=N]"
  echo "  kouten maintenance-plan --data=DIR [--stale-ratio=0.25] [--min-stale-records=256] [--max-rings=1] [--max-bytes=67108864] [--max-elapsed-ms=1000] [--json]"
  echo "  kouten maintenance-run --data=DIR [--stale-ratio=0.25] [--min-stale-records=256] [--max-rings=1] [--max-bytes=67108864] [--max-elapsed-ms=1000] [--json]"
  echo "  kouten maintenance-status --data=DIR [--json]"
  echo "  kouten checkpoint-create --data=DIR [--checkpoint-root=DIR] [--checkpoint-id=ID] [--durability=buffered|strong] [--json]"
  echo "  kouten checkpoint-status --checkpoint=DIR [--json]"
  echo "  kouten checkpoint-verify --checkpoint=DIR [--json]"
  echo "  kouten checkpoint-list --checkpoint-root=DIR [--json]"
  echo "  kouten checkpoint-clean --checkpoint-root=DIR [--keep=N] [--json]"
  echo "  kouten checkpoint-restore --checkpoint=DIR --data=DIR [--overwrite] [--json]"
  echo "  kouten locality --data=DIR [--metrics]"
  echo "  kouten backup --data=DIR --backup=DIR [--durability=buffered|strong]"
  echo "  kouten restore --backup=DIR --data=DIR [--overwrite] [--durability=buffered|strong]"
  echo "  kouten verify [--data=DIR | --backup=DIR | --server-config=FILE] [--segments] [--max-wal-bytes=N] [--max-segment-bytes=N] [--max-dead-records=N] [--max-dead-ratio=F] [--max-segment-generation=N] [--max-segment-files=N] [--max-items=N] [--max-rings=N] [--metrics] [--json]"
  echo "  kouten dump --data=DIR [--out=FILE] [--no-vectors]"
  echo "  kouten import-jsonl --data=DIR --in=FILE [--ring-field=FIELD] [--default-ring=RING] [--batch-size=N]"
  echo "  kouten scale-in-plan --data=OLD_DIR --peers=TARGET_PEERS [--json]"
  echo "  kouten scale-in-migrate --data=OLD_DIR --peers=TARGET_PEERS [--checkpoint=FILE] [--checkpoint-every=N] [--max-transfers=N] [--retry-limit=N] [--retry-delay-ms=N] [--reset-checkpoint] [--json]"
  echo "  kouten scale-in-verify --data=OLD_DIR --peers=TARGET_PEERS [--checkpoint=FILE] [--retry-limit=N] [--retry-delay-ms=N] [--json]"
  echo "  kouten scale-in-status --checkpoint=FILE [--json]"
  echo "  kouten universe-sync --data=SOURCE_DIR [--target-data=TARGET_DIR | --peers=host:port,...] [--prune-acked]"
  echo "  kouten universe-status [--data=DIR | --peers=host:port,...] [--metrics]"
  echo "  kouten recovery-status [--mirror=DIR...] [--universe-config=FILE] [--required-healthy=N] [--metrics]"
  echo "  kouten doctor [--data=DIR | --backup=DIR | --server-config=FILE] [--segments] [--max-wal-bytes=N] [--max-segment-bytes=N] [--max-dead-records=N] [--max-dead-ratio=F] [--max-segment-generation=N] [--max-segment-files=N] [--max-items=N] [--max-rings=N] [--metrics] [--json]"
  echo ""
  echo "ID formats:"
  echo "  parent:seq"
  echo "  parent:epoch:seq:tWrite"
  echo ""
  echo "Local commands use --data=DIR, KOUTEN_DATA, or ./data by default."
  echo "Cluster commands use --peers=host:port,... or --config=FILE."
  echo "KOUTEN_CONFIG can point to the same JSON config file."
  echo "Auth can use --user/--password-file/--secret-key-file or KOUTEN_USER, KOUTEN_PASSWORD, KOUTEN_SECRET_KEY, KOUTEN_AUTH_TOKEN."
  echo "Get uses --view=auto by default; payload codec is inferred from stored metadata."
  echo "--where is accepted as an alias for --filter. --id is a low-level shortcut for scripts."
  echo "Cluster get/query requires --ring=RING so the CLI can reconstruct ring placement metadata."

proc main() =
  var cmd = ""
  var peers = ""
  var dataDir = ""
  var targetDataDir = ""
  var backupDir = ""
  var mirrors: seq[string] = @[]
  var outPath = ""
  var inPath = ""
  var checkpointPath = ""
  var checkpointRoot = ""
  var checkpointId = ""
  var payload = ""
  var codecName = "auto"
  var charset = ""
  var formatVersion = ""
  var view = "auto"
  var idArg = ""
  var nearRingBase = ""
  var subringArg = ""
  var subringLimitArg = ""
  var subringSortArg = ""
  var subringRsortArg = ""
  var whereArg = ""
  var filterArg = ""
  var sortArg = ""
  var rsortArg = "time"
  var paginationArg = "off"
  var selection = ""
  var cursor = ""
  var defaultRing = "imported"
  var ringName = ""
  var stellarName = ""
  var description = ""
  var ringField = ""
  var ringPrefix = ""
  var payloadField = ""
  var vecField = ""
  var overwrite = false
  var pruneAcked = false
  var includeVectors = true
  var metricsFormat = false
  var jsonFormat = false
  var readonly = false
  var verifySegments = false
  var maxWalBytes: int64 = -1
  var maxSegmentBytes: int64 = -1
  var maxSegmentFiles = -1
  var maxDeadRecords = -1
  var maxDeadRatio = -1.0
  var maxSegmentGeneration: int64 = -1
  var staleRatio = 0.25
  var minStaleRecords = 256
  var maxItems = -1
  var maxRings = -1
  var maxRingsSet = false
  var maintenanceMaxBytes = 64'i64 * 1024 * 1024
  var maintenanceMaxElapsedMs = 1000'i64
  var username = ""
  var password = ""
  var passwordFile = ""
  var authToken = ""
  var authTokenFile = ""
  var secretKey = ""
  var secretKeyFile = ""
  var tls = false
  var tlsCaFile = ""
  var tlsServerName = ""
  var tlsInsecureSkipVerify = false
  var backupPassphrase = ""
  var galaxy = ""
  var universeName = ""
  var universeLocation = "local"
  var failureDomain = ""
  var authRef = ""
  var redisEndpoint = "127.0.0.1:6379"
  var configPath = getEnv("KOUTEN_CONFIG")
  var serverConfigPath = ""
  var universeConfig = ""
  var driverManifestPath = ""
  var driverProjectDir = ""
  var n = 10_000
  var queries = 50
  var budget = 20
  var routedBudget = 3
  var ringCount = 100
  var payloadBytes = 100
  var importBatchSize = 1000
  var checkpointEvery = DefaultScaleInCheckpointEvery
  var checkpointKeep = 2
  var retryLimit = DefaultScaleInRetryLimit
  var retryDelayMs = DefaultScaleInRetryDelayMs
  var maxTransfers = 0
  var resetCheckpoint = false
  var priority = 0
  var snapshotSeq: BiggestInt = 0
  var requiredHealthy = 1
  var requiredHealthySet = false
  var help = false
  var executeDriverInstall = false
  var limit = 100
  var page = 1
  var pageLimit = 20
  var depth = 1
  var branchBudget = 0
  var durability = durBuffered
  var timeMs: int64 = -1
  var fromMs: int64 = -1
  var toMs: int64 = -1
  var timeOrbitBits = 60
  var timeOrbitBitsSet = false
  var timeOrbitBucketMs: int64 = 60_000
  var timeOrbitBucketMsSet = false
  var timeOrbitPhase = 0'u64
  var timeOrbitPhaseSet = false
  var timeOrbitSalt = ""
  var timeOrbitSaltSet = false
  var positionals: seq[string] = @[]

  for kind, key, val in getopt():
    if kind == cmdLongOption and key == "config":
      configPath = val

  if configPath.len > 0:
    let cfg = parseFile(configPath)
    if cfg.kind != JObject:
      raise newException(ValueError, "config file must contain a JSON object")
    peers = jsonPeersOpt(cfg, peers)
    dataDir = jsonStringOpt(cfg, "data", dataDir)
    dataDir = jsonStringOpt(cfg, "dataDir", dataDir)
    username = jsonStringOpt(cfg, "user", username)
    username = jsonStringOpt(cfg, "username", username)
    password = jsonStringOpt(cfg, "password", password)
    passwordFile = jsonStringOpt(cfg, "passwordFile", passwordFile)
    passwordFile = jsonStringOpt(cfg, "password-file", passwordFile)
    authToken = jsonStringOpt(cfg, "authToken", authToken)
    authToken = jsonStringOpt(cfg, "auth-token", authToken)
    authTokenFile = jsonStringOpt(cfg, "authTokenFile", authTokenFile)
    authTokenFile = jsonStringOpt(cfg, "auth-token-file", authTokenFile)
    secretKey = jsonStringOpt(cfg, "secretKey", secretKey)
    secretKey = jsonStringOpt(cfg, "secret-key", secretKey)
    secretKeyFile = jsonStringOpt(cfg, "secretKeyFile", secretKeyFile)
    secretKeyFile = jsonStringOpt(cfg, "secret-key-file", secretKeyFile)
    galaxy = jsonStringOpt(cfg, "galaxy", galaxy)
    tls = jsonBoolOpt(cfg, "tls", tls)
    tlsCaFile = jsonStringOpt(cfg, "tlsCaFile", tlsCaFile)
    tlsCaFile = jsonStringOpt(cfg, "tls-ca", tlsCaFile)
    tlsServerName = jsonStringOpt(cfg, "tlsServerName", tlsServerName)
    tlsServerName = jsonStringOpt(cfg, "tls-server-name", tlsServerName)
    tlsInsecureSkipVerify = jsonBoolOpt(cfg, "tlsInsecureSkipVerify",
                                        tlsInsecureSkipVerify)
    tlsInsecureSkipVerify = jsonBoolOpt(cfg, "tls-insecure-skip-verify",
                                        tlsInsecureSkipVerify)
    if cfg.hasKey("durability") and cfg["durability"].kind == JString:
      durability = parseDurability(cfg["durability"].getStr())

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if key == "help" and cmd.len == 0:
        help = true
      else:
        if cmd.len == 0:
          cmd = key
        positionals.add key
    of cmdLongOption:
      case key
      of "help": help = true
      of "config": configPath = val
      of "server-config": serverConfigPath = val
      of "peers": peers = val
      of "data": dataDir = val
      of "target-data": targetDataDir = val
      of "backup": backupDir = val
      of "mirror": mirrors.add val
      of "out": outPath = val
      of "in": inPath = val
      of "checkpoint": checkpointPath = val
      of "checkpoint-root": checkpointRoot = val
      of "checkpoint-id": checkpointId = val
      of "payload": payload = val
      of "codec": codecName = val
      of "charset": charset = val
      of "format-version": formatVersion = val
      of "view": view = val
      of "id": idArg = val
      of "near": nearRingBase = val
      of "subring", "subrings": subringArg = val
      of "subring-limit", "subring-limits": subringLimitArg = val
      of "subring-sort": subringSortArg = val
      of "subring-rsort": subringRsortArg = val
      of "where": whereArg = val
      of "filter": filterArg = val
      of "sort":
        sortArg = val
        if rsortArg == "time": rsortArg = ""
      of "rsort": rsortArg = val
      of "order":
        case val
        of "id-asc":
          sortArg = "id"; rsortArg = ""
        of "id-desc":
          sortArg = ""; rsortArg = "id"
        of "write-asc", "time-asc":
          sortArg = "time"; rsortArg = ""
        of "write-desc", "time-desc":
          sortArg = ""; rsortArg = "time"
        else:
          raise newException(ValueError, "order must be id-asc, id-desc, write-asc, or write-desc")
      of "pagination": paginationArg = val
      of "page": page = parseInt(val)
      of "pagelimit", "page-limit": pageLimit = parseInt(val)
      of "depth": depth = parseInt(val)
      of "branch-budget": branchBudget = parseInt(val)
      of "time-ms":
        timeMs = parseBiggestInt(val).int64
      of "from-ms":
        fromMs = parseBiggestInt(val).int64
      of "to-ms":
        toMs = parseBiggestInt(val).int64
      of "bits":
        timeOrbitBits = parseInt(val)
        timeOrbitBitsSet = true
      of "bucket-ms":
        timeOrbitBucketMs = parseBiggestInt(val).int64
        timeOrbitBucketMsSet = true
      of "phase":
        timeOrbitPhase = parseBiggestUInt(val).uint64
        timeOrbitPhaseSet = true
      of "salt":
        timeOrbitSalt = val
        timeOrbitSaltSet = true
      of "select": selection = val
      of "selection": selection = val
      of "cursor": cursor = val
      of "default-ring": defaultRing = val
      of "ring": ringName = val
      of "stellar": stellarName = val
      of "description": description = val
      of "ring-field": ringField = val
      of "ring-prefix": ringPrefix = val
      of "payload-field": payloadField = val
      of "vec-field": vecField = val
      of "overwrite": overwrite = true
      of "prune-acked": pruneAcked = true
      of "reset-checkpoint": resetCheckpoint = true
      of "readonly": readonly = true
      of "segments": verifySegments = true
      of "max-wal-bytes": maxWalBytes = parseBiggestInt(val).int64
      of "max-segment-bytes": maxSegmentBytes = parseBiggestInt(val).int64
      of "max-segment-files": maxSegmentFiles = parseInt(val)
      of "max-dead-records": maxDeadRecords = parseInt(val)
      of "max-dead-ratio": maxDeadRatio = parseFloat(val)
      of "max-segment-generation":
        maxSegmentGeneration = parseBiggestInt(val).int64
      of "stale-ratio": staleRatio = parseFloat(val)
      of "min-stale-records": minStaleRecords = parseInt(val)
      of "max-items": maxItems = parseInt(val)
      of "max-rings":
        maxRings = parseInt(val)
        maxRingsSet = true
      of "max-bytes": maintenanceMaxBytes = parseBiggestInt(val).int64
      of "max-elapsed-ms":
        maintenanceMaxElapsedMs = parseBiggestInt(val).int64
      of "execute": executeDriverInstall = true
      of "metrics": metricsFormat = true
      of "json": jsonFormat = true
      of "no-vectors": includeVectors = false
      of "user": username = val
      of "password": password = val
      of "password-file": passwordFile = val
      of "auth-token": authToken = val
      of "auth-token-file": authTokenFile = val
      of "secret-key": secretKey = val
      of "secret-key-file": secretKeyFile = val
      of "durability": durability = parseDurability(val)
      of "tls": tls = true
      of "tls-ca": tlsCaFile = val
      of "tls-server-name": tlsServerName = val
      of "tls-insecure-skip-verify": tlsInsecureSkipVerify = true
      of "passphrase": backupPassphrase = val
      of "galaxy": galaxy = val
      of "universe", "lane": universeName = val
      of "location": universeLocation = val
      of "failure-domain": failureDomain = val
      of "auth-ref": authRef = val
      of "manifest-path": driverManifestPath = val
      of "project-dir": driverProjectDir = val
      of "redis": redisEndpoint = val
      of "universe-config": universeConfig = val
      of "n": n = parseInt(val)
      of "limit": limit = parseInt(val)
      of "queries": queries = parseInt(val)
      of "budget": budget = parseInt(val)
      of "routed-budget": routedBudget = parseInt(val)
      of "rings": ringCount = parseInt(val)
      of "payload-bytes": payloadBytes = parseInt(val)
      of "batch-size": importBatchSize = parseInt(val)
      of "checkpoint-every": checkpointEvery = parseInt(val)
      of "keep": checkpointKeep = parseInt(val)
      of "retry-limit": retryLimit = parseInt(val)
      of "retry-delay-ms": retryDelayMs = parseInt(val)
      of "max-transfers": maxTransfers = parseInt(val)
      of "priority": priority = parseInt(val)
      of "snapshot-seq": snapshotSeq = parseBiggestInt(val)
      of "required-healthy":
        requiredHealthy = parseInt(val)
        requiredHealthySet = true
      else: discard
    else: discard
  if passwordFile.len > 0:
    password = readSecretFile(passwordFile, "password")
  if authTokenFile.len > 0:
    authToken = readSecretFile(authTokenFile, "auth-token")
  if secretKeyFile.len > 0:
    secretKey = readSecretFile(secretKeyFile, "secret-key")
  if username.len == 0:
    username = getEnv("KOUTEN_USER")
  if password.len == 0:
    password = getEnv("KOUTEN_PASSWORD")
  if authToken.len == 0:
    authToken = getEnv("KOUTEN_AUTH_TOKEN")
  if secretKey.len == 0:
    secretKey = getEnv("KOUTEN_SECRET_KEY")
  if help or cmd.len == 0:
    printHelp()
    quit 0
  if cmd == "get" and stellarName.len > 0:
    if ringName.len > 0 and ringName != stellarName:
      raise newException(ValueError, "--ring and --stellar cannot differ")
    ringName = stellarName
  case cmd
  of "put":
    runPut(dataDir, peers, username, password, authToken, secretKey, galaxy,
           ringName, nearRingBase, payload, inPath, codecName, tls,
           tlsCaFile, tlsServerName, tlsInsecureSkipVerify)
  of "get":
    let readFilter = effectiveFilter(filterArg, whereArg)
    runGet(dataDir, peers, username, password, authToken, secretKey, galaxy,
           idArg, readFilter, ringName, subringArg, view, selection, cursor,
           limit, page, pageLimit, depth, branchBudget, subringLimitArg,
           subringSortArg, subringRsortArg, paginationArg, sortArg, rsortArg,
           tls, tlsCaFile, tlsServerName, tlsInsecureSkipVerify)
  of "stellar":
    runStellar(dataDir, peers, username, password, authToken, secretKey, galaxy,
               positionals, stellarName, ringName, tls, tlsCaFile,
               tlsServerName, tlsInsecureSkipVerify)
  of "time-orbit":
    runTimeOrbit(dataDir, peers, username, password, authToken, secretKey,
                 galaxy, ringName, timeOrbitBits, timeOrbitBitsSet,
                 timeOrbitBucketMs, timeOrbitBucketMsSet, timeOrbitPhase,
                 timeOrbitPhaseSet, timeOrbitSalt, timeOrbitSaltSet, tls,
                 tlsCaFile, tlsServerName, tlsInsecureSkipVerify)
  of "time-put":
    runTimePut(dataDir, peers, username, password, authToken, secretKey, galaxy,
               ringName, payload, inPath, timeMs, tls, tlsCaFile,
               tlsServerName, tlsInsecureSkipVerify)
  of "time-get":
    let readFilter = effectiveFilter(filterArg, whereArg)
    runTimeGet(dataDir, peers, username, password, authToken, secretKey, galaxy,
               ringName, readFilter, view, selection, fromMs, toMs, limit,
               sortArg, rsortArg, tls, tlsCaFile, tlsServerName,
               tlsInsecureSkipVerify)
  of "query":
    let readFilter = effectiveFilter(filterArg, whereArg)
    runQuery(dataDir, peers, username, password, authToken, secretKey, galaxy,
             idArg, readFilter, ringName, selection, tls, tlsCaFile,
             tlsServerName, tlsInsecureSkipVerify)
  of "list-ring":
    runListRing(dataDir, peers, username, password, authToken, secretKey,
                galaxy, ringName, cursor, limit, tls, tlsCaFile,
                tlsServerName, tlsInsecureSkipVerify)
  of "count-ring":
    runCountRing(dataDir, peers, username, password, authToken, secretKey,
                 galaxy, ringName, tls, tlsCaFile, tlsServerName,
                 tlsInsecureSkipVerify)
  of "ring-profile":
    runRingProfile(dataDir, peers, username, password, authToken, secretKey,
                   galaxy, ringName, codecName, charset, formatVersion, tls,
                   tlsCaFile, tlsServerName, tlsInsecureSkipVerify)
  of "shell":
    runShell(dataDir, peers, username, password, authToken, secretKey, galaxy,
             tls, tlsCaFile, tlsServerName, tlsInsecureSkipVerify)
  of "demo":
    runDemo(peers, username, password, authToken, secretKey, galaxy, tls,
            tlsCaFile, tlsServerName, tlsInsecureSkipVerify)
  of "bench":
    runBench(peers, username, password, authToken, secretKey, galaxy, tls,
             tlsCaFile, tlsServerName, tlsInsecureSkipVerify, n)
  of "health":
    runHealth(peers, username, password, authToken, secretKey, galaxy, tls,
              tlsCaFile, tlsServerName, tlsInsecureSkipVerify)
  of "metrics":
    runMetrics(peers, username, password, authToken, secretKey, galaxy, tls,
               tlsCaFile, tlsServerName, tlsInsecureSkipVerify)
  of "shutdown":
    runShutdown(peers, username, password, authToken, secretKey, galaxy, tls,
                tlsCaFile, tlsServerName, tlsInsecureSkipVerify)
  of "drain":
    runDrain(peers, username, password, authToken, secretKey, galaxy, tls,
             tlsCaFile, tlsServerName, tlsInsecureSkipVerify)
  of "resume":
    runResume(peers, username, password, authToken, secretKey, galaxy, tls,
              tlsCaFile, tlsServerName, tlsInsecureSkipVerify)
  of "snapshot":
    runSnapshot(peers, username, password, authToken, secretKey, galaxy, tls,
                tlsCaFile, tlsServerName, tlsInsecureSkipVerify)
  of "rings":
    runRings(peers, username, password, authToken, secretKey, galaxy, tls,
             tlsCaFile, tlsServerName, tlsInsecureSkipVerify)
  of "atlas": runAtlas(dataDir, peers, username, password, authToken, secretKey,
                       galaxy, tls, tlsCaFile, tlsServerName,
                       tlsInsecureSkipVerify)
  of "describe-galaxy": runDescribeGalaxy(dataDir, description)
  of "describe-ring": runDescribeRing(dataDir, ringName, description)
  of "retrieve-bench":
    runRetrieveBench(peers, username, password, authToken, secretKey, galaxy,
                     tls, tlsCaFile, tlsServerName, tlsInsecureSkipVerify, n)
  of "redis-bench": runRedisBench(n, payloadBytes, redisEndpoint, peers,
                                  username, password, authToken, secretKey,
                                  galaxy, tls, tlsCaFile, tlsServerName,
                                  tlsInsecureSkipVerify)
  of "rag-bench": runRagBench(n, queries, budget, routedBudget)
  of "working-set-bench": runWorkingSetBench(n, ringCount, queries, budget)
  of "memory-pressure-bench": runMemoryPressureBench(n, ringCount, queries,
                                                     budget, payloadBytes)
  of "doctor": runDoctor(dataDir, backupDir, serverConfigPath,
                         backupPassphrase, verifySegments, metricsFormat,
                         jsonFormat, maxWalBytes, maxSegmentFiles,
                         maxItems, maxRings, maxSegmentBytes,
                         maxDeadRecords, maxDeadRatio, maxSegmentGeneration,
                         staleRatio, minStaleRecords)
  of "driver":
    let driverArgs = if positionals.len > 1: positionals[1 .. ^1] else: @[]
    runDriver(driverArgs, driverManifestPath, driverProjectDir,
              executeDriverInstall)
  of "compact": runCompact(dataDir, durability)
  of "pack-ring": runPackRing(dataDir, ringName, durability)
  of "segment-status": runSegmentStatus(dataDir, staleRatio,
                                          minStaleRecords, metricsFormat,
                                          jsonFormat)
  of "pack-recommended": runPackRecommended(dataDir, durability, staleRatio,
                                              minStaleRecords, maxRings,
                                              maxRingsSet)
  of "maintenance-plan":
    runSegmentMaintenance(dataDir, durability, staleRatio, minStaleRecords,
                          (if maxRingsSet: maxRings else: 1),
                          maintenanceMaxBytes, maintenanceMaxElapsedMs,
                          true, jsonFormat)
  of "maintenance-run":
    runSegmentMaintenance(dataDir, durability, staleRatio, minStaleRecords,
                          (if maxRingsSet: maxRings else: 1),
                          maintenanceMaxBytes, maintenanceMaxElapsedMs,
                          false, jsonFormat)
  of "maintenance-status":
    runSegmentMaintenanceStatus(dataDir, jsonFormat)
  of "checkpoint-create":
    runCheckpointCreate(dataDir, checkpointRoot, checkpointId, durability,
                        jsonFormat)
  of "checkpoint-status":
    runCheckpointStatus(checkpointPath, jsonFormat)
  of "checkpoint-verify":
    runCheckpointVerify(checkpointPath, jsonFormat)
  of "checkpoint-list":
    runCheckpointList(checkpointRoot, jsonFormat)
  of "checkpoint-clean":
    runCheckpointCleanup(checkpointRoot, checkpointKeep, jsonFormat)
  of "checkpoint-restore":
    runCheckpointRestore(checkpointPath, dataDir, overwrite, jsonFormat)
  of "locality": runLocality(dataDir, metricsFormat)
  of "backup": runBackup(dataDir, backupDir, durability)
  of "restore": runRestore(backupDir, dataDir, overwrite, durability)
  of "verify": runOperationalVerify(dataDir, backupDir, serverConfigPath,
                                    backupPassphrase, verifySegments,
                                    metricsFormat, jsonFormat,
                                    maxWalBytes, maxSegmentFiles,
                                    maxItems, maxRings, maxSegmentBytes,
                                    maxDeadRecords, maxDeadRatio,
                                    maxSegmentGeneration, staleRatio,
                                    minStaleRecords)
  of "backup-encrypted": runBackupEncrypted(dataDir, backupDir, backupPassphrase,
                                            durability)
  of "restore-encrypted": runRestoreEncrypted(backupDir, dataDir,
                                              backupPassphrase, overwrite,
                                              durability)
  of "recovery-backup":
    let recoveryConfig = recoveryUniversesFromInputs(mirrors, universeConfig,
                                                    universeName, galaxy,
                                                    universeLocation,
                                                    failureDomain, authRef, priority,
                                                    snapshotSeq, readonly)
    runRecoveryBackup(dataDir, recoveryConfig.universes, backupPassphrase)
  of "recovery-verify":
    let mirror = if mirrors.len > 0: mirrors[0] else: backupDir
    runRecoveryVerify(mirror, backupPassphrase, metricsFormat)
  of "recovery-status":
    let recoveryConfig = recoveryUniversesFromInputs(mirrors, universeConfig,
                                                    universeName, galaxy,
                                                    universeLocation,
                                                    failureDomain, authRef, priority,
                                                    snapshotSeq, readonly)
    let needed =
      if requiredHealthySet: requiredHealthy
      elif recoveryConfig.requiredHealthy > 0: recoveryConfig.requiredHealthy
      else: requiredHealthy
    runRecoveryStatus(recoveryArchives(recoveryConfig.universes), backupPassphrase,
                      needed, metricsFormat)
  of "recovery-restore":
    let recoveryConfig = recoveryUniversesFromInputs(mirrors, universeConfig,
                                                    universeName, galaxy,
                                                    universeLocation,
                                                    failureDomain, authRef, priority,
                                                    snapshotSeq, readonly)
    runRecoveryRestore(recoveryArchives(recoveryConfig.universes), dataDir,
                       backupPassphrase, overwrite, durability)
  of "dump": runDump(dataDir, outPath, includeVectors)
  of "import-jsonl": runImportJsonl(dataDir, inPath, defaultRing, ringField,
                                    ringPrefix, payloadField, vecField, n,
                                    importBatchSize)
  of "scale-in-plan":
    runScaleInPlan(dataDir, peers, username, password, authToken, secretKey,
                   galaxy, tls, tlsCaFile, tlsServerName,
                   tlsInsecureSkipVerify, jsonFormat)
  of "scale-in-migrate":
    runScaleInMigrate(dataDir, peers, username, password, authToken, secretKey,
                      galaxy, checkpointPath, checkpointEvery, retryLimit,
                      retryDelayMs, maxTransfers, resetCheckpoint, tls, tlsCaFile,
                      tlsServerName, tlsInsecureSkipVerify, jsonFormat)
  of "scale-in-verify":
    runScaleInVerify(dataDir, peers, username, password, authToken, secretKey,
                     galaxy, checkpointPath, retryLimit, retryDelayMs, tls,
                     tlsCaFile, tlsServerName, tlsInsecureSkipVerify,
                     jsonFormat)
  of "scale-in-status":
    runScaleInStatus(checkpointPath, jsonFormat)
  of "universe-export": runUniverseExport(dataDir, outPath)
  of "universe-apply": runUniverseApply(dataDir, inPath)
  of "universe-sync":
    if targetDataDir.len > 0:
      runUniverseSync(dataDir, targetDataDir, pruneAcked)
    else:
      runUniverseSyncRemote(dataDir, peers, username, password, authToken,
                            secretKey, galaxy, pruneAcked, tls, tlsCaFile,
                            tlsServerName, tlsInsecureSkipVerify)
  of "universe-status":
    runUniverseStatus(dataDir, peers, username, password, authToken, secretKey,
                      galaxy, metricsFormat, tls, tlsCaFile, tlsServerName,
                      tlsInsecureSkipVerify)
  else:
    printHelp()
    quit(1)

when isMainModule:
  try:
    main()
  except CatchableError as e:
    stderr.writeLine("error: " & e.msg)
    quit(1)
