import std/unittest
import ../src/kouten/maintenance_window

suite "maintenance window":
  test "empty window is always open":
    let window = parseMaintenanceWindow("")
    check not window.configured
    check window.containsMinute(0)
    check window.containsMinute(1439)

  test "same-day window includes start and excludes end":
    let window = parseMaintenanceWindow("01:30-03:15")
    check window.containsMinute(90)
    check window.containsMinute(194)
    check not window.containsMinute(195)
    check not window.containsMinute(89)

  test "window can cross UTC midnight":
    let window = parseMaintenanceWindow("23:00-02:00")
    check window.containsMinute(1380)
    check window.containsMinute(0)
    check window.containsMinute(119)
    check not window.containsMinute(120)
    check not window.containsMinute(720)

  test "invalid and ambiguous windows fail closed":
    for value in ["1:00-02:00", "24:00-02:00", "23:60-02:00",
                  "10:00", "10:00-10:00"]:
      expect ValueError:
        discard parseMaintenanceWindow(value)
    let window = parseMaintenanceWindow("")
    expect ValueError:
      discard window.containsMinute(-1)
    expect ValueError:
      discard window.containsMinute(1440)
