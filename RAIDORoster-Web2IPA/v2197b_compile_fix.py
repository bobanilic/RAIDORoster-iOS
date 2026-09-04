from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"

content = CONTENT.read_text()

marker = '''private struct FleetAircraftDetailView: View {\n    let aircraft: FleetAircraftDefinition\n    let snapshot: FleetLiveSnapshot?\n    let intelligence: FleetAircraftIntelligence?\n    let isAssigned: Bool\n    @Environment(\\.dismiss) private var dismiss\n'''

if marker not in content:
    raise RuntimeError('V2.19.7b FleetAircraftDetailView properties marker not found')

if 'init(aircraft: FleetAircraftDefinition, snapshot: FleetLiveSnapshot?, intelligence: FleetAircraftIntelligence?, isAssigned: Bool)' not in content:
    replacement = marker + '''\n    init(aircraft: FleetAircraftDefinition, snapshot: FleetLiveSnapshot?, intelligence: FleetAircraftIntelligence?, isAssigned: Bool) {\n        self.aircraft = aircraft\n        self.snapshot = snapshot\n        self.intelligence = intelligence\n        self.isAssigned = isAssigned\n    }\n'''
    content = content.replace(marker, replacement, 1)

CONTENT.write_text(content)
print('V2.19.7b explicit Fleet detail initializer compile fix applied')
