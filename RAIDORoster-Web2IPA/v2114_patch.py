from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.11.4 patch marker not found: {label}")
    return text.replace(old, new, 1)


def replace_between(text: str, start_marker: str, end_marker: str, replacement: str, label: str) -> str:
    start = text.find(start_marker)
    end = text.find(end_marker, start + len(start_marker))
    if start < 0 or end < 0:
        raise RuntimeError(f"V2.11.4 patch range not found: {label}")
    return text[:start] + replacement + text[end:]


content = CONTENT.read_text()

# -----------------------------------------------------------------------------
# One subtle source/freshness indicator shared by Roster and Today. It is based
# only on the last successful validated RAIDO ingest, so it never pretends that
# the live website is currently reachable when we only have cached data.
# -----------------------------------------------------------------------------
sync_strip = r'''
struct SyncFreshnessStrip: View {
    @ObservedObject var store: RosterStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)

                Text(statusText(at: context.date))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 6)

                if store.hasCache && store.isCacheValidated {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.055), in: Capsule())
            .accessibilityElement(children: .combine)
        }
    }

    private var statusColor: Color {
        if !store.hasCache { return .secondary }
        return store.isCacheValidated ? .green : .orange
    }

    private func statusText(at now: Date) -> String {
        guard store.hasCache else { return "RAIDO · Not synced" }
        guard store.isCacheValidated else { return "Cached roster · Resync required" }
        guard let lastSync = store.lastSync else { return "RAIDO · Offline ready" }
        return "RAIDO · Synced \(compactRelativeAge(from: lastSync, to: now)) · Offline ready"
    }
}

private func compactRelativeAge(from date: Date, to now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "now" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h ago" }
    return "\(hours / 24)d ago"
}

'''
if "struct SyncFreshnessStrip: View" not in content:
    content = replace_once(
        content,
        "struct RosterHomeView: View {\n",
        sync_strip + "struct RosterHomeView: View {\n",
        "sync freshness component",
    )

content = replace_once(
    content,
    '''                    statusHeader

                    Picker("Roster view", selection: $rosterDisplayMode) {
''',
    '''                    SyncFreshnessStrip(store: store)

                    Picker("Roster view", selection: $rosterDisplayMode) {
''',
    "compact Roster freshness strip",
)

content = replace_once(
    content,
    '''                    Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.title2.bold())

                    if !store.isCacheValidated {
''',
    '''                    Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.title2.bold())

                    SyncFreshnessStrip(store: store)

                    if !store.isCacheValidated {
''',
    "Today freshness strip",
)

