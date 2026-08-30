from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"

content = CONTENT.read_text()

old_catalog = '''    static let all: [FleetAircraftDefinition] = [
        .init(registration: "LY-NOW", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-GYM", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-FAS", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-WIL", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-MAL", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-WIZ", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-CAP", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-TAP", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-EKB", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-DAE", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-WSA", type: "A321", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "220Y"),
        .init(registration: "LY-UNO", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-DUE", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-CIN", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-TUI", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-SEI", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "9H-GTS", type: "A320", operatorName: "Airhub Airlines", operatorCode: "AIRHUB", seats: "180Y")
    ]
'''

new_catalog = '''    static let all: [FleetAircraftDefinition] = [
        .init(registration: "LY-ELM", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-FOX", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-MAL", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-NOW", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-TAP", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-TEN", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-WSA", type: "A321", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "220Y"),
        .init(registration: "LY-CIN", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-DUE", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-KUA", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-SEI", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-TUI", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-UNO", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "9H-GTS", type: "A320", operatorName: "Airhub Airlines", operatorCode: "AIRHUB", seats: "180Y")
    ]
'''

if new_catalog not in content:
    if old_catalog not in content:
        raise RuntimeError("V2.17.3 current fleet catalog marker not found")
    content = content.replace(old_catalog, new_catalog, 1)

# V2.17 deliberately keeps the four main tabs. Fleet is a one-tap Today tool
# and a secondary Settings entry. Make sure each presenting view owns its own
# showFleet state so the two sheets cannot accidentally share/miss state.
def ensure_state_for_struct(text: str, struct_name: str, usage: str) -> str:
    start = text.find(struct_name)
    if start < 0:
        raise RuntimeError(f"V2.17.3 {struct_name} not found")
    usage_pos = text.find(usage, start)
    if usage_pos < 0:
        raise RuntimeError(f"V2.17.3 Fleet usage not found in {struct_name}")
    body = text.find("\n    var body: some View {", start, usage_pos)
    if body < 0:
        body = text.find("\n    var body: some View {", start)
    if body < 0:
        raise RuntimeError(f"V2.17.3 body not found in {struct_name}")
    scope = text[start:body]
    if "@State private var showFleet" not in scope:
        text = text[:body] + "\n    @State private var showFleet = false\n" + text[body:]
    return text

# Settings is named explicitly. For Today, find the struct that owns the Fleet
# toolbar button instead of relying on its historical type name.
settings_start = content.find("struct SettingsView: View {")
if settings_start < 0:
    raise RuntimeError("V2.17.3 SettingsView not found")
settings_usage = content.find(".sheet(isPresented: $showFleet)", settings_start)
if settings_usage < 0:
    raise RuntimeError("V2.17.3 Settings Fleet sheet not found")
settings_body = content.find("\n    var body: some View {", settings_start, settings_usage)
if settings_body < 0:
    raise RuntimeError("V2.17.3 Settings body not found")
if "@State private var showFleet" not in content[settings_start:settings_body]:
    content = content[:settings_body] + "\n    @State private var showFleet = false\n" + content[settings_body:]

fleet_button = content.find('Button { showFleet = true }')
if fleet_button < 0:
    raise RuntimeError("V2.17.3 Today Fleet button not found")
public_struct = content.rfind("\nstruct ", 0, fleet_button)
private_struct = content.rfind("\nprivate struct ", 0, fleet_button)
today_start = max(public_struct, private_struct)
if today_start < 0:
    raise RuntimeError("V2.17.3 Today Fleet owner not found")
today_body = content.find("\n    var body: some View {", today_start, fleet_button)
if today_body < 0:
    raise RuntimeError("V2.17.3 Today body not found")
if "@State private var showFleet" not in content[today_start:today_body]:
    content = content[:today_body] + "\n    @State private var showFleet = false\n" + content[today_body:]

CONTENT.write_text(content)
print("V2.17.3 current operational fleet catalog + Fleet presentation state applied")
