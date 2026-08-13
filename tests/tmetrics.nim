import std/[os, strutils, tempfiles, unittest]
import ../src/koutendb
import ../src/kouten/store as koutenStore

suite "operational metrics":
  test "format parser accepts documented names and rejects unknown formats":
    check parseKoutenMetricsFormat("key-value") == kmfKeyValue
    check parseKoutenMetricsFormat("prometheus") == kmfPrometheus
    check parseKoutenMetricsFormat("openmetrics") == kmfOpenMetrics
    expect ValueError:
      discard parseKoutenMetricsFormat("json")

  test "Prometheus output is deterministic bounded and typed":
    let lines = @[
      "node 0 requests 12 connectionsRejected 1 items 3 segmentWalFallbacks 2 " &
        "segmentWalFallbackPointRead 1 segmentWalFallbackRingScan 1",
      "node 1 requests 7 items 4 segmentWalFallbacks 0 " &
        "segmentWalFallbackPointRead 0 segmentWalFallbackRingScan 0"
    ]
    let output = formatMetricLines(lines, kmfPrometheus)
    check output.contains("# TYPE koutendb_requests_total counter")
    check output.contains("koutendb_requests_total{node=\"0\"} 12")
    check output.contains(
      "# TYPE koutendb_connections_rejected_total counter")
    check output.contains(
      "koutendb_connections_rejected_total{node=\"0\"} 1")
    check output.contains("koutendb_items{node=\"1\"} 4")
    check output.contains(
      "koutendb_segment_wal_fallback_reasons_total{node=\"0\"," &
      "reason=\"point-read-failed\"} 1")
    check output.count("# TYPE koutendb_requests_total counter") == 1
    check not output.contains("ring=\"")
    check not output.endsWith("# EOF\n")

  test "OpenMetrics terminates with EOF and malformed input fails closed":
    let output = formatMetricLines(@[
      "node 0 uptimeSec 12 autoPackLastElapsedMs 3.5 items 1"
    ], kmfOpenMetrics)
    check output.contains("koutendb_uptime_seconds{node=\"0\"} 12")
    check output.contains(
      "koutendb_auto_pack_last_elapsed_milliseconds{node=\"0\"} 3.5")
    check output.endsWith("# EOF\n")
    expect ValueError:
      discard formatMetricLines(@["node 0 items"], kmfPrometheus)
    expect ValueError:
      discard formatMetricLines(@["node 0 items nope"], kmfPrometheus)

  test "checkpoint reason codes use a bounded stable vocabulary":
    let cases = [
      ("verified", "verified"),
      ("checkpoint manifest is missing", "manifest-missing"),
      ("checkpoint completion marker is missing", "completion-marker-missing"),
      ("checkpoint manifest checksum mismatch", "manifest-checksum-mismatch"),
      ("unsupported checkpoint manifest format", "unsupported-format"),
      ("invalid checkpoint identity", "invalid-identity"),
      ("invalid checkpoint creation time", "invalid-created-at"),
      ("invalid checkpoint WAL bounds", "invalid-wal-bounds"),
      ("checkpoint stats are missing", "logical-stats-invalid"),
      ("checkpoint file inventory is missing", "inventory-missing"),
      ("invalid checkpoint file metadata: x", "inventory-invalid"),
      ("checkpoint file is missing: x", "file-missing"),
      ("checkpoint file size mismatch: x", "file-size-mismatch"),
      ("checkpoint checksum mismatch: x", "file-checksum-mismatch"),
      ("checkpoint segment index validation failed", "segment-index-invalid"),
      ("checkpoint segment coverage is incomplete",
       "segment-coverage-incomplete"),
      ("checkpoint segment does not match WAL revision",
       "segment-revision-mismatch"),
      ("checkpoint contains an unreferenced segment file: x",
       "unreferenced-file"),
      ("unexpected parser failure", "verification-failed")
    ]
    for (message, code) in cases:
      check koutenStore.checkpointReasonCode(message) == code

  test "Nim API preserves key-value output and reports guardrail reasons":
    var db = open()
    discard db.put("ok", ring = "users/123")
    db.configureGuardrails(KoutenGuardrails(maxPayloadBytes: 2))
    expect KoutenGuardrailError:
      discard db.put("too-large", ring = "users/123")
    let legacy = db.metrics()
    check formatMetricLines(legacy, kmfKeyValue) == legacy.join("\n")
    let output = db.metricsText(kmfPrometheus)
    check output.contains("koutendb_guardrail_rejections_total{node=\"0\"," &
                          "reason=\"payload-bytes\"} 1")
    check output.contains("koutendb_segment_active_generations{node=\"0\"} 0")
    check output.contains("koutendb_segment_bytes{node=\"0\"} 0")
    check output.contains("koutendb_segment_index_bytes{node=\"0\"} 0")
    check not output.contains("users/123")
    db.close()

  test "checkpoint metrics aggregate health without checkpoint IDs":
    let root = createTempDir("kouten-metrics", "checkpoint")
    let checkpointRoot = root / "checkpoints"
    var db = open(dataDir = root / "data", diskBacked = true)
    discard db.put("value", ring = "docs")
    let created = db.createCheckpoint(checkpointRoot, "generation-1")
    let output = checkpointMetricsText(checkpointRoot, kmfPrometheus)
    check output.contains("koutendb_checkpoint_generations{node=\"0\"} 1")
    check output.contains(
      "koutendb_checkpoint_verified_generations{node=\"0\"} 1")
    check output.contains("koutendb_checkpoint_newest_verified{node=\"0\"} 1")
    check not output.contains(created.id)
    writeFile(created.path / "checkpoint.complete", "damaged")
    let damaged = checkpointMetricsText(checkpointRoot, kmfPrometheus)
    check damaged.contains(
      "koutendb_checkpoint_invalid_generations{node=\"0\"} 1")
    check damaged.contains(
      "koutendb_checkpoint_newest_verified{node=\"0\"} 0")
    db.close()
    removeDir(root)
