from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
WEB = ROOT / "RAIDORoster" / "RosterWebView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"

content = CONTENT.read_text()


def block_end(text: str, start: int) -> int:
    brace = text.find('{', start)
    if brace < 0:
        return -1
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == '{': depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return i + 1
    return -1

# -----------------------------------------------------------------------------
# V2.18.1 — faster month UX.
# Cached months are already instant. For an uncached month, move the native
# calendar immediately to the requested yyyy-MM and let RAIDO fill it in in the
# background, instead of leaving the user on the old month while WKWebView loads.
# -----------------------------------------------------------------------------
store_start = content.find('final class RosterStore: ObservableObject {')
store_end = content.find('\n@MainActor\nfinal class AppState:', store_start)
if store_start < 0 or store_end < 0:
    raise RuntimeError('V2.18.1 RosterStore boundaries not found')
store = content[store_start:store_end]

if 'func adjacentRosterMonthKey(previous: Bool)' not in store:
    marker = '    func selectPreviousRosterMonth() {\n'
    idx = store.find(marker)
    if idx < 0:
        raise RuntimeError('V2.18.1 month navigation insertion point not found')
    support = r'''    func adjacentRosterMonthKey(previous: Bool) -> String? {
        guard let key = selectedRosterMonth, key.count == 7 else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]
        comps.month = parts[1]
        comps.day = 1
        guard let date = Calendar(identifier: .gregorian).date(from: comps),
              let target = Calendar(identifier: .gregorian).date(byAdding: .month, value: previous ? -1 : 1, to: date) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: target)
    }

    @discardableResult
    func selectRosterMonthIfCached(_ key: String) -> Bool {
        guard monthSnapshots[key] != nil else { return false }
        selectedRosterMonthKey = key
        return true
    }

    func showPendingRosterMonth(_ key: String) {
        selectedRosterMonthKey = key
    }

'''
    store = store[:idx] + support + store[idx:]

content = content[:store_start] + store + content[store_end:]

# Replace calendar's cache/index-based navigator with direct adjacent-month
# targeting. This avoids odd jumps if cache contains gaps and makes uncached
# navigation visually immediate.
cal_start = content.find('struct RosterMonthCalendarView: View {')
cal_end = content.find('\nstruct RosterCalendarDayCell: View {', cal_start)
if cal_start < 0 or cal_end < 0:
    raise RuntimeError('V2.18.1 calendar boundaries not found')
cal = content[cal_start:cal_end]
nav_start = cal.find('    private func navigateMonth(previous: Bool) {')
if nav_start < 0:
    raise RuntimeError('V2.18.1 navigateMonth not found')
nav_end = block_end(cal, nav_start)
if nav_end < 0:
    raise RuntimeError('V2.18.1 navigateMonth end not found')
new_nav = r'''    private func navigateMonth(previous: Bool) {
        guard let target = store.adjacentRosterMonthKey(previous: previous) else { return }
        if store.selectRosterMonthIfCached(target) { return }

        // Optimistic native transition: the month header/grid changes now.
        // The authenticated hidden RAIDO page then fills the archive.
        store.showPendingRosterMonth(target)
        browser.switchRosterMonth(previous ? "previous" : "next")
    }'''
cal = cal[:nav_start] + new_nav + cal[nav_end:]
content = content[:cal_start] + cal + content[cal_end:]

# -----------------------------------------------------------------------------
# Precaution + rest calculations.
# Alcohol precaution cutoff is 12h before PU; CI/report is the fallback.
# This is a user-awareness feature, not a fitness-for-duty determination.
# -----------------------------------------------------------------------------
store_start = content.find('final class RosterStore: ObservableObject {')
store_end = content.find('\n@MainActor\nfinal class AppState:', store_start)
store = content[store_start:store_end]
if 'func previousOperationalDuty(before item: RosterItem)' not in store:
    marker = '    func nextOperationalDuty(after item: RosterItem) -> RosterItem? {\n'
    idx = store.find(marker)
    if idx < 0:
        raise RuntimeError('V2.18.1 nextOperationalDuty marker not found')
    support = r'''    func previousOperationalDuty(before item: RosterItem) -> RosterItem? {
        guard let start = item.dutyStartUTCDate else { return nil }
        return items.compactMap { candidate -> (RosterItem, Date)? in
            guard candidate.id != item.id,
                  candidate.isOperationalDuty,
                  let end = candidate.dutyEndUTCDate,
                  end <= start else { return nil }
            return (candidate, end)
        }
        .sorted { $0.1 > $1.1 }
        .first?.0
    }

    func precautionReferenceDate(for item: RosterItem) -> Date? {
        item.preDutyPickupUTCDate ?? item.dutyStartUTCDate
    }

    func alcoholPrecautionCutoff(for item: RosterItem) -> Date? {
        precautionReferenceDate(for: item)?.addingTimeInterval(-12 * 3600)
    }

'''
    store = store[:idx] + support + store[idx:]
