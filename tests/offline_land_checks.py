"""Validate bundled geography and representative route landmarks."""
import json
import math
import sys
from pathlib import Path

outlines = json.loads(Path(sys.argv[1]).read_text())
assert len(outlines) >= 1000, "World land resource is incomplete"
for west, south, east, north, ring in outlines:
    assert -180 <= west <= east <= 180 and -90 <= south <= north <= 90
    assert len(ring) >= 4 and ring[0] == ring[-1], "Unclosed land outline"
    assert all(len(point) == 2 and all(math.isfinite(v) for v in point)
               and west <= point[0] <= east and south <= point[1] <= north
               for point in ring), "Invalid coordinates or bounds"

def on_land(longitude, latitude):
    for west, south, east, north, ring in outlines:
        if not (west <= longitude <= east and south <= latitude <= north):
            continue
        inside = False
        for (x1, y1), (x2, y2) in zip(ring, ring[1:]):
            if (y1 > latitude) != (y2 > latitude):
                if longitude < (x2 - x1) * (latitude - y1) / (y2 - y1) + x1:
                    inside = not inside
        if inside:
            return True
    return False

for name, longitude, latitude, expected in [
    ("TLV airport", 34.8867, 32.0114, True),
    ("PFO airport", 32.4857, 34.7180, True),
    ("London", -0.1278, 51.5074, True),
    ("JFK airport", -73.7781, 40.6413, True),
    ("TLV–PFO sea", 33.5, 33.3, False),
    ("Pacific Ocean", -140, 0, False),
]:
    assert on_land(longitude, latitude) == expected, name
print(f"Passed offline geography checks: {len(outlines)} outlines and 6 landmarks")
