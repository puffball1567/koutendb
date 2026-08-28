import std/[algorithm, asyncdispatch, json, net, os, strutils, times]

import prologue
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
    result = fromRaw(
      parseBiggestUInt(parts[0]).uint64,
      parseUInt(parts[1]).uint32,
      parseUInt(parts[2]).uint32,
      parseFloat(parts[3]))
  except ValueError:
    raise newException(HttpInputError, "invalid KoutenDB id")

proc nowIso(): string =
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")

proc bodyObject(ctx: Context): JsonNode =
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
      "title must contain 1 to 120 characters")

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

proc errorResponse(message: string; code: HttpCode): Response =
  jsonResponse(%*{"error": message}, code)

# Prologue runs this demo on one stdlib event-loop thread. Keep the explicit
# GC-safety boundary limited to calls through that thread-owned DB handle.
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

template handleApi(body: untyped) =
  try:
    body
  except HttpInputError as error:
    resp errorResponse(error.msg, Http400)
  except KeyError:
    resp errorResponse("task not found", Http404)
  except CatchableError as error:
    echo "PRK API error: ", error.msg
    resp errorResponse("internal server error", Http500)

proc healthRoute(ctx: Context) {.async, gcsafe.} =
  resp jsonResponse(%*{"status": "ok", "stack": "PRK", "ring": ring})

proc metaRoute(ctx: Context) {.async, gcsafe.} =
  var values = newJArray()
  for category in Categories:
    values.add %category
  resp jsonResponse(%*{"ring": ring, "categories": values})

proc listTasks(ctx: Context) {.async, gcsafe.} =
  handleApi:
    var items = newJArray()
    for category in Categories:
      let page = readTasksPage(category)
      for item in page.items:
        items.add taskNode(rawId(item.id), item.payload, category)
    resp jsonResponse(%*{"items": items, "count": items.len})

proc relatedTasks(ctx: Context) {.async, gcsafe.} =
  handleApi:
    let
      idText = ctx.getPathParams("id", "")
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
    resp jsonResponse(%*{
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
    let idText = ctx.getPathParams("id", "")
    resp jsonResponse(taskNode(idText, getPayload(parseId(idText))))

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
    resp jsonResponse(taskNode(rawId(id), $payload), Http201)

proc updateTask(ctx: Context) {.async, gcsafe.} =
  handleApi:
    let
      idText = ctx.getPathParams("id", "")
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
    resp jsonResponse(taskNode(responseId, $payload))

proc deleteTask(ctx: Context) {.async, gcsafe.} =
  handleApi:
    let id = parseId(ctx.getPathParams("id", ""))
    if not payloadExists(id):
      raise newException(KeyError, "task not found")
    removePayload(id)
    resp "", Http204

proc main() =
  ring = getEnv("KOUTEN_RING", DefaultRing)
  db = connect(
    getEnv("KOUTEN_PEERS", "koutendb:7301"),
    username = getEnv("KOUTEN_USER", "demo"),
    password = getEnv("KOUTEN_PASSWORD", "demo-password"),
    secretKey = getEnv("KOUTEN_SECRET_KEY", "demo-secret-key"),
    galaxy = getEnv("KOUTEN_GALAXY", "prk-demo"))
  db.configureWriteAckMode(wamApplied)

  let port = block:
    try:
      Port(parseInt(getEnv("PORT", "3000")))
    except ValueError:
      raise newException(ValueError, "PORT must be an integer in 1..65535")
  let settings = newSettings(
    address = "0.0.0.0",
    port = port,
    debug = false,
    appName = "KoutenDB PRK CRUD")

  var app = newApp(settings = settings)
  app.get("/health", healthRoute)
  app.get("/meta", metaRoute)
  app.get("/tasks", listTasks)
  app.get("/tasks/{id}/related", relatedTasks)
  app.get("/tasks/{id}", getTask)
  app.post("/tasks", createTask)
  app.addRoute("/tasks/{id}", updateTask, HttpPut)
  app.delete("/tasks/{id}", deleteTask)

  echo "PRK API listening on ", int(port), "; KoutenDB ring=", ring
  app.run()
  db.close()

when isMainModule:
  main()