content = content[:store_start] + store + content[store_end:]

# -----------------------------------------------------------------------------
# Today safety-awareness cards.
# -----------------------------------------------------------------------------
if 'struct CrewReadinessCard: View' not in content:
    marker = 'struct TodayView: View {'
    idx = content.find(marker)
    if idx < 0:
        raise RuntimeError('V2.18.1 TodayView marker not found')
    card = r'''
struct CrewReadinessCard: View {
    let item: RosterItem
    @ObservedObject var store: RosterStore
    @AppStorage("RAIDORoster.RestAwarenessHours") private var restAwarenessHours = 10

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 12) {
                if let reference = store.precautionReferenceDate(for: item),
                   let cutoff = store.alcoholPrecautionCutoff(for: item) {
                    awarenessRow(
                        icon: "wineglass",
                        title: context.date < cutoff ? "12H ALCOHOL PRECAUTION" : "ALCOHOL PRECAUTION WINDOW",
                        value: context.date < cutoff
                            ? "Starts in \(relativeText(from: context.date, to: cutoff))"
                            : "Active • \(relativeText(from: context.date, to: reference)) to \(item.preDutyPickupUTCDate != nil ? "PU" : "CI")",
                        caution: context.date >= cutoff
                    )
                }

                if let previous = store.previousOperationalDuty(before: item),
                   let release = previous.dutyEndUTCDate,
                   let target = store.precautionReferenceDate(for: item),
                   target > release {
                    let total = target.timeIntervalSince(release)
                    let remaining = max(0, target.timeIntervalSince(context.date))
                    let threshold = TimeInterval(restAwarenessHours * 3600)
                    let jeopardy = total < threshold
                    let tight = !jeopardy && total < threshold + 2 * 3600

                    Divider()
                    awarenessRow(
                        icon: jeopardy ? "exclamationmark.triangle.fill" : "bed.double.fill",
                        title: jeopardy ? "REST BELOW AWARENESS THRESHOLD" : (tight ? "TIGHT REST" : "REST WINDOW"),
                        value: "\(durationText(total)) available • \(durationText(remaining)) remaining",
                        caution: jeopardy || tight
                    )

                    Text("From previous release to \(item.preDutyPickupUTCDate != nil ? "PU" : "CI") • app threshold \(restAwarenessHours)h")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private func awarenessRow(icon: String, title: String, value: String, caution: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(caution ? Color.orange : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(caution ? Color.orange : Color.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            Spacer(minLength: 0)
        }
    }
}

'''
    content = content[:idx] + card + content[idx:]

# Insert readiness card in Today before duty briefing / companion where the
# current/upcoming primary duty is already resolved.
today_start = content.find('struct TodayView: View {')
today_end = content.find('\nstruct DutyBriefingView', today_start)
if today_start < 0 or today_end < 0:
    raise RuntimeError('V2.18.1 TodayView boundaries not found')
today = content[today_start:today_end]
if 'CrewReadinessCard(item: item, store: store)' not in today:
    candidates = [
        '                        DutyBriefingView(item: item, showTechnical: false)\n',
        '                        DutyBriefingView(item: item, showTechnical: true)\n'
    ]
    inserted = False
    for anchor in candidates:
        if anchor in today:
            today = today.replace(anchor, '                        CrewReadinessCard(item: item, store: store)\n' + anchor, 1)
            inserted = True
            break
    if not inserted:
        # Alternate later Today implementation may render the primary item via
        # a dedicated card. Attach immediately after the primary item branch.
        anchor = '                    } else if let item = store.todayPrimaryItem {\n'
        if anchor in today:
            today = today.replace(anchor, anchor + '                        CrewReadinessCard(item: item, store: store)\n', 1)
            inserted = True
    if not inserted:
        raise RuntimeError('V2.18.1 Today readiness insertion point not found')
content = content[:today_start] + today + content[today_end:]

# -----------------------------------------------------------------------------
# Settings: configurable rest-awareness threshold.
# -----------------------------------------------------------------------------
settings_start = content.find('struct SettingsView: View {')
settings_end = content.find('\nstruct DutyHeroCard', settings_start)
if settings_start < 0 or settings_end < 0:
    raise RuntimeError('V2.18.1 Settings boundaries not found')
settings = content[settings_start:settings_end]
if '@AppStorage("RAIDORoster.RestAwarenessHours")' not in settings:
    marker = '    @AppStorage("RAIDORoster.AutoCalendarSync") private var autoCalendarSync = true\n'
    if marker in settings:
        settings = settings.replace(marker, marker + '    @AppStorage("RAIDORoster.RestAwarenessHours") private var restAwarenessHours = 10\n', 1)
    else:
        brace = settings.find('\n', settings.find('struct SettingsView: View {')) + 1
        settings = settings[:brace] + '    @AppStorage("RAIDORoster.RestAwarenessHours") private var restAwarenessHours = 10\n' + settings[brace:]

