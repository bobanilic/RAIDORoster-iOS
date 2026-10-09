"""V2.23.0 compile fix: qualify shared registration normalizer in Fleet V2."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent
p = ROOT / "RAIDORoster/ContentView.swift"
s = p.read_text()
a = s.index("struct FleetView: View {")
b = s.index("private func fleetDuration", a)
t = s[a:b]
if "normalizedRegistration(" not in t:
    raise RuntimeError("Fleet V2 registration anchors missing")
t = t.replace("normalizedRegistration(", "FleetTrackingPolicy.normalizedRegistration(")
s = s[:a] + t + s[b:]
p.write_text(s)
print("V2.23.0 Fleet V2 registration helper scope fixed")
