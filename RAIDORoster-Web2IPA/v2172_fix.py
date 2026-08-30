from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"

content = CONTENT.read_text()

# V2.17 added the Fleet toolbar button/sheet to Today, but the original
# broad showCrewControl marker matched a different view first. Add the
# missing state directly to the struct that owns the Fleet button.
needle = "Button { showFleet = true }"
usage = content.find(needle)
if usage < 0:
    raise RuntimeError("V2.17.2 fix: Today Fleet button not found")

# Find the nearest enclosing Swift struct before the Fleet button.
public_struct = content.rfind("\nstruct ", 0, usage)
private_struct = content.rfind("\nprivate struct ", 0, usage)
struct_start = max(public_struct, private_struct)
if struct_start < 0:
    raise RuntimeError("V2.17.2 fix: enclosing Today struct not found")

body_pos = content.find("\n    var body: some View {", struct_start, usage)
if body_pos < 0:
    body_pos = content.find("\n    var body: some View {", struct_start)
if body_pos < 0:
    raise RuntimeError("V2.17.2 fix: Today body marker not found")

scope = content[struct_start:body_pos]
if "@State private var showFleet" not in scope:
    content = content[:body_pos] + "\n    @State private var showFleet = false\n" + content[body_pos:]

CONTENT.write_text(content)
print("V2.17.2 missing Today Fleet state fixed")
