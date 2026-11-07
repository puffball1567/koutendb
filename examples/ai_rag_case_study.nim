## AI/RAG case study over a generated JSONL corpus.
##
## The shell wrapper generates a deterministic corpus, then this program imports
## it through KoutenDB's JSONL import path and measures global vs routed retrieve.

import std/[json, parseopt, strformat, strutils, tables]
import ../src/koutendb

type
  QueryCase = object
    name: string
    ring: string
    wrongRing: string
    targetId: string
    vec: seq[float32]

  Aggregate = object
    recall: int
    scanned: int
    tokens: int

proc hasTarget(hits: seq[KoutenHit], targetId: string): bool =
  for hit in hits:
    try:
      let doc = parseJson(hit.payload)
      if doc{"id"}.getStr() == targetId:
        return true
    except CatchableError:
      discard

proc addRun(agg: var Aggregate, rr: tuple[hits: seq[KoutenHit], stats: RetrieveStats,
                                         plan: RetrievalPlan], targetId: string) =
  if rr.hits.hasTarget(targetId):
    inc agg.recall
  agg.scanned += rr.stats.scanned
  agg.tokens += rr.stats.estimatedTokens

proc vec(values: openArray[float32]): seq[float32] =
  for value in values:
    result.add value

proc exportPrompt(output: File, q: QueryCase, variant: string,
                  hits: seq[KoutenHit], scanned, budget: int) =
  var prompt = "Answer using the supplied references.\nQuestion: " & q.name & "\nReferences:\n"
  for hit in hits:
    let doc = parseJson(hit.payload)
    prompt.add doc{"title"}.getStr() & "\n" & doc{"text"}.getStr() & "\n"
  prompt.add "Answer:"
  output.writeLine($(%*{
    "query": q.name, "variant": variant, "prompt": prompt,
    "target_recalled": hits.hasTarget(q.targetId),
    "scanned": scanned, "budget": budget, "returned": hits.len
  }))