# -----------------------------------------------------------------------------
# Calendar: day taps select in-place and reveal a compact agenda card below the
# month. The detail screen is therefore one deliberate tap deeper, avoiding
# repeated push/back navigation while browsing nearby days.
# -----------------------------------------------------------------------------
calendar_views = r'''
struct RosterMonthCalendarView: View {
    let items: [RosterItem]
    let changedDates: Set<String>
    @State private var selectedDateISO: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
    private let weekdays = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.firstWeekday = 2
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = .current
        return value
    }

    private var firstRosterDate: Date? {
        items.compactMap { item in
            guard let iso = item.dateISO else { return nil }
            return rosterCalendarDate(iso)
        }.sorted().first
    }

    private var itemsByDate: [String: RosterItem] {
        Dictionary(uniqueKeysWithValues: items.compactMap { item in
            guard let iso = item.dateISO else { return nil }
            return (iso, item)
        })
    }

    private var selectedItem: RosterItem? {
        guard let selectedDateISO else { return nil }
        return itemsByDate[selectedDateISO]
    }

    private var monthTitle: String {
        guard let date = firstRosterDate else { return "Roster month" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    private var slots: [String?] {
        guard let firstDate = firstRosterDate else { return [] }
        let parts = calendar.dateComponents([.year, .month], from: firstDate)
        guard let monthStart = calendar.date(from: parts),
              let days = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }

        let weekday = calendar.component(.weekday, from: monthStart)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var result = Array<String?>(repeating: nil, count: leading)

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"

        for day in days {
            var comps = parts
            comps.day = day
            if let date = calendar.date(from: comps) {
                result.append(formatter.string(from: date))
            }
        }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(monthTitle)
                    .font(.title3.bold())
                Spacer()
                if !changedDates.isEmpty {
                    Label("Changed", systemImage: "circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(weekdays, id: \.self) { weekday in
                    Text(weekday)
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, iso in
                    if let iso, let item = itemsByDate[iso] {
                        Button {
                            withAnimation(.snappy(duration: 0.18)) {
                                selectedDateISO = iso
                            }
                        } label: {
                            RosterCalendarDayCell(
                                item: item,
                                day: Int(iso.suffix(2)) ?? 0,
                                isToday: iso == rosterCalendarTodayISO(),
                                isChanged: changedDates.contains(iso),
                                isSelected: selectedDateISO == iso
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.dateText), \(item.displayTitle)")
                    } else if let iso {
                        RosterCalendarDayCell(
                            item: nil,
                            day: Int(iso.suffix(2)) ?? 0,
                            isToday: iso == rosterCalendarTodayISO(),
                            isChanged: false,
                            isSelected: false
                        )
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: 76)
                    }
                }
            }

            if let selectedItem {
                Divider().padding(.top, 2)
                NavigationLink {
                    RosterDetailView(item: selectedItem)
                } label: {
                    RosterCalendarAgendaCard(item: selectedItem, isChanged: selectedItem.dateISO.map(changedDates.contains) ?? false)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
        .onAppear {
            guard selectedDateISO == nil else { return }
            let today = rosterCalendarTodayISO()
            selectedDateISO = itemsByDate[today] != nil ? today : items.compactMap(\.dateISO).first
        }
        .sensoryFeedback(.selection, trigger: selectedDateISO)
    }
}

struct RosterCalendarDayCell: View {
    let item: RosterItem?
    let day: Int
    let isToday: Bool
    let isChanged: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text("\(day)")
                    .font(.caption.weight(isToday || isSelected ? .bold : .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                Spacer(minLength: 0)
                if isChanged {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                }
            }

            if let item {
                Text(calendarPrimaryLabel(item))
                    .font(.caption2.bold())
                    .foregroundStyle(categoryColor(item.category))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                if let secondary = calendarSecondaryLabel(item), !secondary.isEmpty {
                    Text(secondary)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .background(cellBackground, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(
                    isSelected ? Color.accentColor : (isToday ? Color.accentColor.opacity(0.55) : Color.clear),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .contentShape(Rectangle())
    }

    private var cellBackground: Color {
        guard let item else { return Color.secondary.opacity(0.025) }
        let base = categoryColor(item.category)
        return base.opacity(isSelected ? 0.13 : 0.075)
    }
}

struct RosterCalendarAgendaCard: View {
    let item: RosterItem
    let isChanged: Bool

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(categoryColor(item.category))
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(item.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if isChanged {
                        Text("CHANGED")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                }

                if !item.route.isEmpty {
                    Text(item.route)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                let details = [
                    item.reportLocal.isEmpty ? "" : "CI \(item.reportLocal)",
                    item.releaseLocal.isEmpty ? "" : "END \(item.releaseLocal)",
                    item.sectorCount > 0 ? "\(item.sectorCount) sectors" : ""
                ].filter { !$0.isEmpty }
                if !details.isEmpty {
                    Text(details.joined(separator: " • "))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
    }
}

'''
content = replace_between(
    content,
    "struct RosterMonthCalendarView: View {",
    "private func calendarPrimaryLabel",
    calendar_views,
    "calendar selection and agenda",
)

# -----------------------------------------------------------------------------
# Today: keep the same data and navigation, but make the operational sequence
# the visual backbone. Duty Detail remains information-dense; Today becomes the
# glanceable version with pickup/report/sectors/end in one vertical timeline.
# -----------------------------------------------------------------------------
duty_briefing = r'''
struct DutyBriefingView: View {
    let item: RosterItem
    let showTechnical: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: showTechnical ? 16 : 14) {
            DutyHeroCard(item: item)

            if item.isOperationalDuty, !item.operationalActivities.isEmpty {
                DutyLiveStatusCard(item: item)

                if showTechnical {
                    DutyMetricsGrid(item: item)
                    BriefingSectionTitle("Duty timeline")
                    DutyTimelineCard(item: item)
                } else {
                    BriefingSectionTitle("Duty")
                    TodayOperationalTimelineCard(item: item)
                }
            }

            if showTechnical {
                if hasLogistics {
                    BriefingSectionTitle("Logistics")
                    LogisticsCard(item: item)
                }

                if !item.dayNotes.isEmpty || !item.activityNotes.isEmpty {
                    BriefingSectionTitle("Notes")
                    NotesCard(item: item)
                }

                if !item.aircraft.isEmpty {
                    BriefingSectionTitle("Aircraft")
                    AircraftCard(item: item)
                }

                if !item.crewMembers.isEmpty {
                    BriefingSectionTitle("Crew")
                    CrewCard(item: item)
                }
            } else {
                if !item.aircraft.isEmpty {
                    BriefingSectionTitle("Aircraft")
                    AircraftCard(item: item)
                }

                if !item.crewMembers.isEmpty {
                    BriefingSectionTitle("Crew")
                    CrewCard(item: item)
                }

                if hasLogistics {
                    BriefingSectionTitle("Logistics")
                    LogisticsCard(item: item)
                }

                if !item.dayNotes.isEmpty || !item.activityNotes.isEmpty {
                    BriefingSectionTitle("Notes")
                    NotesCard(item: item)
                }
            }

            if showTechnical {
                DisclosureGroup("Technical RAIDO data") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.rawText)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        if !item.cells.isEmpty {
                            Divider()
                            ForEach(item.cells, id: \.self) { value in
                                Text(value).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)
            }
        }
    }

    private var hasLogistics: Bool {
        !item.pickups.isEmpty || !item.transferNotes.isEmpty || !item.hotelAssignments.isEmpty ||
        item.activityList.contains { $0.category.uppercased() == "RELOCATION" }
    }
}

'''
content = replace_between(
    content,
    "struct DutyBriefingView: View {",
    "struct DutyLiveStatusCard: View {",
    duty_briefing,
    "Today briefing hierarchy",
)

