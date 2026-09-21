import std/[algorithm, asyncdispatch, json, math, os, strutils, times]

import jazzy
import koutendb

const DefaultRing = "demo/tasks"
const Categories = ["general", "planning", "engineering", "research", "operations"]

var
  ring {.threadvar.}: string
  db {.threadvar.}: KoutenDb

type HttpInputError = object of CatchableError
type RelatedCandidate = object
  task: JsonNode
  score: int

proc rawId(id: KoutenId): string =
  let value = id.toRaw()
  $value.parent & "_" & $value.epoch & "_" & $value.seq & "_" & $value.tWrite

proc parseId(value: string): KoutenId =
  let parts = value.split('_')
  if parts.len != 4:
    raise newException(HttpInputError,
      "invalid KoutenDB id: expected parent_epoch_seq_tWrite")
  try:
    let parent = parseBiggestUInt(parts[0]).uint64
    let epoch = parseBiggestUInt(parts[1])
    let sequence = parseBiggestUInt(parts[2])
    let timestamp = parseFloat(parts[3])
    if epoch > uint64(high(uint32)) or sequence > uint64(high(uint32)) or
        classify(timestamp) in {fcNan, fcInf, fcNegInf} or timestamp < 0:
      raise newException(ValueError, "invalid id fields")
    result = fromRaw(parent, uint32(epoch), uint32(sequence), timestamp)
  except ValueError:
    raise newException(HttpInputError, "invalid KoutenDB id")

proc nowIso(): string =
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")

proc bodyObject(ctx: Context): JsonNode =
  if ctx.request.body.len > 65536:
    raise newException(HttpInputError, "request body exceeds 64 KiB")
  try:
    result = parseJson(ctx.request.body)
  except JsonParsingError:
    raise newException(HttpInputError, "request body must be valid JSON")
  if result.kind != JObject:
    raise newException(HttpInputError, "request body must be a JSON object")

proc titleFrom(body: JsonNode): string =
  if not body.hasKey("title") or body["title"].kind != JString:
    raise newException(HttpInputError, "title must be a string")
  result = body["title"].getStr().strip()
  if result.len == 0 or result.len > 120:
    raise newException(HttpInputError,
      "title must contain 1 to 120 UTF-8 bytes")

proc completedFrom(body: JsonNode; fallback: bool): bool =
  if not body.hasKey("completed"):
    return fallback
  if body["completed"].kind != JBool:
    raise newException(HttpInputError, "completed must be a boolean")
  body["completed"].getBool()

proc categoryValid(value: string): bool =
  for category in Categories:
    if value == category:
      return true

proc categoryFrom(body: JsonNode; fallback: string): string =
  if not body.hasKey("category"):
    return fallback
  if body["category"].kind != JString or not categoryValid(body["category"].getStr()):
    raise newException(HttpInputError,
      "category must be one of: " & Categories.join(", "))
  body["category"].getStr()

proc validTag(value: string): bool =
  if value.len == 0 or value.len > 24 or not value[0].isAlphaNumeric():
    return false
  for ch in value:
    if not (ch in {'a'..'z', '0'..'9', '-'}):
      return false
  true

proc tagsFrom(body: JsonNode; fallback: seq[string] = @[]): seq[string] =
  if not body.hasKey("tags"):
    return fallback
  let source = body["tags"]
  if source.kind != JArray:
    raise newException(HttpInputError, "tags must be an array")
  if source.len > 6:
    raise newException(HttpInputError, "tags must contain at most 6 values")
  for item in source:
    if item.kind != JString:
      raise newException(HttpInputError, "each tag must be a string")
    let tag = item.getStr().strip().toLowerAscii()
    if not validTag(tag):
      raise newException(HttpInputError,
        "tags must use 1 to 24 lowercase letters, numbers, or hyphens")
    if tag notin result:
      result.add tag

proc tagsNode(tags: seq[string]): JsonNode =
  result = newJArray()
  for tag in tags:
    result.add %tag

proc categoryRing(category: string): string =
  if category == "general": ring else: ring & "/" & category

proc taskPayload(title: string; completed: bool; category: string;
                 tags: seq[string]; createdAt, updatedAt: string): JsonNode =
  %*{
    "title": title,
    "completed": completed,
    "category": category,
    "tags": tagsNode(tags),
    "createdAt": createdAt,
    "updatedAt": updatedAt
  }