proc main() =
  var corpus = ""
  var dataDir = ""
  var globalBudget = 8
  var routedBudget = 3
  var exportPath = ""

  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "corpus": corpus = val
      of "data": dataDir = val
      of "global-budget": globalBudget = parseInt(val)
      of "routed-budget": routedBudget = parseInt(val)
      of "export-prompts": exportPath = val
      else: discard
    of cmdArgument:
      discard
    of cmdShortOption:
      discard
    of cmdEnd:
      discard

  if corpus.len == 0 or dataDir.len == 0:
    raise newException(ValueError,
      "usage: ai_rag_case_study --corpus=FILE --data=DIR [--global-budget=N] [--routed-budget=N] [--export-prompts=FILE]")

  var promptOutput: File
  if exportPath.len > 0:
    promptOutput = open(exportPath, fmWrite)
  defer:
    if exportPath.len > 0:
      promptOutput.close()

  var db = open(dataDir = dataDir)
  defer: db.close()

  db.setGalaxyDescription("Generated AI/RAG case-study corpus")
  db.setRingDescription("docs/japan", "Japanese product and support documentation")
  db.setRingDescription("docs/us", "US product and support documentation")
  db.setRingDescription("support/errors", "Operational incident and error runbooks")
  db.setRingDescription("papers/medicine", "Biomedical and clinical research notes")
  db.setRingDescription("papers/water", "Water treatment and purification research notes")
  db.setRingDescription("noise/general", "General background documents that should usually be skipped")

  let stats = db.importJsonl(corpus, defaultRing = "noise/general",
                             ringField = "ring",
                             payloadField = "body",
                             vecField = "embedding")

  let queries = @[
    QueryCase(name: "japanese refund support",
              ring: "docs/japan",
              wrongRing: "papers/water",
              targetId: "docs-japan-000",
              vec: vec([1.0'f32, 0.02, 0.01, 0.0, 0.0, 0.0])),
    QueryCase(name: "us enterprise onboarding",
              ring: "docs/us",
              wrongRing: "papers/medicine",
              targetId: "docs-us-000",
              vec: vec([0.01'f32, 1.0, 0.02, 0.0, 0.0, 0.0])),
    QueryCase(name: "database timeout incident",
              ring: "support/errors",
              wrongRing: "docs/japan",
              targetId: "support-errors-000",
              vec: vec([0.0'f32, 0.02, 1.0, 0.02, 0.0, 0.0])),
    QueryCase(name: "clinical trial safety",
              ring: "papers/medicine",
              wrongRing: "docs/us",
              targetId: "papers-medicine-000",
              vec: vec([0.0'f32, 0.0, 0.02, 1.0, 0.01, 0.0])),
    QueryCase(name: "membrane filtration",
              ring: "papers/water",
              wrongRing: "support/errors",
              targetId: "papers-water-000",
              vec: vec([0.0'f32, 0.0, 0.0, 0.01, 1.0, 0.02]))
  ]

  var globalAgg, routedAgg, wrongAgg: Aggregate
  var ringCounts = initTable[string, int]()
  for line in lines(corpus):
    let node = parseJson(line)
    let ring = node{"ring"}.getStr("noise/general")
    ringCounts[ring] = ringCounts.getOrDefault(ring, 0) + 1

  echo "== KoutenDB AI/RAG case study =="
  echo &"corpus={corpus}"
  echo &"import read={stats.read} imported={stats.imported} skipped={stats.skipped} errors={stats.errors} rings={stats.rings}"
  echo &"globalBudget={globalBudget} routedBudget={routedBudget}"
  echo ""
  echo "rings:"
  for ring, count in ringCounts:
    echo &"  {ring:<18} docs={count}"
  echo ""
  echo "queries:"

  for q in queries:
    let global = db.retrieveWithStats(q.vec, budget = globalBudget)
    let routed = db.retrieveWithStats(q.vec, ring = q.ring, budget = routedBudget)
    let wrong = db.retrieveWithStats(q.vec, ring = q.wrongRing, budget = routedBudget)
    if exportPath.len > 0:
      let sameBudget = db.retrieveWithStats(q.vec, budget = routedBudget)
      promptOutput.exportPrompt(q, "global", global.hits, global.stats.scanned, globalBudget)
      promptOutput.exportPrompt(q, "routed", routed.hits, routed.stats.scanned, routedBudget)
      promptOutput.exportPrompt(q, "global_same_budget", sameBudget.hits,
                                sameBudget.stats.scanned, routedBudget)
      promptOutput.exportPrompt(q, "wrong_ring", wrong.hits, wrong.stats.scanned, routedBudget)
    globalAgg.addRun(global, q.targetId)
    routedAgg.addRun(routed, q.targetId)
    wrongAgg.addRun(wrong, q.targetId)
    echo &"  {q.name:<28} target={q.targetId}"
    echo &"    global scanned={global.stats.scanned:4}/{global.stats.totalVectors:<4} tokens~={global.stats.estimatedTokens:<4} hit={global.hits.hasTarget(q.targetId)}"
    echo &"    routed scanned={routed.stats.scanned:4}/{routed.stats.totalVectors:<4} tokens~={routed.stats.estimatedTokens:<4} hit={routed.hits.hasTarget(q.targetId)} ring={q.ring}"
    echo &"    wrong  scanned={wrong.stats.scanned:4}/{wrong.stats.totalVectors:<4} tokens~={wrong.stats.estimatedTokens:<4} hit={wrong.hits.hasTarget(q.targetId)} ring={q.wrongRing}"

  let qn = queries.len
  echo ""
  echo "summary:"
  echo &"  global recall={float(globalAgg.recall)/float(qn):.3f} scanned/query={float(globalAgg.scanned)/float(qn):.1f} tokens/query~={float(globalAgg.tokens)/float(qn):.1f}"
  echo &"  routed recall={float(routedAgg.recall)/float(qn):.3f} scanned/query={float(routedAgg.scanned)/float(qn):.1f} tokens/query~={float(routedAgg.tokens)/float(qn):.1f}"
  echo &"  wrong  recall={float(wrongAgg.recall)/float(qn):.3f} scanned/query={float(wrongAgg.scanned)/float(qn):.1f} tokens/query~={float(wrongAgg.tokens)/float(qn):.1f}"
  if routedAgg.scanned > 0:
    echo &"  scanned reduction vs global={100.0 * (1.0 - float(routedAgg.scanned) / float(globalAgg.scanned)):.1f}%"
  if routedAgg.tokens > 0:
    echo &"  token reduction vs global={100.0 * (1.0 - float(routedAgg.tokens) / float(globalAgg.tokens)):.1f}%"

when isMainModule:
  main()
