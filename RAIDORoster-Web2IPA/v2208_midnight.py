"""V2.20.8: Midnight Blue presentation. Runs after all functional patches."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
APP = ROOT / 'RAIDORoster'

def replace_once(s, old, new):
    if s.count(old) != 1:
        raise RuntimeError(f'Midnight anchor expected once, found {s.count(old)}: {old[:100]}')
    return s.replace(old, new, 1)

def region(s, start, end, transform):
    a, b = s.index(start), s.index(end, s.index(start))
    return s[:a] + transform(s[a:b]) + s[b:]

theme = r'''

// Shared native presentation tokens. Functional models do not depend on this theme.
enum MidnightTheme {
    static let accent = Color(red: 0.08, green: 0.56, blue: 1.0)
    static func adaptive(_ dark: UInt32, _ light: UInt32) -> UIColor {
        UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
    static let backgroundUI = adaptive(0x081725, 0xF2F6FC)
    static let surfaceUI = adaptive(0x102437, 0xFFFFFF)
    static let elevatedUI = adaptive(0x163149, 0xE7EFF9)
    static let background = Color(uiColor: backgroundUI)
    static let surface = Color(uiColor: surfaceUI)
    static let elevated = Color(uiColor: elevatedUI)
    static let border = Color(uiColor: adaptive(0x233D54, 0xD7E3F0))

    @MainActor static func configure() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = backgroundUI
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor.label]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.label]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = backgroundUI
        tab.shadowColor = adaptive(0x233D54, 0xD7E3F0)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UISegmentedControl.appearance().selectedSegmentTintColor = UIColor(accent)
        UISegmentedControl.appearance().backgroundColor = elevatedUI
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: UIColor.label], for: .normal)
    }
}

private struct MidnightCard: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(MidnightTheme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(MidnightTheme.border.opacity(0.75), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func midnightCard(radius: CGFloat = 18) -> some View { modifier(MidnightCard(radius: radius)) }
    func midnightCanvas() -> some View {
        scrollContentBackground(.hidden)
            .background(MidnightTheme.background.ignoresSafeArea())
            .toolbarBackground(MidnightTheme.background, for: .navigationBar, .tabBar)
            .toolbarBackground(.visible, for: .navigationBar, .tabBar)
            .tint(MidnightTheme.accent)
    }
}

private struct MidnightQuickAction: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(MidnightTheme.accent)
                Text(title).font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .padding(.horizontal, 4).padding(.vertical, 6)
            .midnightCard(radius: 15)
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}
'''

p = APP / 'ContentView.swift'
s = p.read_text()
s = replace_once(s, '.environmentObject(appState.rosterStore)', '.environmentObject(appState.rosterStore)\n        .tint(MidnightTheme.accent)')
s = s.replace('Text("GetJet / AirHub Roster")\n                    .font(.system(size: 22, weight: .bold))',
              'Text("RAIDO")\n                    .font(.system(size: 19, weight: .semibold))\n                    .tracking(3)')
s = region(s, 'struct RosterHeaderPrincipal:', 'struct RosterHomeView:', lambda t:
    t.replace('Text(statusText(at: context.date))', 'Text("GetJet · Airhub")'))
# Sync remains visible below the calendar, with its original freshness logic.
s = replace_once(s, 'RosterMonthCalendarView(store: store, browser: browser, earnings: earnings, changedDates: store.changedDates)',
                 'RosterMonthCalendarView(store: store, browser: browser, earnings: earnings, changedDates: store.changedDates)\n                        SyncFreshnessStrip(store: store)')

def calendar(t):
    t = t.replace('spacing: 3), count: 7)', 'spacing: 5), count: 7)')
    t = t.replace('LazyVGrid(columns: columns, spacing: 4)', 'LazyVGrid(columns: columns, spacing: 6)')
    t = t.replace('minHeight: 76', 'minHeight: 48')
    t = t.replace('.frame(width: 30, height: 30)', '.frame(width: 44, height: 44)')
    t = t.replace('                Text(monthTitle)\n                    .font(.title3.bold())',
                  '                Spacer(minLength: 0)\n                Text(monthTitle)\n                    .font(.headline)\n                Spacer(minLength: 0)')
    t = t.replace('                Spacer()\n                if !changedDates.isEmpty {\n                    Label("Changed", systemImage: "circle.fill")\n                        .font(.caption2.weight(.semibold))\n                        .foregroundStyle(.orange)\n                }', '')
    t = t.replace('            if let selectedItem {', r'''            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { calendarLegend }
                VStack(alignment: .leading, spacing: 8) { calendarLegend }
            }.padding(.vertical, 6)

            if let selectedItem {''')
    t = t.replace('        .padding(.horizontal, 5)\n        .padding(.vertical, 12)\n        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))', '')
    t = t.replace('    private func navigateMonth', r'''    @ViewBuilder private var calendarLegend: some View {
        ForEach(["FLIGHT", "STANDBY", "OFF", "POSITIONING"], id: \.self) { category in
            HStack(spacing: 4) {
                Circle().fill(categoryColor(category)).frame(width: 5, height: 5)
                Text(category == "FLIGHT" ? "Flight" : category == "STANDBY" ? "Standby" : category == "OFF" ? "Off" : "Positioning")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func navigateMonth''')
    return t
s = region(s, 'struct RosterMonthCalendarView:', 'struct RosterCalendarDayCell:', calendar)
cell = r'''struct RosterCalendarDayCell: View {
    let item: RosterItem?
    let day: Int
    let isToday: Bool
    let isChanged: Bool
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 5) {
            Text("\(day)")
                .font(.subheadline.weight(isToday || isSelected ? .bold : .regular))
                .foregroundStyle(item == nil ? Color.secondary : Color.primary)
            HStack(spacing: 3) {
                Circle().fill(item.map { categoryColor($0.category) } ?? .clear)
                    .frame(width: 5, height: 5)
                if isChanged { Circle().fill(Color.orange).frame(width: 4, height: 4) }
            }.accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(isSelected ? MidnightTheme.elevated : MidnightTheme.surface.opacity(item == nil ? 0.3 : 0.65),
                    in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(isSelected || isToday ? MidnightTheme.accent : MidnightTheme.border.opacity(0.6),
                              lineWidth: isSelected ? 1.5 : 0.5)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day), \(item?.displayTitle ?? "No roster data")\(isToday ? ", today" : "")\(isChanged ? ", changed" : "")")
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

'''
s = region(s, 'struct RosterCalendarDayCell:', 'struct RosterCalendarAgendaCard:', lambda _: cell)

def today(t):
    a, b = t.index('                    SyncFreshnessStrip(store: store)'), t.index('                    if !store.isCacheValidated')
    t = t[:a] + r'''                    if store.isCacheValidated, let item = store.todayPrimaryItem {
                        DutyHeroCard(item: item)
                    }
                    HStack(spacing: 10) {
                        MidnightQuickAction(title: "Announcements", symbol: "megaphone.fill") { showAnnouncements = true }
                        MidnightQuickAction(title: "Fleet", symbol: "airplane") { showFleet = true }
                        MidnightQuickAction(title: "Crew Control", symbol: "person.2.fill") { showCrewControl = true }
                    }
                    SyncFreshnessStrip(store: store)

''' + t[b:]
    t = t.replace('DutyBriefingView(item: item, showTechnical: false)', 'DutyBriefingView(item: item, showTechnical: false, showHero: false)')
    a, b = t.index('            .toolbar {'), t.index('            .alert("Calendar"')
    t = t[:a] + r'''            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("RAIDO").font(.headline).tracking(3)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: openPortal) { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Open RAIDO and sync")
                }
            }
''' + t[b:]
    return t
s = region(s, 'struct TodayView:', 'struct RestToNextDutyCard:', today)
s = region(s, 'struct DutyBriefingView:', 'struct DutyLiveStatusCard:', lambda t:
    t.replace('    let showTechnical: Bool', '    let showTechnical: Bool\n    var showHero = true').replace('            DutyHeroCard(item: item)', '            if showHero { DutyHeroCard(item: item) }'))

def fleet(t):
    t = t.replace('    @State private var filter:', '    @State private var query = ""\n    @State private var filter:')
    t = t.replace('        return filtered.sorted {', r'''        let matching = filtered.filter { aircraft in
            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            [aircraft.registration, aircraft.type, aircraft.operatorName]
                .contains { $0.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return matching.sorted {''')
    t = t.replace('            .navigationTitle("Fleet")', '            .searchable(text: $query, prompt: "Registration or aircraft type")\n            .navigationTitle("Fleet")')
    t = t.replace('                Section("GETJET / AIRHUB FLEET") {', r'''                if visibleAircraft.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                Section("GETJET / AIRHUB FLEET") {''')
    return t
s = region(s, 'struct FleetView:', 'private func fleetDuration', fleet)
def fleetrow(t):
    a = t.index('    var body: some View {')
    return t[:a] + r'''    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            HStack(spacing: 16) {
                Image(systemName: "airplane")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(MidnightTheme.accent)
                    .frame(width: 42)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Text("\(aircraft.registration) · \(aircraft.type)")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if isAssigned {
                        Text("YOUR DUTY").font(.caption2.weight(.semibold)).foregroundStyle(MidnightTheme.accent)
                    }
                    Text(status.0).font(.caption.weight(.semibold))
                        .foregroundStyle(status.1)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(status.1.opacity(0.12), in: Capsule())
                    Text(snapshot.map { "Position " + fleetCompactAge($0.effectivePositionAge) } ?? "No recent position received")
                        .font(.caption).foregroundStyle(.secondary)
                    if let snapshot, let route = snapshot.route {
                        Text(route).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 14).padding(.horizontal, 14)
                .midnightCard(radius: 18)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
    }
}


'''
s = region(s, 'private struct FleetAircraftRow:', '@MainActor\nprivate final class FleetAircraftPhotoStore:', fleetrow)
s = s.replace('Text("Dark").tag("dark")', 'Text("Midnight").tag("dark")')
s = s.replace('Text("System follows the iPhone appearance automatically.")', 'Text("Midnight Blue uses deep navy surfaces and blue accents. System follows your iPhone’s appearance.")')
p.write_text(s)

p = APP / 'EarningsView.swift'
s = p.read_text()
a = s.index('    var body: some View {', s.index('struct MonthlyEarningsCard:'))
b = s.index('\nprivate enum EarningsEditor:', a)
s = s[:a] + r'''    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                NavigationLink {
                    MonthlyEarningsView(roster: roster, earnings: earnings, month: month)
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Image(systemName: "clock").foregroundStyle(MidnightTheme.accent)
                        Text(EarningsMath.hours(summary.estimatedMinutes))
                            .font(.title3.weight(.semibold).monospacedDigit())
                        Text("Block hours").font(.caption)
                        Text(raidoBLHMinutes == nil ? "Estimate" : "RAIDO total")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).midnightCard(radius: 16)
                }.buttonStyle(.plain)
                ZStack(alignment: .topTrailing) {
                    NavigationLink {
                        MonthlyEarningsView(roster: roster, earnings: earnings, month: month)
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Image(systemName: "banknote").foregroundStyle(.green)
                            Text(earnings.error != nil ? "Unavailable" : hideAmount ? "••••" : EarningsMath.money(summary.totalCents))
                                .font(.title3.weight(.semibold).monospacedDigit())
                                .lineLimit(1).minimumScaleFactor(0.65)
                            Text("Estimated earnings").font(.caption)
                            Text("\(daily.filter(\.paid).count) paid days + BLH")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14).midnightCard(radius: 16)
                    }.buttonStyle(.plain)
                    Button { hideAmount.toggle() } label: {
                        Image(systemName: hideAmount ? "eye.slash" : "eye")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                    }.buttonStyle(.plain)
                    .accessibilityLabel(hideAmount ? "Show earnings amount" : "Hide earnings amount")
                }
            }
            if daily.contains(where: \.needsReview) {
                Text("Some daily payments need review").font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}
''' + s[b:]
p.write_text(s)

# Apply common surfaces to every native screen, including secondary sheets.
def closing_brace(text, start):
    depth, quoted, escaped, line_comment, block_comment = 0, False, False, False, False
    i = start
    while i < len(text):
        c, pair = text[i], text[i:i+2]
        if line_comment:
            if c == '\n': line_comment = False
        elif block_comment:
            if pair == '*/': block_comment = False; i += 1
        elif quoted:
            if escaped: escaped = False
            elif c == '\\': escaped = True
            elif c == '"': quoted = False
        elif pair == '//': line_comment = True; i += 1
        elif pair == '/*': block_comment = True; i += 1
        elif c == '"': quoted = True
        elif c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: return i
        i += 1
    raise RuntimeError('Unclosed Swift body')

for name in ['ContentView.swift', 'AnnouncementsView.swift', 'EarningsView.swift']:
    p = APP / name
    s = p.read_text()
    s = re.sub(r'\.background\(Color.secondary.opacity\([0-9.]+\), in: RoundedRectangle\(cornerRadius: (\d+)\)\)',
               r'.midnightCard(radius: \1)', s)
    s = re.sub(r'\.background\(\.thinMaterial, in: RoundedRectangle\(cornerRadius: (\d+)\)\)',
               r'.midnightCard(radius: \1)', s)
    s = s.replace('Color(uiColor: .systemBackground)', 'MidnightTheme.background')
    s = s.replace('.navigationTitle(', '.midnightCanvas().navigationTitle(')
    # Section backgrounds propagate to their rows on both Form and List (iOS 17+).
    ends = []
    for m in re.finditer(r'\bSection(?:\([^\n]*?\))?\s*\{', s):
        end = closing_brace(s, m.end() - 1)
        while True:
            trailing = re.match(r'\s*(?:header|footer):\s*\{', s[end+1:])
            if not trailing: break
            end = closing_brace(s, end + 1 + trailing.end() - 1)
        ends.append(end+1)
    for end in sorted(set(ends), reverse=True):
        s = s[:end] + '.listRowBackground(MidnightTheme.surface)' + s[end:]
    if name == 'AnnouncementsView.swift':
        s = s.replace('.background(Color.primary.opacity(0.05), in: Capsule())', '.background(MidnightTheme.elevated, in: Capsule())')
        s = s.replace('.background(.bar)', '.background(MidnightTheme.background)')
    if name == 'ContentView.swift': s += theme
    p.write_text(s)

p = APP / 'RAIDORosterApp.swift'
s = p.read_text()
s = replace_once(s, '    var body: some Scene {', '''    init() {
        MidnightTheme.configure()
        // Selecting this redesign opts into Midnight once; subsequent appearance choices persist.
        if !UserDefaults.standard.bool(forKey: "RAIDORoster.MidnightIntroduced") {
            UserDefaults.standard.set("dark", forKey: "RAIDORoster.Appearance")
            UserDefaults.standard.set(true, forKey: "RAIDORoster.MidnightIntroduced")
        }
    }

    var body: some Scene {''')
p.write_text(s)
for relative in ['RAIDORoster/ContentView.swift', 'RAIDORoster.xcodeproj/project.pbxproj']:
    p = ROOT / relative
    s = p.read_text()
    if '2.20.7' not in s: raise RuntimeError('Version anchor changed: ' + relative)
    p.write_text(s.replace('2.20.7', '2.20.8'))
print('V2.20.8 Midnight Blue applied across native companion screens')