proc taskNode(id: string; payload: string; fallbackCategory = "general"): JsonNode =
  result = parseJson(payload)
  if result.kind != JObject:
    raise newException(ValueError, "task payload is not a JSON object")
  if not result.hasKey("category") or result["category"].kind != JString or
      not categoryValid(result["category"].getStr()):
    result["category"] = %fallbackCategory
  if not result.hasKey("tags") or result["tags"].kind != JArray:
    result["tags"] = newJArray()
  result["id"] = %id

proc taskTags(task: JsonNode): seq[string] =
  if task.hasKey("tags") and task["tags"].kind == JArray:
    for item in task["tags"]:
      if item.kind == JString:
        result.add item.getStr()

proc sharedTags(left, right: JsonNode): seq[string] =
  let rightTags = taskTags(right)
  for tag in taskTags(left):
    if tag in rightTags:
      result.add tag

# Each synchronous DB call uses the handle owned by this request and worker.
proc readTasksPage(category: string): KoutenReadPage {.gcsafe.} =
  {.cast(gcsafe).}:
    result = db.readRing(categoryRing(category), KoutenReadOptions(
      filter: newJObject(),
      limit: 500,
      sortField: "time",
      sortDirection: rsDesc))

proc getPayload(id: KoutenId): string {.gcsafe.} =
  {.cast(gcsafe).}:
    result = db.get(id)

proc putPayload(payload: JsonNode; targetRing: string): KoutenId {.gcsafe.} =
  {.cast(gcsafe).}:
    result = db.put(payload, targetRing)

proc updatePayload(id: KoutenId; payload: JsonNode) {.gcsafe.} =
  {.cast(gcsafe).}:
    db.update(id, payload)

proc payloadExists(id: KoutenId): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = db.exists(id)

proc removePayload(id: KoutenId) {.gcsafe.} =
  {.cast(gcsafe).}:
    db.remove(id)

proc openRequestDb() {.gcsafe.} =
  {.cast(gcsafe).}:
    ring = getEnv("KOUTEN_RING", DefaultRing)
    db = koutendb.connect(
      getEnv("KOUTEN_PEERS", "127.0.0.1:7301"),
      username = getEnv("KOUTEN_USER", "demo"),
      password = getEnv("KOUTEN_PASSWORD", "demo-password"),
      secretKey = getEnv("KOUTEN_SECRET_KEY", "demo-secret-key"),
      galaxy = getEnv("KOUTEN_GALAXY", "jazzy-demo"),
      tls = getEnv("KOUTEN_TLS", "false") == "true",
      tlsCaFile = getEnv("KOUTEN_TLS_CA_FILE"),
      tlsServerName = getEnv("KOUTEN_TLS_SERVER_NAME"))
    db.configureWriteAckMode(wamApplied)
    # ID reads need the named-ring metadata on each fresh Nim client handle.
    for category in Categories:
      db.configureRingWriteAckMode(categoryRing(category), wamApplied)

proc closeRequestDb() {.gcsafe.} =
  {.cast(gcsafe).}:
    if db != nil:
      db.close()
      db = nil

template handleApi(body: untyped) =
  try:
    openRequestDb()
    body
  except HttpInputError as error:
    ctx.status(400).json(%*{"error": error.msg})
  except KeyError:
    ctx.status(404).json(%*{"error": "task not found"})
  except CatchableError:
    # Do not send database/authentication exception text to HTTP clients or logs.
    ctx.status(503).json(%*{"error": "database operation unavailable"})
  finally:
    closeRequestDb()

proc healthRoute(ctx: Context) {.async, gcsafe.} =
  handleApi:
    var statuses: seq[string]
    {.cast(gcsafe).}:
      statuses = db.health()
    ctx.json(%*{"status": "ok", "stack": "Jazzy", "ring": ring,
                "nodes": statuses})

proc metaRoute(ctx: Context) {.async, gcsafe.} =
  ring = getEnv("KOUTEN_RING", DefaultRing)
  var values = newJArray()
  for category in Categories:
    values.add %category
  ctx.json(%*{"ring": ring, "categories": values})

