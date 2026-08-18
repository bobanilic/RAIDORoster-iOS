from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"

content = CONTENT.read_text()

old = '''            .navigationTitle("RAIDO Roster")
            .toolbar {
'''
new = '''            .navigationTitle("GetJet / AirHub Roster")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
'''

if new not in content:
    if old not in content:
        raise RuntimeError("V2.11.7b roster header marker not found")
    content = content.replace(old, new, 1)

CONTENT.write_text(content)
print("V2.11.7b compact GetJet / AirHub roster header applied")
