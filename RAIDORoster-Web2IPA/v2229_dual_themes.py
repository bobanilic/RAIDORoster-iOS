"""V2.29.0: retain Ice and add GetJet, with per-theme appearance in Settings."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
APP = ROOT / 'RAIDORoster'
CONTENT = APP / 'ContentView.swift'
PBX = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
MARKER = '// V2.29: two native themes'
s = CONTENT.read_text()
if MARKER in s:
    if 'RaidoChromeRefresh' not in (APP / 'RAIDORosterApp.swift').read_text() or 'AppearanceModels.swift in Sources' not in PBX.read_text():
        raise RuntimeError('Incomplete dual-theme installation')
    print('V2.29 dual themes already applied')
    raise SystemExit(0)

def once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f'V2.29 anchor found {text.count(old)} times: {old[:100]}')
    return text.replace(old, new, 1)

def region(text, begin, end, transform):
    a = text.index(begin)
    b = text.index(end, a + len(begin))
    return text[:a] + transform(text[a:b]) + text[b:]

# Read all replacement sources before writing generated output.
theme = (ROOT / 'v2229_theme.swift.inc').read_text()
if not (APP / 'AppearanceModels.swift').exists():
    raise RuntimeError('AppearanceModels.swift missing')
s = region(s, 'enum MidnightTheme {', 'private struct MidnightCard:', lambda _: theme + '\n')
s = once(s, '''    func midnightCanvas() -> some View {
        scrollContentBackground(.hidden)
            .background(MidnightTheme.background.ignoresSafeArea())
            .toolbarBackground(MidnightTheme.background, for: .navigationBar, .tabBar)
            .toolbarBackground(.visible, for: .navigationBar, .tabBar)
            .tint(MidnightTheme.accent)
    }''', '''    func midnightCanvas() -> some View { modifier(RaidoCanvas()) }''')

def settings(t):
    t = once(t, '@AppStorage("RAIDORoster.Appearance") private var appAppearance = "system"', '''@AppStorage("RAIDORoster.Theme") private var selectedTheme = "ice"
    @AppStorage("RAIDORoster.Appearance.Ice") private var iceAppearance = "system"
    @AppStorage("RAIDORoster.Appearance.GetJet") private var getJetAppearance = "system"
    private var appearanceSelection: Binding<String> {
        Binding(get: { selectedTheme == "getJet" ? getJetAppearance : iceAppearance },
                set: { if selectedTheme == "getJet" { getJetAppearance = $0 } else { iceAppearance = $0 } })
    }''')
    a = t.index('                Section("Appearance") {')
    b = t.index('                Section("Version") {', a)
    appearance_section = '''                Section("Appearance") {
                    Picker("Theme", selection: $selectedTheme) {
                        ForEach(RaidoTheme.allCases) { theme in Text(theme.title).tag(theme.rawValue) }
                    }.pickerStyle(.segmented)
                    Picker("Mode", selection: appearanceSelection) {
                        ForEach(RaidoAppearance.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                    }.pickerStyle(.segmented)
                    Text("System follows your iPhone. Each theme remembers its own appearance.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.listRowBackground(MidnightTheme.surface)

'''
    t = t[:a] + t[b:]
    t = once(t, '            Form {\n', '            Form {\n' + appearance_section)
    return t.replace('value: "2.28.0"', 'value: "2.29.0"')
s = region(s, 'struct SettingsView:', 'struct DutyHeroCard:', settings)

def calendar(t):
    t = once(t, 'ForEach(Array(slots.enumerated()), id: \\.offset) { _, iso in',
             'ForEach(Array(slots.enumerated()), id: \\.offset) { _, iso in')
    # Date cells retain exactly the same selection and source-of-truth behavior.
    # Match both empty and populated slot heights; overlay is presentation only.
    t = t.replace('.frame(maxWidth: .infinity, minHeight: 64)',
                  '.frame(maxWidth: .infinity, minHeight: MidnightTheme.isGetJet ? 80 : 64)')
    anchor = '''            }

            ViewThatFits(in: .horizontal)'''
    return once(t, anchor, '''            }
            .overlay {
                if MidnightTheme.isGetJet { GetJetCalendarDividers(rows: slots.count / 7) }
            }

            ViewThatFits(in: .horizontal)''')
s = region(s, 'struct RosterMonthCalendarView:', 'struct RosterCalendarDayCell:', calendar)
def cell(t):
    t = t.replace('isSelected ? Color.white', 'isSelected ? MidnightTheme.selectionInk')
    t = t.replace('isSelected ? MidnightTheme.accent', 'isSelected ? MidnightTheme.highlight')
    t = t.replace('minHeight: 64', 'minHeight: MidnightTheme.isGetJet ? 80 : 64')
    # Breathing room on both sides of the gutters; keep full duty text accessible.
    return once(t, '        }.frame(maxWidth:', '        }.padding(.horizontal, MidnightTheme.isGetJet ? 3 : 0).frame(maxWidth:')
s = region(s, 'struct RosterCalendarDayCell:', 'struct RosterCalendarAgendaCard:', cell)

def agenda(t):
    old = '''                agendaRow(time: activity.localStartTime,
                          title: activity.isFlight && codes.count >= 2 ? codes.joined(separator: " → ") : activity.title,
                          detail: activity.isFlight ? activity.code : activity.description,
                          arrival: activity.localEndTime, sector: activity.isFlight ? activity : nil)'''
    return once(t, old, '''                if MidnightTheme.isGetJet && activity.isFlight && codes.count >= 2 {
                    GetJetSectorCard(sector: activity) { crewSector = activity }
                } else {
''' + old + '''
                }''')
s = region(s, 'private struct IceDutyAgenda:', 'private struct IceSelectedRosterDay:', agenda)
s = region(s, 'private struct IcePickupCard:', 'private struct IceReadinessView:', lambda t:
           once(t, '.midnightCard(radius: 16)', '.midnightCard(radius: MidnightTheme.isGetJet ? 22 : 16)'))
s = once(s, 'let land = Color(uiColor: MidnightTheme.adaptive(0x213943, 0xF4F5EB))', 'let land = MidnightTheme.mapLand')
s = once(s, 'let border = Color(uiColor: MidnightTheme.adaptive(0x385361, 0xBDCED2))', 'let border = MidnightTheme.mapBorder')
s = once(s, 'case "STANDBY": return Color(uiColor: MidnightTheme.adaptive(0xDBB477, 0xAD783A))', 'case "STANDBY": return MidnightTheme.standbyInk')
s = once(s, 'case "OFF", "REST": return Color(uiColor: MidnightTheme.adaptive(0x98AFBC, 0x718A9B))', 'case "OFF", "REST": return MidnightTheme.offInk')
s = once(s, '''                .background(MidnightTheme.mapSea)
            Button { toggleMap() }''', '''                .background(MidnightTheme.mapSea)
                .clipShape(RoundedRectangle(cornerRadius: MidnightTheme.isGetJet ? 28 : 0, style: .continuous))
            Button { toggleMap() }''')

# SwiftUI environment invalidation refreshes existing views in place. No .id()
# on the app root, so authentication, selected dates and GPS/Fleet tasks survive.
def observe_theme(text):
    pattern = re.compile(r'\bstruct\s+\w+\s*:\s*View(?:Modifier)?\s*\{')
    starts = list(pattern.finditer(text))
    for i in range(len(starts) - 1, -1, -1):
        match = starts[i]
        end = starts[i + 1].start() if i + 1 < len(starts) else len(text)
        part = text[match.end():end]
        if '@Environment(\\.raidoTheme)' in part.split('var body:', 1)[0]: continue
        body = re.search(r'(?:var body: some View|func body\(content: Content\) -> some View)\s*\{', part)
        if not body: continue
        rest = part[body.end():]
        if 'func body(' in body.group():
            rest = re.sub(r'^(\s*)content\b', r'\1return content', rest, count=1)
        part = part[:body.end()] + '\n        let _ = raidoVisualTheme\n' + rest
        part = '\n    @Environment(\\.raidoTheme) private var raidoVisualTheme' + part
        text = text[:match.end()] + part + text[end:]
    return text
s = observe_theme(s)

app = '''import SwiftUI

@main
struct RAIDORosterApp: App {
    @AppStorage("RAIDORoster.Theme") private var themeRaw = "ice"
    @AppStorage("RAIDORoster.Appearance.Ice") private var iceAppearance = "system"
    @AppStorage("RAIDORoster.Appearance.GetJet") private var getJetAppearance = "system"

    private var theme: RaidoTheme { RaidoAppearancePreferences.selectedTheme(themeRaw) }
    private var appearance: RaidoAppearance {
        RaidoAppearancePreferences.appearance(theme: themeRaw, ice: iceAppearance, getJet: getJetAppearance)
    }
    private var preferredScheme: ColorScheme? {
        appearance.forcedDark.map { $0 ? .dark : .light }
    }
    init() {
        RaidoAppearancePreferences.migrate(.standard)
        MidnightTheme.configure()
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\\.raidoTheme, theme)
                .preferredColorScheme(preferredScheme)
                .background(RaidoChromeRefresh(theme: theme, appearance: appearance).allowsHitTesting(false))
        }
    }
}
'''
pbx = PBX.read_text()
name, build, file = 'AppearanceModels.swift', 'A22900000000000000000001', 'B22900000000000000000001'
pbx = once(pbx, '/* End PBXBuildFile section */', f'\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file} /* {name} */; }};\n/* End PBXBuildFile section */')
pbx = once(pbx, '/* End PBXFileReference section */', f'\t\t{file} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */')
pbx = once(pbx, 'B00000000000000000000002 /* ContentView.swift */,', f'B00000000000000000000002 /* ContentView.swift */,\n\t\t\t\t{file} /* {name} */,')
pbx = once(pbx, 'A00000000000000000000002 /* ContentView.swift in Sources */,', f'A00000000000000000000002 /* ContentView.swift in Sources */, {build} /* {name} in Sources */,')
pbx = re.sub(r'MARKETING_VERSION = [^;]+;', 'MARKETING_VERSION = 2.29.0;', pbx)
pbx = re.sub(r'CURRENT_PROJECT_VERSION = [^;]+;', 'CURRENT_PROJECT_VERSION = 2290;', pbx)

CONTENT.write_text(s)
(APP / 'RAIDORosterApp.swift').write_text(app)
PBX.write_text(pbx)
for source in APP.glob('*.swift'):
    if source.name in {'ContentView.swift', 'RAIDORosterApp.swift'}: continue
    text = source.read_text()
    if 'MidnightTheme.' in text: source.write_text(observe_theme(text))
print('V2.29 Ice + GetJet themes applied')