proc listTasks(ctx: Context) {.async, gcsafe.} =
  handleApi:
    var items = newJArray()
    for category in Categories:
      let page = readTasksPage(category)
      for item in page.items:
        items.add taskNode(rawId(item.id), item.payload, category)
    ctx.json(%*{"items": items, "count": items.len})

proc relatedTasks(ctx: Context) {.async, gcsafe.} =
  handleApi:
    let
      idText = ctx.param("id")
      current = taskNode(idText, getPayload(parseId(idText)))
      category = current{"category"}.getStr("general")
      page = readTasksPage(category)
    var candidates: seq[RelatedCandidate]
    for item in page.items:
      let candidate = taskNode(rawId(item.id), item.payload, category)
      if candidate{"id"}.getStr() == idText:
        continue
      candidates.add RelatedCandidate(
        task: candidate,
        score: sharedTags(current, candidate).len)
    candidates.sort(proc(left, right: RelatedCandidate): int =
      result = cmp(right.score, left.score)
      if result == 0:
        result = cmp(right.task{"updatedAt"}.getStr(),
                     left.task{"updatedAt"}.getStr()))
    var related = newJArray()
    for i in 0 ..< min(6, candidates.len):
      let shared = sharedTags(current, candidates[i].task)
      var node = candidates[i].task.copy()
      node["sharedTags"] = tagsNode(shared)
      node["score"] = %shared.len
      related.add node
    ctx.json(%*{
      "task": current,
      "scope": {
        "ring": categoryRing(category),
        "candidates": candidates.len,
        "categoriesScanned": 1
      },
      "items": related
    })

proc getTask(ctx: Context) {.async, gcsafe.} =
  handleApi:
    let idText = ctx.param("id")
    ctx.json(taskNode(idText, getPayload(parseId(idText))))

proc createTask(ctx: Context) {.async, gcsafe.} =
  handleApi:
    let
      body = bodyObject(ctx)
      timestamp = nowIso()
      category = categoryFrom(body, "general")
      payload = taskPayload(titleFrom(body), completedFrom(body, false), category,
                            tagsFrom(body),
                            timestamp, timestamp)
      id = putPayload(payload, categoryRing(category))
    ctx.status(201).json(taskNode(rawId(id), $payload))

proc updateTask(ctx: Context) {.async, gcsafe.} =
  handleApi:
    let
      idText = ctx.param("id")
      id = parseId(idText)
      current = taskNode(idText, getPayload(id))
      body = bodyObject(ctx)
      currentCategory = current{"category"}.getStr("general")
      category = categoryFrom(body, currentCategory)
      payload = taskPayload(
        titleFrom(body),
        completedFrom(body, current{"completed"}.getBool(false)),
        category,
        tagsFrom(body, taskTags(current)),
        current{"createdAt"}.getStr(nowIso()),
        nowIso())
    var responseId = idText
    if category == currentCategory:
      updatePayload(id, payload)
    else:
      let relocated = putPayload(payload, categoryRing(category))
      removePayload(id)
      responseId = rawId(relocated)
    ctx.json(taskNode(responseId, $payload))

proc deleteTask(ctx: Context) {.async, gcsafe.} =
  handleApi:
    let id = parseId(ctx.param("id"))
    if not payloadExists(id):
      raise newException(KeyError, "task not found")
    removePayload(id)
    ctx.status(204).text("")

proc main() =
  let port = parseInt(getEnv("PORT", "3000"))
  if port notin 1..65535:
    raise newException(ValueError, "PORT must be in 1..65535")
  # Jazzy initializes SQL at startup even when handlers never use it.
  # Keep that unused subsystem in memory; task data belongs only to KoutenDB.
  connectDB(":memory:")
  Route.get("/health", healthRoute)
  Route.get("/meta", metaRoute)
  Route.get("/tasks", listTasks)
  Route.get("/tasks/:id/related", relatedTasks)
  Route.get("/tasks/:id", getTask)
  Route.post("/tasks", createTask)
  Route.put("/tasks/:id", updateTask)
  Route.delete("/tasks/:id", deleteTask)
  Jazzy.serve(port, getEnv("BIND_ADDRESS", "127.0.0.1"))

when isMainModule:
  main()