live_and_today_timeline = r'''
struct DutyLiveStatusCard: View {
    let item: RosterItem

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let status = item.liveStatus(at: context.date) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(status.label)
                            .font(.caption.bold())
                            .foregroundStyle(Color.accentColor)
                        Text(status.title)
                            .font(.title3.bold())
                        if !status.subtitle.isEmpty {
                            Text(status.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Spacer(minLength: 8)

                    Image(systemName: status.systemImage)
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor.opacity(0.10), in: Circle())
                }
                .padding(15)
                .background(Color.accentColor.opacity(0.075), in: RoundedRectangle(cornerRadius: 17))
            }
        }
    }
}

private struct TodayTimelineEntry: Identifiable {
    let id: String
    let time: String
    let title: String
    let subtitle: String
    let trailing: String
    let icon: String
}

struct TodayOperationalTimelineCard: View {
    let item: RosterItem

    private var entries: [TodayTimelineEntry] {
        var result: [TodayTimelineEntry] = []

        if !item.preDutyPickupDisplay.isEmpty {
            result.append(.init(
                id: "pickup",
                time: compactClock(in: item.preDutyPickupDisplay),
                title: "Pickup",
                subtitle: "Transport",
                trailing: "",
                icon: "car.fill"
            ))
        }

        if let first = item.operationalActivities.first,
           !first.localCheckInTime.isEmpty,
           first.localCheckInTime != first.localStartTime {
            result.append(.init(
                id: "report",
                time: first.localCheckInTime,
                title: "Report",
                subtitle: first.station,
                trailing: "",
                icon: "person.badge.clock"
            ))
        }

        for activity in item.operationalActivities {
            result.append(.init(
                id: "activity-\(activity.id)",
                time: activity.localStartTime,
                title: activity.title,
                subtitle: activity.route.isEmpty ? activity.description : activity.route,
                trailing: activity.localEndTime,
                icon: activity.isFlight ? "airplane" : timelineIcon(activity.category)
            ))
        }

        if let last = item.operationalActivities.last,
           !last.localCheckOutTime.isEmpty,
           last.localCheckOutTime != last.localEndTime {
            result.append(.init(
                id: "release",
                time: last.localCheckOutTime,
                title: "Release",
                subtitle: "Duty complete",
                trailing: "",
                icon: "checkmark.circle.fill"
            ))
        }

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                TodayTimelineRow(entry: entry, isLast: index == entries.count - 1)
            }
        }
        .padding(.horizontal, 13)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 17))
    }
}

private struct TodayTimelineRow: View {
    let entry: TodayTimelineEntry
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Text(entry.time)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(width: 48, alignment: .leading)
                .padding(.top, 13)

            VStack(spacing: 0) {
                Image(systemName: entry.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor.opacity(0.10), in: Circle())
                    .padding(.top, 10)

                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    if !entry.trailing.isEmpty {
                        Text(entry.trailing)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 12)
        }
        .frame(minHeight: 56)
    }
}

private func compactClock(in value: String) -> String {
    if let range = value.range(of: #"\b\d{1,2}:\d{2}\b"#, options: .regularExpression) {
        return String(value[range])
    }
    return value
}

'''
content = replace_between(
    content,
    "struct DutyLiveStatusCard: View {",
    "struct DutyMetricsGrid: View {",
    live_and_today_timeline,
    "live status and Today timeline",
)

# Version only; parser/extraction version intentionally remains untouched.
content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.11.3")',
    'LabeledContent("RAIDO Roster", value: "2.11.4")',
    1,
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 16;", "CURRENT_PROJECT_VERSION = 17;")
pbx = pbx.replace("MARKETING_VERSION = 2.11.3;", "MARKETING_VERSION = 2.11.4;")
PBX.write_text(pbx)

print("V2.11.4 focused UX refinement applied")
