"""Add the offline announcements library after the existing patch chain."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / 'RAIDORoster/ContentView.swift'
PBX = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
content = CONTENT.read_text()
start = content.index('struct TodayView: View {')
end = content.index('\nstruct TodayPrimaryTimingRow:', start)
today = content[start:end]

def replace(old, new):
    global today
    if today.count(old) != 1:
        raise RuntimeError(f'Today anchor mismatch: {old[:90]}')
    today = today.replace(old, new)

replace('    @State private var showFleet = false', '    @State private var showFleet = false\n    @State private var showAnnouncements = false')
replace('''                    if let item = store.todayPrimaryItem {
                        Button { calendarExporter.export(item) } label: {
                            Image(systemName: "calendar.badge.plus")
                        }
                        .disabled(calendarExporter.isWorking)
                        .accessibilityLabel("Sync today's duty to Calendar")
                    }
''', '''                    Button { showAnnouncements = true } label: {
                        Image(systemName: "book.closed.fill")
                    }
                    .accessibilityLabel("Announcements")
''')
# Keep Calendar in the duty's options, leaving three quick actions in the toolbar.
replace('''                        CrewReadinessCard(item: item, store: store)''', '''                        HStack {
                            Text("Duty briefing").font(.headline)
                            Spacer()
                            Menu {
                                Button("Sync duty to Calendar", systemImage: "calendar.badge.plus") {
                                    calendarExporter.export(item)
                                }.disabled(calendarExporter.isWorking)
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .frame(width: 44, height: 44)
                            }.accessibilityLabel("Duty options")
                        }
                        CrewReadinessCard(item: item, store: store)''')
replace('''            .sheet(isPresented: $showFleet) {
                FleetView(store: store)
            }''', '''            .sheet(isPresented: $showFleet) {
                FleetView(store: store)
            }
            .sheet(isPresented: $showAnnouncements) {
                AnnouncementsView(item: store.isCacheValidated ? store.todayPrimaryItem : nil)
            }''')
content = content[:start] + today + content[end:]
content = content.replace('"2.19.8"', '"2.19.9"').replace('RAIDORoster/2.19.8', 'RAIDORoster/2.19.9')
# Reuse exact entries from the app's fleet list, never a national registration prefix.
content += '''
// Announcements 2.19.9
func announcementAirline(registration: String) -> AnnouncementAirline {
    let key = registration.uppercased().filter { $0.isLetter || $0.isNumber }
    guard let aircraft = FleetAircraftDefinition.all.first(where: {
        $0.registration.uppercased().filter { $0.isLetter || $0.isNumber } == key
    }) else { return .unspecified }
    switch aircraft.operatorCode {
    case "GETJET": return .getjet
    case "AIRHUB": return .airhub
    default: return .unspecified
    }
}
'''
CONTENT.write_text(content)
pbx = PBX.read_text()

def project_replace(old, new):
    global pbx
    if pbx.count(old) != 1: raise RuntimeError(f'PBX anchor mismatch: {old}')
    pbx = pbx.replace(old, new)

for i, name in enumerate(['AnnouncementModels.swift', 'AnnouncementsView.swift', 'GetJetAnnouncements.json'], 1):
    a, b = f'A199{i:020d}', f'B199{i:020d}'
    phase, filetype = ('Resources', 'text.json') if name.endswith('.json') else ('Sources', 'sourcecode.swift')
    project_replace('/* End PBXBuildFile section */', f'{a} /* {name} in {phase} */ = {{isa = PBXBuildFile; fileRef = {b} /* {name} */; }};\n/* End PBXBuildFile section */')
    project_replace('/* End PBXFileReference section */', f'{b} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {filetype}; path = {name}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */')
    anchor = 'B00000000000000000000002 /* ContentView.swift */,'
    project_replace(anchor, anchor + f'\n {b} /* {name} */,')
    anchor = ('A00000000000000000000004 /* RosterEnhancements.js in Resources */,' if phase == 'Resources'
              else 'A00000000000000000000002 /* ContentView.swift in Sources */,')
    project_replace(anchor, anchor + f' {a} /* {name} in {phase} */,')
pbx = pbx.replace('MARKETING_VERSION = 2.19.8;', 'MARKETING_VERSION = 2.19.9;')
PBX.write_text(pbx)
print('V2.19.9 Offline announcements applied')
