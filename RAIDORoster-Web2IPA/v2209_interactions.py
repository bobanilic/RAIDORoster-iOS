"""V2.20.9: restore informative calendar and improve companion interactions."""
from pathlib import Path
ROOT = Path(__file__).resolve().parent
APP = ROOT / 'RAIDORoster'
def once(s, old, new):
    if s.count(old) != 1: raise RuntimeError('Interaction fix anchor changed: ' + old[:100])
    return s.replace(old, new, 1)
def region(s, start, end, transform):
    a = s.index(start); b = s.index(end, a)
    return s[:a] + transform(s[a:b]) + s[b:]

def repair():
    p = APP / 'ContentView.swift'
    s = p.read_text()
    s = region(s, 'struct RosterCalendarDayCell:', 'struct RosterCalendarAgendaCard:', lambda _: CALENDAR_CELL)
    def calendar(t):
        t = t.replace('spacing: 5), count: 7)', 'spacing: 3), count: 7)')
        t = t.replace('LazyVGrid(columns: columns, spacing: 6)', 'LazyVGrid(columns: columns, spacing: 4)')
        t = t.replace('minHeight: 48', 'minHeight: 76')
        t = once(t, '        .sensoryFeedback(.selection, trigger: selectedDateISO)', r'''        .onChange(of: items.map(\.dateISO)) { _, _ in
            if let selectedDateISO, itemsByDate[selectedDateISO] != nil { return }
            let today = rosterCalendarTodayISO()
            selectedDateISO = itemsByDate[today] != nil ? today : items.compactMap(\.dateISO).first
        }
        .sensoryFeedback(.selection, trigger: selectedDateISO)''')
        return t
    s = region(s, 'struct RosterMonthCalendarView:', 'struct RosterCalendarDayCell:', calendar)
    # One native sheet presenter avoids competing presentations from Today actions.
    def today(t):
        t = once(t, '''    @State private var showCrewControl = false
    @State private var showFleet = false
    @State private var showAnnouncements = false''', '''    private enum CompanionSheet: String, Identifiable {
        case crewControl, fleet, announcements
        var id: String { rawValue }
    }
    @State private var activeSheet: CompanionSheet?''')
        t = t.replace('showAnnouncements = true', 'activeSheet = .announcements')
        t = t.replace('showFleet = true', 'activeSheet = .fleet')
        t = t.replace('showCrewControl = true', 'activeSheet = .crewControl')
        a = t.index('            .sheet(isPresented: $showCrewControl)')
        b = t.index('\n        }\n    }', a)
        return t[:a] + '''            .sheet(item: $activeSheet) { destination in
                switch destination {
                case .crewControl:
                    CrewControlSheet(item: store.todayPrimaryItem ?? store.nextDuty)
                case .fleet:
                    FleetView(store: store)
                case .announcements:
                    AnnouncementsView(item: store.isCacheValidated ? store.todayPrimaryItem : nil)
                }
            }''' + t[b:]
    s = region(s, 'struct TodayView:', 'struct RestToNextDutyCard:', today)
    def sync_status(t):
        a = t.index('    var body: some View {')
        b = t.index('    private var statusColor:', a)
        return t[:a] + '''    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 9) {
                Image(systemName: store.hasCache && store.isCacheValidated ? "checkmark.icloud" : "icloud.slash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
                Text(statusText(at: context.date))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }

''' + t[b:]
    s = region(s, 'struct SyncFreshnessStrip:', 'private func compactRelativeAge', sync_status)
    p.write_text(s)

    p = APP / 'EarningsView.swift'
    s = region(p.read_text(), 'struct MonthlyEarningsCard:', 'private enum EarningsEditor:', lambda _: EARNINGS_CARD)
    s = once(s, '@AppStorage("RAIDORoster.Earnings.HideAmount") private var hideAmount = false', '''@State private var hideAmount = true
    @Environment(\\.scenePhase) private var scenePhase''')
    s = once(s, '        .midnightCard(radius: 16)', '''        .midnightCard(radius: 16)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { hideAmount = true }
        }
        .onDisappear { hideAmount = true }''')
    p.write_text(s)

    p = APP / 'AnnouncementsView.swift'
    s = p.read_text()
    s = once(s, '    @State private var scrollID: String?', '    @State private var scrollID: String?\n    @State private var segments: [AnnouncementSegment]')
    s = once(s, '        _language = State(initialValue: announcement.hasLanguage(preferredLanguage) ? preferredLanguage : .en)', '''        let initialLanguage = announcement.hasLanguage(preferredLanguage) ? preferredLanguage : .en
        _language = State(initialValue: initialLanguage)
        _segments = State(initialValue: announcement.readingSegments(language: initialLanguage, aircraft: aircraft))''')
    s = once(s, '''    private var segments: [AnnouncementSegment] {
        announcement.readingSegments(language: language, aircraft: aircraft)
    }''', '')
    s = once(s, '''        .onChange(of: scrollID) { _, value in
            if let value { store.preferences.savePosition(value, for: positionKey) }
        }''', '''        .task(id: positionKey + "|" + (scrollID ?? "")) {
            // Persist after scrolling settles, not on every paragraph transition.
            let key = positionKey
            guard let value = scrollID else { return }
            do { try await Task.sleep(for: .milliseconds(400)) }
            catch { return }
            guard !Task.isCancelled else { return }
            store.preferences.savePosition(value, for: key)
        }''')
    s = once(s, '        .onDisappear { restoreIdleTimer() }', '''        .onDisappear {
            if let scrollID { store.preferences.savePosition(scrollID, for: positionKey) }
            restoreIdleTimer()
        }''')
    s = once(s, '            if phase == .active { keepAwake() } else { restoreIdleTimer() }', '''            if phase == .active { keepAwake() } else {
                if let scrollID { store.preferences.savePosition(scrollID, for: positionKey) }
                restoreIdleTimer()
            }''')
    s = once(s, '''        .onChange(of: language) { _, _ in
            scrollID = store.preferences.position(for: positionKey) ?? "header"
        }''', '''        .onChange(of: language) { previous, _ in
            if let scrollID {
                let previousKey = "\\(key)|\\(previous.rawValue)|\\(catalogue.issue).\\(catalogue.revision)"
                store.preferences.savePosition(scrollID, for: previousKey)
            }
            segments = announcement.readingSegments(language: language, aircraft: aircraft)
            scrollID = store.preferences.position(for: positionKey) ?? "header"
        }''')
    # Decorative rules do not participate in touch handling.
    s = s.replace('.frame(width: 2)', '.frame(width: 2).allowsHitTesting(false)')
    p.write_text(s)
    for relative in ['RAIDORoster/ContentView.swift', 'RAIDORoster.xcodeproj/project.pbxproj']:
        p = ROOT / relative
        s = p.read_text()
        if '2.20.8' not in s: raise RuntimeError('Version anchor changed: ' + relative)
        p.write_text(s.replace('2.20.8', '2.20.9'))
    print('V2.20.9 detailed calendar, independent earnings controls, single sheet presenter and reader caching applied')

