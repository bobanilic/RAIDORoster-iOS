"""2.21.0: on-device crew document vault, preserving the fixed Midnight UI."""
from pathlib import Path
ROOT = Path(__file__).resolve().parent
def once(s, old, new):
    if s.count(old) != 1: raise RuntimeError('Documents anchor changed: ' + old[:100])
    return s.replace(old, new, 1)
p = ROOT / 'RAIDORoster/ContentView.swift'
s = p.read_text()
a = s.index('struct TodayView:'); b = s.index('struct RestToNextDutyCard:', a)
t = s[a:b]
t = once(t, 'case crewControl, fleet, announcements', 'case crewControl, fleet, announcements, documents')
t = once(t, '                case .crewControl:\n                    CrewControlSheet', '                case .documents:\n                    CrewDocumentsView()\n                case .crewControl:\n                    CrewControlSheet')
t = once(t, '                ToolbarItem(placement: .topBarTrailing) {', '''                ToolbarItem(placement: .topBarTrailing) {
                    Button { activeSheet = .documents } label: {
                        Image(systemName: "doc.text").frame(minWidth: 32, minHeight: 44)
                    }.accessibilityLabel("Documents")
                }
                ToolbarItem(placement: .topBarTrailing) {''')
s = s[:a] + t + s[b:]
a = s.index('struct SettingsView:'); b = s.index('struct DutyHeroCard:', a)
t = s[a:b]
t = once(t, '    @State private var showFleet = false', '    @State private var showFleet = false\n    @State private var showDocuments = false')
t = once(t, '            Form {', '''            Form {
                Section("Crew documents") {
                    Button { showDocuments = true } label: {
                        Label("Documents", systemImage: "lock.doc")
                    }
                    Text("Passports, certificates, medical records and vaccinations, stored privately on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(MidnightTheme.surface)''')
t = once(t, '            .sheet(isPresented: $showFleet)', '            .sheet(isPresented: $showDocuments) { CrewDocumentsView() }\n            .sheet(isPresented: $showFleet)')
s = s[:a] + t + s[b:]
if '2.20.9' not in s: raise RuntimeError('Documents version anchor changed')
p.write_text(s.replace('2.20.9', '2.21.0'))
p = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
s = p.read_text()
for i, name in enumerate(['CrewDocumentVault.swift', 'CrewDocumentServices.swift', 'CrewDocumentsView.swift'], 1):
    a, b = f'A221{i:020d}', f'B221{i:020d}'
    s = once(s, '/* End PBXBuildFile section */', f'{a} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {b} /* {name} */; }};\n/* End PBXBuildFile section */')
    s = once(s, '/* End PBXFileReference section */', f'{b} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */')
    marker = 'B00000000000000000000002 /* ContentView.swift */,'
    s = once(s, marker, marker + f'\n {b} /* {name} */,')
    marker = 'A00000000000000000000002 /* ContentView.swift in Sources */,'
    s = once(s, marker, marker + f' {a} /* {name} in Sources */,')
s = s.replace('MARKETING_VERSION = 2.20.9;', 'MARKETING_VERSION = 2.21.0;')
s = s.replace('GENERATE_INFOPLIST_FILE = YES;', '''GENERATE_INFOPLIST_FILE = YES;
            INFOPLIST_KEY_NSFaceIDUsageDescription = "Use Face ID to unlock your private crew documents.";
            INFOPLIST_KEY_NSCameraUsageDescription = "Scan paper documents into your private crew document storage.";''')
p.write_text(s)
print('V2.21.0 private crew Documents integrated')
