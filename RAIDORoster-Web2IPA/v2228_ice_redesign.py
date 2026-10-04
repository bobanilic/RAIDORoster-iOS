"""V2.28.0: shared Ice appearance, Today map header and four-tab navigation."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
APP = ROOT / 'RAIDORoster'
CONTENT = APP / 'ContentView.swift'
PBX = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
MARKER = '// V2.28 Ice presentation.'
s, pbx = CONTENT.read_text(), PBX.read_text()
if MARKER in s:
    if 'case today, roster, fleet, more' not in s or 'B22800000000000000000001' not in pbx:
        raise RuntimeError('Incomplete Ice installation')
    print('V2.28 Ice redesign already applied')
    raise SystemExit(0)

def once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f'Ice anchor count {text.count(old)}: {old[:100]!r}')
    return text.replace(old, new, 1)

def region(text, start, end, transform):
    a = text.index(start)
    b = text.index(end, a)
    return text[:a] + transform(text[a:b]) + text[b:]

s = once(s, 'enum MainTab: Hashable { case roster, today, portal, settings }',
         'enum MainTab: Hashable { case today, roster, fleet, more }')
s = once(s, '@State private var selectedTab: MainTab = .roster',
         '@State private var selectedTab: MainTab = .today\n    @State private var showPortal = false')
a = s.index('        TabView(selection: $selectedTab) {')
b = s.index('        .onAppear { TodayLiveFlightLocationManager', a)
s = s[:a] + r'''        TabView(selection: $selectedTab) {
            TodayView(store: appState.rosterStore) { showPortal = true }
                .tabItem { Label("Today", systemImage: "sun.max") }.tag(MainTab.today)
            RosterHomeView(store: appState.rosterStore, browser: appState.browser) { showPortal = true }
                .tabItem { Label("Roster", systemImage: "calendar") }.tag(MainTab.roster)
            FleetView(store: appState.rosterStore, tabActive: selectedTab == .fleet, showsDismissButton: false)
                .tabItem { Label("Fleet", systemImage: "airplane") }.tag(MainTab.fleet)
            IceMoreView(store: appState.rosterStore, browser: appState.browser) { showPortal = true }
                .tabItem { Label("More", systemImage: "ellipsis") }.tag(MainTab.more)
        }
        .environmentObject(appState.rosterStore)
        .tint(MidnightTheme.accent)
        .foregroundStyle(MidnightTheme.ink)
        .sheet(isPresented: $showPortal) {
            PortalView(model: appState.browser, store: appState.rosterStore) { showPortal = false; selectedTab = .roster }
        }
''' + s[b:]

# Replace Today as a whole, keeping the models and sensor manager untouched.
s = region(s, 'struct TodayView: View {', 'struct RestToNextDutyCard:', lambda _: '')
s += '\n' + (ROOT / 'v2228_ice_views.swift.inc').read_text()

def roster(t):
    t = once(t, '                    Picker("Roster view",', '''                    HStack(alignment: .top) {
                        IcePageHeading(title: "Roster", subtitle: "Your month, at a glance")
                        Button(action: openPortal) {
                            Image(systemName: store.isCacheValidated ? "checkmark.icloud" : "icloud.slash")
                                .font(.title3).frame(width: 44, height: 44)
                        }.accessibilityLabel("Open Live RAIDO and sync")
                    }.padding(.top, 10).padding(.bottom, 4)
                    Picker("Roster view",''')
    a, b = t.index('            .midnightCanvas().navigationTitle'), t.index('\n        }\n    }', t.index('            .midnightCanvas().navigationTitle'))
    t = t[:a] + '            .midnightCanvas().toolbar(.hidden, for: .navigationBar)' + t[b:]
    return t
s = region(s, 'struct RosterHomeView:', 'struct OperationalMetricsGrid:', roster)

def calendar(t):
    t = t.replace('spacing: 3), count: 7)', 'spacing: 3), count: 7)')
    t = t.replace('private let weekdays = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]',
                  'private let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]')
    t = t.replace('LazyVGrid(columns: columns, spacing: 4)', 'LazyVGrid(columns: columns, spacing: 8)')
    t = t.replace('.font(.caption2.bold())', '.font(.caption.weight(.medium))')
    t = t.replace('minHeight: 76', 'minHeight: 64')
    earnings = '''            if let month = store.selectedRosterMonth {
                MonthlyEarningsCard(roster: store, earnings: earnings, month: month)
            }
'''
    t = once(t, earnings, '')
    a = t.index('            if let selectedItem {')
    b = t.index('\n        }\n', a)
    t = t[:a] + '''            if let selectedItem {
                IceSelectedRosterDay(item: selectedItem, isChanged: selectedItem.dateISO.map(changedDates.contains) ?? false)
                    .transition(.opacity)
            }
            if let month = store.selectedRosterMonth {
                DisclosureGroup("Month overview & earnings") {
                    MonthlyEarningsCard(roster: store, earnings: earnings, month: month).padding(.top, 10)
                }.font(.subheadline).padding(14).midnightCard(radius: 14)
            }
''' + t[b:]
    # Jump to the current month without losing the selected-day semantics.
    anchor = '                Text(monthTitle)\n                    .font(.headline)'
    t = once(t, anchor, '''                Text(monthTitle).font(.title3.weight(.semibold))
                Button("Today") {
                    let today = rosterCalendarTodayISO()
                    if store.selectRosterMonthIfCached(String(today.prefix(7))) { selectedDateISO = today }
                }.font(.caption.weight(.medium)).frame(minHeight: 44)''')
    return t
s = region(s, 'struct RosterMonthCalendarView:', 'struct RosterCalendarDayCell:', calendar)
cell = r'''struct RosterCalendarDayCell: View {
    let item: RosterItem?
    let day: Int
    let isToday: Bool
    let isChanged: Bool
    let isSelected: Bool
    var body: some View {
        VStack(spacing: 4) {
            Text("\(day)").font(.system(size: 17, weight: isSelected || isToday ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : item == nil ? Color.secondary : MidnightTheme.ink)
                .frame(width: 32, height: 32)
                .background(isSelected ? MidnightTheme.accent : .clear, in: Circle())
                .overlay { if isToday && !isSelected { Circle().strokeBorder(MidnightTheme.accent.opacity(0.6), lineWidth: 1) } }
            if let item {
                HStack(spacing: 3) {
                    Circle().fill(categoryColor(item.category)).frame(width: 4, height: 4)
                    Text(calendarPrimaryLabel(item)).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(categoryColor(item.category)).lineLimit(1).minimumScaleFactor(0.6)
                    if isChanged { Circle().fill(Color.orange).frame(width: 4, height: 4) }
                }
                if let secondary = calendarSecondaryLabel(item) {
                    Text(secondary).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, minHeight: 64, alignment: .top).contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(day), \(item?.displayTitle ?? "No roster data")\(isToday ? ", today" : "")\(isChanged ? ", changed" : "")")
            .accessibilityValue(isSelected ? "Selected" : "")
    }
}

'''
s = region(s, 'struct RosterCalendarDayCell:', 'struct RosterCalendarAgendaCard:', lambda _: cell)

def map_card(t):
    t = once(t, '    let item: RosterItem\n', '''    let item: RosterItem
    var iceHeader = false
    @State private var mapExpanded = false
''')
    t = once(t, '    var body: some View {\n        VStack', '    private var legacyBody: some View {\n        VStack')
    start = t.index('            ZStack {', t.index('private var legacyBody'))
    end = t.index('            .frame(height: gps.isTracking ? 230 : 195)', start)
    surface = t[start:end].strip()
    controls = surface.index('                VStack {\n                    HStack {\n                        Menu')
    surface = surface[:controls] + '                if !iceHeader {\n' + surface[controls:-1] + '                }\n            }'
    # Compact passive map, expanded interactive map. The gesture belongs to the
    # canvas rather than the disabled badge overlay.
    surface = surface.replace('                        .allowsHitTesting(false)\n                        .contentShape(Rectangle())',
                              '                        .contentShape(Rectangle())')
    t = t[:start] + '            mapSurface\n' + t[end:]
    # Common lifecycle remains attached to either visual presentation.
    a = t.index('        .animation(.snappy(duration: 0.2), value: gps.isTracking)')
    b = t.index('\n    @ViewBuilder\n    private func liveMetric', a)
    lifecycle = t[a:b]
    # lifecycle includes the closing body brace; add a conditional public body.
    body = '''    var body: some View {
        Group {
            if iceHeader { iceMapHeader } else { legacyBody }
        }
''' + lifecycle + '\n'
    t = t[:a] + '    }\n\n' + body + '    private var mapSurface: some View {\n        ' + surface + '\n    }\n\n' + (ROOT / 'v2228_map_header.swift.inc').read_text() + '\n' + t[b:]
    return t
s = region(s, 'struct TodayRouteMapCard:', 'private struct OfflineAviationMapCanvas:', map_card)

def fleet(t):
    t = once(t, '    @ObservedObject var store: RosterStore', '    @ObservedObject var store: RosterStore\n    var tabActive = true\n    var showsDismissButton = true')
    t = once(t, '            List {', '''            List {
                IcePageHeading(title: "Fleet", subtitle: "Your aircraft, rotation & live observations")
                    .padding(.vertical, 8).listRowSeparator(.hidden).listRowBackground(Color.clear)''')
    t = once(t, '            .searchable(text: $query', '''            .listStyle(.plain)
            .listRowSeparator(.hidden)
            .midnightCanvas()
            .searchable(text: $query''')
    t = t.replace('.navigationTitle("Fleet")', '.navigationTitle("")')
    t = once(t, 'ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }',
             'ToolbarItem(placement: .cancellationAction) { if showsDismissButton { Button("Done") { dismiss() } } }')
    # In a tab the lifetime exceeds visibility. Explicitly cancel polling when
    # another tab is selected, preserving the bounded refresh policy.
    t = t.replace('.task(id: "\\(scenePhase)-\\(refreshNonce)-"', '.task(id: "\\(tabActive)-\\(scenePhase)-\\(refreshNonce)-"')
    t = once(t, 'guard scenePhase == .active else { return }', 'guard tabActive, scenePhase == .active else { return }')
    t = t.replace('                                .contentShape(Rectangle())',
                  '                                .listRowBackground(Color.clear).listRowSeparator(.hidden)\n                                .contentShape(Rectangle())')
    return t
s = region(s, 'struct FleetView:', 'private func fleetDuration', fleet)
def fleet_row(t):
    t = t.replace('.font(.title2.weight(.semibold))', '.font(.title2.weight(.regular))')
    t = t.replace('.font(.subheadline.weight(.bold))', '.font(.subheadline.weight(.medium))')
    return once(t, '            .padding(.vertical, 5)', '            .padding(14).midnightCard(radius: 16)')
s = region(s, 'private struct FleetAircraftRow:', '@MainActor\nprivate final class FleetAircraftPhotoStore:', fleet_row)

def settings(t):
    a = t.index('                Section("Fleet") {')
    b = t.index('                Section("Units") {', a)
    t = t[:a] + t[b:]
    t = t.replace('Text("Midnight").tag("dark")', 'Text("Ice Dark").tag("dark")')
    t = t.replace('Text("Light").tag("light")', 'Text("Ice").tag("light")')
    t = t.replace('Midnight Blue uses deep navy surfaces and blue accents. System follows your iPhone’s appearance.',
                  'Ice uses soft blue surfaces and clear typography. Ice Dark keeps the same layout with deep navy surfaces. System follows your iPhone’s appearance.')
    t = t.replace('LabeledContent("RAIDO Roster", value: "2.26.1")', '''LabeledContent("RAIDO Roster", value: "2.28.0")
                    Link("Airport time zones · OpenFlights (ODbL)", destination: URL(string: "https://openflights.org/data.html#license")!)
                        .font(.caption)''')
    return once(t, '.midnightCanvas().navigationTitle("Settings")', '''.midnightCanvas().navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }''').replace(
                'struct SettingsView: View {', 'struct SettingsView: View {\n    @Environment(\\.dismiss) private var dismiss')
s = region(s, 'struct SettingsView:', 'struct DutyHeroCard:', settings)
s = once(s, '.midnightCanvas().navigationTitle(model.pageTitle.isEmpty ? "RAIDO" : model.pageTitle)',
         '.midnightCanvas().navigationTitle(model.pageTitle.isEmpty ? "Live RAIDO" : model.pageTitle)')
s = once(s, 'ToolbarItemGroup(placement: .topBarTrailing) {\n                    Button { model.goBack()',
         'ToolbarItemGroup(placement: .topBarTrailing) {\n                    Button("Done", action: openRoster)\n                    Button { model.goBack()')

# Shared appearance updates every existing themed detail screen too.
s = once(s, 'static let accent = Color(red: 0.08, green: 0.56, blue: 1.0)',
         'static let accent = Color(uiColor: adaptive(0x7DC3E4, 0x1F6C94))')
s = once(s, 'adaptive(0x081725, 0xF2F6FC)', 'adaptive(0x0D1A25, 0xEEF4F7)')
s = once(s, 'adaptive(0x102437, 0xFFFFFF)', 'adaptive(0x142C3B, 0xFFFFFF)')
s = once(s, 'adaptive(0x163149, 0xE7EFF9)', 'adaptive(0x1B3B4B, 0xE2EEF4)')
s = once(s, '    static let border = Color(uiColor: adaptive(0x233D54, 0xD7E3F0))', '''    static let border = Color(uiColor: adaptive(0x294452, 0xD8E4EB))
    static let ink = Color(uiColor: adaptive(0xE6F0F5, 0x172E3E))
    static let warning = Color(uiColor: adaptive(0x392C20, 0xFFF0DA))
    static let warningInk = Color(uiColor: adaptive(0xE9BD85, 0x885519))
    static let mapSea = Color(uiColor: adaptive(0x163747, 0xD8EAF1))''')
s = region(s, 'private struct MidnightCard:', 'extension View {\n    func midnightCard', lambda t:
           t[:t.index('            .overlay {')] + '''            .shadow(color: .black.opacity(0.025), radius: 12, x: 0, y: 4)
    }
}

''')
s = once(s, '.font(.system(size: 23, weight: .medium))', '.font(.system(size: 21, weight: .regular))')
CONTENT.write_text(s)

earnings = APP / 'EarningsView.swift'
earnings.write_text(once(earnings.read_text(), 'private struct MonthlyEarningsView:', 'struct MonthlyEarningsView:'))

# Preserve the authenticated browser/page after moving the portal into a sheet.
# WKUserContentController retains handlers, so its coordinator must weakly hold
# the model. The model can then retain the reusable web view without a cycle.
web = APP / 'RosterWebView.swift'
w = web.read_text()
w = once(w, 'fileprivate weak var webView: WKWebView?', 'fileprivate var webView: WKWebView?')
w = once(w, '    func makeUIView(context: Context) -> WKWebView {', '''    func makeUIView(context: Context) -> WKWebView {
        if let existing = model.webView {
            let controller = existing.configuration.userContentController
            controller.removeScriptMessageHandler(forName: "rosterCache")
            controller.removeScriptMessageHandler(forName: "rosterCalendarFeed")
            controller.add(context.coordinator, name: "rosterCache")
            controller.add(context.coordinator, name: "rosterCalendarFeed")
            existing.navigationDelegate = context.coordinator
            existing.uiDelegate = context.coordinator
            let refresh = UIRefreshControl()
            refresh.addTarget(context.coordinator, action: #selector(Coordinator.refresh(_:)), for: .valueChanged)
            existing.scrollView.refreshControl = refresh
            return existing
        }''')
a = w.index('    final class Coordinator:')
c = w[a:]
c = once(c, 'private let model: RosterBrowserModel', 'private weak var model: RosterBrowserModel?')
for anchor in [
    '@objc func refresh(_ sender: UIRefreshControl) {',
    'func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {',
    'func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {',
    'func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {',
    'private func showOfflineError(_ error: Error) {',
]:
    c = once(c, anchor, anchor + '\n            guard let model else { return }')
c = c.replace('self.model.', 'model.')
w = w[:a] + c
web.write_text(w)

app = APP / 'RAIDORosterApp.swift'
a = app.read_text()
start = a.index('        // Selecting this redesign')
end = a.index('\n    }', start)
a = a[:start] + '''        // Opt into the approved light Ice design once; retain subsequent choices.
        if !UserDefaults.standard.bool(forKey: "RAIDORoster.IceIntroduced") {
            UserDefaults.standard.set("light", forKey: "RAIDORoster.Appearance")
            UserDefaults.standard.set(true, forKey: "RAIDORoster.IceIntroduced")
        }''' + a[end:]
app.write_text(a)

name = 'AirportTimeZones.json'
if not (APP / name).is_file(): raise RuntimeError(name + ' missing')
build_id, file_id = 'A22800000000000000000001', 'B22800000000000000000001'
pbx = once(pbx, '/* End PBXBuildFile section */', f'\t\t{build_id} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};\n/* End PBXBuildFile section */')
pbx = once(pbx, '/* End PBXFileReference section */', f'\t\t{file_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = text.json; path = {name}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */')
pbx = once(pbx, 'B00000000000000000000002 /* ContentView.swift */,', f'B00000000000000000000002 /* ContentView.swift */,\n\t\t\t\t{file_id} /* {name} */,')
pbx = once(pbx, 'A00000000000000000000004 /* RosterEnhancements.js in Resources */,', f'A00000000000000000000004 /* RosterEnhancements.js in Resources */, {build_id} /* {name} in Resources */,')
pbx = re.sub(r'MARKETING_VERSION = [^;]+;', 'MARKETING_VERSION = 2.28.0;', pbx)
pbx = re.sub(r'CURRENT_PROJECT_VERSION = [^;]+;', 'CURRENT_PROJECT_VERSION = 2280;', pbx)
PBX.write_text(pbx)
print('V2.28 Ice redesign applied')
