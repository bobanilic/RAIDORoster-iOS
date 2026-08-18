from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
JS = ROOT / "RAIDORoster" / "RosterEnhancements.js"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.11.3 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# Retire the experimental historical crew counter. Historical RAIDO pages do
# not guarantee complete Crew On Board coverage, so the resulting totals cannot
# be presented as authoritative. Keep current-duty crew contact functionality.
content = content.replace(
    "        indexCrewHistory(month: validation.month, items: parsed)\n\n",
    "",
    1,
)

content = replace_once(
    content,
    '''    init() {
        load()
        loadChangeState()
        loadCrewHistory()
    }
''',
    '''    init() {
        load()
        loadChangeState()
        // V2.11.3 retires historical crew counting and removes any previously
        // generated archive from this device.
        crewHistoryMonths = [:]
        try? FileManager.default.removeItem(at: crewHistoryURL)
    }
''',
    "retire crew history archive",
)

content = replace_once(
    content,
    '''struct CrewCard: View {
    let item: RosterItem
    @EnvironmentObject private var store: RosterStore
    @State private var expandedCrewID: String?
''',
    '''struct CrewCard: View {
    let item: RosterItem
    @State private var expandedCrewID: String?
''',
    "remove CrewCard history store",
)

history_start = '''
                            if let history = store.crewHistory(for: member), history.duties > 0 {
'''
history_end = '''
                        }
                        .padding(.leading, 50)
'''
if history_start in content:
    start = content.index(history_start)
    end = content.index(history_end, start)
    content = content[:start] + content[end:]

settings_start = '''                Section("Crew history") {
'''
settings_end = '''                Section("Portal") {
'''
if settings_start in content:
    start = content.index(settings_start)
    end = content.index(settings_end, start)
    content = content[:start] + content[end:]

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.11.2")',
    'LabeledContent("RAIDO Roster", value: "2.11.3")',
    1,
)
CONTENT.write_text(content)

# Stop exposing the retired month-traversal function through the injected JS.
js = JS.read_text()
js = js.replace(
    '''    diagnostics,
    backfillCrewHistory
  };
''',
    '''    diagnostics
  };
''',
    1,
)
JS.write_text(js)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 15;", "CURRENT_PROJECT_VERSION = 16;")
pbx = pbx.replace("MARKETING_VERSION = 2.11.2;", "MARKETING_VERSION = 2.11.3;")
PBX.write_text(pbx)

print("V2.11.3 unreliable crew history/backfill retired")
