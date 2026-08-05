## UTC maintenance-window parsing shared by the server and tests.

import std/[strutils, times]

type
  MaintenanceWindow* = object
    configured*: bool
    startMinute*: int
    endMinute*: int

proc parseClock(value: string): int =
  let parts = value.split(':')
  if parts.len != 2:
    raise newException(ValueError,
      "maintenance window times must use HH:MM")
  let hour = parseInt(parts[0])
  let minute = parseInt(parts[1])
  if parts[0].len != 2 or parts[1].len != 2 or
      hour < 0 or hour > 23 or minute < 0 or minute > 59:
    raise newException(ValueError,
      "maintenance window times must use 00:00..23:59")
  hour * 60 + minute

proc parseMaintenanceWindow*(value: string): MaintenanceWindow =
  let normalized = value.strip()
  if normalized.len == 0:
    return
  let bounds = normalized.split('-')
  if bounds.len != 2:
    raise newException(ValueError,
      "maintenance window must use HH:MM-HH:MM UTC")
  result.configured = true
  result.startMinute = parseClock(bounds[0])
  result.endMinute = parseClock(bounds[1])
  if result.startMinute == result.endMinute:
    raise newException(ValueError,
      "maintenance window start and end must differ; omit it for all day")

proc containsMinute*(window: MaintenanceWindow; minuteOfDay: int): bool =
  if minuteOfDay < 0 or minuteOfDay >= 24 * 60:
    raise newException(ValueError, "minuteOfDay must be in 0..1439")
  if not window.configured:
    return true
  if window.startMinute < window.endMinute:
    minuteOfDay >= window.startMinute and minuteOfDay < window.endMinute
  else:
    minuteOfDay >= window.startMinute or minuteOfDay < window.endMinute

proc isOpenNow*(window: MaintenanceWindow; current = now().utc): bool =
  window.containsMinute(current.hour * 60 + current.minute)
