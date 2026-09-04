from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"

content = CONTENT.read_text()
start = content.find('private struct FleetAircraftDetailView: View {')
end = content.find('\nprivate struct FleetMetric: View {', start)
if start < 0 or end < 0:
    raise RuntimeError('V2.19.7c Fleet detail boundaries not found')

block = content[start:end]

# V2.17.1 already owns a @StateObject photo loader and its custom initializer.
# V2.19.7 added `intelligence`; V2.19.7b added a second initializer, which left
# each initializer missing one stored property. Normalize the header to exactly
# one designated initializer that initializes every stored property.
body_marker = '    var body: some View {'
body_index = block.find(body_marker)
if body_index < 0:
    raise RuntimeError('V2.19.7c Fleet detail body marker not found')

header = block[:body_index]
body = block[body_index:]

required_props = '''private struct FleetAircraftDetailView: View {\n    let aircraft: FleetAircraftDefinition\n    let snapshot: FleetLiveSnapshot?\n    let intelligence: FleetAircraftIntelligence?\n    let isAssigned: Bool\n    @Environment(\\.dismiss) private var dismiss\n    @StateObject private var photo: FleetAircraftPhotoStore\n\n'''

if '@StateObject private var photo: FleetAircraftPhotoStore' not in header:
    raise RuntimeError('V2.19.7c Fleet photo state not found')
if 'let intelligence: FleetAircraftIntelligence?' not in header:
    raise RuntimeError('V2.19.7c Fleet intelligence property not found')

initializer = '''    init(aircraft: FleetAircraftDefinition, snapshot: FleetLiveSnapshot?, intelligence: FleetAircraftIntelligence?, isAssigned: Bool) {\n        self.aircraft = aircraft\n        self.snapshot = snapshot\n        self.intelligence = intelligence\n        self.isAssigned = isAssigned\n        _photo = StateObject(wrappedValue: FleetAircraftPhotoStore(registration: aircraft.registration))\n    }\n\n'''

block = required_props + initializer + body
content = content[:start] + block + content[end:]
CONTENT.write_text(content)
print('V2.19.7c Fleet detail initializer + photo StateObject fix applied')
