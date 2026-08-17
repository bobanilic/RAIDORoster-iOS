from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
JS = ROOT / "RAIDORoster" / "RosterEnhancements.js"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.11.1 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# -----------------------------------------------------------------------------
# Roster tab: preserve the existing List view and add a persistent Calendar
# mode. No RAIDO parser behavior changes are required for the calendar.
# -----------------------------------------------------------------------------
content = replace_once(
    content,
    '''struct RosterHomeView: View {
    @ObservedObject var store: RosterStore
    let openPortal: () -> Void
''',
    '''struct RosterHomeView: View {
    @ObservedObject var store: RosterStore
    let openPortal: () -> Void
    @AppStorage("RAIDORoster.RosterDisplayMode") private var rosterDisplayMode = "list"
''',
    "Roster display mode state"
)

content = replace_once(
    content,
    '''                    statusHeader

                    if let notice = store.changeNotice {
''',
    '''                    statusHeader

                    Picker("Roster view", selection: $rosterDisplayMode) {
                        Label("List", systemImage: "list.bullet").tag("list")
                        Label("Calendar", systemImage: "calendar").tag("calendar")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Roster view")

                    if let notice = store.changeNotice {
''',
    "Roster List Calendar picker"
)

start = content.index("struct RosterHomeView: View {")
end = content.index("struct TodayView: View {", start)
home = content[start:end]
old_branch = '''                    if !store.hasCache {
                        emptyState
                    } else {
'''
new_branch = '''                    if !store.hasCache {
                        emptyState
                    } else if rosterDisplayMode == "calendar" {
                        RosterMonthCalendarView(items: store.items, changedDates: store.changedDates)
                    } else {
'''
if new_branch not in home:
    if old_branch not in home:
        raise RuntimeError("V2.11.1 patch marker not found: Roster content branch")
    home = home.replace(old_branch, new_branch, 1)
content = content[:start] + home + content[end:]

calendar_views = r'''
struct RosterMonthCalendarView: View {
    let items: [RosterItem]
    let changedDates: Set<String>

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
                        NavigationLink {
                            RosterDetailView(item: item)
                        } label: {
                            RosterCalendarDayCell(
                                item: item,
                                day: Int(iso.suffix(2)) ?? 0,
                                isToday: iso == rosterCalendarTodayISO(),
                                isChanged: changedDates.contains(iso)
                            )
                        }
                        .buttonStyle(.plain)
                    } else if let iso {
                        RosterCalendarDayCell(
                            item: nil,
                            day: Int(iso.suffix(2)) ?? 0,
                            isToday: iso == rosterCalendarTodayISO(),
                            isChanged: false
                        )
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: 78)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct RosterCalendarDayCell: View {
    let item: RosterItem?
    let day: Int
    let isToday: Bool
    let isChanged: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text("\(day)")
                    .font(.caption.weight(isToday ? .bold : .semibold))
                    .foregroundStyle(isToday ? Color.accentColor : Color.primary)
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
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .background(cellBackground, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            if isToday {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
    }

    private var cellBackground: Color {
        guard let item else { return Color.secondary.opacity(0.025) }
        return categoryColor(item.category).opacity(0.075)
    }
}

private func calendarPrimaryLabel(_ item: RosterItem) -> String {
    switch item.category.uppercased() {
    case "FLIGHT":
        let codes = item.flightActivities.map(\.code).filter { !$0.isEmpty }
        return compactCalendarFlightCodes(codes)
    case "POSITIONING": return "POS"
    case "STANDBY":
        let title = item.displayTitle.uppercased()
        if title.contains("MORNING") { return "STB M" }
        if title.contains("AFTERNOON") { return "STB A" }
        return "STB"
    case "RESERVE": return "RES"
    case "OFF": return "OFF"
    case "REST": return "REST"
    case "DND": return "DND"
    case "VACATION": return "VAC"
    case "LEAVE": return "LEAVE"
    case "TRAINING": return "TRN"
    default: return prettyCategory(item.category)
    }
}

private func calendarSecondaryLabel(_ item: RosterItem) -> String? {
    switch item.category.uppercased() {
    case "FLIGHT":
        return item.reportLocal.isEmpty ? nil : "CI \(item.reportLocal)"
    case "POSITIONING":
        return item.route.isEmpty ? item.reportLocal.nilIfEmpty : item.route
    case "STANDBY", "RESERVE", "TRAINING":
        return item.reportLocal.nilIfEmpty
    default:
        return nil
    }
}

private func compactCalendarFlightCodes(_ codes: [String]) -> String {
    guard let first = codes.first else { return "FLT" }
    guard codes.count > 1 else { return first }

    let pattern = #"\d+$"#
    guard let firstDigits = first.range(of: pattern, options: .regularExpression) else {
        return codes.prefix(2).joined(separator: "/")
    }
    let prefix = String(first[..<firstDigits.lowerBound])
    guard !prefix.isEmpty,
          codes.allSatisfy({ $0.hasPrefix(prefix) }) else {
        return codes.prefix(2).joined(separator: "/")
    }

    let rest = codes.dropFirst().map { String($0.dropFirst(prefix.count)) }
    return ([first] + rest).joined(separator: "/")
}

private func rosterCalendarDate(_ iso: String) -> Date? {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: iso)
}

private func rosterCalendarTodayISO() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
}

'''
content = replace_once(
    content,
    '''struct TodayView: View {
''',
    calendar_views + '''struct TodayView: View {
''',
    "Roster calendar views"
)

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.11")',
    'LabeledContent("RAIDO Roster", value: "2.11.1")',
    1
)
CONTENT.write_text(content)

