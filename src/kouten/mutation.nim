## Durable mutation ordering shared by the store and cluster wire protocol.
##
## Versions are hybrid-logical-clock tuples. Physical microseconds preserve
## useful wall-clock ordering, logical distinguishes mutations in the same
## microsecond, and origin provides a deterministic final tie-breaker.

import std/[algorithm, math, strutils]

type
  MutationVersion* = object
    physicalMicros*: int64
    logical*: uint32
    origin*: uint32

proc isZero*(version: MutationVersion): bool =
  version.physicalMicros == 0 and version.logical == 0 and version.origin == 0

proc validateMutationVersion*(version: MutationVersion) =
  if version.isZero:
    return
  if version.physicalMicros <= 0:
    raise newException(ValueError,
      "mutation version physicalMicros must be positive")

proc cmp*(a, b: MutationVersion): int =
  result = system.cmp(a.physicalMicros, b.physicalMicros)
  if result == 0:
    result = system.cmp(a.logical, b.logical)
  if result == 0:
    result = system.cmp(a.origin, b.origin)

proc `<`*(a, b: MutationVersion): bool = cmp(a, b) < 0
proc `<=`*(a, b: MutationVersion): bool = cmp(a, b) <= 0
proc `>`*(a, b: MutationVersion): bool = cmp(a, b) > 0
proc `>=`*(a, b: MutationVersion): bool = cmp(a, b) >= 0

proc legacyMutationVersion*(tWrite: float): MutationVersion =
  ## Old WAL/wire records had only tWrite. Preserve their relative ordering
  ## while reserving origin zero for compatibility data.
  let micros =
    if tWrite <= 0 or tWrite.classify in {fcNan, fcInf, fcNegInf}: 1'i64
    elif tWrite >= float(int64.high) / 1_000_000.0: int64.high
    else: max(1'i64, int64(floor(tWrite * 1_000_000.0)))
  MutationVersion(physicalMicros: micros, logical: 0, origin: 0)

proc mutationVersionFields*(version: MutationVersion): string =
  $version.physicalMicros & " " & $version.logical & " " & $version.origin

proc canonicalAcknowledgedNodes*(nodes: openArray[uint16]): seq[uint16] =
  result = @nodes
  result.sort()
  var writeAt = 0
  for node in result:
    if writeAt == 0 or result[writeAt - 1] != node:
      result[writeAt] = node
      inc writeAt
  result.setLen(writeAt)

proc acknowledgedNodesField*(nodes: openArray[uint16]): string =
  let canonical = canonicalAcknowledgedNodes(nodes)
  if canonical.len == 0:
    return "-"
  for i, node in canonical:
    if i > 0:
      result.add ','
    result.add $node

proc parseAcknowledgedNodes*(field: string): seq[uint16] =
  if field.len == 0 or field == "-":
    return @[]
  for part in field.split(','):
    if part.len == 0:
      raise newException(ValueError, "empty acknowledged node id")
    let parsed = parseUInt(part)
    if parsed > uint16.high.uint:
      raise newException(ValueError, "acknowledged node id exceeds uint16")
    result.add parsed.uint16
  result = canonicalAcknowledgedNodes(result)

proc acknowledgeNode*(nodes: var seq[uint16], node: uint16): bool =
  for existing in nodes:
    if existing == node:
      return false
  nodes.add node
  nodes.sort()
  true

proc acknowledgesAllNodes*(nodes: openArray[uint16], nNodes: int): bool =
  if nNodes <= 0 or nNodes > int(uint16.high) + 1:
    return false
  let canonical = canonicalAcknowledgedNodes(nodes)
  if canonical.len < nNodes:
    return false
  for node in 0 ..< nNodes:
    if canonical[node] != uint16(node):
      return false
  true

proc parseMutationVersion*(parts: openArray[string], first: int,
                           fallbackTWrite: float): MutationVersion =
  if first >= 0 and parts.len >= first + 3:
    let logical = parseUInt(parts[first + 1])
    let origin = parseUInt(parts[first + 2])
    if logical > uint(uint32.high):
      raise newException(ValueError, "mutation logical counter exceeds uint32")
    if origin > uint(uint32.high):
      raise newException(ValueError, "mutation origin exceeds uint32")
    result = MutationVersion(
      physicalMicros: parseBiggestInt(parts[first]).int64,
      logical: logical.uint32,
      origin: origin.uint32)
    result.validateMutationVersion()
    if not result.isZero:
      return
  result = legacyMutationVersion(fallbackTWrite)