CALENDAR_CELL = 'struct RosterCalendarDayCell: View {\n    let item: RosterItem?\n    let day: Int\n    let isToday: Bool\n    let isChanged: Bool\n    let isSelected: Bool\n\n    var body: some View {\n        VStack(alignment: .leading, spacing: 4) {\n            HStack(spacing: 3) {\n                Text("\\(day)")\n                    .font(.subheadline.weight(isToday || isSelected ? .bold : .semibold))\n                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)\n                Spacer(minLength: 0)\n                if isChanged {\n                    Circle()\n                        .fill(Color.orange)\n                        .frame(width: 6, height: 6)\n                }\n            }\n\n            if let item {\n                Text(calendarPrimaryLabel(item))\n                    .font(.system(size: 10, weight: .bold, design: .rounded))\n                    .foregroundStyle(categoryColor(item.category))\n                    .lineLimit(1)\n                    .minimumScaleFactor(0.55)\n                    .allowsTightening(true)\n                    .frame(maxWidth: .infinity, alignment: .leading)\n\n                if let secondary = calendarSecondaryLabel(item), !secondary.isEmpty {\n                    Text(secondary)\n                        .font(.system(size: 9, weight: .medium, design: .rounded))\n                        .foregroundStyle(.secondary)\n                        .lineLimit(1)\n                        .minimumScaleFactor(0.72)\n                }\n            }\n\n            Spacer(minLength: 0)\n        }\n        .padding(.horizontal, 5)\n        .padding(.vertical, 7)\n        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)\n        .background(cellBackground, in: RoundedRectangle(cornerRadius: 11))\n        .overlay {\n            RoundedRectangle(cornerRadius: 11)\n                .stroke(\n                    isSelected ? Color.accentColor : (isToday ? Color.accentColor.opacity(0.55) : Color.clear),\n                    lineWidth: isSelected ? 2 : 1\n                )\n        }\n        .contentShape(Rectangle())\n    }\n\n    private var cellBackground: Color {\n        guard let item else { return Color.secondary.opacity(0.025) }\n        let base = categoryColor(item.category)\n        return base.opacity(isSelected ? 0.13 : 0.075)\n    }\n}\n\n'
EARNINGS_CARD = 'struct MonthlyEarningsCard: View {\n    @ObservedObject var roster: RosterStore\n    @ObservedObject var earnings: EarningsStore\n    let month: String\n    @AppStorage("RAIDORoster.Earnings.HideAmount") private var hideAmount = false\n    private var flights: [EarningsFlight] { earningsFlights(store: roster, month: month) }\n    private var daily: [EarningsDailyLine] { earningsDailyLines(store: roster, month: month, record: earnings.record(month)) }\n    private var raidoBLHMinutes: Int? {\n        guard roster.selectedRosterMonth == month,\n              let value = roster.rosterViewSnapshot?.monthlyBLH else { return nil }\n        return EarningsMath.parseMonthlyBLH(value)\n    }\n    private var summary: EarningsSummary { EarningsMath.summarize(month: month, flights: flights, record: EarningsDailyPolicy.recordForCalculation(earnings.record(month), lines: daily), authoritativeBLHMinutes: raidoBLHMinutes) }\n\n    var body: some View {\n        HStack(spacing: 12) {\n            NavigationLink {\n                MonthlyEarningsView(roster: roster, earnings: earnings, month: month)\n            } label: {\n                VStack(alignment: .leading, spacing: 7) {\n                    Text(EarningsMath.monthTitle(month)).font(.caption).foregroundStyle(.secondary)\n                    HStack(alignment: .firstTextBaseline) {\n                        VStack(alignment: .leading, spacing: 3) {\n                            Text(EarningsMath.hours(summary.estimatedMinutes)).font(.title3.bold().monospacedDigit())\n                            Text(raidoBLHMinutes == nil ? "Block hours · estimate" : "Block hours · RAIDO").font(.caption).foregroundStyle(.secondary)\n                        }\n                        Spacer(minLength: 12)\n                        VStack(alignment: .trailing, spacing: 3) {\n                            Text(earnings.error != nil ? "Unavailable" : hideAmount ? "••••" : EarningsMath.money(summary.totalCents))\n                                .font(.headline.monospacedDigit())\n                            Text("Monthly earnings ›").font(.caption).foregroundStyle(.secondary)\n                        }\n                    }\n                    Text("Block pay + \\(daily.filter(\\.paid).count) daily payments")\n                        .font(.caption2).foregroundStyle(.secondary)\n                    if daily.contains(where: \\.needsReview) {\n                        Text("Some daily payments need review").font(.caption2).foregroundStyle(.orange)\n                    }\n                }.foregroundStyle(.primary)\n            }.buttonStyle(.plain)\n            Button { hideAmount.toggle() } label: {\n                Image(systemName: hideAmount ? "eye.slash" : "eye")\n                    .frame(width: 44, height: 44).foregroundStyle(.secondary)\n            }.buttonStyle(.plain).accessibilityLabel(hideAmount ? "Show earnings amount" : "Hide earnings amount")\n        }\n        .padding(14)\n        .midnightCard(radius: 16)\n    }\n}\n\n'

repair()
