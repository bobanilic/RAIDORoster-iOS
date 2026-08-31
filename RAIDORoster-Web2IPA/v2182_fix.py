from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"

content = CONTENT.read_text()

# -----------------------------------------------------------------------------
# V2.18.2 — Calendar idempotency + legacy duplicate reconciliation.
# Old builds keyed events to RosterItem.id. Duty-envelope/month changes can alter
# that wrapper ID even when the underlying RAIDO activities are the same, which
# caused duplicate Calendar events. Calendar identity now comes from stable
# activity signatures and every sync reconciles only RAIDO-owned events.
# -----------------------------------------------------------------------------
start = content.find('@MainActor\nfinal class CalendarExporter: ObservableObject {')
if start < 0:
    start = content.find('final class CalendarExporter: ObservableObject {')
if start < 0:
    raise RuntimeError('V2.18.2 CalendarExporter start not found')

# Find the matching class brace.
brace = content.find('{', start)
depth = 0
end = -1
for i in range(brace, len(content)):
    if content[i] == '{':
        depth += 1
    elif content[i] == '}':
        depth -= 1
        if depth == 0:
            end = i + 1
            break
if end < 0:
    raise RuntimeError('V2.18.2 CalendarExporter end not found')

replacement = r'''@MainActor
final class CalendarExporter: ObservableObject {
    @Published var message: String?
    @Published var isWorking = false

    private let eventStore = EKEventStore()
    private let legacyMarkerPrefix = "[RAIDO-ROSTER-ID:"
    private let stableMarkerPrefix = "[RAIDO-CALENDAR-KEY:"

    func export(_ item: RosterItem) {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            guard await requestAccess() else { return }
            do {
                let created = try upsert(item)
                try reconcile(items: [item], month: item.dateISO.map { String($0.prefix(7)) }, removeObsolete: false)
                try eventStore.commit()
                message = created ? "Duty added to Calendar." : "Calendar duty updated."
            } catch {
                message = "Calendar export failed: \(error.localizedDescription)"
            }
        }
    }

    func exportMonth(_ items: [RosterItem], month: String?) {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            guard await requestAccess() else { return }
            do {
                let selected = items.filter { item in
                    guard let month, !month.isEmpty else { return true }
                    return item.dateISO?.hasPrefix(month) == true
                }

                var created = 0
                var updated = 0
                for item in selected {
                    if try upsert(item) { created += 1 } else { updated += 1 }
                }

                // After all canonical events exist, remove duplicate and stale
                // events that were created by this app in older versions.
                try reconcile(items: selected, month: month, removeObsolete: true)
                try eventStore.commit()
                message = "Calendar synced • \(selected.count) duties • \(created) added • \(updated) updated"
            } catch {
                message = "Calendar export failed: \(error.localizedDescription)"
            }
        }
    }

    private func requestAccess() async -> Bool {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            if !granted { message = "Calendar access was not granted." }
            return granted
        } catch {
            message = "Calendar access failed: \(error.localizedDescription)"
            return false
        }
    }

    private func upsert(_ item: RosterItem) throws -> Bool {
        guard let span = eventSpan(item) else { throw CalendarExportError.invalidDuty }

        let stableKey = calendarStableKey(item)
        let stableMarker = marker(prefix: stableMarkerPrefix, value: stableKey)
        let legacyMarker = marker(prefix: legacyMarkerPrefix, value: item.id)
        let candidates = ownedEvents(around: span)

        // Priority: V2.18.2 stable marker -> current legacy marker -> semantic
        // match among older RAIDO-owned events. The latter migrates events whose
        // old RosterItem.id changed after parser improvements.
        let existing = candidates.first(where: { $0.notes?.contains(stableMarker) == true })
            ?? candidates.first(where: { $0.notes?.contains(legacyMarker) == true })
            ?? candidates.first(where: { semanticMatch($0, item: item, span: span) })

        let event = existing ?? EKEvent(eventStore: eventStore)
        let created = existing == nil

        if event.calendar == nil { event.calendar = eventStore.defaultCalendarForNewEvents }
        guard event.calendar != nil else { throw CalendarExportError.noCalendar }

        event.title = eventTitle(item)
        event.startDate = span.start
        event.endDate = span.end
        event.isAllDay = span.allDay

        let notes = eventNotes(item)
        event.notes = notes.isEmpty ? stableMarker : notes + "\n\n" + stableMarker
        event.url = URL(string: "raidoroster://calendar/\(stableKey)")
        event.alarms = readinessAlarms(for: item, eventStart: span.start)

        try eventStore.save(event, span: .thisEvent, commit: false)

        // If several legacy copies describe this exact duty, remove all except
        // the canonical event we just migrated/updated.
        for duplicate in candidates where duplicate.eventIdentifier != event.eventIdentifier {
            if duplicate.notes?.contains(stableMarker) == true || semanticMatch(duplicate, item: item, span: span) {
                try eventStore.remove(duplicate, span: .thisEvent, commit: false)
            }
        }
        return created
    }

    private func reconcile(items: [RosterItem], month: String?, removeObsolete: Bool) throws {
        guard !items.isEmpty || (month?.isEmpty == false) else { return }

        let expected: [(item: RosterItem, span: (start: Date, end: Date, allDay: Bool), key: String)] = items.compactMap { item in
            guard let span = eventSpan(item) else { return nil }
            return (item, span, calendarStableKey(item))
        }

        let range: (Date, Date)? = {
            if let month, let monthRange = monthDateRange(month) { return monthRange }
            guard let first = expected.map({ $0.span.start }).min(),
                  let last = expected.map({ $0.span.end }).max() else { return nil }
            return (first.addingTimeInterval(-86400), last.addingTimeInterval(86400))
        }()
        guard let range else { return }

        let predicate = eventStore.predicateForEvents(withStart: range.0, end: range.1, calendars: nil)
        let owned = eventStore.events(matching: predicate).filter(isRAIDOOwned)

        var keepIDs = Set<String>()
        for expectedDuty in expected {
            let stableMarker = marker(prefix: stableMarkerPrefix, value: expectedDuty.key)
            let matches = owned.filter {
                $0.notes?.contains(stableMarker) == true ||
                semanticMatch($0, item: expectedDuty.item, span: expectedDuty.span)
            }
            guard !matches.isEmpty else { continue }

            // Prefer the already-migrated stable-key event, otherwise the first
            // EventKit result becomes canonical and is migrated in place.
            let canonical = matches.first(where: { $0.notes?.contains(stableMarker) == true }) ?? matches[0]
            if let id = canonical.eventIdentifier { keepIDs.insert(id) }

            if canonical.notes?.contains(stableMarker) != true {
                canonical.notes = strippedRAIDOMarkers(canonical.notes ?? "")
                let base = canonical.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                canonical.notes = base.isEmpty ? stableMarker : base + "\n\n" + stableMarker
                canonical.url = URL(string: "raidoroster://calendar/\(expectedDuty.key)")
                try eventStore.save(canonical, span: .thisEvent, commit: false)
            }

            for duplicate in matches where duplicate.eventIdentifier != canonical.eventIdentifier {
                try eventStore.remove(duplicate, span: .thisEvent, commit: false)
            }
        }

        guard removeObsolete else { return }

        // Remove stale RAIDO-owned events in the synced month only when they do
        // not correspond to any current roster duty. Personal/non-RAIDO events
        // never enter `owned` and therefore cannot be touched here.
        for event in owned {
            if let id = event.eventIdentifier, keepIDs.contains(id) { continue }
            let belongs = expected.contains { duty in
                event.notes?.contains(marker(prefix: stableMarkerPrefix, value: duty.key)) == true ||
                semanticMatch(event, item: duty.item, span: duty.span)
            }
            if !belongs {
                try eventStore.remove(event, span: .thisEvent, commit: false)
            }
        }
    }

    private func isRAIDOOwned(_ event: EKEvent) -> Bool {
        if event.notes?.contains(stableMarkerPrefix) == true { return true }
        if event.notes?.contains(legacyMarkerPrefix) == true { return true }
        if event.url?.scheme?.lowercased() == "raidoroster" { return true }
        return false
    }

    private func ownedEvents(around span: (start: Date, end: Date, allDay: Bool)) -> [EKEvent] {
        let predicate = eventStore.predicateForEvents(
            withStart: span.start.addingTimeInterval(-2 * 86400),
            end: span.end.addingTimeInterval(2 * 86400),
            calendars: nil
        )
        return eventStore.events(matching: predicate).filter(isRAIDOOwned)
    }

    private func semanticMatch(
        _ event: EKEvent,
        item: RosterItem,
        span: (start: Date, end: Date, allDay: Bool)
    ) -> Bool {
        guard isRAIDOOwned(event), event.isAllDay == span.allDay else { return false }

        if span.allDay {
            return Calendar.current.isDate(event.startDate, inSameDayAs: span.start) &&
                   normalizedCalendarTitle(event.title) == normalizedCalendarTitle(eventTitle(item))
        }

        // Time is the strongest legacy identity. Allow a small tolerance for
        // historical timezone/rounding changes, then use title/route as a
        // secondary guard so two legitimate same-day duties are never merged.
        let startDelta = abs(event.startDate.timeIntervalSince(span.start))
        let endDelta = abs(event.endDate.timeIntervalSince(span.end))
        guard startDelta <= 15 * 60, endDelta <= 15 * 60 else { return false }

        let oldTitle = normalizedCalendarTitle(event.title)
        let newTitle = normalizedCalendarTitle(eventTitle(item))
        if oldTitle == newTitle { return true }

        let flightCodes = item.flightActivities.map(\.code).filter { !$0.isEmpty }
        return !flightCodes.isEmpty && flightCodes.allSatisfy { oldTitle.contains($0.uppercased()) }
    }

    private func normalizedCalendarTitle(_ value: String?) -> String {
        (value ?? "")
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "•", with: "")
            .replacingOccurrences(of: "→", with: "-")
    }

    private func calendarStableKey(_ item: RosterItem) -> String {
        let activityIDs = item.activityList.map(\.id).filter { !$0.isEmpty }.sorted()
        let fallback = [
            item.dateISO ?? "",
            item.category.uppercased(),
            item.flightActivities.map(\.code).joined(separator: "+"),
            item.dutyStartUTCDate.map { String(Int($0.timeIntervalSince1970)) } ?? "",
            item.dutyEndUTCDate.map { String(Int($0.timeIntervalSince1970)) } ?? ""
        ].joined(separator: "|")
        let source = activityIDs.isEmpty
            ? fallback
            : [item.dateISO ?? "", activityIDs.joined(separator: "|")].joined(separator: "|")
        return fnv1a64(source)
    }

    private func fnv1a64(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    private func marker(prefix: String, value: String) -> String {
        "\(prefix)\(value)]"
    }

    private func strippedRAIDOMarkers(_ value: String) -> String {
        value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.contains(legacyMarkerPrefix) && !$0.contains(stableMarkerPrefix) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func monthDateRange(_ month: String) -> (Date, Date)? {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]
        comps.month = parts[1]
        comps.day = 1
        guard let start = Calendar.current.date(from: comps),
              let end = Calendar.current.date(byAdding: .month, value: 1, to: start) else { return nil }
        return (start, end)
    }

    private func eventSpan(_ item: RosterItem) -> (start: Date, end: Date, allDay: Bool)? {
        let allDayCategories = ["OFF", "DND", "REST", "VACATION", "LEAVE"]
        if allDayCategories.contains(item.category.uppercased()),
           let key = item.dateISO,
           let start = localDay(key),
           let end = Calendar.current.date(byAdding: .day, value: 1, to: start) {
            return (start, end, true)
        }

        guard let start = item.dutyStartUTCDate,
              let end = item.dutyEndUTCDate,
              end > start else { return nil }
        return (start, end, false)
    }

    private func localDay(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func eventTitle(_ item: RosterItem) -> String {
        let duty = item.displayTitle.replacingOccurrences(of: " + ", with: "/")
        guard !item.route.isEmpty else { return duty }
        return "\(duty) • \(item.route.replacingOccurrences(of: " → ", with: "-"))"
    }

    private func readinessAlarms(for item: RosterItem, eventStart: Date) -> [EKAlarm] {
        guard item.isOperationalDuty else { return [] }
        let reference = item.preDutyPickupUTCDate ?? item.dutyStartUTCDate
        guard let reference else { return [] }
        let precaution = reference.addingTimeInterval(-12 * 3600)
        return [
            EKAlarm(relativeOffset: reference.timeIntervalSince(eventStart)),
            EKAlarm(relativeOffset: precaution.timeIntervalSince(eventStart))
        ]
    }

    private func eventNotes(_ item: RosterItem) -> String {
        var lines: [String] = []
        if !item.route.isEmpty { lines.append("Route: \(item.route)") }
        if !item.reportLocal.isEmpty { lines.append("Report: \(item.reportLocal)") }
        if !item.releaseLocal.isEmpty { lines.append("Release: \(item.releaseLocal)") }
        if !item.dutyDuration.isEmpty { lines.append("Duty: \(item.dutyDuration)") }

        if let reference = item.preDutyPickupUTCDate ?? item.dutyStartUTCDate {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.timeZone = .current
            formatter.dateFormat = "EEE d MMM HH:mm"
            if item.preDutyPickupUTCDate != nil {
                lines.append("PU: \(formatter.string(from: reference))")
            }
            lines.append("12h alcohol precaution cutoff: \(formatter.string(from: reference.addingTimeInterval(-12 * 3600)))")
        }

        if !item.flightActivities.isEmpty {
            lines.append("")
            lines.append("Sectors:")
            for sector in item.flightActivities {
                let times = [sector.localStartTime, sector.localEndTime].filter { !$0.isEmpty }.joined(separator: "–")
                lines.append("• \(sector.title)  \(sector.route)  \(times)")
            }
        }

        if !item.pickups.isEmpty {
            lines.append("")
            lines.append("Pickup:")
            lines.append(contentsOf: item.pickups.map { "• \($0)" })
        }

        if !item.hotelAssignments.isEmpty {
            lines.append("")
            lines.append("Hotel:")
            for hotel in item.hotelAssignments {
                let name = hotel.hotelName.isEmpty ? hotel.title : hotel.hotelName
                lines.append("• \(name)  \(hotelRange(hotel))")
            }
        }

        let notes = uniqueStrings(item.transferNotes + item.dayNotes + item.activityNotes)
        if !notes.isEmpty {
            lines.append("")
            lines.append("RAIDO notes:")
            lines.append(contentsOf: notes.map { "• \($0)" })
        }

        if let aircraft = item.aircraft.first, !aircraft.aircraftDisplay.isEmpty {
            lines.append("")
            lines.append("Aircraft: \(aircraft.aircraftDisplay)")
        }
        return lines.joined(separator: "\n")
    }

    private enum CalendarExportError: LocalizedError {
        case invalidDuty
        case noCalendar

        var errorDescription: String? {
            switch self {
            case .invalidDuty: return "The roster entry has no usable start/end time."
            case .noCalendar: return "No writable default calendar is available."
            }
        }
    }
}'''

content = content[:start] + replacement + content[end:]

# Alcohol readiness card is only actionable before PU/CI. Hide it at the
# reference time instead of displaying a clamped "Active • in 0m" during duty.
card_start = content.find('struct CrewReadinessCard: View {')
card_end = content.find('\nstruct TodayView: View {', card_start)
if card_start >= 0 and card_end > card_start:
    card = content[card_start:card_end]
    old = '''                if let reference = store.precautionReferenceDate(for: item),\n                   let cutoff = store.alcoholPrecautionCutoff(for: item) {'''
    new = '''                if let reference = store.precautionReferenceDate(for: item),\n                   let cutoff = store.alcoholPrecautionCutoff(for: item),\n                   context.date < reference {'''
    if old in card:
        card = card.replace(old, new, 1)
    content = content[:card_start] + card + content[card_end:]

content = content.replace('LabeledContent("RAIDO Roster", value: "2.18.1")',
                          'LabeledContent("RAIDO Roster", value: "2.18.2")', 1)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace('MARKETING_VERSION = 2.18.1;', 'MARKETING_VERSION = 2.18.2;')
PBX.write_text(pbx)

print('V2.18.2 stable Calendar identity + RAIDO-only duplicate/stale cleanup + pre-duty-only alcohol card applied')
