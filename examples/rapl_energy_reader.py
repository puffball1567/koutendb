#!/usr/bin/env python3
"""Read-only RAPL helper. Uses stdlib only; accepts only a 'read' command."""

import json
import sys
from pathlib import Path


def discover(root=Path("/sys/class/powercap")):
    zones = []
    seen = set()
    for path in sorted(root.glob("*")):
        try:
            name = (path / "name").read_text().strip()
        except FileNotFoundError:
            continue
        if not name.startswith("package-") or path.resolve() in seen:
            continue
        maximum = int((path / "max_energy_range_uj").read_text())
        if maximum <= 0:
            raise ValueError("invalid energy range")
        # Verify all packages before declaring coverage available.
        value = int((path / "energy_uj").read_text())
        if not 0 <= value <= maximum:
            raise ValueError("invalid energy counter")
        seen.add(path.resolve())
        zones.append((path, maximum))
    if not zones:
        raise ValueError("no CPU package energy counters found")
    return zones


def reply(value):
    print(json.dumps(value), flush=True)


def serve(zones, source):
    reply({"domains": [path.name for path, _ in zones],
           "ranges": [maximum for _, maximum in zones]})
    for line in source:
        if line.strip() != "read":
            raise ValueError("only the read command is supported")
        values = [int((path / "energy_uj").read_text()) for path, _ in zones]
        if any(not 0 <= value <= maximum
               for value, (_, maximum) in zip(values, zones)):
            raise ValueError("invalid energy counter")
        reply({"values": values})


def main():
    try:
        serve(discover(), sys.stdin)
    except (OSError, ValueError) as error:
        reply({"error": str(error)})
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
