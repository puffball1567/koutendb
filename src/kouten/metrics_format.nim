## Stable operational-metrics formatting shared by the Nim API, CLI, and C ABI.
## The legacy key/value lines remain the source contract. This module adds
## bounded Prometheus/OpenMetrics projections without introducing ring labels.

import std/[sets, strutils, tables]

type
  KoutenMetricsFormat* = enum
    kmfKeyValue
    kmfPrometheus
    kmfOpenMetrics

const CounterKeys = [
  "requests", "errors", "authFailures", "authzDenied",
  "drainRejectedWrites", "connectionsAccepted", "tombstonesReclaimed",
  "handoffQueued", "handoffApplied", "handoffFailed", "handoffStaleAck",
  "handoffQueueFull", "universeApplyApplied", "universeApplySkipped",
  "universeApplyErrors", "universeApplyForwarded", "retrieveRequests",
  "retrieveScopedRequests", "retrieveGlobalRequests",
  "retrievePhysicalVisited", "retrieveCandidatesScored",
  "autoPackAttempts", "autoPackCompleted", "autoPackPartial",
  "autoPackInterrupted", "autoPackFailed", "autoPackNoWork",
  "autoPackRings", "autoPackBytes", "clusterTxCommitted",
  "clusterTxApplied", "segmentHits", "segmentWalFallbacks",
  "segmentWalFallbackPointRead", "segmentWalFallbackRingScan",
  "segmentWalFallbackWindowRead", "guardrailDeniedPayloadBytes",
  "guardrailDeniedVectorDim", "guardrailDeniedRingCount",
  "guardrailDeniedRecordsPerRing"
]

proc parseKoutenMetricsFormat*(value: string): KoutenMetricsFormat =
  case value.toLowerAscii()
  of "key-value", "keyvalue", "kv": kmfKeyValue
  of "prometheus", "prom": kmfPrometheus
  of "openmetrics", "open-metrics": kmfOpenMetrics
  else:
    raise newException(ValueError,
      "metrics format must be key-value, prometheus, or openmetrics")

proc snakeCase(value: string): string =
  for i, ch in value:
    if ch in {'A'..'Z'}:
      if i > 0:
        result.add '_'
      result.add ch.toLowerAscii()
    elif ch in {'a'..'z', '0'..'9', '_'}:
      result.add ch
    else:
      result.add '_'

proc metricName(key: string): string =
  result = "koutendb_" & snakeCase(key)
  if result.endsWith("_sec"):
    result.setLen(result.len - 4)
    result.add "_seconds"
  elif result.endsWith("_ms"):
    result.setLen(result.len - 3)
    result.add "_milliseconds"
  if key in CounterKeys and not result.endsWith("_total"):
    result.add "_total"

proc escapeLabel(value: string): string =
  value.replace("\\", "\\\\").replace("\n", "\\n").replace("\"", "\\\"")

proc specialMetric(key: string): tuple[name, labelName, labelValue: string] =
  case key
  of "segmentWalFallbackPointRead":
    ("koutendb_segment_wal_fallback_reasons_total", "reason", "point-read-failed")
  of "segmentWalFallbackRingScan":
    ("koutendb_segment_wal_fallback_reasons_total", "reason", "ring-scan-failed")
  of "segmentWalFallbackWindowRead":
    ("koutendb_segment_wal_fallback_reasons_total", "reason", "window-read-failed")
  of "guardrailDeniedPayloadBytes":
    ("koutendb_guardrail_rejections_total", "reason", "payload-bytes")
  of "guardrailDeniedVectorDim":
    ("koutendb_guardrail_rejections_total", "reason", "vector-dimension")
  of "guardrailDeniedRingCount":
    ("koutendb_guardrail_rejections_total", "reason", "ring-count")
  of "guardrailDeniedRecordsPerRing":
    ("koutendb_guardrail_rejections_total", "reason", "records-per-ring")
  else:
    (metricName(key), "", "")

proc formatMetricLines*(lines: openArray[string],
                        format: KoutenMetricsFormat): string =
  if format == kmfKeyValue:
    return lines.join("\n")

  var seenFamilies = initHashSet[string]()
  for line in lines:
    let fields = line.splitWhitespace()
    if fields.len == 0:
      continue
    if fields.len mod 2 != 0:
      raise newException(ValueError, "invalid KoutenDB metrics key/value line")
    var values = initOrderedTable[string, string]()
    var i = 0
    while i < fields.len:
      values[fields[i]] = fields[i + 1]
      inc i, 2
    let node = values.getOrDefault("node", "0")
    for key, value in values:
      if key == "node":
        continue
      # Reject malformed server output instead of producing an invalid scrape.
      try:
        discard parseFloat(value)
      except ValueError:
        raise newException(ValueError,
          "non-numeric KoutenDB metric " & key & ": " & value)
      let special = specialMetric(key)
      let kind = if key in CounterKeys: "counter" else: "gauge"
      if special.name notin seenFamilies:
        result.add "# HELP " & special.name &
          " KoutenDB operational metric.\n"
        result.add "# TYPE " & special.name & " " & kind & "\n"
        seenFamilies.incl special.name
      result.add special.name & "{node=\"" & escapeLabel(node) & "\""
      if special.labelName.len > 0:
        result.add "," & special.labelName & "=\"" &
          escapeLabel(special.labelValue) & "\""
      result.add "} " & value & "\n"
  if format == kmfOpenMetrics:
    result.add "# EOF\n"