if 'Section("Crew readiness")' not in settings:
    marker = '                Section("Apple Calendar") {'
    idx = settings.find(marker)
    if idx < 0:
        marker = '                Section("Calendar") {'
        idx = settings.find(marker)
    if idx < 0:
        raise RuntimeError('V2.18.1 Settings section insertion point not found')
    section = r'''                Section("Crew readiness") {
                    Picker("Rest awareness threshold", selection: $restAwarenessHours) {
                        ForEach(Array(8...14), id: \.self) { hours in
                            Text("\(hours) hours").tag(hours)
                        }
                    }

                    Text("The app calculates rest from previous release to the next PU, or CI when PU is unavailable. This is an awareness threshold only; company FTL/SOP remains authoritative.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("Alcohol precaution: 12 hours before PU, falling back to CI/report when PU is not present in RAIDO.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

'''
    settings = settings[:idx] + section + settings[idx:]
content = content[:settings_start] + settings + content[settings_end:]

# -----------------------------------------------------------------------------
# Apple Calendar: include PU and precaution cutoff in event notes and alarms.
# The Calendar event remains the duty event; alarms provide the useful countdown
# behavior without creating duplicate pseudo-duty events.
# -----------------------------------------------------------------------------
calexp_start = content.find('final class CalendarExporter: ObservableObject {')
calexp_end = content.find('\n}', calexp_start)
# use a broader structural boundary: next major type after exporter
next_type = content.find('\nstruct ', calexp_start)
if calexp_start < 0 or next_type < 0:
    raise RuntimeError('V2.18.1 CalendarExporter boundaries not found')
calexp = content[calexp_start:next_type]

# Add two alarms: at PU and at the 12h precaution cutoff. Existing alarms are
# replaced deterministically on each roster sync so changes do not duplicate.
if 'event.alarms = readinessAlarms' not in calexp:
    anchor = '        event.url = URL(string: "raidoroster://duty/\\(item.id)")\n'
    if anchor not in calexp:
        raise RuntimeError('V2.18.1 Calendar event URL anchor not found')
    calexp = calexp.replace(anchor, anchor + '        event.alarms = readinessAlarms(for: item, eventStart: span.start)\n', 1)

if 'private func readinessAlarms(for item: RosterItem' not in calexp:
    marker = '    private func eventNotes(_ item: RosterItem) -> String {\n'
    idx = calexp.find(marker)
    if idx < 0:
        raise RuntimeError('V2.18.1 Calendar eventNotes marker not found')
    helper = r'''    private func readinessAlarms(for item: RosterItem, eventStart: Date) -> [EKAlarm] {
        guard item.isOperationalDuty else { return [] }
        let reference = item.preDutyPickupUTCDate ?? item.dutyStartUTCDate
        guard let reference else { return [] }
        let precaution = reference.addingTimeInterval(-12 * 3600)
        var alarms: [EKAlarm] = []

        // PU reminder (or CI fallback) relative to the duty event start.
        let referenceOffset = reference.timeIntervalSince(eventStart)
        alarms.append(EKAlarm(relativeOffset: referenceOffset))

        // 12-hour precautionary alcohol cutoff.
        let precautionOffset = precaution.timeIntervalSince(eventStart)
        alarms.append(EKAlarm(relativeOffset: precautionOffset))
        return alarms
    }

'''
    calexp = calexp[:idx] + helper + calexp[idx:]

# Enrich notes with explicit pickup + cutoff clock values. UTC dates are used for
# calculation; formatted display uses the device's local time zone.
if 'Precautionary alcohol cutoff:' not in calexp:
    needle = '        if !item.pickups.isEmpty {\n'
    idx = calexp.find(needle)
    if idx < 0:
        raise RuntimeError('V2.18.1 Calendar pickup notes marker not found')
    # Inject before pickup list; eventNotes has a mutable lines array.
    note = r'''        if item.isOperationalDuty,
           let reference = item.preDutyPickupUTCDate ?? item.dutyStartUTCDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "dd MMM HH:mm"
            lines.append("")
            if item.preDutyPickupUTCDate != nil {
                lines.append("PU: \(formatter.string(from: reference))")
            }
            lines.append("Precautionary alcohol cutoff: \(formatter.string(from: reference.addingTimeInterval(-12 * 3600)))")
        }

'''
    calexp = calexp[:idx] + note + calexp[idx:]

content = content[:calexp_start] + calexp + content[next_type:]

# Version bump.
content = content.replace('LabeledContent("RAIDO Roster", value: "2.18")',
                          'LabeledContent("RAIDO Roster", value: "2.18.1")', 1)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace('MARKETING_VERSION = 2.18;', 'MARKETING_VERSION = 2.18.1;')
PBX.write_text(pbx)

print('V2.18.1 instant month transition + crew readiness/rest/alcohol calendar tools applied')
