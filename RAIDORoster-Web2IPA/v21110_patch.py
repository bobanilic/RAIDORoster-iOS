from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"

content = CONTENT.read_text()

# The compact navigation header already owns roster freshness. Remove any
# standalone SyncFreshnessStrip still present inside RosterHomeView only.
start = content.find("struct RosterHomeView: View {")
end = content.find("struct RosterMonthCalendarView: View {", start)
if end < 0:
    end = content.find("struct TodayView: View {", start)
if start < 0 or end < 0:
    raise RuntimeError("V2.11.10 RosterHomeView range not found")

home = content[start:end]
removed = home.count("SyncFreshnessStrip(store: store)")
home = home.replace("                    SyncFreshnessStrip(store: store)\n\n", "")
home = home.replace("                    SyncFreshnessStrip(store: store)\n", "")
content = content[:start] + home + content[end:]

if "SyncFreshnessStrip(store: store)" in content[start:end]:
    raise RuntimeError("V2.11.10 duplicate roster freshness strip still present")

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.11.9")',
    'LabeledContent("RAIDO Roster", value: "2.11.10")',
    1,
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 22;", "CURRENT_PROJECT_VERSION = 23;")
pbx = pbx.replace("MARKETING_VERSION = 2.11.9;", "MARKETING_VERSION = 2.11.10;")
PBX.write_text(pbx)

print(f"V2.11.10 duplicate Roster freshness strip removed ({removed} occurrence(s))")