# -----------------------------------------------------------------------------
# Diagnostics only: inspect RAIDO's month navigation controls without clicking
# or mutating them. This gives the evidence needed for safe historical backfill.
# -----------------------------------------------------------------------------
js = JS.read_text()
month_diag = r'''
  function monthNavigationDiagnostics() {
    const controls = Array.from(document.querySelectorAll('button, a, input, select, [role="button"]'));

    function summary(el) {
      const tag = upper(el.tagName || '');
      const text = compact(el.innerText || el.textContent || '');
      const value = compact(el.value || '');
      const title = compact(el.getAttribute?.('title') || '');
      const aria = compact(el.getAttribute?.('aria-label') || '');
      const id = compact(el.id || '');
      const name = compact(el.getAttribute?.('name') || '');
      const cls = compact(typeof el.className === 'string' ? el.className : '');
      const onclick = compact(el.getAttribute?.('onclick') || '');
      const options = tag === 'SELECT'
        ? Array.from(el.options || []).slice(0, 36).map(o => ({ text: compact(o.textContent || ''), value: compact(o.value || ''), selected: !!o.selected }))
        : [];
      return {
        tag,
        text: redact(text).slice(0, 100),
        value: redact(value).slice(0, 100),
        title: redact(title).slice(0, 100),
        aria: redact(aria).slice(0, 100),
        id: redact(id).slice(0, 100),
        name: redact(name).slice(0, 100),
        className: redact(cls).slice(0, 140),
        onclick: redact(onclick).slice(0, 180),
        options
      };
    }

    const summaries = controls.map(summary);
    const monthWords = MONTH_NAMES.join('|');
    const candidateRE = new RegExp(`(?:PREV|NEXT|BACK|FORWARD|MONTH|${monthWords}|[‹›«»])`, 'i');
    const candidates = summaries.filter(item => {
      const haystack = [item.text, item.value, item.title, item.aria, item.id, item.name, item.className, item.onclick].join(' ');
      return candidateRE.test(haystack) || item.tag === 'SELECT' && item.options.some(o => candidateRE.test(o.text));
    });

    const fallbackLabels = summaries
      .filter(item => item.text || item.value || item.title || item.aria || item.onclick)
      .slice(0, 30);

    return {
      controlCount: controls.length,
      candidateControls: candidates.slice(0, 30),
      fallbackControls: candidates.length ? [] : fallbackLabels
    };
  }

'''
js = replace_once(
    js,
    '''  function diagnostics() {
''',
    month_diag + '''  function diagnostics() {
''',
    "month navigation diagnostic function"
)

js = replace_once(
    js,
    '''        todayISO: `${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())}`,
        parsedDays: b.days.slice(0, 40).map(d => ({
''',
    '''        todayISO: `${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())}`,
        monthNavigation: monthNavigationDiagnostics(),
        parsedDays: b.days.slice(0, 40).map(d => ({
''',
    "month navigation diagnostics payload"
)
JS.write_text(js)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 13;", "CURRENT_PROJECT_VERSION = 14;")
pbx = pbx.replace("MARKETING_VERSION = 2.11;", "MARKETING_VERSION = 2.11.1;")
PBX.write_text(pbx)

print("V2.11.1 List/Calendar roster + month navigation diagnostics applied")
