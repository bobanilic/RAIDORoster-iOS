import SwiftUI
import CoreMotion
import CoreLocation
import MapKit
import CoreLocation
import Network
import UIKit
import EventKit
import UserNotifications

struct CrewMember: Codable, Equatable, Identifiable {
    let role: String
    let code: String
    let name: String
    let country: String?
    let phone: String?

    var id: String { "\(role)|\(code)|\(name)" }
}

struct RosterActivity: Codable, Equatable, Identifiable {
    let id: String
    let code: String
    let category: String
    let title: String
    let description: String
    let route: String
    let station: String
    let checkInLT: String
    let checkInUTC: String
    let startLT: String
    let startUTC: String
    let endLT: String
    let endUTC: String
    let checkOutLT: String
    let checkOutUTC: String
    let hotelName: String
    let pickup: String
    let transferNote: String
    let activityNote: String
    let dayNote: String
    let aircraftReg: String
    let aircraftType: String
    let aircraftVersion: String
    let aircraftPhone: String
    let crew: [CrewMember]
    let rawText: String

    var isAuxiliary: Bool {
        ["HOTEL", "EXPENSE", "RELOCATION"].contains(category.uppercased())
    }

    var isFlight: Bool { category.uppercased() == "FLIGHT" }

    var localStartTime: String { clockPart(startLT) }
    var localEndTime: String { clockPart(endLT) }
    var localCheckInTime: String { clockPart(checkInLT) }
    var localCheckOutTime: String { clockPart(checkOutLT) }

    var timeText: String {
        let span = [localStartTime, localEndTime].filter { !$0.isEmpty }.joined(separator: "–")
        if !localCheckInTime.isEmpty && ["FLIGHT", "POSITIONING"].contains(category.uppercased()) {
            return "CI \(localCheckInTime)  •  \(span)"
        }
        return span
    }

    var aircraftDisplay: String {
        var pieces: [String] = []
        if !aircraftReg.isEmpty { pieces.append(aircraftReg) }
        let typeLabel = aircraftTypeLabel(aircraftType)
        if !typeLabel.isEmpty { pieces.append(typeLabel) }
        if !aircraftVersion.isEmpty { pieces.append(aircraftVersion) }
        return pieces.joined(separator: " • ")
    }
}

struct RosterItem: Identifiable, Codable, Equatable {
    let id: String
    let index: Int
    let dateISO: String?
    let dateText: String
    let category: String
    let title: String
    let route: String
    let timeText: String
    let rawText: String
    let cells: [String]
    let activities: [RosterActivity]?
    let activeHotels: [RosterActivity]?

    var displayTitle: String { title.isEmpty ? category.capitalized : title }

    var displaySubtitle: String {
        if !route.isEmpty && !timeText.isEmpty { return "\(route)  •  \(timeText)" }
        if !route.isEmpty { return route }
        if !timeText.isEmpty { return timeText }
        return rawText
    }

    var isOperationalDuty: Bool {
        !["OFF", "DND", "REST", "VACATION", "LEAVE"].contains(category.uppercased())
    }

    var activityList: [RosterActivity] { activities ?? [] }

    var operationalActivities: [RosterActivity] {
        activityList
            .filter { !$0.isAuxiliary }
            .sorted { activitySortKey($0) < activitySortKey($1) }
    }

    var flightActivities: [RosterActivity] {
        operationalActivities.filter(\.isFlight)
    }

    var sectorCount: Int { flightActivities.count }

    var hotelAssignments: [RosterActivity] {
        uniqueActivities((activeHotels ?? []) + activityList.filter { $0.category.uppercased() == "HOTEL" })
    }

    var reportLocal: String {
        if let value = operationalActivities.compactMap({ $0.localCheckInTime.nilIfEmpty }).first { return value }
        return operationalActivities.first?.localStartTime ?? ""
    }

    var releaseLocal: String {
        if let value = operationalActivities.reversed().compactMap({ $0.localCheckOutTime.nilIfEmpty }).first { return value }
        return operationalActivities.last?.localEndTime ?? ""
    }

    var dutyDuration: String {
        guard let start = dutyStartUTCDate, let end = dutyEndUTCDate, end >= start else { return "" }
        return durationText(end.timeIntervalSince(start))
    }

    var dutyStartUTCDate: Date? {
        for activity in operationalActivities {
            if let date = parseUTCStamp(activity.checkInUTC) { return date }
            if let date = parseUTCStamp(activity.startUTC) { return date }
        }
        return nil
    }

    var dutyEndUTCDate: Date? {
        for activity in operationalActivities.reversed() {
            if let date = parseUTCStamp(activity.checkOutUTC) { return date }
            if let date = parseUTCStamp(activity.endUTC) { return date }
        }
        return nil
    }

    var transferNotes: [String] {
        uniqueStrings(activityList.map(\.transferNote).filter { !$0.isEmpty })
    }

    var activityNotes: [String] {
        uniqueStrings(activityList.map(\.activityNote).filter { !$0.isEmpty })
    }

    var dayNotes: [String] {
        uniqueStrings(activityList.map(\.dayNote).filter { !$0.isEmpty })
    }

    var pickups: [String] {
        uniqueStrings(activityList.map(\.pickup).filter { !$0.isEmpty })
    }

    var aircraft: [RosterActivity] {
        var seen = Set<String>()
        return flightActivities.filter { activity in
            let key = "\(activity.aircraftReg)|\(activity.aircraftType)|\(activity.aircraftVersion)"
            guard !key.replacingOccurrences(of: "|", with: "").isEmpty, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    var crewMembers: [CrewMember] {
        var seen = Set<String>()
        var unique: [CrewMember] = []

        for member in flightActivities.flatMap(\.crew) {
            // RAIDO can repeat the same person once per sector and decorate the
            // display name with operational markers such as (x), (y), (p) or
            // combinations of those markers. Employee/crew code is the stable
            // identity when available; otherwise use a normalized clean name.
            let cleanName = member.name
                .replacingOccurrences(
                    of: #"\s*\((?i:[xyp](?:\s+[xyp])*)\)\s*"#,
                    with: " ",
                    options: .regularExpression
                )
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let normalizedCode = member.code
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            let normalizedName = cleanName
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .uppercased()
            let identity = normalizedCode.isEmpty ? "NAME|\(normalizedName)" : "CODE|\(normalizedCode)"

            guard !identity.hasSuffix("|"), !seen.contains(identity) else { continue }
            seen.insert(identity)
            unique.append(CrewMember(
                role: member.role,
                code: member.code,
                name: cleanName.isEmpty ? member.name : cleanName,
                country: member.country,
                phone: member.phone
            ))
        }
        return unique
    }


    // V2.29.8 flight-associated transport.
    // DLRP may begin before the hotel pickup. Preserve the duty envelope, but
    // match pre-flight transport against the first sector's own check-in.
    private var pickupReportUTCDate: Date? {
        if let sector = operationalActivities.first(where: {
            ["FLIGHT", "POSITIONING"].contains($0.category.uppercased())
        }) {
            return parseUTCStamp(sector.checkInUTC) ?? parseUTCStamp(sector.startUTC) ?? dutyStartUTCDate
        }
        return dutyStartUTCDate
    }

    var preDutyPickupUTCDate: Date? {
        let all = activityList.compactMap { activity -> (Date, String)? in
            guard !activity.pickup.isEmpty, let date = pickupUTCDate(for: activity) else { return nil }
            return (date, activity.pickup)
        }
        guard !all.isEmpty else { return nil }
        if let report = pickupReportUTCDate {
            return all.filter { $0.0 <= report }.sorted { $0.0 < $1.0 }.last?.0
        }
        return all.sorted { $0.0 < $1.0 }.first?.0
    }

    var preDutyPickupDisplay: String {
        guard let selected = preDutyPickupUTCDate else { return "" }
        return activityList.compactMap { activity -> (Date, String)? in
            guard !activity.pickup.isEmpty, let date = pickupUTCDate(for: activity) else { return nil }
            return (date, activity.pickup)
        }
        .min { abs($0.0.timeIntervalSince(selected)) < abs($1.0.timeIntervalSince(selected)) }?.1 ?? ""
    }

    func nextPickup(at now: Date) -> PickupStatus? {
        let candidates: [PickupStatus] = activityList.compactMap { activity in
            guard !activity.pickup.isEmpty,
                  let date = pickupUTCDate(for: activity),
                  date >= now else { return nil }
            return PickupStatus(
                date: date,
                displayTime: activity.pickup,
                title: "Pickup",
                subtitle: activity.route.isEmpty ? activity.title : activity.route
            )
        }
        return candidates.sorted { $0.date < $1.date }.first
    }

    func liveStatus(at now: Date) -> DutyStatus? {
        guard isOperationalDuty, !operationalActivities.isEmpty else { return nil }

        for activity in operationalActivities {
            if let start = parseUTCStamp(activity.startUTC),
               let end = parseUTCStamp(activity.endUTC),
               now >= start, now < end {
                return DutyStatus(
                    label: "NOW",
                    title: activity.title,
                    subtitle: activity.route.isEmpty ? activity.description : activity.route,
                    systemImage: activity.isFlight ? "airplane" : "clock.fill"
                )
            }
        }

        if let pickup = preDutyPickupUTCDate, pickup > now {
            return DutyStatus(
                label: "NEXT • \(relativeText(from: now, to: pickup))",
                title: "Pickup",
                subtitle: compactPickupClock(preDutyPickupDisplay),
                systemImage: "car.fill"
            )
        }

        var future: [(Date, String, String, String)] = []
        if let first = operationalActivities.first,
           let date = parseUTCStamp(first.checkInUTC), date > now {
            future.append((date, "Check-in", first.localCheckInTime, "person.badge.clock"))
        }
        for activity in operationalActivities {
            if let date = parseUTCStamp(activity.startUTC), date > now {
                future.append((date, activity.title, activity.route, activity.isFlight ? "airplane.departure" : "clock"))
            }
        }
        if let last = operationalActivities.last,
           let date = parseUTCStamp(last.checkOutUTC), date > now {
            future.append((date, "Check-out", last.localCheckOutTime, "checkmark.circle"))
        }

        if let next = future.sorted(by: { $0.0 < $1.0 }).first {
            return DutyStatus(
                label: "NEXT • \(relativeText(from: now, to: next.0))",
                title: next.1,
                subtitle: next.2,
                systemImage: next.3
            )
        }

        if let end = dutyEndUTCDate, now >= end {
            return DutyStatus(label: "COMPLETE", title: "Duty finished", subtitle: releaseLocal.isEmpty ? "" : "Released \(releaseLocal)", systemImage: "checkmark.circle.fill")
        }
        return nil
    }
}

struct DutyStatus {
    let label: String
    let title: String
    let subtitle: String
    let systemImage: String
}

struct PickupStatus {
    let date: Date
    let displayTime: String
    let title: String
    let subtitle: String
}

struct RosterValidation: Codable, Equatable {
    let isValid: Bool
    let parser: String
    let month: String
    let datedRows: Int
    let message: String
}

struct RosterSnapshot: Codable, Equatable {
    let capturedAt: Date
    let sourceURL: String
    let pageTitle: String
    let items: [RosterItem]
    let validation: RosterValidation?
    // Authoritative monthly BLH displayed by N-OC/RAIDO (for example "70:48").
    // Optional preserves decoding of older cached snapshots.
    let monthlyBLH: String?
}


struct RosterChangeField: Codable, Equatable, Identifiable {
    let label: String
    let oldValue: String
    let newValue: String
    var id: String { label }
}

struct RosterDayChange: Codable, Equatable, Identifiable {
    let dateISO: String
    let dateText: String
    let fields: [RosterChangeField]
    var id: String { dateISO }
}

struct RosterChangeBundle: Codable, Equatable {
    let capturedAt: Date
    let changes: [RosterDayChange]
}

extension RosterSnapshot {
    // Compatibility for feed/archive paths created before monthlyBLH existed.
    // Live RAIDO page snapshots use the six-argument initializer and preserve monthlyBLH.
    init(capturedAt: Date, sourceURL: String, pageTitle: String, items: [RosterItem], validation: RosterValidation?) {
        self.init(
            capturedAt: capturedAt,
            sourceURL: sourceURL,
            pageTitle: pageTitle,
            items: items,
            validation: validation,
            monthlyBLH: nil
        )
    }
}

struct SummaryMetric: Identifiable {
    let label: String
    let value: Int
    var id: String { label }
}

struct OperationalMetric: Identifiable {
    let label: String
    let value: String
    let systemImage: String
    var id: String { label }
}



@MainActor
final class DutyReminderScheduler: ObservableObject {
    @Published var message: String?
    @Published var isWorking = false

    private let center = UNUserNotificationCenter.current()
    private let identifierPrefix = "RAIDO-ROSTER-"

    func requestAndSchedule(_ items: [RosterItem], pickupLead: Int, reportLead: Int) {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                if pickupLead <= 0 && reportLead <= 0 {
                    await clearPending()
                    message = "Duty reminders are off."
                    return
                }
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                guard granted else {
                    message = "Notification access was not granted."
                    return
                }
                let count = try await schedule(items, pickupLead: pickupLead, reportLead: reportLead)
                message = "Duty reminders scheduled • \(count) upcoming"
            } catch {
                message = "Reminder scheduling failed: \(error.localizedDescription)"
            }
        }
    }

    func syncIfAuthorized(_ items: [RosterItem], pickupLead: Int, reportLead: Int, completion: @escaping (String) -> Void) {
        Task { @MainActor in
            if pickupLead <= 0 && reportLead <= 0 {
                await clearPending()
                completion("Duty reminders off")
                return
            }

            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional ||
                    settings.authorizationStatus == .ephemeral else {
                completion("Reminder permission required • configure once in Settings")
                return
            }

            do {
                let count = try await schedule(items, pickupLead: pickupLead, reportLead: reportLead)
                completion("Reminders refreshed • \(count) upcoming")
            } catch {
                completion("Reminder refresh failed: \(error.localizedDescription)")
            }
        }
    }

    func clearRosterReminders() {
        Task { @MainActor in await clearPending() }
    }

    private func schedule(_ items: [RosterItem], pickupLead: Int, reportLead: Int) async throws -> Int {
        await clearPending()
        let now = Date()
        var requests: [(Date, UNNotificationRequest)] = []

        for item in items where item.isOperationalDuty {
            if reportLead > 0, let report = item.dutyStartUTCDate {
                let fire = report.addingTimeInterval(TimeInterval(-reportLead * 60))
                if fire > now.addingTimeInterval(2) {
                    let content = UNMutableNotificationContent()
                    content.title = "Report in \(reportLead) min"
                    content.body = reminderBody(item)
                    content.sound = .default
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fire.timeIntervalSinceNow), repeats: false)
                    let request = UNNotificationRequest(
                        identifier: identifierPrefix + "REPORT-" + item.id,
                        content: content,
                        trigger: trigger
                    )
                    requests.append((fire, request))
                }
            }

            if pickupLead > 0, let pickup = item.preDutyPickupUTCDate {
                let fire = pickup.addingTimeInterval(TimeInterval(-pickupLead * 60))
                if fire > now.addingTimeInterval(2) {
                    let content = UNMutableNotificationContent()
                    content.title = "Pickup in \(pickupLead) min"
                    let pickupText = item.preDutyPickupDisplay
                    let dutyText = reminderBody(item)
                    content.body = pickupText.isEmpty ? dutyText : "\(pickupText) • \(dutyText)"
                    content.sound = .default
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fire.timeIntervalSinceNow), repeats: false)
                    let request = UNNotificationRequest(
                        identifier: identifierPrefix + "PICKUP-" + item.id,
                        content: content,
                        trigger: trigger
                    )
                    requests.append((fire, request))
                }
            }
        }

        // Stay comfortably within iOS' finite pending-notification budget.
        // Nearest reminders are the ones that matter operationally.
        let selected = requests.sorted { $0.0 < $1.0 }.prefix(60)
        for (_, request) in selected {
            try await center.add(request)
        }
        return selected.count
    }

    private func clearPending() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
    }

    private func reminderBody(_ item: RosterItem) -> String {
        if !item.route.isEmpty { return "\(item.displayTitle) • \(item.route)" }
        return item.displayTitle
    }
}

@MainActor
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

    func syncMonthIfAuthorized(
        _ items: [RosterItem],
        month: String?,
        completion: @escaping (String) -> Void
    ) {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }

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

            try reconcile(items: selected, month: month, removeObsolete: true)
            try eventStore.commit()
            completion("Calendar synced • \(selected.count) duties • \(created) added • \(updated) updated")
        } catch {
            completion("Calendar sync failed: \(error.localizedDescription)")
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
        for duplicate in candidates {
            if duplicate === event { continue }
            if duplicate.calendarItemIdentifier == event.calendarItemIdentifier { continue }
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
        let owned = eventStore.events(matching: predicate).filter { self.isRAIDOOwned($0) }

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

            if canonical.notes?.contains(stableMarker) != true {
                canonical.notes = strippedRAIDOMarkers(canonical.notes ?? "")
                let base = canonical.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                canonical.notes = base.isEmpty ? stableMarker : base + "\n\n" + stableMarker
                canonical.url = URL(string: "raidoroster://calendar/\(expectedDuty.key)")
                try eventStore.save(canonical, span: .thisEvent, commit: false)
            }

            for duplicate in matches {
                if duplicate === canonical { continue }
                if duplicate.calendarItemIdentifier == canonical.calendarItemIdentifier { continue }
                try eventStore.remove(duplicate, span: .thisEvent, commit: false)
            }
        }

        guard removeObsolete else { return }

        // Remove stale RAIDO-owned events in the synced month only when they do
        // not correspond to any current roster duty. Personal/non-RAIDO events
        // never enter `owned` and therefore cannot be touched here.
        for event in owned {
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
        return eventStore.events(matching: predicate).filter { self.isRAIDOOwned($0) }
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
}


@MainActor
final class RosterStore: ObservableObject {
    @Published private(set) var snapshot: RosterSnapshot?
    @Published private(set) var monthSnapshots: [String: RosterSnapshot] = [:]
    @Published var selectedRosterMonthKey: String?
    @Published var changeNotice: String?
    @Published private(set) var changedDates: Set<String> = []
    @Published private(set) var latestChanges: [RosterDayChange] = []
    @Published var calendarSyncStatus: String?
    @Published var reminderSyncStatus: String?

    private let calendar = Calendar.current
    private let automaticCalendarExporter = CalendarExporter()
    private let automaticReminderScheduler = DutyReminderScheduler()
    private let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init() {
        load()
        loadChangeState()
        try? FileManager.default.removeItem(at: storageFolderURL.appendingPathComponent("crew-history.json"))
        // V2.11.3 retires historical crew counting and removes any previously
        // generated archive from this device.
    }

    var items: [RosterItem] { snapshot?.items ?? [] }
    var lastSync: Date? { snapshot?.capturedAt }
    var hasCache: Bool { !(snapshot?.items.isEmpty ?? true) }
    var isCacheValidated: Bool { snapshot?.validation?.isValid == true }
    var validationMessage: String? { snapshot?.validation?.message }
    var cachedMonth: String? { snapshot?.validation?.month }


    private func monthKey(for snapshot: RosterSnapshot) -> String {
        if let month = snapshot.validation?.month,
           month.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil {
            return month
        }
        if let iso = snapshot.items.compactMap(\.dateISO).first(where: {
            $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        }) {
            return String(iso.prefix(7))
        }
        return "unknown"
    }

    var rosterMonthKeys: [String] { monthSnapshots.keys.sorted() }

    var rosterViewSnapshot: RosterSnapshot? {
        if let key = selectedRosterMonthKey {
            return monthSnapshots[key]
        }
        return snapshot
    }

    var rosterViewItems: [RosterItem] { rosterViewSnapshot?.items ?? [] }


    var selectedRosterMonth: String? {
        selectedRosterMonthKey ?? rosterViewSnapshot.map(monthKey(for:))
    }

    var rosterCalendarItems: [RosterItem] {
        guard let month = selectedRosterMonth, month.count == 7 else { return rosterViewItems }
        return rosterViewItems.filter { $0.dateISO?.hasPrefix(month) == true }
    }

    var rosterMonthTitle: String {
        guard let key = selectedRosterMonthKey ?? snapshot.map(monthKey(for:)), key.count == 7 else {
            return rosterViewSnapshot?.validation?.month.nilIfEmpty ?? "Roster"
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale.current
        formatter.dateFormat = "yyyy-MM"
        guard let date = formatter.date(from: key) else { return key }
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: date)
    }

    var canSelectPreviousRosterMonth: Bool {
        adjacentRosterMonthKey(previous: true) != nil
    }

    var canSelectNextRosterMonth: Bool {
        adjacentRosterMonthKey(previous: false) != nil
    }

    func adjacentRosterMonthKey(previous: Bool) -> String? {
        guard let key = selectedRosterMonth, key.count == 7 else { return nil }
        let parts = key.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              (1...12).contains(month) else { return nil }

        let delta = previous ? -1 : 1
        let zeroBased = (year * 12) + (month - 1) + delta
        guard zeroBased >= 0 else { return nil }
        let targetYear = zeroBased / 12
        let targetMonth = (zeroBased % 12) + 1
        return String(format: "%04d-%02d", targetYear, targetMonth)
    }

    @discardableResult
    func selectRosterMonthIfCached(_ key: String) -> Bool {
        selectedRosterMonthKey = key
        return monthSnapshots[key] != nil
    }

    func showPendingRosterMonth(_ key: String) {
        selectedRosterMonthKey = key
    }

    func selectPreviousRosterMonth() {
        guard let target = adjacentRosterMonthKey(previous: true) else { return }
        selectedRosterMonthKey = target
    }

    func selectNextRosterMonth() {
        guard let target = adjacentRosterMonthKey(previous: false) else { return }
        selectedRosterMonthKey = target
    }

    var rosterViewSummaryMetrics: [SummaryMetric] {
        let selectedItems = rosterViewItems
        let flightDays = selectedItems.filter { $0.category.uppercased() == "FLIGHT" }.count
        let sectors = selectedItems.reduce(0) { $0 + $1.sectorCount }
        let categories = Dictionary(grouping: selectedItems, by: { $0.category.uppercased() })
        return [
            SummaryMetric(label: "FLY DAYS", value: flightDays),
            SummaryMetric(label: "SECTORS", value: sectors),
            SummaryMetric(label: "POSITION", value: categories["POSITIONING"]?.count ?? 0),
            SummaryMetric(label: "RES", value: categories["RESERVE"]?.count ?? 0),
            SummaryMetric(label: "SBY", value: categories["STANDBY"]?.count ?? 0),
            SummaryMetric(label: "OFF", value: categories["OFF"]?.count ?? 0)
        ].filter { $0.value > 0 }
    }

    var rosterViewDuty: RosterItem? {
        let todayKey = isoDay.string(from: Date())
        let operational = rosterViewItems.filter(\.isOperationalDuty)
        return operational.first(where: { ($0.dateISO ?? "") >= todayKey }) ?? operational.first
    }

    var todayItems: [RosterItem] {
        let key = isoDay.string(from: Date())
        let month = String(key.prefix(7))

        // Today is a global app concept, not a property of the month currently
        // selected in the Roster tab. Prefer the archived current-month
        // snapshot, then the legacy current snapshot, then any archive row that
        // actually contains today's date.
        let preferred: [RosterItem]
        if let currentMonth = monthSnapshots[month] {
            preferred = currentMonth.items
        } else if snapshot?.items.contains(where: { $0.dateISO == key }) == true {
            preferred = snapshot?.items ?? []
        } else {
            preferred = monthSnapshots.values
                .sorted { $0.capturedAt > $1.capturedAt }
                .first(where: { $0.items.contains(where: { $0.dateISO == key }) })?
                .items ?? []
        }
        return preferred.filter { $0.dateISO == key }
    }

    var todayPrimaryItem: RosterItem? {
        let now = Date()
        let today = todayItems
        if let active = today.first(where: { item in
            guard let start = item.dutyStartUTCDate, let end = item.dutyEndUTCDate else { return false }
            return now >= start && now < end
        }) { return active }

        let future = today.compactMap { item -> (RosterItem, Date)? in
            guard item.isOperationalDuty, let start = item.dutyStartUTCDate, start > now else { return nil }
            return (item, start)
        }.sorted { $0.1 < $1.1 }
        if let next = future.first { return next.0 }

        let completed = today.compactMap { item -> (RosterItem, Date)? in
            guard item.isOperationalDuty, let end = item.dutyEndUTCDate, end <= now else { return nil }
            return (item, end)
        }.sorted { $0.1 > $1.1 }
        return completed.first?.0 ?? today.first
    }


    var upcomingItems: [RosterItem] {
        let today = calendar.startOfDay(for: Date())
        let future = items.filter { item in
            guard let key = item.dateISO, let date = isoDay.date(from: key) else { return false }
            return date >= today
        }
        return future.isEmpty ? items : future
    }

    var nextDuty: RosterItem? {
        let today = calendar.startOfDay(for: Date())
        var byID: [String: RosterItem] = [:]
        for snap in monthSnapshots.values {
            for item in snap.items { byID[item.id] = item }
        }
        for item in snapshot?.items ?? [] { byID[item.id] = item }

        return byID.values.compactMap { item -> (RosterItem, Date)? in
            guard item.isOperationalDuty,
                  let key = item.dateISO,
                  let date = isoDay.date(from: key) else { return nil }
            return (item, date)
        }
        .filter { $0.1 >= today }
        .sorted {
            if $0.1 == $1.1 { return $0.0.index < $1.0.index }
            return $0.1 < $1.1
        }
        .first?.0
    }

    var operationalMetrics: [OperationalMetric] {
        var flightSeconds: TimeInterval = 0
        var dutySeconds: TimeInterval = 0
        var standbySeconds: TimeInterval = 0
        var reserveSeconds: TimeInterval = 0
        var longestDuty: TimeInterval = 0
        var earlyReports = 0

        for item in items {
            if let start = item.dutyStartUTCDate, let end = item.dutyEndUTCDate, end > start {
                let interval = end.timeIntervalSince(start)
                dutySeconds += interval
                longestDuty = max(longestDuty, interval)
            }

            if let hour = Int(item.reportLocal.split(separator: ":").first ?? ""), hour < 6, item.isOperationalDuty {
                earlyReports += 1
            }

            for activity in item.activityList {
                guard let start = parseUTCStamp(activity.startUTC),
                      let end = parseUTCStamp(activity.endUTC), end > start else { continue }
                let interval = end.timeIntervalSince(start)
                switch activity.category.uppercased() {
                case "FLIGHT": flightSeconds += interval
                case "STANDBY": standbySeconds += interval
                case "RESERVE": reserveSeconds += interval
                default: break
                }
            }
        }

        var result: [OperationalMetric] = []
        if flightSeconds > 0 { result.append(.init(label: "FLIGHT TIME", value: durationText(flightSeconds), systemImage: "airplane")) }
        if dutySeconds > 0 { result.append(.init(label: "DUTY TIME", value: durationText(dutySeconds), systemImage: "clock")) }
        if standbySeconds > 0 { result.append(.init(label: "STANDBY", value: durationText(standbySeconds), systemImage: "hourglass")) }
        if reserveSeconds > 0 { result.append(.init(label: "RESERVE", value: durationText(reserveSeconds), systemImage: "clock.badge.questionmark")) }
        if longestDuty > 0 { result.append(.init(label: "LONGEST DUTY", value: durationText(longestDuty), systemImage: "arrow.left.and.right")) }
        if earlyReports > 0 { result.append(.init(label: "EARLY <06", value: "\(earlyReports)", systemImage: "sunrise")) }
        return result
    }

    func previousOperationalDuty(before item: RosterItem) -> RosterItem? {
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

    func nextOperationalDuty(after item: RosterItem) -> RosterItem? {
        guard let end = item.dutyEndUTCDate else { return nil }
        return items.compactMap { candidate -> (RosterItem, Date)? in
            guard candidate.id != item.id,
                  candidate.isOperationalDuty,
                  let start = candidate.dutyStartUTCDate,
                  start > end else { return nil }
            return (candidate, start)
        }
        .sorted { $0.1 < $1.1 }
        .first?.0
    }

    func restInterval(after item: RosterItem, before next: RosterItem) -> TimeInterval? {
        guard let end = item.dutyEndUTCDate,
              let start = next.dutyStartUTCDate,
              start > end else { return nil }
        return start.timeIntervalSince(end)
    }

    var summaryMetrics: [SummaryMetric] {
        let flightDays = items.filter { $0.category.uppercased() == "FLIGHT" }.count
        let sectors = items.reduce(0) { $0 + $1.sectorCount }
        let categories = Dictionary(grouping: items, by: { $0.category.uppercased() })
        var metrics = [
            SummaryMetric(label: "FLY DAYS", value: flightDays),
            SummaryMetric(label: "SECTORS", value: sectors),
            SummaryMetric(label: "POSITION", value: categories["POSITIONING"]?.count ?? 0),
            SummaryMetric(label: "RES", value: categories["RESERVE"]?.count ?? 0),
            SummaryMetric(label: "SBY", value: categories["STANDBY"]?.count ?? 0),
            SummaryMetric(label: "OFF", value: categories["OFF"]?.count ?? 0)
        ]
        metrics = metrics.filter { $0.value > 0 }
        return metrics
    }

    func ingest(messageBody: Any) {
        guard let payload = messageBody as? [String: Any],
              let rawRows = payload["rows"] as? [[String: Any]],
              let validationPayload = payload["validation"] as? [String: Any] else { return }

        let validation = RosterValidation(
            isValid: validationPayload["isValid"] as? Bool ?? false,
            parser: validationPayload["parser"] as? String ?? "unknown",
            month: validationPayload["month"] as? String ?? "",
            datedRows: validationPayload["datedRows"] as? Int ?? 0,
            message: validationPayload["message"] as? String ?? "Roster parse incomplete"
        )

        guard validation.isValid else { return }
        let parsed: [RosterItem] = rawRows.enumerated().compactMap { offset, row in
            let text = (row["rawText"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let dateISO = row["dateISO"] as? String,
                  !dateISO.isEmpty else { return nil }

            let activities = (row["activities"] as? [[String: Any]])?.enumerated().compactMap { index, raw in
                parseActivity(raw, fallbackID: "\(dateISO)-a\(index)")
            }
            let hotels = (row["activeHotels"] as? [[String: Any]])?.enumerated().compactMap { index, raw in
                parseActivity(raw, fallbackID: "\(dateISO)-h\(index)")
            }

            return RosterItem(
                id: row["id"] as? String ?? "day-\(dateISO)",
                index: row["index"] as? Int ?? offset,
                dateISO: dateISO,
                dateText: row["dateText"] as? String ?? dateISO,
                category: row["category"] as? String ?? "OTHER",
                title: row["title"] as? String ?? "",
                route: row["route"] as? String ?? "",
                timeText: row["timeText"] as? String ?? "",
                rawText: text,
                cells: row["cells"] as? [String] ?? [],
                activities: activities,
                activeHotels: hotels
            )
        }
        .sorted { ($0.dateISO ?? "") < ($1.dateISO ?? "") }

        guard parsed.count >= 5,
              parsed.count == validation.datedRows,
              parsed.allSatisfy({ $0.dateISO != nil }) else { return }

        let old = snapshot
        let newSnapshot = RosterSnapshot(
            capturedAt: Date(),
            sourceURL: payload["sourceURL"] as? String ?? "",
            pageTitle: payload["pageTitle"] as? String ?? "RAIDO",
            items: parsed,
            validation: validation,
            monthlyBLH: (payload["monthlyBLH"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )

        if let old,
           old.validation?.month == validation.month,
           normalized(old.items) != normalized(parsed) {
            let changes = buildDayChanges(old: old.items, new: parsed)
            if !changes.isEmpty {
                latestChanges = changes
                changedDates = Set(changes.map(\.dateISO))
                let changed = changes.count
                changeNotice = "Roster changed • \(changed) day\(changed == 1 ? "" : "s")"
                saveChangeState()
                notifyRosterChanges(changes)
            }
        }

        snapshot = newSnapshot
        save(newSnapshot)
        let archiveKey = monthKey(for: newSnapshot)
        selectedRosterMonthKey = validation.month.isEmpty ? archiveKey : validation.month
        monthSnapshots[archiveKey] = newSnapshot
        selectedRosterMonthKey = archiveKey
        saveMonthSnapshots()

        let autoCalendar = UserDefaults.standard.object(forKey: "RAIDORoster.AutoCalendarSync") as? Bool ?? true
        if autoCalendar {
            automaticCalendarExporter.syncMonthIfAuthorized(parsed, month: validation.month) { [weak self] status in
                self?.calendarSyncStatus = status
            }
        }

        let pickupLead = UserDefaults.standard.integer(forKey: "RAIDORoster.PickupReminderLead")
        let reportLead = UserDefaults.standard.integer(forKey: "RAIDORoster.ReportReminderLead")
        automaticReminderScheduler.syncIfAuthorized(parsed, pickupLead: pickupLead, reportLead: reportLead) { [weak self] status in
            self?.reminderSyncStatus = status
        }
    }

    func ingestCalendarFeed(messageBody: Any) {
        guard let payload = messageBody as? [String: Any],
              let rawEvents = payload["events"] as? [[String: Any]],
              !rawEvents.isEmpty else { return }

        let currentMonth = currentRosterMonthKey()
        let selectedBefore = selectedRosterMonthKey
        let grouped = Dictionary(grouping: rawEvents) { event in
            (event["dateISO"] as? String).map { String($0.prefix(7)) } ?? ""
        }

        var changedArchive = false
        for (month, events) in grouped where month.count == 7 {
            // Historical HTML snapshots are immutable. Feed snapshots from
            // earlier feed-parser versions may be rebuilt/migrated.
            if month < currentMonth,
               let existing = monthSnapshots[month],
               existing.validation?.parser.hasPrefix("raido-duty-envelope") == true {
                continue
            }

            // Never replace the detailed HTML snapshot for the current month.
            if month == currentMonth,
               let existing = monthSnapshots[month],
               existing.validation?.parser.hasPrefix("raido-duty-envelope") == true {
                continue
            }

            let items = events.enumerated().compactMap { offset, event -> RosterItem? in
                guard let dateISO = event["dateISO"] as? String, !dateISO.isEmpty else { return nil }
                let summary = (event["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let description = (event["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let category = feedCategory(summary: summary, description: description)
                let title = feedTitle(summary: summary, category: category)
                let route = feedRoute(summary: summary, description: description)
                let startLocal = event["startLocal"] as? String ?? ""
                let endLocal = event["endLocal"] as? String ?? ""
                let startUTC = event["startUTC"] as? String ?? ""
                let endUTC = event["endUTC"] as? String ?? ""
                let uid = event["uid"] as? String ?? "feed-\(dateISO)-\(offset)"
                let code = summary.split(separator: " ").first.map(String.init) ?? title

                let activity = RosterActivity(
                    id: "feed-a-\(uid)",
                    code: code,
                    category: category,
                    title: title,
                    description: description,
                    route: route,
                    station: feedStation(summary),
                    checkInLT: "",
                    checkInUTC: "",
                    startLT: startLocal.isEmpty ? "" : "\(dateISO) \(startLocal)",
                    startUTC: startUTC,
                    endLT: endLocal.isEmpty ? "" : "\(dateISO) \(endLocal)",
                    endUTC: endUTC,
                    checkOutLT: "",
                    checkOutUTC: "",
                    hotelName: "",
                    pickup: "",
                    transferNote: "",
                    activityNote: "",
                    dayNote: "",
                    aircraftReg: "",
                    aircraftType: "",
                    aircraftVersion: "",
                    aircraftPhone: "",
                    crew: [],
                    rawText: description
                )

                let timeText: String
                if !startLocal.isEmpty && !endLocal.isEmpty { timeText = "\(startLocal)–\(endLocal)" }
                else { timeText = "" }

                return RosterItem(
                    id: "feed-\(uid)",
                    index: offset,
                    dateISO: dateISO,
                    dateText: dateISO,
                    category: category,
                    title: title,
                    route: route,
                    timeText: timeText,
                    rawText: description.isEmpty ? summary : description,
                    cells: [],
                    activities: [activity],
                    activeHotels: []
                )
            }
            .sorted {
                if $0.dateISO == $1.dateISO { return $0.index < $1.index }
                return ($0.dateISO ?? "") < ($1.dateISO ?? "")
            }

            guard !items.isEmpty else { continue }
            let snapshot = RosterSnapshot(
                capturedAt: Date(),
                sourceURL: "n-oc-webcal-feed",
                pageTitle: "N-OC roster calendar feed",
                items: items,
                validation: RosterValidation(
                    isValid: true,
                    parser: "n-oc-webcal-2.19.4",
                    month: month,
                    datedRows: items.count,
                    message: "\(items.count) roster events from N-OC calendar feed"
                )
            )
            monthSnapshots[month] = snapshot
            changedArchive = true
        }

        if changedArchive { saveMonthSnapshots() }
        // Background feed refresh must never move the user's visible calendar.
        selectedRosterMonthKey = selectedBefore ?? selectedRosterMonthKey ?? monthSnapshots.keys.sorted().last
    }

    private func currentRosterMonthKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }

    private func feedCategory(summary: String, description: String) -> String {
        let value = (summary + " " + description).uppercased()
        if value.contains("DAY OFF") || value.hasPrefix("OFF ") { return "OFF" }
        if value.contains("RESERVE") || value.hasPrefix("RES ") { return "RESERVE" }
        if value.contains("STANDBY") || value.hasPrefix("STB") { return "STANDBY" }
        if value.contains("POSITIONING") || value.hasPrefix("POS ") { return "POSITIONING" }
        if value.contains("DND") { return "DND" }
        if value.contains("REST") { return "REST" }
        if value.contains("VACATION") || value.contains("HOLIDAY") { return "VACATION" }
        if value.contains("LEAVE") { return "LEAVE" }
        if value.contains("HOTEL") || value.hasPrefix("HTL ") { return "HOTEL" }
        if summary.range(of: #"\b[A-Z0-9]{2,3}\d{2,4}[A-Z]?\b"#, options: .regularExpression) != nil { return "FLIGHT" }
        return "OTHER"
    }

    private func feedTitle(summary: String, category: String) -> String {
        switch category {
        case "OFF": return "OFF"
        case "RESERVE": return "RESERVE"
        case "STANDBY": return summary.uppercased().contains("MORNING") ? "STANDBY MORNING" : (summary.uppercased().contains("AFTERNOON") ? "STANDBY AFTERNOON" : "STANDBY")
        case "POSITIONING": return "POSITIONING"
        case "DND": return "DND"
        case "REST": return "REST"
        case "VACATION": return "VACATION"
        case "LEAVE": return "LEAVE"
        default:
            return summary.isEmpty ? category.capitalized : summary
        }
    }

    private func feedStation(_ summary: String) -> String {
        let tokens = summary.uppercased().split(separator: " ").map(String.init)
        return tokens.reversed().first(where: { $0.count == 3 && $0.allSatisfy(\.isLetter) }) ?? ""
    }

    private func feedRoute(summary: String, description: String) -> String {
        let text = (summary + " " + description).uppercased()
        if let match = text.range(of: #"\b[A-Z]{3}\s*(?:-|→|TO)\s*[A-Z]{3}\b"#, options: .regularExpression) {
            return String(text[match]).replacingOccurrences(of: " TO ", with: " → ").replacingOccurrences(of: "-", with: " → ")
        }
        return ""
    }

    func dismissChangeNotice() {
        changeNotice = nil
        changedDates = []
        latestChanges = []
        try? FileManager.default.removeItem(at: changeStateURL)
    }

    func change(for dateISO: String?) -> RosterDayChange? {
        guard let dateISO else { return nil }
        return latestChanges.first { $0.dateISO == dateISO }
    }

    func clearCache() {
        snapshot = nil
        monthSnapshots = [:]
        selectedRosterMonthKey = nil
        changeNotice = nil
        changedDates = []
        latestChanges = []
        calendarSyncStatus = nil
        reminderSyncStatus = nil
        automaticReminderScheduler.clearRosterReminders()
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.removeItem(at: monthCacheURL)
        try? FileManager.default.removeItem(at: changeStateURL)
    }

    private func parseActivity(_ raw: [String: Any], fallbackID: String) -> RosterActivity? {
        let code = raw["code"] as? String ?? ""
        let title = raw["title"] as? String ?? code
        guard !title.isEmpty || !code.isEmpty else { return nil }
        let crew = (raw["crew"] as? [[String: Any]])?.compactMap { member -> CrewMember? in
            let role = member["role"] as? String ?? ""
            let code = member["code"] as? String ?? ""
            let name = member["name"] as? String ?? ""
            guard !name.isEmpty else { return nil }
            return CrewMember(
                role: role,
                code: code,
                name: name,
                country: member["country"] as? String,
                phone: member["phone"] as? String
            )
        } ?? []

        return RosterActivity(
            id: raw["id"] as? String ?? fallbackID,
            code: code,
            category: raw["category"] as? String ?? "OTHER",
            title: title,
            description: raw["description"] as? String ?? "",
            route: raw["route"] as? String ?? "",
            station: raw["station"] as? String ?? "",
            checkInLT: raw["checkInLT"] as? String ?? "",
            checkInUTC: raw["checkInUTC"] as? String ?? "",
            startLT: raw["startLT"] as? String ?? "",
            startUTC: raw["startUTC"] as? String ?? "",
            endLT: raw["endLT"] as? String ?? "",
            endUTC: raw["endUTC"] as? String ?? "",
            checkOutLT: raw["checkOutLT"] as? String ?? "",
            checkOutUTC: raw["checkOutUTC"] as? String ?? "",
            hotelName: raw["hotelName"] as? String ?? "",
            pickup: raw["pickup"] as? String ?? "",
            transferNote: raw["transferNote"] as? String ?? "",
            activityNote: raw["activityNote"] as? String ?? "",
            dayNote: raw["dayNote"] as? String ?? "",
            aircraftReg: raw["aircraftReg"] as? String ?? "",
            aircraftType: raw["aircraftType"] as? String ?? "",
            aircraftVersion: raw["aircraftVersion"] as? String ?? "",
            aircraftPhone: raw["aircraftPhone"] as? String ?? "",
            crew: crew,
            rawText: raw["rawText"] as? String ?? ""
        )
    }

    private func normalized(_ items: [RosterItem]) -> [String] {
        items.map(normalizedItem)
    }

    private func normalizedItem(_ item: RosterItem) -> String {
        let detail = item.activityList.map {
            let crew = $0.crew.map { "\($0.role):\($0.code):\($0.name)" }.joined(separator: ",")
            return "\($0.id)|\($0.transferNote)|\($0.activityNote)|\($0.dayNote)|\($0.pickup)|\($0.aircraftReg)|\($0.aircraftType)|\($0.checkInUTC)|\($0.checkOutUTC)|\(crew)"
        }.joined(separator: "~")
        return "\(item.dateISO ?? "")|\(item.category)|\(item.title)|\(item.route)|\(item.timeText)|\(detail)"
    }


    private func buildDayChanges(old: [RosterItem], new: [RosterItem]) -> [RosterDayChange] {
        let oldGroups = Dictionary(grouping: old.compactMap { item -> RosterItem? in item.dateISO == nil ? nil : item }, by: { $0.dateISO ?? "" })
        let newGroups = Dictionary(grouping: new.compactMap { item -> RosterItem? in item.dateISO == nil ? nil : item }, by: { $0.dateISO ?? "" })
        let oldMap = oldGroups.compactMapValues { $0.sorted { $0.index < $1.index }.first }
        let newMap = newGroups.compactMapValues { $0.sorted { $0.index < $1.index }.first }
        let dates = Set(oldMap.keys).union(newMap.keys).sorted()

        return dates.compactMap { date in
            let before = oldMap[date]
            let after = newMap[date]
            guard before.map(normalizedItem) != after.map(normalizedItem) else { return nil }

            var fields: [RosterChangeField] = []
            addChange(&fields, label: "Duty", old: dutyLabel(before), new: dutyLabel(after))
            addChange(&fields, label: "Route", old: before?.route ?? "", new: after?.route ?? "")
            addChange(&fields, label: "CI", old: before?.reportLocal ?? "", new: after?.reportLocal ?? "")
            addChange(&fields, label: "Release", old: before?.releaseLocal ?? "", new: after?.releaseLocal ?? "")
            addChange(&fields, label: "Schedule", old: dutySpan(before), new: dutySpan(after))
            addChange(&fields, label: "Pickup", old: before?.preDutyPickupDisplay ?? "", new: after?.preDutyPickupDisplay ?? "")
            addChange(&fields, label: "Aircraft", old: aircraftSummary(before), new: aircraftSummary(after))
            addChange(&fields, label: "Hotel", old: hotelSummary(before), new: hotelSummary(after))
            addChange(&fields, label: "Crew", old: crewSummary(before), new: crewSummary(after))

            addChange(
                &fields,
                label: "Transfer note",
                old: changeNoteSummary(before?.transferNotes ?? []),
                new: changeNoteSummary(after?.transferNotes ?? [])
            )
            addChange(
                &fields,
                label: "Activity note",
                old: changeNoteSummary(before?.activityNotes ?? []),
                new: changeNoteSummary(after?.activityNotes ?? [])
            )
            addChange(
                &fields,
                label: "Day note",
                old: changeNoteSummary(before?.dayNotes ?? []),
                new: changeNoteSummary(after?.dayNotes ?? [])
            )

            if fields.isEmpty {
                fields.append(.init(label: "Roster data", oldValue: before == nil ? "Not assigned" : "Previous assignment", newValue: after == nil ? "Removed" : "Updated assignment"))
            }

            return RosterDayChange(
                dateISO: date,
                dateText: after?.dateText ?? before?.dateText ?? date,
                fields: fields
            )
        }
    }

    private func addChange(_ fields: inout [RosterChangeField], label: String, old: String, new: String) {
        let a = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard a != b else { return }
        fields.append(.init(label: label, oldValue: a.isEmpty ? "—" : a, newValue: b.isEmpty ? "—" : b))
    }

    private func dutyLabel(_ item: RosterItem?) -> String {
        guard let item else { return "" }
        let flights = item.flightActivities.map(\.code).filter { !$0.isEmpty }
        return flights.isEmpty ? item.displayTitle : flights.joined(separator: " + ")
    }

    private func dutySpan(_ item: RosterItem?) -> String {
        guard let item,
              let first = item.operationalActivities.first,
              let last = item.operationalActivities.last else { return "" }
        return [first.localStartTime, last.localEndTime].filter { !$0.isEmpty }.joined(separator: "–")
    }

    private func aircraftSummary(_ item: RosterItem?) -> String {
        guard let item else { return "" }
        return item.aircraft.map { aircraft in
            let op = OperatorResolver.resolve(registration: aircraft.aircraftReg)
            let operatorText = op == .verify ? "" : op.rawValue
            return [operatorText, aircraftTypeLabel(aircraft.aircraftType), aircraft.aircraftReg]
                .filter { !$0.isEmpty }
                .joined(separator: " • ")
        }.joined(separator: ", ")
    }

    private func hotelSummary(_ item: RosterItem?) -> String {
        guard let item else { return "" }
        return uniqueStrings(item.hotelAssignments.map { $0.hotelName.isEmpty ? $0.title : $0.hotelName }).joined(separator: ", ")
    }

    private func crewSummary(_ item: RosterItem?) -> String {
        guard let item else { return "" }
        return item.crewMembers.map { member in
            member.role.isEmpty ? member.name : "\(member.role) \(member.name)"
        }.joined(separator: ", ")
    }


    private func changeNoteSummary(_ notes: [String]) -> String {
        let value = uniqueStrings(notes)
            .map { $0.replacingOccurrences(of: "\n", with: " • ") }
            .joined(separator: " | ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if value.count <= 220 { return value }
        return String(value.prefix(217)) + "…"
    }

    private func notifyRosterChanges(_ changes: [RosterDayChange]) {
        guard !changes.isEmpty else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional ||
                    settings.authorizationStatus == .ephemeral else { return }

            let content = UNMutableNotificationContent()
            content.title = changes.count == 1
                ? "Roster changed • \(changes[0].dateText)"
                : "Roster changed • \(changes.count) days"
            content.body = rosterChangeNotificationBody(changes)
            content.sound = .default
            content.userInfo = ["raidoRosterChanges": true]
            let request = UNNotificationRequest(
                identifier: "RAIDO-CHANGE-" + UUID().uuidString,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )
            try? await center.add(request)
        }
    }

    private func rosterChangeNotificationBody(_ changes: [RosterDayChange]) -> String {
        guard let first = changes.first else { return "Open RAIDO Roster to review the changes." }
        let priority = ["Duty", "CI", "Pickup", "Aircraft", "Route", "Schedule", "Release", "Hotel", "Crew"]
        let ordered = first.fields.sorted {
            (priority.firstIndex(of: $0.label) ?? 99) < (priority.firstIndex(of: $1.label) ?? 99)
        }
        var pieces: [String] = []
        for field in ordered.prefix(3) {
            pieces.append("\(field.label): \(field.oldValue) → \(field.newValue)")
        }
        var body = pieces.joined(separator: " • ")
        if changes.count > 1 { body += " • +\(changes.count - 1) more day\(changes.count == 2 ? "" : "s")" }
        if body.count > 300 { body = String(body.prefix(297)) + "…" }
        return body.isEmpty ? "Open RAIDO Roster to review the changes." : body
    }

    private func currentMonthKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }

    private var storageFolderURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("RAIDORoster", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private var changeStateURL: URL { storageFolderURL.appendingPathComponent("roster-changes.json") }

    private func saveChangeState() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bundle = RosterChangeBundle(capturedAt: Date(), changes: latestChanges)
        if let data = try? encoder.encode(bundle) { try? data.write(to: changeStateURL, options: .atomic) }
    }

    private func loadChangeState() {
        guard let data = try? Data(contentsOf: changeStateURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let bundle = try? decoder.decode(RosterChangeBundle.self, from: data), !bundle.changes.isEmpty else { return }
        let migrated = bundle.changes.map { change in
            RosterDayChange(
                dateISO: change.dateISO,
                dateText: change.dateText,
                fields: change.fields.map { field in
                    if field.oldValue == "Previous details" && field.newValue == "Updated details" {
                        return RosterChangeField(label: field.label, oldValue: "—", newValue: "Details changed")
                    }
                    return field
                }
            )
        }
        latestChanges = migrated
        changedDates = Set(migrated.map(\.dateISO))
        let count = migrated.count
        changeNotice = "Roster changed • \(count) day\(count == 1 ? "" : "s")"
        if migrated != bundle.changes { saveChangeState() }
    }

    private var cacheURL: URL {
        storageFolderURL.appendingPathComponent("roster-cache.json")
    }

    private var monthCacheURL: URL {
        cacheURL.deletingLastPathComponent().appendingPathComponent("roster-months.json")
    }

    private func normalizeMonthArchive() {
        guard !monthSnapshots.isEmpty else { return }
        var repaired: [String: RosterSnapshot] = [:]
        for snapshot in monthSnapshots.values.sorted(by: { $0.capturedAt < $1.capturedAt }) {
            let key = monthKey(for: snapshot)
            guard key != "unknown" else { continue }
            if let existing = repaired[key], existing.capturedAt > snapshot.capturedAt { continue }
            repaired[key] = snapshot
        }
        monthSnapshots = repaired
        if let current = snapshot {
            monthSnapshots[monthKey(for: current)] = current
        }
        if let selected = selectedRosterMonthKey, monthSnapshots[selected] == nil {
            selectedRosterMonthKey = snapshot.map(monthKey(for:)) ?? monthSnapshots.keys.sorted().last
        }
    }

    private func saveMonthSnapshots() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(monthSnapshots) {
            try? data.write(to: monthCacheURL, options: .atomic)
        }
    }

    private func save(_ snapshot: RosterSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: monthCacheURL),
           let months = try? decoder.decode([String: RosterSnapshot].self, from: data) {
            monthSnapshots = months
        }

        if let data = try? Data(contentsOf: cacheURL),
           let latest = try? decoder.decode(RosterSnapshot.self, from: data) {
            snapshot = latest
            let key = monthKey(for: latest)
            monthSnapshots[key] = latest
            selectedRosterMonthKey = key
            saveMonthSnapshots()
        } else if let key = monthSnapshots.keys.sorted().last {
            snapshot = monthSnapshots[key]
            selectedRosterMonthKey = key
        }
            normalizeMonthArchive()
        saveMonthSnapshots()
}
}

@MainActor
final class AppState: ObservableObject {
    let rosterStore: RosterStore
    let browser: RosterBrowserModel

    init() {
        let store = RosterStore()
        rosterStore = store
        browser = RosterBrowserModel(store: store)
    }
}

enum MainTab: Hashable { case today, roster, fleet, more }

struct ContentView: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @Environment(\.scenePhase) private var raidoScenePhase
    @StateObject private var appState = AppState()
    @State private var selectedTab: MainTab = .today
    @State private var showPortal = false

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        TabView(selection: $selectedTab) {
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
        .onAppear { TodayLiveFlightLocationManager.shared.configureAutomaticFlight(from: appState.rosterStore.items)
            FlightCompanionV3ShadowEngine.shared.startShadowObservation()
        }
        .onChange(of: appState.rosterStore.snapshot) { _, _ in
            TodayLiveFlightLocationManager.shared.configureAutomaticFlight(from: appState.rosterStore.items)
        }
        .onChange(of: raidoScenePhase) { _, phase in
            if phase == .active {
                TodayLiveFlightLocationManager.shared.configureAutomaticFlight(from: appState.rosterStore.items)
            }
        }
    }
}


struct SyncFreshnessStrip: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @ObservedObject var store: RosterStore

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

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


struct RosterHeaderPrincipal: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @ObservedObject var store: RosterStore

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: 1) {
                Text("RAIDO")
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .accessibilityAddTraits(.isHeader)

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)

                    Text("GetJet · Airhub")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
            }
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

struct RosterHomeView: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @ObservedObject private var earnings = EarningsStore.shared
    @ObservedObject var store: RosterStore
    @ObservedObject var browser: RosterBrowserModel
    let openPortal: () -> Void
    @AppStorage("RAIDORoster.RosterDisplayMode") private var rosterDisplayMode = "calendar"

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        IcePageHeading(title: "Roster", subtitle: "Your month, at a glance")
                        Button(action: openPortal) {
                            Image(systemName: store.isCacheValidated ? "checkmark.icloud" : "icloud.slash")
                                .font(.title3).frame(width: 44, height: 44)
                        }.accessibilityLabel("Open Live RAIDO and sync")
                    }.padding(.top, 10).padding(.bottom, 4)
                    Picker("Roster view", selection: $rosterDisplayMode) {
                        Label("Calendar", systemImage: "calendar").tag("calendar")
                        Label("List", systemImage: "list.bullet").tag("list")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Roster view")

                    if let notice = store.changeNotice {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 7, height: 7)

                            Text(store.latestChanges.isEmpty
                                 ? notice
                                 : "\(store.latestChanges.count) roster change\(store.latestChanges.count == 1 ? "" : "s")")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            if !store.latestChanges.isEmpty {
                                NavigationLink("Review") {
                                    RosterChangesView(changes: store.latestChanges)
                                }
                                .font(.caption.bold())
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.orange.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                    }

                    if !store.hasCache {
                        emptyState
                    } else if rosterDisplayMode == "calendar" {
                        RosterMonthCalendarView(store: store, browser: browser, earnings: earnings, changedDates: store.changedDates)
                        SyncFreshnessStrip(store: store)
                    } else {
                        rosterMonthNavigator
                        if let month = store.selectedRosterMonth {
                            MonthlyEarningsCard(roster: store, earnings: earnings, month: month)
                        }
                        if let duty = store.rosterViewDuty {
                            sectionTitle("Next duty")
                            NavigationLink { RosterDetailView(item: duty) } label: { DutyHeroCard(item: duty) }
                                .buttonStyle(.plain)
                        }

                        if !store.rosterViewSummaryMetrics.isEmpty {
                            sectionTitle("Month overview")
                            summaryGrid
                        }

                        if !store.operationalMetrics.isEmpty {
                            sectionTitle("Operational totals")
                            OperationalMetricsGrid(metrics: store.operationalMetrics)
                        }

                        sectionTitle("Upcoming")
                        VStack(spacing: 10) {
                            ForEach(store.rosterViewItems) { item in
                                NavigationLink { RosterDetailView(item: item) } label: {
                                    RosterRowCard(
                                        item: item,
                                        isChanged: store.changedDates.contains(item.dateISO ?? "")
                                    )
                                }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
                .padding(.top, 0)
            }
            .midnightCanvas().toolbar(.hidden, for: .navigationBar)
        }
    }

    private var rosterMonthNavigator: some View {
        HStack(spacing: 12) {
            Button { store.selectPreviousRosterMonth() } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Previous cached roster month")

            VStack(spacing: 2) {
                Text(store.rosterMonthTitle)
                    .font(.headline)
                Text("Offline roster")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Button { store.selectNextRosterMonth() } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Next cached roster month")
        }
        .padding(10)
        .midnightCard(radius: 16)
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.subheadline.weight(.semibold))
                if let date = store.lastSync {
                    Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Open RAIDO once to import your roster")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(14)
        .midnightCard(radius: 16)
    }

    private var statusTitle: String {
        if !store.hasCache { return "No offline roster yet" }
        return store.isCacheValidated ? "Roster available offline" : "Offline cache needs resync"
    }

    private var statusIcon: String {
        if !store.hasCache { return "icloud.slash" }
        return store.isCacheValidated ? "checkmark.icloud.fill" : "exclamationmark.icloud.fill"
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Import your roster").font(.title3.weight(.semibold))
            Text("Open RAIDO, enter the mobile roster normally, and the app will save your roster for offline use.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open RAIDO", action: openPortal).raidoPrimaryAction()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
            ForEach(store.rosterViewSummaryMetrics) { metric in
                VStack(spacing: 5) {
                    Text("\(metric.value)").font(.title2.bold())
                    Text(metric.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .midnightCard(radius: 14)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline).padding(.top, 2)
    }
}


struct OperationalMetricsGrid: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let metrics: [OperationalMetric]

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 10)], spacing: 10) {
            ForEach(metrics) { metric in
                HStack(spacing: 10) {
                    Image(systemName: metric.systemImage)
                        .frame(width: 22)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(metric.value)
                            .font(.headline.monospacedDigit())
                        Text(metric.label)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .midnightCard(radius: 14)
            }
        }
    }
}



struct RosterMonthCalendarView: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @ObservedObject var store: RosterStore
    @ObservedObject var browser: RosterBrowserModel
    @ObservedObject var earnings: EarningsStore
    let changedDates: Set<String>

    private var items: [RosterItem] { store.rosterCalendarItems }
    @State private var selectedDateISO: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)
    private let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

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
        let grouped = Dictionary(grouping: items.compactMap { item -> RosterItem? in
            item.dateISO == nil ? nil : item
        }, by: { $0.dateISO ?? "" })
        return grouped.compactMapValues { rows in
            rows.first(where: { $0.isOperationalDuty }) ?? rows.first
        }
    }

    private var selectedItem: RosterItem? {
        guard let selectedDateISO else { return nil }
        return itemsByDate[selectedDateISO]
    }

    private var monthTitle: String { store.rosterMonthTitle }

    private var slots: [String?] {
        guard let month = store.selectedRosterMonth, month.count == 7 else { return [] }
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return [] }
        var comps = DateComponents()
        comps.year = parts[0]
        comps.month = parts[1]
        comps.day = 1
        guard let monthStart = calendar.date(from: comps),
              let days = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }

        let weekday = calendar.component(.weekday, from: monthStart)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var result = Array<String?>(repeating: nil, count: leading)
        for day in days {
            result.append(String(format: "%04d-%02d-%02d", parts[0], parts[1], day))
        }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { navigateMonth(previous: true) } label: {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.bold())
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                                .accessibilityLabel("Previous cached roster month")

                Spacer(minLength: 0)
                Text(monthTitle).font(.title3.weight(.semibold))
                Button("Today") {
                    let today = rosterCalendarTodayISO()
                    if store.selectRosterMonthIfCached(String(today.prefix(7))) { selectedDateISO = today }
                }.font(.caption.weight(.medium)).frame(minHeight: 44)
                Spacer(minLength: 0)

                Button { navigateMonth(previous: false) } label: {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.bold())
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                                .accessibilityLabel("Next cached roster month")


            }


            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(weekdays, id: \.self) { weekday in
                    Text(weekday)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 8) {
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
                            .frame(maxWidth: .infinity, minHeight: MidnightTheme.isGetJet ? 80 : 64)
                    }
                }
            }
            .overlay {
                if MidnightTheme.isGetJet { GetJetCalendarDividers(rows: slots.count / 7) }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { calendarLegend }
                VStack(alignment: .leading, spacing: 8) { calendarLegend }
            }.padding(.vertical, 6)

            if let selectedItem {
                IceSelectedRosterDay(item: selectedItem, isChanged: selectedItem.dateISO.map(changedDates.contains) ?? false)
                    .transition(.opacity)
            }
            if let month = store.selectedRosterMonth {
                DisclosureGroup("Month overview & earnings") {
                    MonthlyEarningsCard(roster: store, earnings: earnings, month: month).padding(.top, 10)
                }.font(.subheadline).padding(14).midnightCard(radius: 14)
            }

        }

        .onAppear {
            guard selectedDateISO == nil else { return }
            let today = rosterCalendarTodayISO()
            selectedDateISO = itemsByDate[today] != nil ? today : items.compactMap(\.dateISO).first
        }
        .onChange(of: items.map(\.dateISO)) { _, _ in
            if let selectedDateISO, itemsByDate[selectedDateISO] != nil { return }
            let today = rosterCalendarTodayISO()
            selectedDateISO = itemsByDate[today] != nil ? today : items.compactMap(\.dateISO).first
        }
        .sensoryFeedback(.selection, trigger: selectedDateISO)
    }

    @ViewBuilder private var calendarLegend: some View {
        ForEach(["FLIGHT", "STANDBY", "OFF", "POSITIONING"], id: \.self) { category in
            HStack(spacing: 4) {
                Circle().fill(categoryColor(category)).frame(width: 5, height: 5)
                Text(category == "FLIGHT" ? "Flight" : category == "STANDBY" ? "Standby" : category == "OFF" ? "Off" : "Positioning")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func navigateMonth(previous: Bool) {
        guard let target = store.adjacentRosterMonthKey(previous: previous) else { return }

        // Instant native navigation uses the archive/feed when available.
        _ = store.selectRosterMonthIfCached(target)

        // In parallel, move the authenticated RAIDO roster page as well.
        // Its HTML snapshot is the authoritative rich source for crew,
        // aircraft, pickup and detailed duty data that WebCal cannot provide.
        browser.switchRosterMonth(previous ? "previous" : "next")

        // WebCal remains a fallback for fast/offline month coverage.
        browser.refreshRosterCalendarFeed()
    }

}

struct RosterCalendarDayCell: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem?
    let day: Int
    let isToday: Bool
    let isChanged: Bool
    let isSelected: Bool
    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(spacing: 4) {
            Text("\(day)").font(.system(size: 17, weight: isSelected || isToday ? .semibold : .regular))
                .foregroundStyle(isSelected ? MidnightTheme.selectionInk : item == nil ? Color.secondary : MidnightTheme.ink)
                .frame(width: 32, height: 32)
                .background(isSelected ? MidnightTheme.highlight : .clear, in: Circle())
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
        }.padding(.horizontal, MidnightTheme.isGetJet ? 3 : 0).frame(maxWidth: .infinity, minHeight: MidnightTheme.isGetJet ? 80 : 64, alignment: .top).contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(day), \(item?.displayTitle ?? "No roster data")\(isToday ? ", today" : "")\(isChanged ? ", changed" : "")")
            .accessibilityValue(isSelected ? "Selected" : "")
    }
}

struct RosterCalendarAgendaCard: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem
    let isChanged: Bool

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

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

                if !item.preDutyPickupDisplay.isEmpty {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let clock = compactPickupClock(item.preDutyPickupDisplay)
                        let countdown = item.preDutyPickupUTCDate.map { calendarPickupCountdown(from: context.date, to: $0) } ?? ""
                        Text(["PU \(clock)", countdown].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                    }
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
        .midnightCard(radius: 14)
    }
}


private func calendarPickupCountdown(from now: Date, to pickup: Date) -> String {
    let seconds = pickup.timeIntervalSince(now)
    guard seconds > 0 else { return "" }
    let minutes = max(1, Int((seconds + 59) / 60))
    if minutes < 60 { return "in \(minutes)m" }
    if minutes < 24 * 60 {
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "in \(hours)h" : "in \(hours)h \(remainder)m"
    }
    let days = minutes / (24 * 60)
    let hours = (minutes % (24 * 60)) / 60
    return hours == 0 ? "in \(days)d" : "in \(days)d \(hours)h"
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


struct CrewReadinessCard: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem
    @ObservedObject var store: RosterStore
    @AppStorage("RAIDORoster.RestAwarenessHours") private var restAwarenessHours = 10

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 12) {
                if let reference = store.precautionReferenceDate(for: item),
                   let cutoff = store.alcoholPrecautionCutoff(for: item),
                   context.date < reference {
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
            .midnightCard(radius: 16)
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

struct RestToNextDutyCard: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let next: RosterItem
    let interval: TimeInterval

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        HStack(spacing: 12) {
            Image(systemName: "bed.double.fill")
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("REST AVAILABLE")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(durationText(interval))
                    .font(.title3.bold().monospacedDigit())
                Text([next.dateText, next.displayTitle, next.reportLocal.isEmpty ? "" : "CI \(next.reportLocal)"]
                    .filter { !$0.isEmpty }
                    .joined(separator: " • "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .midnightCard(radius: 16)
    }
}



private func compactPickupClock(_ display: String) -> String {
    let parts = display.components(separatedBy: .whitespacesAndNewlines)
    if let clock = parts.first(where: { token in
        token.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil
    }) {
        return clock
    }
    return display
}

struct TodayPrimaryTimingRow: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem

    private var values: [(String, String)] {
        let pickup = compactPickupClock(item.preDutyPickupDisplay)
        if !pickup.isEmpty {
            return [
                ("PU", pickup),
                ("CI", item.reportLocal.isEmpty ? "—" : item.reportLocal),
                ("RELEASE", item.releaseLocal.isEmpty ? "—" : item.releaseLocal)
            ]
        }
        return [
            ("CI", item.reportLocal.isEmpty ? "—" : item.reportLocal),
            ("RELEASE", item.releaseLocal.isEmpty ? "—" : item.releaseLocal),
            ("DUTY", item.dutyDuration.isEmpty ? "—" : item.dutyDuration)
        ]
    }

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        HStack(spacing: 8) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                VStack(spacing: 4) {
                    Text(value.1)
                        .font(.headline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(value.0)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .midnightCard(radius: 12)
            }
        }
    }
}




private struct TodayAirportMapPoint: Identifiable {
    let code: String
    let name: String
    let coordinate: CLLocationCoordinate2D

    var id: String { code }
}

private enum TodayAirportCoordinates {
    // Compact embedded set for current/common GetJet/AirHub European and
    // Mediterranean operations. This keeps known routes instant and offline.
    // Unknown airports simply omit the map rather than affecting roster data.
    static let airports: [String: TodayAirportMapPoint] = [
        "TLV": .init(code: "TLV", name: "Tel Aviv", coordinate: .init(latitude: 32.0005, longitude: 34.8708)),
        "BUD": .init(code: "BUD", name: "Budapest", coordinate: .init(latitude: 47.4399, longitude: 19.2610)),
        "BEG": .init(code: "BEG", name: "Belgrade", coordinate: .init(latitude: 44.8184, longitude: 20.3091)),
        "BUS": .init(code: "BUS", name: "Batumi", coordinate: .init(latitude: 41.6103, longitude: 41.5997)),
        "SKG": .init(code: "SKG", name: "Thessaloniki", coordinate: .init(latitude: 40.5197, longitude: 22.9709)),
        "CFU": .init(code: "CFU", name: "Corfu", coordinate: .init(latitude: 39.6019, longitude: 19.9117)),
        "PFO": .init(code: "PFO", name: "Paphos", coordinate: .init(latitude: 34.7180, longitude: 32.4857)),
        "LCA": .init(code: "LCA", name: "Larnaca", coordinate: .init(latitude: 34.8751, longitude: 33.6249)),
        "ATH": .init(code: "ATH", name: "Athens", coordinate: .init(latitude: 37.9364, longitude: 23.9445)),
        "RHO": .init(code: "RHO", name: "Rhodes", coordinate: .init(latitude: 36.4054, longitude: 28.0862)),
        "HER": .init(code: "HER", name: "Heraklion", coordinate: .init(latitude: 35.3397, longitude: 25.1803)),
        "CHQ": .init(code: "CHQ", name: "Chania", coordinate: .init(latitude: 35.5317, longitude: 24.1497)),
        "KGS": .init(code: "KGS", name: "Kos", coordinate: .init(latitude: 36.7933, longitude: 27.0917)),
        "VIE": .init(code: "VIE", name: "Vienna", coordinate: .init(latitude: 48.1103, longitude: 16.5697)),
        "PRG": .init(code: "PRG", name: "Prague", coordinate: .init(latitude: 50.1008, longitude: 14.2600)),
        "WAW": .init(code: "WAW", name: "Warsaw", coordinate: .init(latitude: 52.1657, longitude: 20.9671)),
        "KRK": .init(code: "KRK", name: "Krakow", coordinate: .init(latitude: 50.0777, longitude: 19.7848)),
        "SOF": .init(code: "SOF", name: "Sofia", coordinate: .init(latitude: 42.6952, longitude: 23.4062)),
        "OTP": .init(code: "OTP", name: "Bucharest", coordinate: .init(latitude: 44.5711, longitude: 26.0850)),
        "TIA": .init(code: "TIA", name: "Tirana", coordinate: .init(latitude: 41.4147, longitude: 19.7206)),
        "DBV": .init(code: "DBV", name: "Dubrovnik", coordinate: .init(latitude: 42.5614, longitude: 18.2682)),
        "SPU": .init(code: "SPU", name: "Split", coordinate: .init(latitude: 43.5389, longitude: 16.2980)),
        "ZAG": .init(code: "ZAG", name: "Zagreb", coordinate: .init(latitude: 45.7429, longitude: 16.0688)),
        "FCO": .init(code: "FCO", name: "Rome", coordinate: .init(latitude: 41.8003, longitude: 12.2389)),
        "MXP": .init(code: "MXP", name: "Milan", coordinate: .init(latitude: 45.6306, longitude: 8.7281)),
        "FRA": .init(code: "FRA", name: "Frankfurt", coordinate: .init(latitude: 50.0379, longitude: 8.5622)),
        "MUC": .init(code: "MUC", name: "Munich", coordinate: .init(latitude: 48.3538, longitude: 11.7861)),
        "BER": .init(code: "BER", name: "Berlin", coordinate: .init(latitude: 52.3667, longitude: 13.5033)),
        "AMS": .init(code: "AMS", name: "Amsterdam", coordinate: .init(latitude: 52.3105, longitude: 4.7683)),
        "CDG": .init(code: "CDG", name: "Paris", coordinate: .init(latitude: 49.0097, longitude: 2.5479)),
        "BCN": .init(code: "BCN", name: "Barcelona", coordinate: .init(latitude: 41.2974, longitude: 2.0833)),
        "MAD": .init(code: "MAD", name: "Madrid", coordinate: .init(latitude: 40.4983, longitude: -3.5676)),
        "LHR": .init(code: "LHR", name: "London", coordinate: .init(latitude: 51.4700, longitude: -0.4543)),
        "CPH": .init(code: "CPH", name: "Copenhagen", coordinate: .init(latitude: 55.6180, longitude: 12.6508)),
        "ARN": .init(code: "ARN", name: "Stockholm", coordinate: .init(latitude: 59.6519, longitude: 17.9186)),
        "OSL": .init(code: "OSL", name: "Oslo", coordinate: .init(latitude: 60.1939, longitude: 11.1004)),
        "HEL": .init(code: "HEL", name: "Helsinki", coordinate: .init(latitude: 60.3172, longitude: 24.9633)),
        "RIX": .init(code: "RIX", name: "Riga", coordinate: .init(latitude: 56.9236, longitude: 23.9711)),
        "VNO": .init(code: "VNO", name: "Vilnius", coordinate: .init(latitude: 54.6341, longitude: 25.2858)),
        "TLL": .init(code: "TLL", name: "Tallinn", coordinate: .init(latitude: 59.4133, longitude: 24.8328)),
        "TBS": .init(code: "TBS", name: "Tbilisi", coordinate: .init(latitude: 41.6692, longitude: 44.9547)),
        "KUT": .init(code: "KUT", name: "Kutaisi", coordinate: .init(latitude: 42.1767, longitude: 42.4826))
    ]
}


private struct OfflineAviationMapViewport {
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    init(route: [CLLocationCoordinate2D]) {
        let latitudes = route.map(\.latitude)
        let longitudes = route.map(\.longitude)

        let minLat = latitudes.min() ?? 30
        let maxLat = latitudes.max() ?? 50
        let minLon = longitudes.min() ?? 10
        let maxLon = longitudes.max() ?? 30

        let latSpan = max(2.0, maxLat - minLat)
        let lonSpan = max(2.0, maxLon - minLon)
        let latPadding = max(0.7, latSpan * 0.25)
        let lonPadding = max(0.7, lonSpan * 0.25)

        minLatitude = max(-80, minLat - latPadding)
        maxLatitude = min(80, maxLat + latPadding)
        minLongitude = max(-180, minLon - lonPadding)
        maxLongitude = min(180, maxLon + lonPadding)
    }

    var midLatitude: Double { (minLatitude + maxLatitude) / 2 }
    var midLongitude: Double { (minLongitude + maxLongitude) / 2 }

    func point(
        for coordinate: CLLocationCoordinate2D,
        in size: CGSize,
        zoom: CGFloat,
        pan: CGSize
    ) -> CGPoint {
        let latitudeSpan = max(1, maxLatitude - minLatitude)
        let longitudeSpan = max(1, maxLongitude - minLongitude)
        let longitudeCompression = max(0.25, cos(midLatitude * .pi / 180))

        let projectedWidth = longitudeSpan * longitudeCompression
        let projectedHeight = latitudeSpan
        let baseScale = min(
            Double(size.width) / projectedWidth,
            Double(size.height) / projectedHeight
        ) * 0.88

        let x = (coordinate.longitude - midLongitude) * longitudeCompression * baseScale
        let y = (midLatitude - coordinate.latitude) * baseScale

        return CGPoint(
            x: size.width / 2 + CGFloat(x) * zoom + pan.width,
            y: size.height / 2 + CGFloat(y) * zoom + pan.height
        )
    }

    func gridStep() -> Double {
        let span = max(maxLatitude - minLatitude, maxLongitude - minLongitude)
        switch span {
        case ..<12: return 2
        case ..<28: return 5
        case ..<60: return 10
        default: return 20
        }
    }
}

private enum OfflineAviationBasemap {
    struct Outline: Decodable {
        let west: Double
        let south: Double
        let east: Double
        let north: Double
        let coordinates: [CLLocationCoordinate2D]
        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            west = try values.decode(Double.self); south = try values.decode(Double.self)
            east = try values.decode(Double.self); north = try values.decode(Double.self)
            let ring = try values.decode([[Double]].self)
            coordinates = ring.filter { $0.count == 2 }.map { .init(latitude: $0[1], longitude: $0[0]) }
        }
        func isVisible(viewport: OfflineAviationMapViewport, size: CGSize, zoom: CGFloat, pan: CGSize) -> Bool {
            let a = viewport.point(for: .init(latitude: south, longitude: west), in: size, zoom: zoom, pan: pan)
            let b = viewport.point(for: .init(latitude: north, longitude: east), in: size, zoom: zoom, pan: pan)
            return max(a.x, b.x) >= 0 && min(a.x, b.x) <= size.width && max(a.y, b.y) >= 0 && min(a.y, b.y) <= size.height
        }
    }
    // Natural Earth 1:50m land, public domain. Decoded once, with per-outline
    // bounds culling before projection; no downloads or tile dependency.
    static let outlines: [Outline] = {
        guard let url = Bundle.main.url(forResource: "OfflineLand", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode([Outline].self, from: data) else { return [] }
        return result
    }()
}


private final class TodayMapConnectivityMonitor: ObservableObject {
    @Published private(set) var isConnected = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "RAIDORoster.TodayMapConnectivity")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

private struct TodayOnlineRouteMap: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let points: [TodayAirportMapPoint]
    let trail: [CLLocationCoordinate2D]
    let liveLocation: CLLocation?
    let isTracking: Bool

    @Binding var cameraPosition: MapCameraPosition

    private var coordinates: [CLLocationCoordinate2D] {
        points.map(\.coordinate)
    }

    private var planeRotation: Angle {
        guard let location = liveLocation,
              location.course >= 0,
              location.speed > 2 else { return .degrees(-20) }
        return .degrees(location.course - 90)
    }

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
            MapPolyline(coordinates: coordinates, contourStyle: .geodesic)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

            if trail.count >= 2 {
                MapPolyline(coordinates: trail)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }

            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                Annotation(point.code, coordinate: point.coordinate, anchor: .center) {
                    VStack(spacing: 3) {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 12, height: 12)
                            Circle()
                                .stroke(Color.white.opacity(0.95), lineWidth: 2)
                                .frame(width: 18, height: 18)
                        }

                        if index == 0 || index == points.count - 1 || points.count <= 3 {
                            VStack(spacing: 0) {
                                Text(point.code)
                                    .font(.caption.bold())
                                Text(point.name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(MidnightTheme.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }

            if isTracking, let coordinate = liveLocation?.coordinate {
                Annotation("Aircraft", coordinate: coordinate, anchor: .center) {
                    Image(systemName: "airplane")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Color.green)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .rotationEffect(planeRotation)
                }
            }
        }
        .mapStyle(.standard)
    }
}

@MainActor
private final class TodayLiveFlightLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = TodayLiveFlightLocationManager()
    @Published private(set) var location: CLLocation?
    @Published private(set) var trail: [CLLocationCoordinate2D] = []
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private var servicesAvailable = true
    private var servicesCheckGeneration = 0
    @Published private(set) var isTracking = false
    @Published private(set) var errorText: String?
    @Published private(set) var acquisitionStartedAt: Date?
    @Published private(set) var fusedLocation: CLLocation?
    @Published private(set) var fusedTrail: [CLLocationCoordinate2D] = []
    @Published private(set) var positionSourceText = "Acquiring"
    @Published private(set) var positionIsEstimated = false
    @Published private(set) var flightPhaseText = "Parked"
    @Published private(set) var taxiOutDurationText: String?
    @Published private(set) var airborneDurationText: String?
    @Published private(set) var taxiInDurationText: String?
    @Published private(set) var takeoffTimeText: String?
    @Published private(set) var landingTimeText: String?


    private var trackedRegistration: String?
    private var networkLatitude: Double?
    private var networkLongitude: Double?
    private var networkAltitudeMeters: Double?
    private var networkGroundSpeedMPS: Double?
    private var networkTrackDegrees: Double?
    private var networkObservationAt: Date?
    private var hybridTask: Task<Void, Never>?
    private var lastFusedTrailAt: Date?
    private enum CompanionPhase: String, Codable { case parked, armed, groundCandidate, taxiOut, takeoffRoll, airborne, descent, taxiIn, complete }
    private var companionPhase: CompanionPhase = .parked
    private var routeCoordinates: [CLLocationCoordinate2D] = []
    private var taxiOutStartedAt: Date?
    private var airborneAt: Date?
    private var landedAt: Date?
    private var stationarySince: Date?
    private var groundAltitude: CLLocationDistance?
    private var lastMeasuredProgress = 0.0
    private var lastMeasuredProgressAt: Date?
    private var previousMeasuredSpeed: CLLocationSpeed?
    private var automaticDepartureAt: Date?
    private var automaticOrigin: CLLocationCoordinate2D?
    private var automaticKey: String?
    private var automaticMonitoring = false
    private var automaticRegionID: String?
    private var groundCandidateAt: Date?
    private var stoppedAt: Date?
    private var highSpeedAt: Date?
    private var scheduledArrivalAt: Date?
    private var activeRouteText = ""
    private var landedUsingSensors = false
    private let autoLead: TimeInterval = 30 * 60
    private let autoGrace: TimeInterval = 4 * 60 * 60
    private let airportGateRadius: CLLocationDistance = 6_000


    private struct PersistedTrailPoint: Codable {
        let latitude: Double
        let longitude: Double
    }
    private var trailPersistenceKey: String?
    private var lastTrailPersistAt: Date?
    private let trailStoragePrefix = "RAIDORoster.FlightTrail.V1."

    private let maximumNetworkObservationAge: TimeInterval = 90
    private let maximumExtrapolationAge: TimeInterval = 20

    @Published private(set) var gpsQualityText = "Acquiring"
    @Published private(set) var rejectedFixCount = 0

    private var retainedSpeed: CLLocationSpeed?
    private var retainedSpeedAt: Date?
    private var retainedCourse: CLLocationDirection?
    private var retainedCourseAt: Date?
    private let retainedNavigationLifetime: TimeInterval = 15

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .airborne
        manager.pausesLocationUpdatesAutomatically = true
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        authorizationStatus = manager.authorizationStatus
        refreshLocationServicesAvailability()
        restoreSession(now: Date())
        Task { @MainActor [weak self] in self?.resumeRestoredSession(now: Date()) }
    }

    var isPrecise: Bool {
        manager.accuracyAuthorization == .fullAccuracy
    }

    var displaySpeed: CLLocationSpeed? {
        if let location, location.speed >= 0 { return location.speed }
        if let retainedSpeed, let retainedSpeedAt,
           Date().timeIntervalSince(retainedSpeedAt) <= retainedNavigationLifetime {
            return retainedSpeed
        }
        return nil
    }

    var displayCourse: CLLocationDirection? {
        if let location, location.course >= 0 { return location.course }
        if let retainedCourse, let retainedCourseAt,
           Date().timeIntervalSince(retainedCourseAt) <= retainedNavigationLifetime {
            return retainedCourse
        }
        return nil
    }

    var fixAge: TimeInterval? {
        guard let location else { return nil }
        return max(0, Date().timeIntervalSince(location.timestamp))
    }

    func startIfAuthorized() {
        guard CLLocationManager.locationServicesEnabled() else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if !isTracking { start() }
        default:
            break
        }
    }

    private func qualityText(for location: CLLocation) -> String {
        let age = abs(location.timestamp.timeIntervalSinceNow)
        let accuracy = location.horizontalAccuracy
        guard accuracy >= 0 else { return "Acquiring" }
        if age <= 5 && accuracy <= 30 { return "Excellent" }
        if age <= 10 && accuracy <= 75 { return "Good" }
        if age <= 20 && accuracy <= 200 { return "Usable" }
        if age <= 30 && accuracy <= 300 { return "Weak" }
        return "Poor"
    }

    private func isPhysicallyPlausible(_ candidate: CLLocation, after previous: CLLocation?) -> Bool {
        guard let previous else { return true }
        let dt = candidate.timestamp.timeIntervalSince(previous.timestamp)
        guard dt > 0 else { return false }
        let impliedSpeed = candidate.distance(from: previous) / dt

        // ~816 kt. Deliberately above normal transport-category cruise speed,
        // but low enough to reject cabin GNSS jumps spanning many kilometres.
        if impliedSpeed > 420 { return false }

        // At short intervals, large sideways jumps are almost always bad fixes.
        if dt < 5 && candidate.distance(from: previous) > 1_500 { return false }
        return true
    }

    func configureTrailPersistence(sessionKey: String) {
        guard !automaticMonitoring || airborneAt == nil else { return }
        let safe = sessionKey.data(using: .utf8)?.base64EncodedString() ?? sessionKey
        let key = trailStoragePrefix + safe
        guard trailPersistenceKey != key else { return }
        trailPersistenceKey = key
        loadPersistedTrail()
    }

    private func loadPersistedTrail() {
        guard let key = trailPersistenceKey,
              let data = UserDefaults.standard.data(forKey: key),
              let points = try? JSONDecoder().decode([PersistedTrailPoint].self, from: data) else {
            fusedTrail = []
            return
        }
        fusedTrail = points.suffix(1_500).map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    private func persistFusedTrail(now: Date, force: Bool = false) {
        guard let key = trailPersistenceKey, !fusedTrail.isEmpty else { return }
        if !force, let last = lastTrailPersistAt, now.timeIntervalSince(last) < 30 { return }
        let points = fusedTrail.suffix(1_500).map {
            PersistedTrailPoint(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard let data = try? JSONEncoder().encode(points) else { return }
        UserDefaults.standard.set(data, forKey: key)
        lastTrailPersistAt = now
    }

    func configureAircraftTracking(registration: String?) {
        guard !automaticMonitoring || !isTracking else { return }
        let canonical = FleetTrackingPolicy.canonicalRegistration(registration ?? "")
        trackedRegistration = canonical.isEmpty ? nil : canonical
        if isTracking { restartHybridTask() }
    }

    private var usableGNSSLocation: CLLocation? {
        guard let location else { return nil }
        let age = max(0, Date().timeIntervalSince(location.timestamp))
        guard age <= 20, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 250 else { return nil }
        return location
    }

    private func sourceLabel(for location: CLLocation) -> String {
        if #available(iOS 15.0, *), location.sourceInformation?.isProducedByAccessory == true {
            return "External GNSS"
        }
        return "iPhone GNSS"
    }

    private func restartHybridTask() {
        hybridTask?.cancel()
        hybridTask = Task { [weak self] in
            guard let self else { return }
            var secondsSincePoll = 10_000
            while !Task.isCancelled {
                let pollEvery: Int
                switch self.companionPhase {
                case .parked, .armed: pollEvery = 30
                case .groundCandidate, .taxiOut, .taxiIn: pollEvery = 4
                case .takeoffRoll: pollEvery = 2
                case .airborne: pollEvery = 20
                case .descent: pollEvery = 6
                case .complete: pollEvery = 60
                }
                if secondsSincePoll >= pollEvery, let registration = self.trackedRegistration {
                    await self.fetchNetworkAircraft(registration: registration)
                    secondsSincePoll = 0
                }
                self.refreshFusedPosition()
                secondsSincePoll += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func fetchNetworkAircraft(registration: String) async {
        let encoded = registration.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? registration
        let urls = [
            "https://api.adsb.lol/v2/reg/\(encoded)",
            "https://opendata.adsb.fi/api/v2/registration/\(encoded)",
            "https://api.adsb.one/v2/reg/\(encoded)"
        ]
        for raw in urls {
            guard !Task.isCancelled, let url = URL(string: raw) else { return }
            if await acceptNetworkAircraft(url: url) { return }
        }
    }

    private func acceptNetworkAircraft(url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("RAIDORoster/2.23", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let aircraft = (root["ac"] as? [[String: Any]])?.first,
                  let lat = aircraft["lat"] as? Double,
                  let lon = aircraft["lon"] as? Double,
                  (-90...90).contains(lat), (-180...180).contains(lon) else { return false }

            let seen = max(0, aircraft["seen"] as? Double ?? 0)
            networkLatitude = lat
            networkLongitude = lon
            networkGroundSpeedMPS = (aircraft["gs"] as? Double).map { $0 * 0.514444 }
            networkTrackDegrees = aircraft["track"] as? Double
            if let altitudeFeet = aircraft["alt_baro"] as? Double {
                networkAltitudeMeters = altitudeFeet * 0.3048
            } else {
                networkAltitudeMeters = nil
            }
            networkObservationAt = Date().addingTimeInterval(-seen)
            return true
        } catch {
            return false
        }
    }

    private func propagatedNetworkLocation(now: Date) -> (CLLocation, Bool)? {
        guard let lat = networkLatitude,
              let lon = networkLongitude,
              let observedAt = networkObservationAt else { return nil }
        let age = max(0, now.timeIntervalSince(observedAt))
        guard age <= maximumExtrapolationAge else { return nil }

        var latitude = lat
        var longitude = lon
        let canPropagate = age > 2 && age <= maximumExtrapolationAge
        if canPropagate,
           let speed = networkGroundSpeedMPS,
           speed > 1,
           let track = networkTrackDegrees {
            let distance = speed * age
            let radius = 6_371_000.0
            let bearing = track * .pi / 180
            let phi1 = lat * .pi / 180
            let lambda1 = lon * .pi / 180
            let angular = distance / radius
            let phi2 = asin(sin(phi1) * cos(angular) + cos(phi1) * sin(angular) * cos(bearing))
            let lambda2 = lambda1 + atan2(
                sin(bearing) * sin(angular) * cos(phi1),
                cos(angular) - sin(phi1) * sin(phi2)
            )
            latitude = phi2 * 180 / .pi
            longitude = lambda2 * 180 / .pi
        }

        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: networkAltitudeMeters ?? 0,
            horizontalAccuracy: -1,
            verticalAccuracy: -1,
            course: networkTrackDegrees ?? -1,
            speed: networkGroundSpeedMPS ?? -1,
            timestamp: observedAt
        )
        return (location, canPropagate && networkGroundSpeedMPS.map { $0 > 1 } == true && networkTrackDegrees != nil)
    }

    private func refreshFusedPosition() {
        let now = Date()
        maintainSession(now: now)
        if let gnss = usableGNSSLocation {
            publishFused(gnss, source: sourceLabel(for: gnss), estimated: false, now: now)
            return
        }
        if let (network, estimated) = propagatedNetworkLocation(now: now) {
            publishFused(network, source: estimated ? "ADS-B estimated" : "ADS-B live", estimated: estimated, now: now)
            return
        }
        if let estimate = estimatedRouteLocation(now: now) {
            publishFused(estimate, source: "Estimated · route model", estimated: true, now: now)
            return
        }
        if let location { publishFused(location, source: "Last GNSS fix", estimated: true, now: now); return }
        fusedLocation = nil
        positionSourceText = "Acquiring"
        positionIsEstimated = false
    }

    private func publishFused(_ value: CLLocation, source: String, estimated: Bool, now: Date) {
        fusedLocation = value
        positionSourceText = source
        positionIsEstimated = estimated

        updatePhase(value, estimated: estimated, now: now)
        applyFreshADSBPhase(value, source: source, estimated: estimated, now: now)
        maintainSession(now: now)

        guard !estimated else { return } // measured trail only
        if companionPhase == .parked || companionPhase == .armed || companionPhase == .groundCandidate { return } // preflight ground transport is not aircraft trail

        let shouldAppend: Bool
        if let last = fusedTrail.last {
            let previous = CLLocation(latitude: last.latitude, longitude: last.longitude)
            shouldAppend = value.distance(from: previous) >= 100 ||
                lastFusedTrailAt.map { now.timeIntervalSince($0) >= 10 } == true
        } else {
            shouldAppend = true
        }
        if shouldAppend {
            fusedTrail.append(value.coordinate)
            lastFusedTrailAt = now
            if fusedTrail.count > 1_500 {
                fusedTrail.removeFirst(fusedTrail.count - 1_500)
            }
            persistFusedTrail(now: now)
        }
    }

    func configureFlightRoute(coordinates: [CLLocationCoordinate2D]) {
        // A visible duty card may contain several sectors; keep the active sector geometry.
        guard !automaticMonitoring, airborneAt == nil else { return }
        routeCoordinates = coordinates
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds.rounded()))
        let h = t / 3600, min = (t % 3600) / 60
        return h > 0 ? String(format: "%dh %02dm", h, min) : String(format: "%dm", min)
    }

    private func clockText(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; return f.string(from: date)
    }

    private var routeDistance: CLLocationDistance? {
        guard let a = routeCoordinates.first, let b = routeCoordinates.last else { return nil }
        return CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private func destinationDistance(_ value: CLLocation) -> CLLocationDistance? {
        guard let d = routeCoordinates.last else { return nil }
        return value.distance(from: CLLocation(latitude: d.latitude, longitude: d.longitude))
    }

    private func progress(_ value: CLLocation) -> Double? {
        guard let total = routeDistance, total > 1_000, let remaining = destinationDistance(value) else { return nil }
        return min(1, max(0, 1 - remaining / total))
    }

    private func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ f: Double) -> CLLocationCoordinate2D {
        let t = min(1, max(0, f)); let p1 = a.latitude * .pi / 180, l1 = a.longitude * .pi / 180
        let p2 = b.latitude * .pi / 180, l2 = b.longitude * .pi / 180
        let d = 2 * asin(sqrt(pow(sin((p2-p1)/2),2) + cos(p1)*cos(p2)*pow(sin((l2-l1)/2),2)))
        guard d > 0.000001 else { return a }
        let x = sin((1-t)*d)/sin(d), y = sin(t*d)/sin(d)
        let vx = x*cos(p1)*cos(l1)+y*cos(p2)*cos(l2), vy = x*cos(p1)*sin(l1)+y*cos(p2)*sin(l2), vz = x*sin(p1)+y*sin(p2)
        return .init(latitude: atan2(vz, sqrt(vx*vx+vy*vy)) * 180 / .pi, longitude: atan2(vy, vx) * 180 / .pi)
    }

    private func estimatedRouteLocation(now: Date) -> CLLocation? {
        if landedUsingSensors, landedAt != nil, companionPhase == .taxiIn || companionPhase == .complete,
           let destination = routeCoordinates.last {
            return CLLocation(coordinate: destination, altitude: 0, horizontalAccuracy: 3_000,
                              verticalAccuracy: -1, course: -1, speed: 0, timestamp: now)
        }
        guard companionPhase == .airborne || companionPhase == .descent, let takeoff = airborneAt,
              let a = routeCoordinates.first, let b = routeCoordinates.last, let total = routeDistance, total > 1_000 else { return nil }
        let speed = modelCruiseSpeed(total: total), anchorDate = lastMeasuredProgressAt ?? takeoff
        let anchor = lastMeasuredProgressAt == nil ? 0 : lastMeasuredProgress
        let p = min(0.995, max(anchor, anchor + max(0, now.timeIntervalSince(anchorDate))*speed/total))
        if p >= 0.86 && companionPhase == .airborne { companionPhase = .descent; flightPhaseText = "Descent · estimated"; applyPowerProfile() }
        let c = interpolate(a, b, p)
        return CLLocation(coordinate: c, altitude: 0, horizontalAccuracy: 5_000, verticalAccuracy: -1, course: -1, speed: speed, timestamp: now)
    }

    private func applyPowerProfile() {
        switch companionPhase {
        case .parked, .armed: manager.desiredAccuracy = kCLLocationAccuracyHundredMeters; manager.distanceFilter = 50
        case .groundCandidate: manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters; manager.distanceFilter = 15
        case .complete: manager.desiredAccuracy = kCLLocationAccuracyHundredMeters; manager.distanceFilter = 50
        case .taxiOut, .taxiIn: manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters; manager.distanceFilter = 10
        case .takeoffRoll: manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation; manager.distanceFilter = kCLDistanceFilterNone
        case .airborne: manager.desiredAccuracy = kCLLocationAccuracyHundredMeters; manager.distanceFilter = 150
        case .descent: manager.desiredAccuracy = kCLLocationAccuracyBest; manager.distanceFilter = 30
        }
        manager.pausesLocationUpdatesAutomatically = companionPhase == .complete
    }

    private func updateDurations(_ now: Date) {
        if let d = taxiOutStartedAt { taxiOutDurationText = durationText((airborneAt ?? now).timeIntervalSince(d)) }
        if let d = airborneAt { airborneDurationText = durationText((landedAt ?? now).timeIntervalSince(d)) }
        if let d = landedAt { taxiInDurationText = durationText(now.timeIntervalSince(d)) }
    }

    private func updatePhase(_ value: CLLocation, estimated: Bool, now: Date) {
        updateDurations(now); guard !estimated else { return }; let speed = max(0, value.speed)
        if groundAltitude == nil && speed < 2.5 && value.verticalAccuracy >= 0 { groundAltitude = value.altitude }
        if let p = progress(value) { lastMeasuredProgress = max(lastMeasuredProgress, p); lastMeasuredProgressAt = now }
        let gain = groundAltitude.map { value.altitude - $0 } ?? 0, remaining = destinationDistance(value) ?? .greatestFiniteMagnitude
        switch companionPhase {
        case .parked:
            if automaticMonitoring { companionPhase = .armed; flightPhaseText = "Armed · automatic"; applyPowerProfile() }
            else if speed >= 2.5 { taxiOutStartedAt = now; companionPhase = .taxiOut; flightPhaseText = "Taxi out"; applyPowerProfile() }
        case .armed:
            if insideAutoWindow(now), insideAirport(value), speed >= 2.5 {
                groundCandidateAt = now; stoppedAt = nil; companionPhase = .groundCandidate
                flightPhaseText = "Ground movement · checking"; applyPowerProfile()
            }
        case .groundCandidate:
            if !insideAutoWindow(now) || !insideAirport(value) {
                companionPhase = .armed; flightPhaseText = "Armed · automatic"; groundCandidateAt = nil; applyPowerProfile()
            } else if speed < 1.5 {
                stoppedAt = stoppedAt ?? now
                if now.timeIntervalSince(stoppedAt ?? now) >= 75 {
                    companionPhase = .armed; flightPhaseText = "At departure airport · armed"
                    groundCandidateAt = nil; stoppedAt = nil; applyPowerProfile()
                }
            } else if now.timeIntervalSince(groundCandidateAt ?? now) >= 45 && speed <= 18 {
                taxiOutStartedAt = groundCandidateAt ?? now; companionPhase = .taxiOut
                flightPhaseText = "Taxi out · probable"; applyPowerProfile()
            }
        case .taxiOut:
            if speed < 1.5 { stationarySince = stationarySince ?? now; if now.timeIntervalSince(stationarySince ?? now) >= 30 { manager.desiredAccuracy = kCLLocationAccuracyHundredMeters; manager.distanceFilter = 25 } }
            else { stationarySince = nil; applyPowerProfile() }
            let accelerating = previousMeasuredSpeed.map { speed - $0 >= 4 } ?? false
            if speed >= 28 || (speed >= 20 && accelerating) { highSpeedAt = highSpeedAt ?? now; if now.timeIntervalSince(highSpeedAt ?? now) >= 5 { companionPhase = .takeoffRoll; flightPhaseText = "Takeoff roll · probable"; applyPowerProfile() } } else { highSpeedAt = nil }
        case .takeoffRoll:
            if speed >= 55 || gain >= 80 { airborneAt = now; takeoffTimeText = clockText(now); companionPhase = .airborne; flightPhaseText = "Airborne"; stationarySince = nil; applyPowerProfile() }
            else if speed < 8 { companionPhase = .taxiOut; flightPhaseText = "Taxi out"; applyPowerProfile() }
        case .airborne:
            if remaining < 80_000 || (lastMeasuredProgress > 0.82 && speed < 180) { companionPhase = .descent; flightPhaseText = "Descent"; applyPowerProfile() }
        case .descent:
            if remaining < 12_000 && speed < 55 { landedAt = now; landingTimeText = clockText(now); companionPhase = .taxiIn; flightPhaseText = "Landed · taxi in"; stationarySince = nil; applyPowerProfile() }
        case .taxiIn:
            if speed < 1.5 { stationarySince = stationarySince ?? now; if now.timeIntervalSince(stationarySince ?? now) >= 120 { companionPhase = .complete; flightPhaseText = "On block"; applyPowerProfile() } } else { stationarySince = nil }
        case .complete: break
        }
        previousMeasuredSpeed = speed; updateDurations(now)
    }

    func configureAutomaticFlight(from items: [RosterItem], now: Date = Date()) {
        resumeRestoredSession(now: now)
        let candidates = items.flatMap { $0.flightActivities }.compactMap { activity -> (activity: RosterActivity, start: Date, end: Date?)? in
            guard let start = parseUTCStamp(activity.startUTC) else { return nil }
            return (activity, start, parseUTCStamp(activity.endUTC))
        }.filter { candidate in
            let key = [candidate.activity.startUTC, candidate.activity.route, candidate.activity.aircraftReg].joined(separator: "|")
            return completedSectors[key] == nil
        }.sorted { $0.start < $1.start }

        var currentPhaseCanHold = false
        switch companionPhase {
        case .taxiOut, .takeoffRoll, .airborne, .descent, .taxiIn:
            currentPhaseCanHold = airborneAt.map {
                FlightSensorSessionPolicy.arrivalWindow(takeoff: $0, departure: automaticDepartureAt, arrival: scheduledArrivalAt, now: now)
            } ?? (automaticMonitoring && insideAutoWindow(now))
        default:
            break
        }

        var selected: (activity: RosterActivity, start: Date, end: Date?)?
        if currentPhaseCanHold, let currentKey = automaticKey {
            selected = candidates.first { candidate in
                [candidate.activity.startUTC, candidate.activity.route, candidate.activity.aircraftReg]
                    .joined(separator: "|") == currentKey
            }
            if selected == nil {
                // Retain a running session even when a refresh omits it or revises STD.
                selected = candidates.first { candidate in
                    candidate.activity.route == activeRouteText
                        && FleetTrackingPolicy.canonicalRegistration(candidate.activity.aircraftReg) == (trackedRegistration ?? "")
                        && automaticDepartureAt.map { abs(candidate.start.timeIntervalSince($0)) <= 2 * 60 * 60 } == true
                }
            }
            if selected == nil { persistSession(now: now, force: true); return }
        }

        if selected == nil {
            let staleCutoff = now.addingTimeInterval(-30 * 60)
            selected = candidates.first { candidate in
                guard candidate.start >= now.addingTimeInterval(-autoGrace) else { return false }
                if let end = candidate.end, end < staleCutoff { return false }
                return true
            }
        }

        if selected == nil {
            selected = candidates.first { $0.start >= now }
        }

        guard let selected else {
            if companionPhase == .complete { stop() }
            automaticMonitoring = false
            persistSession(now: now, force: true)
            return
        }

        let codes = routeCodes(selected.activity.route)
        guard let originCode = codes.first,
              let origin = TodayGlobalAirportIndex.point(for: originCode) else { return }

        let selectedKey = [selected.activity.startUTC, selected.activity.route, selected.activity.aircraftReg].joined(separator: "|")
        let key = currentPhaseCanHold ? (automaticKey ?? selectedKey) : selectedKey

        if automaticKey != key {
            persistFusedTrail(now: now, force: true)
            FlightCompanionV3Observer.shared.stopObservation()
            if isTracking {
                manager.stopUpdatingLocation()
                isTracking = false
            }
            hybridTask?.cancel()
            hybridTask = nil
            fusedLocation = nil
            groundCandidateAt = nil
            stoppedAt = nil
            highSpeedAt = nil
            taxiOutStartedAt = nil
            airborneAt = nil
            landedAt = nil
            stationarySince = nil
            groundAltitude = nil
            lastMeasuredProgress = 0
            lastMeasuredProgressAt = nil
            previousMeasuredSpeed = nil
            taxiOutDurationText = nil
            airborneDurationText = nil
            taxiInDurationText = nil
            takeoffTimeText = nil
            landingTimeText = nil

            automaticKey = key
            automaticDepartureAt = selected.start
            scheduledArrivalAt = selected.end
            activeRouteText = selected.activity.route
            landedUsingSensors = false
            location = nil; trail = []
            networkObservationAt = nil; networkLatitude = nil; networkLongitude = nil
            automaticOrigin = origin.coordinate
            routeCoordinates = codes.compactMap { TodayGlobalAirportIndex.point(for: $0)?.coordinate }
            configureAircraftTracking(registration: selected.activity.aircraftReg)
            let canonicalReg = FleetTrackingPolicy.canonicalRegistration(selected.activity.aircraftReg)
            configureTrailPersistence(sessionKey: [selected.activity.startUTC, selected.activity.endUTC, selected.activity.route, canonicalReg].joined(separator: "|"))
            companionPhase = .armed
            flightPhaseText = "Armed · automatic"
            positionIsEstimated = false
            configureAutoRegion(code: originCode, coordinate: origin.coordinate)
            applyPowerProfile()
        } else {
            // A roster refresh can revise STD without changing route/registration.
            automaticDepartureAt = selected.start
            scheduledArrivalAt = selected.end
        }

        automaticMonitoring = true
        requestAutomaticAuthorization()
        manager.startMonitoringSignificantLocationChanges()
        if let id = automaticRegionID,
           let region = manager.monitoredRegions.first(where: { $0.identifier == id }) {
            manager.requestState(for: region)
        }
        evaluateAuto(now: now, location: manager.location)
        persistSession(now: now, force: true)
    }

    private func routeCodes(_ route: String) -> [String] {
        route.uppercased().replacingOccurrences(of: "→", with: " ")
            .replacingOccurrences(of: "–", with: " ").replacingOccurrences(of: "—", with: " ")
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "/", with: " ")
            .split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count == 3 }
    }

    private func requestAutomaticAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    private func configureAutoRegion(code: String, coordinate: CLLocationCoordinate2D) {
        if let id = automaticRegionID {
            for region in manager.monitoredRegions where region.identifier == id { manager.stopMonitoring(for: region) }
        }
        let radius = min(airportGateRadius, manager.maximumRegionMonitoringDistance)
        guard radius > 0 else { return }
        let id = "RAIDORoster.AutoDeparture.\(code)"
        let region = CLCircularRegion(center: coordinate, radius: radius, identifier: id)
        region.notifyOnEntry = true; region.notifyOnExit = false
        automaticRegionID = id
        manager.startMonitoring(for: region)
        manager.requestState(for: region)
    }

    private func insideAirport(_ value: CLLocation) -> Bool {
        guard let origin = automaticOrigin else { return false }
        return value.distance(from: CLLocation(latitude: origin.latitude, longitude: origin.longitude)) <= airportGateRadius
    }

    private func insideAutoWindow(_ now: Date) -> Bool {
        guard let departure = automaticDepartureAt else { return false }
        return now >= departure.addingTimeInterval(-autoLead) && now <= departure.addingTimeInterval(autoGrace)
    }

    private func evaluateAuto(now: Date, location: CLLocation?) {
        guard automaticMonitoring, companionPhase != .complete,
              automaticKey.map({ completedSectors[$0] == nil }) ?? true,
              insideAutoWindow(now), let location, insideAirport(location),
              (0...120).contains(now.timeIntervalSince(location.timestamp)),
              location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 1_000 else { return }
        guard !isTracking else { return }
        acquisitionStartedAt = now
        isTracking = true
        companionPhase = .armed
        flightPhaseText = "At departure airport · armed"
        applyPowerProfile()
        manager.startUpdatingLocation()
        restartHybridTask()
        FlightCompanionV3Observer.shared.startObservation(sessionKey: sensorSessionKey)
        persistSession(now: now, force: true)
    }

    // V2.29.1 flight context and GPS status
    private func refreshLocationServicesAvailability() {
        servicesCheckGeneration += 1
        let generation = servicesCheckGeneration
        Task { @MainActor [weak self] in
            let enabled = await Task.detached(priority: .utility) { CLLocationManager.locationServicesEnabled() }.value
            guard let self, self.servicesCheckGeneration == generation else { return }
            self.servicesAvailable = enabled
        }
    }

    func mapStatus(now: Date = Date()) -> FlightTrackingStatus {
        let permission: FlightTrackingStatus.Permission
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: permission = .allowed
        case .notDetermined: permission = .pending
        default: permission = .blocked
        }
        let opens = automaticDepartureAt?.addingTimeInterval(-autoLead)
        return FlightTrackingStatus.resolve(
            tracking: isTracking, automatic: automaticMonitoring, completed: companionPhase == .complete,
            servicesEnabled: servicesAvailable, permission: permission,
            source: fusedLocation == nil ? nil : positionSourceText, estimated: positionIsEstimated,
            acquisitionAge: acquisitionStartedAt.map { max(0, now.timeIntervalSince($0)) },
            windowOpen: insideAutoWindow(now), upcomingStart: opens.flatMap { now < $0 ? clockText($0) : nil })
    }

    private var companionPowerModeText: String {
        if !isTracking { return automaticMonitoring ? "low-power armed" : "idle" }
        switch companionPhase {
        case .parked, .armed: return "armed low-power"
        case .groundCandidate: return "ground verification"
        case .taxiOut, .taxiIn: return "taxi"
        case .takeoffRoll: return "takeoff high-accuracy"
        case .airborne: return "cruise reduced"
        case .descent: return "descent high-accuracy"
        case .complete: return "complete"
        }
    }

    func companionStateText(now: Date = Date()) -> String {
        let departure = automaticDepartureAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none"
        let origin = automaticRegionID?.split(separator: ".").last.map(String.init) ?? "none"
        let fusedAge = fusedLocation.map { max(0, Int(now.timeIntervalSince($0.timestamp).rounded())) } ?? -1
        let insideGate = manager.location.map { insideAirport($0) } ?? false
        let regionActive = automaticRegionID.map { id in
            manager.monitoredRegions.contains(where: { $0.identifier == id })
        } ?? false
        let adsbPollSeconds: Int
        switch companionPhase {
        case .parked, .armed: adsbPollSeconds = 30
        case .groundCandidate, .taxiOut, .taxiIn: adsbPollSeconds = 4
        case .takeoffRoll: adsbPollSeconds = 2
        case .airborne: adsbPollSeconds = 20
        case .descent: adsbPollSeconds = 6
        case .complete: adsbPollSeconds = 60
        }
        return [
            "version=2.26.0-sensor-driver",
            "pausesUpdates=\(manager.pausesLocationUpdatesAutomatically)",
            "scheduledDepartureUTC=\(departure)",
            "originAirport=\(origin)",
            "automaticMonitoring=\(automaticMonitoring)",
            "activeWindow=\(insideAutoWindow(now))",
            "insideOriginGate=\(insideGate)",
            "regionMonitoring=\(regionActive)",
            "locationAuthorization=\(String(describing: manager.authorizationStatus))",
            "phase=\(flightPhaseText)",
            "tracking=\(isTracking)",
            "source=\(positionSourceText)",
            "estimated=\(positionIsEstimated)",
            "fusedAgeSeconds=\(fusedAge)",
            "trailPoints=\(fusedTrail.count)",
            "powerMode=\(companionPowerModeText)",
            "standardGPS=\(isTracking)",
            "adsbPollIntervalSeconds=\(adsbPollSeconds)",
            "desiredAccuracy=\(Int(manager.desiredAccuracy.rounded()))",
            "distanceFilter=\(Int(manager.distanceFilter.rounded()))"
        ].joined(separator: "\n")
    }

    private func applyFreshADSBPhase(_ value: CLLocation, source: String, estimated: Bool, now: Date) {
        guard source == "ADS-B live", !estimated, automaticMonitoring, insideAutoWindow(now) else { return }
        let speed = max(0, value.speed)
        let remaining = destinationDistance(value) ?? .greatestFiniteMagnitude

        switch companionPhase {
        case .armed:
            guard insideAirport(value), speed >= 2.5 else { return }
            groundCandidateAt = groundCandidateAt ?? now
            stoppedAt = nil
            companionPhase = .groundCandidate
            flightPhaseText = "Ground movement · ADS-B"
            applyPowerProfile()

        case .groundCandidate:
            guard insideAirport(value) else { return }
            if speed >= 55 {
                taxiOutStartedAt = taxiOutStartedAt ?? groundCandidateAt ?? now
                airborneAt = now
                takeoffTimeText = clockText(now)
                companionPhase = .airborne
                flightPhaseText = "Airborne · ADS-B"
                stationarySince = nil
                applyPowerProfile()
            } else if speed >= 2.5, now.timeIntervalSince(groundCandidateAt ?? now) >= 8 {
                taxiOutStartedAt = groundCandidateAt ?? now
                companionPhase = .taxiOut
                flightPhaseText = "Taxi out · ADS-B"
                stoppedAt = nil
                applyPowerProfile()
            }

        case .taxiOut:
            if speed >= 55 {
                airborneAt = now
                takeoffTimeText = clockText(now)
                companionPhase = .airborne
                flightPhaseText = "Airborne · ADS-B"
                stationarySince = nil
                applyPowerProfile()
            } else if speed >= 28 {
                highSpeedAt = highSpeedAt ?? now
                companionPhase = .takeoffRoll
                flightPhaseText = "Takeoff roll · ADS-B"
                applyPowerProfile()
            }

        case .takeoffRoll:
            if speed >= 45 {
                airborneAt = now
                takeoffTimeText = clockText(now)
                companionPhase = .airborne
                flightPhaseText = "Airborne · ADS-B"
                stationarySince = nil
                applyPowerProfile()
            }

        case .airborne:
            if remaining < 80_000 || (lastMeasuredProgress > 0.82 && speed < 180) {
                companionPhase = .descent
                flightPhaseText = "Descent · ADS-B"
                applyPowerProfile()
            }

        case .descent:
            if remaining < 12_000 && speed < 55 {
                landedAt = landedAt ?? now
                landingTimeText = landingTimeText ?? clockText(now)
                companionPhase = .taxiIn
                flightPhaseText = "Landed · taxi in · ADS-B"
                stationarySince = nil
                applyPowerProfile()
            }

        case .taxiIn:
            if speed < 1.5 {
                stationarySince = stationarySince ?? now
                if now.timeIntervalSince(stationarySince ?? now) >= 120 {
                    companionPhase = .complete
                    flightPhaseText = "On block · ADS-B"
                    applyPowerProfile()
                }
            } else {
                stationarySince = nil
            }

        case .parked, .complete:
            break
        }
        updateDurations(now)
    }

    func start() {
        FlightCompanionV3Observer.shared.stopObservation()
        resumeAfterRestore = false
        automaticMonitoring = false
        landedUsingSensors = false
        guard CLLocationManager.locationServicesEnabled() else {
            errorText = "Location Services are off"
            isTracking = false
            return
        }

        errorText = nil
        trail = []
        location = nil
        retainedSpeed = nil
        retainedSpeedAt = nil
        retainedCourse = nil
        retainedCourseAt = nil
        gpsQualityText = "Acquiring"
        rejectedFixCount = 0
        acquisitionStartedAt = Date()
        companionPhase = .parked
        flightPhaseText = "Parked"
        taxiOutStartedAt = nil; airborneAt = nil; landedAt = nil; stationarySince = nil; groundAltitude = nil
        lastMeasuredProgress = 0; lastMeasuredProgressAt = nil; previousMeasuredSpeed = nil
        taxiOutDurationText = nil; airborneDurationText = nil; taxiInDurationText = nil; takeoffTimeText = nil; landingTimeText = nil
        applyPowerProfile()
        if fusedTrail.isEmpty { loadPersistedTrail() }
        fusedLocation = nil
        lastFusedTrailAt = nil
        positionSourceText = "Acquiring"
        positionIsEstimated = false
        isTracking = true
        restartHybridTask()

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
            FlightCompanionV3Observer.shared.startObservation(sessionKey: sensorSessionKey)
        case .denied, .restricted:
            errorText = "Location permission required"
            isTracking = false
        @unknown default:
            errorText = "Location unavailable"
            isTracking = false
        }
    }

    // MARK: V2.26 sensor driver and recoverable session
    var sensorPhase: FlightSensorPolicy.Phase {
        guard isTracking else { return .inactive }
        switch companionPhase {
        case .parked, .armed, .groundCandidate, .taxiOut, .takeoffRoll: return .preflight
        case .airborne, .descent: return .airborne
        case .taxiIn, .complete: return .inactive
        }
    }

    private var sensorSessionKey: String { automaticKey ?? trailPersistenceKey ?? "manual" }

    func stopForBackgroundIfIdle() {
        persistSession(now: Date(), force: true)
        if companionPhase == .complete { stop(); return }
        if automaticMonitoring, isTracking { return }
        switch companionPhase {
        case .taxiOut, .takeoffRoll, .airborne, .descent, .taxiIn: return
        default: stop()
        }
    }

    private func modelCruiseSpeed(total: CLLocationDistance) -> CLLocationSpeed {
        FlightSensorSessionPolicy.cruiseSpeed(distance: total, departure: automaticDepartureAt, arrival: scheduledArrivalAt)
    }

    private func sensorProgress(now: Date) -> Double? {
        guard let takeoff = airborneAt, let total = routeDistance, total > 1_000 else { return nil }
        let anchorDate = lastMeasuredProgressAt ?? takeoff
        let anchor = lastMeasuredProgressAt == nil ? 0 : lastMeasuredProgress
        return min(1, max(anchor, anchor + max(0, now.timeIntervalSince(anchorDate)) * modelCruiseSpeed(total: total) / total))
    }

    private func freshMeasuredLocations(now: Date) -> [CLLocation] {
        var values: [CLLocation] = []
        if let value = location, (0...20).contains(now.timeIntervalSince(value.timestamp)),
           value.horizontalAccuracy >= 0, value.horizontalAccuracy <= 250 { values.append(value) }
        if let (value, estimated) = propagatedNetworkLocation(now: now), !estimated { values.append(value) }
        return values
    }

    @discardableResult
    func sensorTakeoffDetected(burstEnd: Date, now: Date) -> Bool {
        guard isTracking, airborneAt == nil, sensorPhase == .preflight,
              (0...360).contains(now.timeIntervalSince(burstEnd)),
              !automaticMonitoring || (insideAutoWindow(now) && insideAutoWindow(burstEnd)),
              !freshMeasuredLocations(now: now).contains(where: { insideAirport($0) && $0.speed >= 0 && $0.speed < 20 }) else { return false }
        taxiOutStartedAt = taxiOutStartedAt ?? groundCandidateAt
        airborneAt = burstEnd; takeoffTimeText = clockText(burstEnd)
        companionPhase = .airborne; flightPhaseText = "Airborne · sensors"
        stationarySince = nil; landedUsingSensors = false
        applyPowerProfile()
        persistSession(now: now, force: true)
        refreshFusedPosition()
        return true
    }

    @discardableResult
    func sensorLandingDetected(at touchdown: Date, now: Date) -> Bool {
        guard isTracking, sensorPhase == .airborne, landedAt == nil,
              (0...180).contains(now.timeIntervalSince(touchdown)),
              let takeoff = airborneAt, touchdown > takeoff else { return false }
        let conflict = freshMeasuredLocations(now: now).contains {
            $0.speed >= 55 || (destinationDistance($0).map { $0 > 20_000 } ?? true)
        }
        guard FlightSensorSessionPolicy.canLand(takeoff: airborneAt, departure: automaticDepartureAt,
                  arrival: scheduledArrivalAt, progress: sensorProgress(now: now), conflictingMeasurement: conflict, now: now) else { return false }
        landedAt = touchdown; landingTimeText = clockText(touchdown)
        companionPhase = .taxiIn; flightPhaseText = "Landed · taxi in · sensors"
        landedUsingSensors = true; stationarySince = nil
        FlightCompanionV3Observer.shared.stopObservation()
        applyPowerProfile()
        persistSession(now: now, force: true)
        refreshFusedPosition()
        return true
    }

    private struct PersistedSession: Codable {
        let key: String?
        let registration: String?
        let routeText: String
        let phase: CompanionPhase
        let tracking: Bool
        let automatic: Bool
        let departure: Date?
        let arrival: Date?
        let origin: PersistedTrailPoint?
        let route: [PersistedTrailPoint]
        let trailKey: String?
        let taxiOut: Date?
        let takeoff: Date?
        let landing: Date?
        let sensorLanding: Bool
        let progress: Double
        let progressAt: Date?
        let savedAt: Date
    }
    private let sessionStorageKey = "RAIDORoster.FlightSession.V226"
    private let completedStorageKey = "RAIDORoster.CompletedSectors.V226"
    private var completedSectors: [String: Date] = [:]
    private var lastSessionPersistAt: Date?
    private var lastPersistedPhase: CompanionPhase?
    private var resumeAfterRestore = false

    private func persistSession(now: Date, force: Bool = false) {
        guard force || lastPersistedPhase != companionPhase || lastSessionPersistAt.map({ now.timeIntervalSince($0) >= 15 }) ?? true else { return }
        let state = PersistedSession(key: automaticKey, registration: trackedRegistration, routeText: activeRouteText,
            phase: companionPhase, tracking: isTracking, automatic: automaticMonitoring,
            departure: automaticDepartureAt, arrival: scheduledArrivalAt,
            origin: automaticOrigin.map { .init(latitude: $0.latitude, longitude: $0.longitude) },
            route: routeCoordinates.map { .init(latitude: $0.latitude, longitude: $0.longitude) },
            trailKey: trailPersistenceKey, taxiOut: taxiOutStartedAt, takeoff: airborneAt,
            landing: landedAt, sensorLanding: landedUsingSensors, progress: lastMeasuredProgress,
            progressAt: lastMeasuredProgressAt, savedAt: now)
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: sessionStorageKey) }
        lastSessionPersistAt = now; lastPersistedPhase = companionPhase
    }

    private func restoreSession(now: Date) {
        if let data = UserDefaults.standard.data(forKey: completedStorageKey),
           let values = try? JSONDecoder().decode([String: Date].self, from: data) {
            completedSectors = values.filter { (0...7 * 24 * 60 * 60).contains(now.timeIntervalSince($0.value)) }
        }
        guard let data = UserDefaults.standard.data(forKey: sessionStorageKey),
              let state = try? JSONDecoder().decode(PersistedSession.self, from: data),
              (0...18 * 60 * 60).contains(now.timeIntervalSince(state.savedAt)),
              state.key.map({ completedSectors[$0] == nil }) ?? true,
              state.tracking, state.phase != .complete,
              state.route.count >= 2, state.route.allSatisfy({ (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) }) else { return }
        if let takeoff = state.takeoff {
            guard FlightSensorSessionPolicy.arrivalWindow(takeoff: takeoff, departure: state.departure, arrival: state.arrival, now: now) else { return }
        } else if state.automatic {
            guard let departure = state.departure, now >= departure.addingTimeInterval(-autoLead), now <= departure.addingTimeInterval(autoGrace) else { return }
        } else { return } // Idle manual sessions are not relaunched.
        automaticKey = state.key; automaticMonitoring = state.automatic
        automaticDepartureAt = state.departure; scheduledArrivalAt = state.arrival
        automaticOrigin = state.origin.map { .init(latitude: $0.latitude, longitude: $0.longitude) }
        routeCoordinates = state.route.map { .init(latitude: $0.latitude, longitude: $0.longitude) }
        trackedRegistration = state.registration; trailPersistenceKey = state.trailKey
        activeRouteText = state.routeText
        companionPhase = state.phase; taxiOutStartedAt = state.taxiOut
        airborneAt = state.takeoff; landedAt = state.landing; landedUsingSensors = state.sensorLanding
        lastMeasuredProgress = state.progress; lastMeasuredProgressAt = state.progressAt
        takeoffTimeText = state.takeoff.map(clockText); landingTimeText = state.landing.map(clockText)
        flightPhaseText = "Restored session · \(state.phase.rawValue)"
        loadPersistedTrail()
        resumeAfterRestore = true
        // Restore phase/times, but never restore partial sensor evidence across a process gap.
    }

    private func resumeRestoredSession(now: Date) {
        guard resumeAfterRestore, manager.authorizationStatus == .authorizedAlways ||
              (manager.authorizationStatus == .authorizedWhenInUse && UIApplication.shared.applicationState == .active) else { return }
        resumeAfterRestore = false
        acquisitionStartedAt = now; isTracking = true
        applyPowerProfile(); manager.startUpdatingLocation(); restartHybridTask()
        if sensorPhase != .inactive { FlightCompanionV3Observer.shared.startObservation(sessionKey: sensorSessionKey) }
    }

    private func maintainSession(now: Date) {
        if landedUsingSensors, companionPhase == .taxiIn, let landing = landedAt,
           now.timeIntervalSince(landing) >= 25 * 60 {
            companionPhase = .complete; flightPhaseText = "Session complete · estimated"
            applyPowerProfile()
        }
        if companionPhase == .complete {
            if let key = automaticKey, completedSectors[key] == nil {
                completedSectors[key] = now
                completedSectors = completedSectors.filter { (0...7 * 24 * 60 * 60).contains(now.timeIntervalSince($0.value)) }
                if let data = try? JSONEncoder().encode(completedSectors) { UserDefaults.standard.set(data, forKey: completedStorageKey) }
            }
            if isTracking { stop() }
            return
        }
        let expired: Bool
        if let takeoff = airborneAt {
            expired = !FlightSensorSessionPolicy.arrivalWindow(takeoff: takeoff, departure: automaticDepartureAt, arrival: scheduledArrivalAt, now: now)
        } else { expired = automaticMonitoring && !insideAutoWindow(now) }
        if expired, isTracking {
            flightPhaseText = "Session expired · reopen to resume"
            stop()
            return
        }
        persistSession(now: now)
    }

    func stop() {
        resumeAfterRestore = false
        FlightCompanionV3Observer.shared.stopObservation()
        persistFusedTrail(now: Date(), force: true)
        manager.stopUpdatingLocation()
        hybridTask?.cancel()
        hybridTask = nil
        isTracking = false
        acquisitionStartedAt = nil
        persistSession(now: Date(), force: true)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshLocationServicesAvailability()
        if automaticMonitoring {
            requestAutomaticAuthorization()
            manager.startMonitoringSignificantLocationChanges()
            if let id = automaticRegionID, let region = manager.monitoredRegions.first(where: { $0.identifier == id }) {
                manager.requestState(for: region)
            }
            evaluateAuto(now: Date(), location: manager.location)
        }

        authorizationStatus = manager.authorizationStatus
        guard isTracking else { return }

        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            errorText = nil
            manager.startUpdatingLocation()
            FlightCompanionV3Observer.shared.startObservation(sessionKey: sensorSessionKey)
        case .denied, .restricted:
            stop()
            errorText = "Location permission required"
            isTracking = false
            acquisitionStartedAt = nil
            manager.stopUpdatingLocation()
        case .notDetermined:
            break
        @unknown default:
            errorText = "Location unavailable"
            isTracking = false
            acquisitionStartedAt = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let candidates = locations
            .filter {
                $0.horizontalAccuracy >= 0 &&
                abs($0.timestamp.timeIntervalSinceNow) <= 30
            }
            .sorted { lhs, rhs in
                // Prefer materially better horizontal accuracy; otherwise keep
                // the newer fix. This avoids blindly accepting the last object.
                if abs(lhs.horizontalAccuracy - rhs.horizontalAccuracy) > 20 {
                    return lhs.horizontalAccuracy < rhs.horizontalAccuracy
                }
                return lhs.timestamp > rhs.timestamp
            }

        guard let candidate = candidates.first else {
            gpsQualityText = location == nil ? "Acquiring" : "Weak"
            return
        }

        // A coarse cellular/Wi-Fi estimate is not good enough to move an
        // aircraft marker. Keep the last good GNSS fix until reception returns.
        guard candidate.horizontalAccuracy <= 300 else {
            gpsQualityText = location == nil ? "Acquiring" : "Poor"
            if location == nil {
                errorText = "Waiting for GNSS (±\(Int(candidate.horizontalAccuracy.rounded())) m)"
            }
            return
        }

        guard isPhysicallyPlausible(candidate, after: location) else {
            rejectedFixCount += 1
            gpsQualityText = location == nil ? "Acquiring" : "Weak"
            return
        }

        location = candidate
        evaluateAuto(now: Date(), location: candidate)
        Task { @MainActor in FlightCompanionV3ShadowEngine.shared.recordGNSS(candidate) }
        refreshFusedPosition()
        gpsQualityText = qualityText(for: candidate)
        errorText = nil

        if candidate.speed >= 0 {
            retainedSpeed = candidate.speed
            retainedSpeedAt = candidate.timestamp
        }
        if candidate.course >= 0 {
            retainedCourse = candidate.course
            retainedCourseAt = candidate.timestamp
        }

        if let lastCoordinate = trail.last {
            let last = CLLocation(latitude: lastCoordinate.latitude, longitude: lastCoordinate.longitude)
            guard candidate.distance(from: last) >= 25 else { return }
        }

        trail.append(candidate.coordinate)
        if trail.count > 1_200 {
            trail.removeFirst(trail.count - 1_200)
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard automaticMonitoring, region.identifier == automaticRegionID else { return }
        evaluateAuto(now: Date(), location: manager.location)
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard automaticMonitoring, region.identifier == automaticRegionID, state == .inside else { return }
        evaluateAuto(now: Date(), location: manager.location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let coreError = error as? CLError, coreError.code == .locationUnknown {
            return
        }
        errorText = "GPS temporarily unavailable"
    }
}


enum FlightV3EvidenceSource: String, Codable {
    case barometer, motionActivity, deviceMotion
}

enum FlightV3EvidenceKind: String, Codable {
    case relativeAltitude, activity, acceleration
}

struct FlightV3Evidence: Codable, Identifiable {
    var id = UUID()
    let timestamp: Date
    let source: FlightV3EvidenceSource
    let kind: FlightV3EvidenceKind
    let value: Double?
    let detail: String?
    let confidence: Double
}

actor FlightV3EvidenceLog {
    static let shared = FlightV3EvidenceLog()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let url: URL

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("FlightCompanionV3", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("sensor-evidence.jsonl")
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    func append(_ evidence: FlightV3Evidence) { appendBatch([evidence]) }

    func appendBatch(_ values: [FlightV3Evidence]) {
        var data = Data()
        for value in values {
            guard let encoded = try? encoder.encode(value) else { continue }
            data.append(encoded); data.append(0x0A)
        }
        guard !data.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: data) } catch { }
    }

    func all() -> [FlightV3Evidence] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap {
            try? decoder.decode(FlightV3Evidence.self, from: Data($0))
        }
    }
}

@MainActor
final class FlightCompanionV3Observer: ObservableObject {
    static let shared = FlightCompanionV3Observer()
    @Published private(set) var available = false
    @Published private(set) var relativeAltitudeM: Double?
    @Published private(set) var pressureKPa: Double?
    @Published private(set) var climbRateFtMin: Double = 0
    @Published private(set) var sampleCount = 0
    private let altimeter = CMAltimeter()
    private let motion = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "RAIDORoster.FlightCompanionV3"
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 1
        return q
    }()
    // All tunable thresholds live in FlightSensorPolicy.Thresholds.
    private var policy = FlightSensorPolicy()
    private var epoch = UUID()
    private var started = false
    private var sessionKey: String?
    private var pendingEvidence: [FlightV3Evidence] = []
    private var lastFlushAt: Date?

    func startObservation(sessionKey key: String) {
        if started, sessionKey == key { return }
        stopObservation()
        sessionKey = key
        started = true
        let generation = epoch
        policy.setPhase(TodayLiveFlightLocationManager.shared.sensorPhase)
        available = CMAltimeter.isRelativeAltitudeAvailable() && motion.isDeviceMotionAvailable
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: queue) { [weak self] data, error in
                let received = Date(), uptime = ProcessInfo.processInfo.systemUptime
                guard let data else {
                    Task { @MainActor in self?.sensorFailed(generation: generation, detail: "barometer unavailable") }
                    return
                }
                let timestamp = data.timestamp
                let altitude = data.relativeAltitude.doubleValue
                let pressure = data.pressure.doubleValue
                Task { @MainActor in
                    guard let self, self.started, self.epoch == generation else { return }
                    guard let time = FlightSensorPolicy.sampleDate(uptime: timestamp, receivedAt: received, currentUptime: uptime),
                          Date().timeIntervalSince(time) <= 2 else {
                        self.sensorFailed(generation: generation, detail: "delayed barometer sample")
                        return
                    }
                    self.ingestAltitude(time: time, altitude: altitude, pressure: pressure)
                }
            }
        }
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.20
            motion.startDeviceMotionUpdates(to: queue) { [weak self] data, error in
                let received = Date(), uptime = ProcessInfo.processInfo.systemUptime
                guard let data else {
                    Task { @MainActor in self?.sensorFailed(generation: generation, detail: "motion unavailable") }
                    return
                }
                let timestamp = data.timestamp
                let a = data.userAcceleration
                let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
                Task { @MainActor in
                    guard let self, self.started, self.epoch == generation else { return }
                    guard let time = FlightSensorPolicy.sampleDate(uptime: timestamp, receivedAt: received, currentUptime: uptime),
                          Date().timeIntervalSince(time) <= 2 else {
                        self.sensorFailed(generation: generation, detail: "delayed motion sample")
                        return
                    }
                    self.ingestMotion(time: time, magnitude: magnitude)
                }
            }
        }
        record(.init(timestamp: Date(), source: .deviceMotion, kind: .activity, value: nil,
                     detail: "sensor session started", confidence: 1), force: true)
    }

    func stopObservation() {
        epoch = UUID() // Drop callbacks queued by the previous sector/session.
        altimeter.stopRelativeAltitudeUpdates()
        motion.stopDeviceMotionUpdates()
        flushEvidence()
        started = false
        available = false
        sessionKey = nil
        policy.reset()
        relativeAltitudeM = nil; pressureKPa = nil; climbRateFtMin = 0
    }

    private func sensorFailed(generation: UUID, detail: String) {
        guard started, epoch == generation else { return }
        policy.reset(to: TodayLiveFlightLocationManager.shared.sensorPhase)
        climbRateFtMin = 0
        record(.init(timestamp: Date(), source: .deviceMotion, kind: .activity,
                     value: nil, detail: detail, confidence: 0), force: true)
    }

    private func ingestMotion(time: Date, magnitude: Double) {
        let manager = TodayLiveFlightLocationManager.shared
        policy.setPhase(manager.sensorPhase)
        let event = policy.ingestMotion(magnitude, at: time, receivedAt: Date())
        record(.init(timestamp: time, source: .deviceMotion, kind: .acceleration,
                     value: magnitude, detail: "userAcceleration magnitude g", confidence: 0.5))
        handle(event)
    }

    private func ingestAltitude(time: Date, altitude: Double, pressure: Double) {
        let manager = TodayLiveFlightLocationManager.shared
        policy.setPhase(manager.sensorPhase)
        relativeAltitudeM = altitude; pressureKPa = pressure
        let event = policy.ingestAltitude(altitude, at: time, receivedAt: Date())
        climbRateFtMin = policy.climbRateFtMin ?? 0
        record(.init(timestamp: time, source: .barometer, kind: .relativeAltitude, value: altitude,
                     detail: "pressure=\(pressure)kPa rate=\(policy.climbRateFtMin.map(String.init(describing:)) ?? "unknown")fpm",
                     confidence: policy.climbRateFtMin == nil ? 0 : 0.8))
        handle(event)
    }

    private func handle(_ event: FlightSensorPolicy.Event?) {
        guard let event else { return }
        let manager = TodayLiveFlightLocationManager.shared
        let accepted: Bool
        switch event {
        case .takeoff(let at): accepted = manager.sensorTakeoffDetected(burstEnd: at, now: Date())
        case .landing(let at): accepted = manager.sensorLandingDetected(at: at, now: Date())
        }
        record(.init(timestamp: Date(), source: .deviceMotion, kind: .activity, value: nil,
                     detail: "candidate=\(event) accepted=\(accepted)", confidence: accepted ? 0.8 : 0), force: true)
        if accepted { policy.reset(to: manager.sensorPhase) }
    }

    private func record(_ value: FlightV3Evidence, force: Bool = false) {
        sampleCount += 1
        pendingEvidence.append(value)
        let now = Date()
        if force || pendingEvidence.count >= 64 || lastFlushAt.map({ now.timeIntervalSince($0) >= 5 }) ?? true {
            flushEvidence()
        }
    }

    private func flushEvidence() {
        guard !pendingEvidence.isEmpty else { return }
        let batch = pendingEvidence
        pendingEvidence.removeAll(keepingCapacity: true)
        lastFlushAt = Date()
        Task { await FlightV3EvidenceLog.shared.appendBatch(batch) }
    }

    var diagnosticText: String {
        ["version=2.26.0-sensor-driver", "observing=\(started)", "available=\(available)",
         "samples=\(sampleCount)", "rejectedSamples=\(policy.rejectedSamples)",
         "baroRateFtMin=\(policy.climbRateFtMin.map(String.init(describing:)) ?? "unknown")",
         "smoothedAccelG=\(String(format: "%.3f", policy.smoothedAcceleration))",
         "mode=drives-phase-offline"].joined(separator: "\n")
    }
}

private enum TodayGlobalAirportIndex {
    private struct Entry: Decodable {
        let name: String
        let latitude: Double
        let longitude: Double

        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            name = try values.decode(String.self)
            latitude = try values.decode(Double.self)
            longitude = try values.decode(Double.self)
        }
    }

    // The embedded dictionary remains a zero-I/O fast path for common routes.
    // The bundled global index is the source of truth for all other IATA codes.
    private static let records: [String: Entry] = {
        guard let url = Bundle.main.url(forResource: "GlobalAirportIndex", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return decoded
    }()

    static func point(for code: String) -> TodayAirportMapPoint? {
        let normalized = code
            .uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil else { return nil }

        if let local = TodayAirportCoordinates.airports[normalized] {
            return local
        }
        guard let record = records[normalized],
              (-90...90).contains(record.latitude),
              (-180...180).contains(record.longitude) else { return nil }
        return TodayAirportMapPoint(
            code: normalized,
            name: record.name,
            coordinate: CLLocationCoordinate2D(latitude: record.latitude, longitude: record.longitude)
        )
    }

    static func routeCodes(_ route: String) -> [String] {
        route
            .uppercased()
            .replacingOccurrences(of: "→", with: " ")
            .replacingOccurrences(of: "–", with: " ")
            .replacingOccurrences(of: "—", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count == 3 }
    }

    static func routePoints(for route: String) -> [TodayAirportMapPoint] {
        var output: [TodayAirportMapPoint] = []
        for code in routeCodes(route) {
            guard let point = point(for: code) else { continue }
            // Keep a return-to-origin route (e.g. TLV-VAR-TLV), while removing
            // only repeated adjacent tokens.
            if output.last?.code != point.code {
                output.append(point)
            }
        }
        return output
    }
}

struct TodayRouteMapCard: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem
    var iceHeader = false
    @AppStorage("RAIDORoster.Map.PlaceLabels") private var showsPlaceLabels = true
    @State private var mapExpanded = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("RAIDORoster.GroundSpeedUnit") private var groundSpeedUnit = "kt"

    @ObservedObject private var gps = TodayLiveFlightLocationManager.shared
    @StateObject private var connectivity = TodayMapConnectivityMonitor()
    @AppStorage("RAIDORoster.TodayMapSource") private var todayMapSource = "auto"
    @State private var onlineCameraPosition: MapCameraPosition = .automatic
    @State private var committedZoom: CGFloat = 1
    @State private var committedPan: CGSize = .zero

    static func canDisplay(_ item: RosterItem) -> Bool {
        TodayGlobalAirportIndex.routeCodes(item.route).count >= 2
    }

    private var useOfflineMap: Bool {
        todayMapSource == "offline" || !connectivity.isConnected
    }

    private var trackedAircraftRegistration: String? {
        let raw = item.aircraft.first?.aircraftReg
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        return raw.isEmpty ? nil : raw
    }

    private var trackingSessionKey: String {
        let activity = item.flightActivities.first
        return [activity?.startUTC ?? "", activity?.endUTC ?? "", activity?.route ?? "", trackedAircraftRegistration ?? ""]
            .joined(separator: "|")
    }

    private var points: [TodayAirportMapPoint] {
        Self.routePoints(for: item)
    }

    private var coordinates: [CLLocationCoordinate2D] {
        points.map(\.coordinate)
    }

    private var gpsQuality: (label: String, color: Color) {
        guard gps.isTracking else { return ("GPS Off", .secondary) }
        guard let location = gps.location else { return ("Acquiring GPS", .orange) }

        let age = abs(location.timestamp.timeIntervalSinceNow)
        if age > 15 { return ("GPS Stale", .orange) }
        if !gps.isPrecise { return ("Reduced Accuracy", .orange) }
        if location.horizontalAccuracy <= 50 { return ("GPS Strong", .green) }
        if location.horizontalAccuracy <= 200 { return ("GPS Usable", .green) }
        if location.horizontalAccuracy <= 1_000 { return ("GPS Weak", .orange) }
        return ("GPS Poor", .red)
    }

    private var altitudeText: String {
        guard let location = gps.location,
              location.verticalAccuracy >= 0 else { return "— ft" }
        let feet = Int((location.altitude * 3.28084).rounded())
        return "\(feet.formatted()) ft"
    }

    private var speedText: String {
        guard let speed = gps.displaySpeed else {
            switch groundSpeedUnit {
            case "kmh": return "— km/h"
            case "mph": return "— mph"
            default: return "— kt"
            }
        }

        switch groundSpeedUnit {
        case "kmh":
            return "\(Int((speed * 3.6).rounded())) km/h"
        case "mph":
            return "\(Int((speed * 2.23694).rounded())) mph"
        default:
            return "\(Int((speed * 1.94384).rounded())) kt"
        }
    }

    private var courseText: String {
        guard let location = gps.location,
              location.course >= 0,
              location.courseAccuracy >= 0,
              location.speed > 2 else { return "—°" }
        return "\(Int(location.course.rounded()))°"
    }

    private var positionAccuracyText: String {
        guard let location = gps.location, location.horizontalAccuracy >= 0 else { return "POS —" }
        return "POS ±\(Int(location.horizontalAccuracy.rounded()))m"
    }

    private var altitudeAccuracyText: String {
        guard let location = gps.location, location.verticalAccuracy >= 0 else { return "ALT —" }
        let feet = Int((location.verticalAccuracy * 3.28084).rounded())
        return "ALT ±\(feet)ft"
    }

    private var positionSourceDetailText: String {
        if let location = gps.fusedLocation {
            let age = Int(max(0, Date().timeIntervalSince(location.timestamp)).rounded())
            return "\(gps.positionSourceText) • \(age)s"
        }
        return gps.positionSourceText
    }

    private var gpsQualityDetailText: String {
        guard let location = gps.location else { return gps.gpsQualityText }
        let accuracy = Int(max(0, location.horizontalAccuracy).rounded())
        let age = Int(max(0, Date().timeIntervalSince(location.timestamp)).rounded())
        return "\(gps.gpsQualityText) • ±\(accuracy)m • \(age)s"
    }

    private var horizontalAccuracyText: String {
        guard let location = gps.location, location.horizontalAccuracy >= 0 else { return "—" }
        return "±\(Int(location.horizontalAccuracy.rounded())) m"
    }

    private var speedAccuracyText: String {
        guard let location = gps.location, location.speedAccuracy >= 0 else { return "SPD —" }
        switch groundSpeedUnit {
        case "kmh":
            return "SPD ±\(Int((location.speedAccuracy * 3.6).rounded()))km/h"
        case "mph":
            return "SPD ±\(Int((location.speedAccuracy * 2.23694).rounded()))mph"
        default:
            return "SPD ±\(Int((location.speedAccuracy * 1.94384).rounded()))kt"
        }
    }

    private var courseAccuracyText: String {
        guard let location = gps.location, location.courseAccuracy >= 0 else { return "CRS —" }
        return "CRS ±\(Int(location.courseAccuracy.rounded()))°"
    }

    private var fixAgeText: String {
        guard let location = gps.location else { return "AGE —" }
        let age = max(0, Int(abs(location.timestamp.timeIntervalSinceNow).rounded()))
        return "AGE \(age)s"
    }

    private var progressText: String? {
        guard gps.isTracking,
              let location = gps.location,
              let estimate = Self.routeProgress(
                location: location,
                coordinates: coordinates,
                preferredSegment: preferredSegmentIndex(at: Date())
              ) else { return nil }

        let base = "\(estimate.percent)% route • \(estimate.remainingKM.formatted()) km remaining"

        guard location.speed >= 30,
              location.speedAccuracy >= 0,
              estimate.remainingKM > 0 else { return base }

        let seconds = (Double(estimate.remainingKM) * 1_000) / location.speed
        guard seconds.isFinite, seconds > 0, seconds < 24 * 60 * 60 else { return base }

        let minutes = max(1, Int((seconds / 60).rounded()))
        let eta: String
        if minutes < 60 {
            eta = "\(minutes)m"
        } else {
            let hours = minutes / 60
            let remainder = minutes % 60
            eta = remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        }
        return base + " • ~" + eta
    }

    private var legacyBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Flight Companion", systemImage: "airplane.circle.fill")
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)

                HStack(spacing: 5) {
                    Circle()
                        .fill(gps.isTracking ? gpsQuality.color : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(gps.isTracking ? "LIVE GPS" : "ROUTE OVERVIEW")
                        .font(.caption2.bold())
                        .foregroundStyle(gps.isTracking ? gpsQuality.color : Color.secondary)
                }
            }
            .padding(.horizontal, 2)

            mapSurface
            .frame(height: gps.isTracking ? 230 : 195)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.secondary.opacity(colorScheme == .dark ? 0.24 : 0.14), lineWidth: 1)
            }

            if gps.isTracking {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(spacing: 7) {
                        HStack(spacing: 0) {
                            liveMetric("Altitude", altitudeText)
                            Divider().frame(height: 28)
                            liveMetric("Phase", gps.flightPhaseText)
                        liveMetric("Position", positionSourceDetailText)
                            Divider().frame(height: 28)

                            Menu {
                                Button {
                                    groundSpeedUnit = "kt"
                                } label: {
                                    HStack {
                                        Text("Knots (kt)")
                                        if groundSpeedUnit == "kt" { Image(systemName: "checkmark") }
                                    }
                                }

                                Button {
                                    groundSpeedUnit = "kmh"
                                } label: {
                                    HStack {
                                        Text("Kilometres/hour (km/h)")
                                        if groundSpeedUnit == "kmh" { Image(systemName: "checkmark") }
                                    }
                                }

                                Button {
                                    groundSpeedUnit = "mph"
                                } label: {
                                    HStack {
                                        Text("Miles/hour (mph)")
                                        if groundSpeedUnit == "mph" { Image(systemName: "checkmark") }
                                    }
                                }
                            } label: {
                                liveMetric("Ground speed", speedText)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Divider().frame(height: 28)
                            liveMetric("Track", courseText)
                        }

                        HStack(spacing: 5) {
                            Circle()
                                .fill(gpsQuality.color)
                                .frame(width: 7, height: 7)
                            Text(gpsQuality.label)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            if !gps.isPrecise {
                                Text("Precise Location recommended")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }

                        Text([
                            positionAccuracyText,
                            altitudeAccuracyText,
                            speedAccuracyText,
                            courseAccuracyText,
                            fixAgeText
                        ].joined(separator: " • "))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)

                        HStack(spacing: 8) {
                            if let progressText {
                                Text(progressText)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            } else if gps.location == nil {
                                Text(acquisitionText(at: Date()))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Position available • route projection not reliable yet")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 6)

                            Button("Stop") {
                                gps.stop()
                            }
                            .font(.caption.bold())
                        }
                    }
                }
            }
        }
    }

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        Group {
            if iceHeader { iceMapHeader } else { legacyBody }
        }
        .animation(.snappy(duration: 0.2), value: gps.isTracking)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                gps.stopForBackgroundIfIdle()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Flight route map " + points.map(\.code).joined(separator: " to "))
        .onAppear {
            gps.configureAircraftTracking(registration: trackedAircraftRegistration)
            gps.configureFlightRoute(coordinates: points.map(\.coordinate))
            gps.configureTrailPersistence(sessionKey: trackingSessionKey)
        }
        .onChange(of: trackedAircraftRegistration) { _, value in
            gps.configureAircraftTracking(registration: value)
        }
        .onChange(of: trackingSessionKey) { _, value in
            gps.configureTrailPersistence(sessionKey: value)
        }
    }

    private var mapSurface: some View {
        ZStack {
                if !useOfflineMap {
                    TodayOnlineRouteMap(
                        points: points,
                        trail: gps.fusedTrail,
                        liveLocation: gps.fusedLocation,
                        isTracking: gps.isTracking,
                        cameraPosition: $onlineCameraPosition
                    )
                } else {
                    GeometryReader { _ in
                        OfflineAviationMapCanvas(
                            points: points,
                            trail: gps.fusedTrail,
                            liveLocation: gps.fusedLocation,
                            isTracking: gps.isTracking,
                            zoom: committedZoom,
                            pan: committedPan,
                            colorScheme: colorScheme
                        )
                        VStack {
                            HStack {
                                if !iceHeader {
                                Text("LOCAL • NO DATA REQUIRED")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(MidnightTheme.background.opacity(0.88), in: Capsule())
                                }
                                Spacer()
                            }
                            Spacer()
                        }
                        .padding(9)
                        .contentShape(Rectangle())
                        .overlay {
                            OfflineMapInteractionSurface(zoom: $committedZoom, pan: $committedPan,
                                interactive: !iceHeader || mapExpanded)
                        }
                    }
                }

                if !iceHeader {
                VStack {
                    HStack {
                        Menu {
                            Button {
                                todayMapSource = "auto"
                                onlineCameraPosition = .automatic
                            } label: {
                                HStack {
                                    Text("Apple Map / Auto")
                                    if !useOfflineMap { Image(systemName: "checkmark") }
                                }
                            }

                            Button {
                                todayMapSource = "offline"
                            } label: {
                                HStack {
                                    Text("Offline local map")
                                    if useOfflineMap { Image(systemName: "checkmark") }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: !useOfflineMap ? "map.fill" : "airplane.circle.fill")
                                Text(!useOfflineMap ? "APPLE MAP" : "OFFLINE MAP")
                            }
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(MidnightTheme.background.opacity(0.92), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if !useOfflineMap {
                                    if let coordinate = gps.fusedLocation?.coordinate {
                                        onlineCameraPosition = .region(
                                            MKCoordinateRegion(
                                                center: coordinate,
                                                latitudinalMeters: 500_000,
                                                longitudinalMeters: 500_000
                                            )
                                        )
                                    } else {
                                        onlineCameraPosition = .automatic
                                    }
                                } else {
                                    committedZoom = 1
                                    committedPan = .zero
                                }
                            }
                        } label: {
                            Image(systemName: "scope")
                                .font(.subheadline.bold())
                                .frame(width: 34, height: 34)
                                .background(MidnightTheme.background.opacity(0.92), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Recenter route map")
                    }
                    .padding(10)

                    Spacer()

                    if gps.isTracking {
                        Button {
                            gps.stop()
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "stop.circle.fill")
                                Text("Stop Live Tracking")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Color(uiColor: .systemBackground).opacity(0.94), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 12)
                        .accessibilityLabel("Stop live flight tracking")
                    } else {
                        Button {
                            gps.start()
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "location.fill")
                                Text(gps.errorText ?? "Start Live GPS")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(gps.errorText == nil ? Color.accentColor : Color.orange)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(MidnightTheme.background.opacity(0.94), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 12)
                        .accessibilityLabel("Start foreground live GPS flight tracking")
                    }
                }
                            }
            }
    }

    // Compact header is passive. Map interaction and existing GPS controls are
    // available only after expansion; this view never starts a second session.
    private var iceMapHeader: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Both layers share the same projection. The blurred layer is
                // passive local geography, even when Apple Maps is selected.
                OfflineAviationMapCanvas(points: points, trail: gps.fusedTrail,
                    liveLocation: gps.fusedLocation, isTracking: gps.isTracking,
                    zoom: committedZoom, pan: committedPan, colorScheme: colorScheme)
                    .blur(radius: 12).allowsHitTesting(false).accessibilityHidden(true)
                mapSurface
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(0.12), location: 0.18),
                        .init(color: .white, location: 0.40),
                        .init(color: .white, location: 0.68),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom))
                    .allowsHitTesting(mapExpanded)
                // Fully meet the page colour at both boundaries. No material
                // panel: coastlines soften gradually beneath the title/handle.
                LinearGradient(stops: [
                    .init(color: MidnightTheme.background, location: 0),
                    .init(color: MidnightTheme.background.opacity(0.78), location: 0.16),
                    .init(color: MidnightTheme.background.opacity(0.20), location: 0.32),
                    .init(color: .clear, location: 0.44),
                    .init(color: .clear, location: 0.67),
                    .init(color: MidnightTheme.background.opacity(0.40), location: 0.82),
                    .init(color: MidnightTheme.background.opacity(0.90), location: 0.95),
                    .init(color: MidnightTheme.background, location: 1)
                ], startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
                HStack(alignment: .top, spacing: 10) {
                    IcePageHeading(title: "Today", subtitle: Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    IceDestinationClock(item: item)
                }.padding(.horizontal, 18).padding(.top, 10)
                VStack {
                    Spacer()
                    if gps.isTracking {
                        TimelineView(.periodic(from: .now, by: 5)) { context in
                            let status = gps.mapStatus(now: context.date)
                            HStack(spacing: 6) {
                                Image(systemName: status.symbol)
                                Text(status.title).lineLimit(2)
                                Spacer(minLength: 0)
                            }.font(.caption2).foregroundStyle(.secondary).padding(9)
                                .background(MidnightTheme.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 9))
                                .padding(.horizontal, 18).padding(.bottom, 30)
                                .accessibilityElement(children: .combine)
                                .accessibilityHint(status.detail)
                                .accessibilityIdentifier("today-map-tracking-status")
                        }
                    }
                }.allowsHitTesting(false)
                VStack {
                    Spacer()
                    Capsule().fill(MidnightTheme.accent.opacity(0.5)).frame(width: 30, height: 3)
                        .padding(.bottom, 12)
                }.allowsHitTesting(false).accessibilityHidden(true)
            }.frame(height: mapExpanded ? 474 : 324).clipped()
                .contentShape(Rectangle())
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("today-map-surface")
                .overlay(alignment: .bottom) {
                    MapHeaderTapControl(expanded: mapExpanded, onToggle: toggleMap).frame(height: 44)
                }
                .background(MidnightTheme.background)
            if mapExpanded {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(gps.flightPhaseText).font(.subheadline.weight(.semibold))
                        Text(gps.mapStatus().title + " · " + speedText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Apple Map / Auto") { todayMapSource = "auto"; onlineCameraPosition = .automatic }
                        Button("Offline local map") { todayMapSource = "offline" }
                        Toggle("Geographic labels", isOn: $showsPlaceLabels)
                        Button("Recenter map") { onlineCameraPosition = .automatic; committedZoom = 1; committedPan = .zero }
                        if gps.isTracking { Button("Stop tracking", role: .destructive) { gps.stop() } }
                        else { Button("Start Live GPS") { gps.start() } }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                    .accessibilityLabel("Flight Companion controls")
                }.padding(13).midnightCard(radius: 14).padding(.horizontal, 18).padding(.bottom, 14)
                DisclosureGroup("Flight details") {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            liveMetric("Altitude", altitudeText)
                            liveMetric("Track", courseText)
                            liveMetric("Position", horizontalAccuracyText)
                        }
                        Text(gps.mapStatus().detail).font(.caption).foregroundStyle(.secondary)
                        if gps.isTracking { Text(gpsQualityDetailText).font(.caption).foregroundStyle(.secondary) }
                        if let error = gps.errorText { Text(error).font(.caption).foregroundStyle(MidnightTheme.warningInk) }
                    }.padding(.top, 10)
                }.font(.caption).padding(.horizontal, 18).padding(.bottom, 14)
            }
        }
        .background(TodayMapDisclosureObserver(expanded: mapExpanded, onToggle: toggleMap))
        .contentShape(Rectangle())
    }


    private func toggleMap() {
        if mapExpanded { committedPan = .zero; committedZoom = 1; onlineCameraPosition = .automatic }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { mapExpanded.toggle() }
    }


    @ViewBuilder
    private func liveMetric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func acquisitionText(at now: Date) -> String {
        guard let started = gps.acquisitionStartedAt else { return "Acquiring GPS…" }
        let seconds = max(0, Int(now.timeIntervalSince(started).rounded()))
        if seconds < 12 { return "Acquiring GPS… \(seconds)s" }
        if seconds < 45 { return "Waiting for satellite/location fix… \(seconds)s" }
        return "Weak/no GPS fix • try placing iPhone near a window"
    }

    private func preferredSegmentIndex(at now: Date) -> Int? {
        for (index, flight) in item.flightActivities.enumerated() {
            guard index < max(0, coordinates.count - 1),
                  let start = parseUTCStamp(flight.startUTC),
                  let end = parseUTCStamp(flight.endUTC) else { continue }
            if now >= start && now < end { return index }
        }

        if let next = item.flightActivities.enumerated()
            .compactMap({ pair -> (Int, Date)? in
                guard pair.offset < max(0, coordinates.count - 1),
                      let start = parseUTCStamp(pair.element.startUTC),
                      start > now else { return nil }
                return (pair.offset, start)
            })
            .sorted(by: { $0.1 < $1.1 })
            .first {
            return next.0
        }

        return nil
    }

    private static func routePoints(for item: RosterItem) -> [TodayAirportMapPoint] {
        TodayGlobalAirportIndex.routePoints(for: item.route)
    }

    private static func routeProgress(
        location: CLLocation,
        coordinates: [CLLocationCoordinate2D],
        preferredSegment: Int?
    ) -> (percent: Int, remainingKM: Int)? {
        guard coordinates.count >= 2,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 5_000,
              abs(location.timestamp.timeIntervalSinceNow) <= 30 else { return nil }

        var segmentDistances: [Double] = []
        var totalDistance = 0.0

        for index in 0..<(coordinates.count - 1) {
            let distance = geoDistance(coordinates[index], coordinates[index + 1])
            segmentDistances.append(distance)
            totalDistance += distance
        }

        guard totalDistance > 1 else { return nil }

        var bestScore = Double.greatestFiniteMagnitude
        var bestAlong = 0.0
        var cumulative = 0.0

        for index in 0..<segmentDistances.count {
            let a = coordinates[index]
            let b = coordinates[index + 1]
            let segment = segmentDistances[index]
            guard segment > 1 else { continue }

            let dAC = geoDistance(a, location.coordinate)
            let dBC = geoDistance(b, location.coordinate)
            let fraction = max(
                0,
                min(
                    1,
                    (dAC * dAC + segment * segment - dBC * dBC) /
                    (2 * segment * segment)
                )
            )
            let routeExcess = max(0, dAC + dBC - segment)

            var headingPenalty = 0.0
            if location.course >= 0 && location.courseAccuracy >= 0 {
                let routeBearing = bearing(from: a, to: b)
                let delta = angularDifference(location.course, routeBearing)
                headingPenalty = (delta / 180.0) * 350_000
            }

            let schedulePenalty: Double
            if let preferredSegment {
                schedulePenalty = preferredSegment == index ? 0 : 750_000
            } else {
                schedulePenalty = 0
            }

            let score = routeExcess + headingPenalty + schedulePenalty

            if score < bestScore {
                bestScore = score
                bestAlong = cumulative + fraction * segment
            }

            cumulative += segment
        }

        guard bestScore < 1_400_000 else { return nil }

        let progress = max(0, min(1, bestAlong / totalDistance))
        return (
            percent: Int((progress * 100).rounded()),
            remainingKM: Int(((totalDistance - bestAlong) / 1_000).rounded())
        )
    }

    private static func geoDistance(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private static func bearing(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let deltaLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func angularDifference(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(diff, 360 - diff)
    }
}

private struct OfflineAviationMapCanvas: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @AppStorage("RAIDORoster.Map.PlaceLabels") private var showsPlaceLabels = true
    let points: [TodayAirportMapPoint]
    let trail: [CLLocationCoordinate2D]
    let liveLocation: CLLocation?
    let isTracking: Bool
    let zoom: CGFloat
    let pan: CGSize
    let colorScheme: ColorScheme

    private var coordinates: [CLLocationCoordinate2D] {
        points.map(\.coordinate)
    }

    private var viewport: OfflineAviationMapViewport {
        .init(route: coordinates)
    }

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        Canvas(rendersAsynchronously: true) { context, size in
            let sea = MidnightTheme.mapSea
            let land = MidnightTheme.mapLand
            let border = MidnightTheme.mapBorder

            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(sea))

            for outline in OfflineAviationBasemap.outlines
                where outline.isVisible(viewport: viewport, size: size, zoom: zoom, pan: pan) {
                let polygon = outline.coordinates
                guard polygon.count >= 3 else { continue }
                var path = Path()
                path.move(to: viewport.point(for: polygon[0], in: size, zoom: zoom, pan: pan))
                for coordinate in polygon.dropFirst() {
                    path.addLine(
                        to: viewport.point(
                            for: coordinate,
                            in: size,
                            zoom: zoom,
                            pan: pan
                        )
                    )
                }
                path.closeSubpath()
                context.fill(path, with: .color(land))
                context.stroke(path, with: .color(border), lineWidth: 0.8)
            }

            if showsPlaceLabels {
                OfflineMapPlaces.draw(in: &context, size: size, viewport: viewport, zoom: zoom, pan: pan,
                    airports: coordinates, aircraft: isTracking ? liveLocation?.coordinate : nil)
            }

            if coordinates.count >= 2 {
                var route = Path()
                route.move(to: viewport.point(for: coordinates[0], in: size, zoom: zoom, pan: pan))
                for coordinate in coordinates.dropFirst() {
                    route.addLine(
                        to: viewport.point(
                            for: coordinate,
                            in: size,
                            zoom: zoom,
                            pan: pan
                        )
                    )
                }
                context.stroke(
                    route,
                    with: .color(Color.accentColor),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [4, 5])
                )
            }

            if trail.count >= 2 {
                var track = Path()
                track.move(to: viewport.point(for: trail[0], in: size, zoom: zoom, pan: pan))
                for coordinate in trail.dropFirst() {
                    track.addLine(
                        to: viewport.point(
                            for: coordinate,
                            in: size,
                            zoom: zoom,
                            pan: pan
                        )
                    )
                }
                context.stroke(
                    track,
                    with: .color(.green),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                )
            }

            for point in points {
                let position = viewport.point(for: point.coordinate, in: size, zoom: zoom, pan: pan)

                context.fill(
                    Path(ellipseIn: CGRect(x: position.x - 5, y: position.y - 5, width: 10, height: 10)),
                    with: .color(Color.accentColor)
                )
                context.stroke(
                    Path(ellipseIn: CGRect(x: position.x - 8, y: position.y - 8, width: 16, height: 16)),
                    with: .color(.white.opacity(0.9)),
                    lineWidth: 1.5
                )

                context.draw(
                    Text(point.code)
                        .font(.caption2.bold())
                        .foregroundStyle(.primary),
                    at: CGPoint(x: position.x, y: position.y + 17),
                    anchor: .center
                )
            }

            if isTracking, let location = liveLocation {
                let position = viewport.point(
                    for: location.coordinate,
                    in: size,
                    zoom: zoom,
                    pan: pan
                )

                context.fill(
                    Path(ellipseIn: CGRect(x: position.x - 10, y: position.y - 10, width: 20, height: 20)),
                    with: .color(.green.opacity(0.18))
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: position.x - 4, y: position.y - 4, width: 8, height: 8)),
                    with: .color(.green)
                )
            }
        }
        .background(Color.clear)
    }
}

private struct CrewCompanionPhase {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
}

private enum CrewCompanionTimeZones {
    static let airport: [String: String] = [
        "TLV": "Asia/Jerusalem",
        "BUD": "Europe/Budapest",
        "BEG": "Europe/Belgrade",
        "BUS": "Asia/Tbilisi",
        "SKG": "Europe/Athens",
        "CFU": "Europe/Athens",
        "PFO": "Asia/Nicosia",
        "LCA": "Asia/Nicosia",
        "ATH": "Europe/Athens",
        "RHO": "Europe/Athens",
        "HER": "Europe/Athens",
        "CHQ": "Europe/Athens",
        "KGS": "Europe/Athens",
        "VIE": "Europe/Vienna",
        "PRG": "Europe/Prague",
        "WAW": "Europe/Warsaw",
        "KRK": "Europe/Warsaw",
        "SOF": "Europe/Sofia",
        "OTP": "Europe/Bucharest",
        "CLJ": "Europe/Bucharest",
        "TIA": "Europe/Tirane",
        "DBV": "Europe/Zagreb",
        "SPU": "Europe/Zagreb",
        "ZAG": "Europe/Zagreb",
        "FCO": "Europe/Rome",
        "MXP": "Europe/Rome",
        "FRA": "Europe/Berlin",
        "MUC": "Europe/Berlin",
        "BER": "Europe/Berlin",
        "AMS": "Europe/Amsterdam",
        "CDG": "Europe/Paris",
        "BCN": "Europe/Madrid",
        "MAD": "Europe/Madrid",
        "LHR": "Europe/London",
        "LGW": "Europe/London",
        "MAN": "Europe/London",
        "CPH": "Europe/Copenhagen",
        "ARN": "Europe/Stockholm",
        "OSL": "Europe/Oslo",
        "HEL": "Europe/Helsinki",
        "RIX": "Europe/Riga",
        "VNO": "Europe/Vilnius",
        "TLL": "Europe/Tallinn",
        "TBS": "Asia/Tbilisi",
        "KUT": "Asia/Tbilisi",
        "EVN": "Asia/Yerevan",
        "VAR": "Europe/Sofia",
        "BOJ": "Europe/Sofia"
    ]
}

private func crewCompanionRouteCodes(_ route: String) -> [String] {
    let normalized = route
        .uppercased()
        .replacingOccurrences(of: "→", with: " ")
        .replacingOccurrences(of: "–", with: " ")
        .replacingOccurrences(of: "—", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "/", with: " ")

    return normalized
        .split(whereSeparator: { !$0.isLetter })
        .map(String.init)
        .filter { $0.count == 3 }
}

private func crewCompanionSector(_ item: RosterItem, at now: Date) -> RosterActivity? {
    if let active = item.flightActivities.first(where: { activity in
        guard let start = parseUTCStamp(activity.startUTC),
              let end = parseUTCStamp(activity.endUTC) else { return false }
        return now >= start && now < end
    }) {
        return active
    }

    if let next = item.flightActivities
        .compactMap({ activity -> (RosterActivity, Date)? in
            guard let start = parseUTCStamp(activity.startUTC), start > now else { return nil }
            return (activity, start)
        })
        .sorted(by: { $0.1 < $1.1 })
        .first?.0 {
        return next
    }

    return item.flightActivities.last
}

private func crewCompanionDestinationCode(_ item: RosterItem, at now: Date) -> String? {
    if let sector = crewCompanionSector(item, at: now) {
        let codes = crewCompanionRouteCodes(sector.route)
        if let destination = codes.last { return destination }
    }
    return crewCompanionRouteCodes(item.route).last
}

private func crewCompanionClock(_ date: Date, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private func crewCompanionCountdown(from now: Date, to target: Date) -> String {
    let interval = target.timeIntervalSince(now)
    guard interval > 0 else { return "now" }

    let minutes = max(1, Int((interval + 59) / 60))
    if minutes < 60 { return "in \(minutes)m" }

    let hours = minutes / 60
    let remainder = minutes % 60
    if hours < 24 {
        return remainder == 0 ? "in \(hours)h" : "in \(hours)h \(remainder)m"
    }

    let days = hours / 24
    let restHours = hours % 24
    return restHours == 0 ? "in \(days)d" : "in \(days)d \(restHours)h"
}

private func crewCompanionPhase(_ item: RosterItem, at now: Date) -> CrewCompanionPhase {
    if let pickup = item.preDutyPickupUTCDate, pickup > now {
        return .init(
            title: "PICKUP",
            detail: crewCompanionCountdown(from: now, to: pickup),
            systemImage: "car.fill",
            tint: .orange
        )
    }

    if let report = item.dutyStartUTCDate, report > now {
        return .init(
            title: "REPORTING",
            detail: crewCompanionCountdown(from: now, to: report),
            systemImage: "person.badge.clock",
            tint: .blue
        )
    }

    for (index, flight) in item.flightActivities.enumerated() {
        guard let start = parseUTCStamp(flight.startUTC),
              let end = parseUTCStamp(flight.endUTC) else { continue }
        if now >= start && now < end {
            return .init(
                title: item.sectorCount > 1 ? "SECTOR \(index + 1) / \(item.sectorCount)" : "IN FLIGHT",
                detail: flight.route.isEmpty ? flight.title : flight.route,
                systemImage: "airplane",
                tint: .green
            )
        }
    }

    if item.flightActivities.count >= 2 {
        for index in 0..<(item.flightActivities.count - 1) {
            let previous = item.flightActivities[index]
            let next = item.flightActivities[index + 1]
            guard let previousEnd = parseUTCStamp(previous.endUTC),
                  let nextStart = parseUTCStamp(next.startUTC),
                  now >= previousEnd,
                  now < nextStart else { continue }

            let nextRoute = next.route.isEmpty ? next.title : next.route
            return .init(
                title: "TURNAROUND",
                detail: "\(nextRoute) · \(crewCompanionCountdown(from: now, to: nextStart))",
                systemImage: "arrow.triangle.2.circlepath",
                tint: .indigo
            )
        }
    }

    if let active = item.operationalActivities.first(where: { activity in
        guard let start = parseUTCStamp(activity.startUTC),
              let end = parseUTCStamp(activity.endUTC) else { return false }
        return now >= start && now < end
    }) {
        return .init(
            title: prettyCategory(active.category),
            detail: active.route.isEmpty ? active.title : active.route,
            systemImage: active.isFlight ? "airplane" : "clock.fill",
            tint: categoryColor(active.category)
        )
    }

    if let release = item.dutyEndUTCDate, now >= release {
        return .init(
            title: "DUTY COMPLETE",
            detail: item.releaseLocal.isEmpty ? "" : "Released \(item.releaseLocal)",
            systemImage: "checkmark.circle.fill",
            tint: .green
        )
    }

    return .init(
        title: prettyCategory(item.category),
        detail: item.route,
        systemImage: item.sectorCount > 0 ? "airplane" : "clock",
        tint: categoryColor(item.category)
    )
}

private struct CrewCompanionRolePicker: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let dutyID: String
    let sectorID: String

    @AppStorage private var role: String

    init(dutyID: String, sectorID: String) {
        self.dutyID = dutyID
        self.sectorID = sectorID
        self._role = AppStorage(
            wrappedValue: "",
            "RAIDORoster.CrewRole." + dutyID + "." + sectorID
        )
    }

    private let roles = ["SCCM", "Deputy", "CC2", "CC3", "CC4", "CC5", "CC6"]

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        Menu {
            ForEach(roles, id: \.self) { option in
                Button {
                    role = option
                } label: {
                    HStack {
                        Text(option)
                        if role == option { Image(systemName: "checkmark") }
                    }
                }
            }

            if !role.isEmpty {
                Divider()
                Button("Clear role", role: .destructive) {
                    role = ""
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.text.rectangle")
                Text(role.isEmpty ? "Set role" : role)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(role.isEmpty ? "Set crew role for this sector" : "Crew role \(role)")
    }
}

struct CrewCompanionContextCard: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        TimelineView(.periodic(from: .now, by: 60)) { context in
            let phase = crewCompanionPhase(item, at: context.date)
            let sector = crewCompanionSector(item, at: context.date)
            let destinationCode = crewCompanionDestinationCode(item, at: context.date)
            let destinationZone = destinationCode
                .flatMap { CrewCompanionTimeZones.airport[$0] }
                .flatMap { TimeZone(identifier: $0) }

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: phase.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(phase.tint)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase.title)
                            .font(.caption.bold())
                            .foregroundStyle(phase.tint)
                        if !phase.detail.isEmpty {
                            Text(phase.detail)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                    }

                    Spacer(minLength: 6)

                    if let sector {
                        CrewCompanionRolePicker(dutyID: item.id, sectorID: sector.id)
                            .id(sector.id)
                    }
                }

                Divider()

                HStack(spacing: 0) {
                    CrewCompanionClockCell(
                        label: "LOCAL",
                        value: crewCompanionClock(context.date, timeZone: .current)
                    )

                    Divider().frame(height: 27)

                    if let destinationCode, let destinationZone {
                        CrewCompanionClockCell(
                            label: destinationCode,
                            value: crewCompanionClock(context.date, timeZone: destinationZone)
                        )
                        Divider().frame(height: 27)
                    }

                    CrewCompanionClockCell(
                        label: "UTC",
                        value: crewCompanionClock(
                            context.date,
                            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
                        )
                    )
                }
            }
            .padding(13)
            .midnightCard(radius: 16)
        }
    }
}

private struct CrewCompanionClockCell: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let label: String
    let value: String

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct TodayPersonalNoteDisclosure: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem
    @State private var isExpanded = false
    @AppStorage private var storedNote: String

    init(item: RosterItem) {
        self.item = item
        self._storedNote = AppStorage(
            wrappedValue: "",
            "RAIDORoster.PersonalNote." + item.id
        )
    }

    private var hasStoredNote: Bool {
        !storedNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                    Text("My note")
                        .fontWeight(.semibold)
                    Spacer(minLength: 8)
                    Text(isExpanded ? "Hide" : (hasStoredNote ? "Added" : "View"))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide my note" : (hasStoredNote ? "Open existing my note" : "Add my note"))

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    PersonalDutyNoteCard(item: item)
                    Text("Stored only on this iPhone. Avoid sensitive passenger information.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .sensoryFeedback(.selection, trigger: isExpanded)
    }
}

struct DutyBriefingView: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem
    let showTechnical: Bool
    var showHero = true

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(alignment: .leading, spacing: showTechnical ? 16 : 14) {
            if showHero { DutyHeroCard(item: item) }

            if !showTechnical, item.isOperationalDuty {
                CrewCompanionContextCard(item: item)
            }

            if !showTechnical, TodayRouteMapCard.canDisplay(item) {
                TodayRouteMapCard(item: item)
            }

            if !showTechnical {
                TodayPersonalNoteDisclosure(item: item)
            }

            if item.isOperationalDuty, !item.operationalActivities.isEmpty {
                DutyLiveStatusCard(item: item)

                if showTechnical {
                    DutyMetricsGrid(item: item)
                    BriefingSectionTitle("Duty timeline")
                    DutyTimelineCard(item: item)
                } else {
                    TodayPrimaryTimingRow(item: item)
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


struct DutyLiveStatusCard: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

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
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
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
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                TodayTimelineRow(entry: entry, isLast: index == entries.count - 1)
            }
        }
        .padding(.horizontal, 13)
        .midnightCard(radius: 17)
    }
}

private struct TodayTimelineRow: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let entry: TodayTimelineEntry
    let isLast: Bool

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

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

struct DutyMetricsGrid: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem

    var metrics: [(String, String)] {
        var values: [(String, String)] = []
        if !item.reportLocal.isEmpty { values.append(("REPORT", item.reportLocal)) }
        if !item.releaseLocal.isEmpty { values.append(("RELEASE", item.releaseLocal)) }
        if !item.dutyDuration.isEmpty { values.append(("DUTY", item.dutyDuration)) }
        if item.sectorCount > 0 { values.append(("SECTORS", "\(item.sectorCount)")) }
        return values
    }

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                VStack(spacing: 4) {
                    Text(metric.1).font(.headline.monospacedDigit())
                    Text(metric.0).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .midnightCard(radius: 12)
            }
        }
    }
}

struct DutyTimelineCard: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(spacing: 0) {
            if let first = item.operationalActivities.first, !first.localCheckInTime.isEmpty {
                TimelinePoint(time: first.localCheckInTime, title: "Check-in", subtitle: first.station, icon: "person.badge.clock")
                Divider().padding(.leading, 74)
            }

            ForEach(item.operationalActivities) { activity in
                TimelinePoint(
                    time: activity.localStartTime,
                    title: activity.title,
                    subtitle: activity.route.isEmpty ? activity.description : activity.route,
                    trailing: activity.localEndTime,
                    icon: activity.isFlight ? "airplane" : timelineIcon(activity.category)
                )
                if activity.id != item.operationalActivities.last?.id {
                    Divider().padding(.leading, 74)
                }
            }

            if let last = item.operationalActivities.last, !last.localCheckOutTime.isEmpty {
                Divider().padding(.leading, 74)
                TimelinePoint(time: last.localCheckOutTime, title: "Check-out", subtitle: "", icon: "checkmark.circle")
            }
        }
        .midnightCard(radius: 16)
    }
}

struct TimelinePoint: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let time: String
    let title: String
    let subtitle: String
    var trailing: String = ""
    let icon: String

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        HStack(alignment: .top, spacing: 12) {
            Text(time)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(width: 52, alignment: .leading)
            Image(systemName: icon)
                .font(.subheadline)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !trailing.isEmpty {
                Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(13)
    }
}


private struct HotelDisplayRow: Identifiable {
    let id: String
    let title: String
    let value: String
}

private func groupedHotelDisplayRows(_ hotels: [RosterActivity]) -> [HotelDisplayRow] {
    var order: [String] = []
    var titles: [String: String] = [:]
    var ranges: [String: [String]] = [:]

    for hotel in hotels {
        let title = (hotel.hotelName.isEmpty ? hotel.title : hotel.hotelName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = title.lowercased()
        guard !key.isEmpty else { continue }

        if titles[key] == nil {
            order.append(key)
            titles[key] = title
            ranges[key] = []
        }

        let range = hotelRange(hotel)
        if !range.isEmpty, !(ranges[key] ?? []).contains(range) {
            ranges[key, default: []].append(range)
        }
    }

    return order.map { key in
        HotelDisplayRow(
            id: key,
            title: titles[key] ?? "Hotel",
            value: (ranges[key] ?? []).joined(separator: "\n")
        )
    }
}

struct LogisticsCard: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(alignment: .leading, spacing: 14) {
            ForEach(item.pickups, id: \.self) { pickup in
                InfoRow(icon: "car.fill", title: "Pickup", value: pickup)
            }

            ForEach(groupedHotelDisplayRows(item.hotelAssignments)) { hotel in
                InfoRow(
                    icon: "bed.double.fill",
                    title: hotel.title,
                    value: hotel.value
                )
            }

            ForEach(item.activityList.filter { $0.category.uppercased() == "RELOCATION" }, id: \.id) { relocation in
                InfoRow(icon: "arrow.left.arrow.right", title: "Hotel relocation", value: relocation.timeText)
            }

            ForEach(item.transferNotes, id: \.self) { note in
                Divider()
                Label("Transfer note", systemImage: "car.side.fill")
                    .font(.subheadline.weight(.semibold))
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(15)
        .midnightCard(radius: 16)
    }
}

struct NotesCard: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(alignment: .leading, spacing: 14) {
            ForEach(item.dayNotes, id: \.self) { note in
                NoteBlock(title: "Day note", icon: "calendar.badge.exclamationmark", text: note)
            }
            ForEach(item.activityNotes, id: \.self) { note in
                NoteBlock(title: "Activity note", icon: "note.text", text: note)
            }
        }
        .padding(15)
        .midnightCard(radius: 16)
    }
}

struct NoteBlock: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let title: String
    let icon: String
    let text: String

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
            Text(text).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}


enum DutyOperator: String, Equatable {
    case getjet = "GETJET"
    case airhub = "AIRHUB"
    case verify = "VERIFY"

    var systemImage: String {
        switch self {
        case .getjet, .airhub: return "airplane.circle.fill"
        case .verify: return "questionmark.circle.fill"
        }
    }
}

struct OperatorResolver {
    static func resolve(registration: String) -> DutyOperator {
        let upper = registration.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = upper
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")

        if compact == "9HGTS" { return .airhub }
        if compact.hasPrefix("LY") { return .getjet }
        return .verify
    }
}

private func aircraftTypeLabel(_ value: String) -> String {
    let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !raw.isEmpty else { return "" }
    let compact = raw.replacingOccurrences(of: " ", with: "")

    if compact.hasPrefix("A") || compact.hasPrefix("B") { return raw }
    if ["318", "319", "320", "321", "330", "340", "350", "380"].contains(compact) {
        return "A" + compact
    }
    if compact.hasPrefix("73") || compact.hasPrefix("7M") {
        return "B" + compact
    }
    return raw
}

struct OperatorBadge: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let value: DutyOperator

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        Label(value.rawValue, systemImage: value.systemImage)
            .font(.caption.bold())
            .foregroundStyle(value == .verify ? Color.orange : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                (value == .verify ? Color.orange : Color.secondary).opacity(0.11),
                in: Capsule()
            )
    }
}

struct AircraftCard: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(alignment: .leading, spacing: 12) {
            ForEach(item.aircraft) { aircraft in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "airplane.circle.fill").font(.title2)
                    VStack(alignment: .leading, spacing: 7) {
                        OperatorBadge(value: OperatorResolver.resolve(registration: aircraft.aircraftReg))

                        let details = [
                            aircraftTypeLabel(aircraft.aircraftType),
                            aircraft.aircraftReg,
                            aircraft.aircraftVersion
                        ].filter { !$0.isEmpty }

                        Text(details.isEmpty ? "Aircraft" : details.joined(separator: " • "))
                            .font(.headline)

                        if !aircraft.aircraftPhone.isEmpty {
                            Text("A/C phone \(aircraft.aircraftPhone)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(15)
        .midnightCard(radius: 16)
    }
}

struct CrewCard: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem
    @State private var expandedCrewID: String?

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(spacing: 0) {
            ForEach(Array(item.crewMembers.enumerated()), id: \.offset) { index, member in
                VStack(spacing: 0) {
                    Button {
                        guard hasPhone(member) else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            expandedCrewID = expandedCrewID == member.id ? nil : member.id
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(member.role)
                                .font(.caption.bold())
                                .frame(width: 38)
                                .padding(.vertical, 5)
                                .background(Color.secondary.opacity(0.12), in: Capsule())

                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                if !member.code.isEmpty {
                                    Text(member.code)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            if let country = member.country, !country.isEmpty {
                                Text(country)
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.10), in: Capsule())
                                    .accessibilityLabel("Phone country \(country)")
                            }

                            if hasPhone(member) {
                                Image(systemName: expandedCrewID == member.id ? "chevron.up" : "chevron.down")
                                    .font(.caption.bold())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 14)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(hasPhone(member) ? "Shows crew contact options" : "")

                    if expandedCrewID == member.id,
                       let phone = member.phone?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !phone.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Divider()

                            HStack(spacing: 10) {
                                Image(systemName: "phone.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Phone")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(phone)
                                        .font(.subheadline.monospacedDigit().weight(.medium))
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                            }

                            HStack(spacing: 8) {
                                Button {
                                    openCrewWhatsApp(phone)
                                } label: {
                                    Label("WA", systemImage: "message.fill")
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity)
                                }
                                .raidoPrimaryAction()

                                Button {
                                    callCrew(phone)
                                } label: {
                                    Label("Call", systemImage: "phone.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    UIPasteboard.general.string = phone
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .frame(minWidth: 28)
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Copy crew phone number")
                            }

                        }
                        .padding(.leading, 50)
                        .padding(.bottom, 11)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                if index < item.crewMembers.count - 1 {
                    Divider().padding(.leading, 50)
                }
            }
        }
        .padding(.horizontal, 15)
        .midnightCard(radius: 16)
    }

    private func hasPhone(_ member: CrewMember) -> Bool {
        !(member.phone?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func phoneDigits(_ phone: String) -> String {
        phone.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
    }

    private func openCrewWhatsApp(_ phone: String) {
        let digits = phoneDigits(phone)
        guard digits.count >= 8,
              let url = URL(string: "https://wa.me/\(digits)") else { return }
        UIApplication.shared.open(url)
    }

    private func callCrew(_ phone: String) {
        let digits = phoneDigits(phone)
        guard digits.count >= 6,
              let url = URL(string: "tel:+\(digits)") else { return }
        UIApplication.shared.open(url)
    }
}

struct InfoRow: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let icon: String
    let title: String
    let value: String

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                if !value.isEmpty { Text(value).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
        }
    }
}

struct BriefingSectionTitle: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme
 Text(text).font(.headline).padding(.top, 2) }
}

struct PortalView: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @ObservedObject var model: RosterBrowserModel
    @ObservedObject var store: RosterStore
    let openRoster: () -> Void

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        NavigationStack {
            ZStack {
                RosterWebView(model: model).ignoresSafeArea(edges: .bottom)

                if let error = model.loadError {
                    MidnightTheme.background.ignoresSafeArea()
                    VStack(spacing: 14) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("RAIDO unavailable offline").font(.title3.bold())
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        if let date = store.lastSync {
                            Text("Offline roster saved \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if store.hasCache {
                            Button("View Offline Roster", action: openRoster).raidoPrimaryAction()
                        }
                        Button("Try RAIDO Again") { model.reload() }.buttonStyle(.bordered)
                    }
                    .padding(28)
                }
            }
            .midnightCanvas().navigationTitle(model.pageTitle.isEmpty ? "Live RAIDO" : model.pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Done", action: openRoster)
                    Button { model.goBack() } label: { Image(systemName: "chevron.backward") }
                        .disabled(!model.canGoBack)
                    Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
    }
}


enum CompanyContacts {
    static let crewControlDisplay = "+370 688 38250"
    static let crewControlPhone = "+37068838250"
    static let crewControlWhatsApp = "37068838250"
    static let crewControlEmail = "crewcontrol@getjet.aero"
}

enum CrewControlTemplate: String, CaseIterable, Identifiable {
    case roster = "Roster clarification"
    case pickup = "Pickup / transport"
    case hotel = "Hotel issue"
    case standby = "Standby / reserve"
    case operational = "Operational issue"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .roster: return "calendar.badge.questionmark"
        case .pickup: return "car.fill"
        case .hotel: return "bed.double.fill"
        case .standby: return "clock.badge.questionmark"
        case .operational: return "exclamationmark.triangle.fill"
        }
    }
}

struct CrewControlSheet: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("24/7 Crew Control")
                            .font(.title3.bold())
                        Text(CompanyContacts.crewControlDisplay)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button {
                            openWhatsApp(message: nil)
                        } label: {
                            Label("WhatsApp", systemImage: "message.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .raidoPrimaryAction()

                        Button {
                            openURL("tel:\(CompanyContacts.crewControlPhone)")
                        } label: {
                            Image(systemName: "phone.fill").frame(minWidth: 28)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Call Crew Control")

                        Button {
                            openURL("mailto:\(CompanyContacts.crewControlEmail)")
                        } label: {
                            Image(systemName: "envelope.fill").frame(minWidth: 28)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Email Crew Control")
                    }

                    if let item {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("CURRENT / NEXT DUTY")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)

                            if let aircraft = item.aircraft.first {
                                HStack(spacing: 8) {
                                    OperatorBadge(value: OperatorResolver.resolve(registration: aircraft.aircraftReg))
                                    let details = [aircraftTypeLabel(aircraft.aircraftType), aircraft.aircraftReg]
                                        .filter { !$0.isEmpty }
                                    if !details.isEmpty {
                                        Text(details.joined(separator: " • "))
                                            .font(.subheadline.weight(.semibold))
                                    }
                                }
                            }

                            Text(item.displayTitle).font(.headline)
                            if !item.route.isEmpty {
                                Label(item.route, systemImage: "airplane").font(.subheadline)
                            }
                            let timing = [
                                item.dateText,
                                item.reportLocal.isEmpty ? "" : "CI \(item.reportLocal)"
                            ].filter { !$0.isEmpty }
                            if !timing.isEmpty {
                                Text(timing.joined(separator: " • "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .midnightCard(radius: 16)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quick WhatsApp").font(.headline)

                        ForEach(CrewControlTemplate.allCases) { template in
                            Button {
                                openWhatsApp(message: message(for: template))
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: template.systemImage).frame(width: 24)
                                    Text(template.rawValue).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)

                            if template.id != CrewControlTemplate.allCases.last?.id {
                                Divider().padding(.leading, 36)
                            }
                        }
                    }
                    .padding(14)
                    .midnightCard(radius: 16)

                    Text("Quick messages open Crew Control in WhatsApp with duty context pre-filled. Review and send the message in WhatsApp.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .midnightCanvas().navigationTitle("Crew Control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func message(for template: CrewControlTemplate) -> String {
        let context = dutyContext
        switch template {
        case .roster:
            return "Hi Crew Control,\n\nRegarding \(context):\n\nCould you please clarify the roster details?"
        case .pickup:
            if let pickup = item?.pickups.first, !pickup.isEmpty {
                return "Hi Crew Control,\n\nRegarding \(context), my roster shows pickup: \(pickup).\n\nCould you please confirm the transport?"
            }
            return "Hi Crew Control,\n\nRegarding \(context):\n\nCould you please assist with the pickup / transport details?"
        case .hotel:
            if let hotel = item?.hotelAssignments.first {
                let name = hotel.hotelName.isEmpty ? hotel.title : hotel.hotelName
                if !name.isEmpty {
                    return "Hi Crew Control,\n\nRegarding \(context), my roster shows \(name).\n\nCould you please assist with the hotel arrangement?"
                }
            }
            return "Hi Crew Control,\n\nRegarding \(context):\n\nCould you please assist with the hotel arrangement?"
        case .standby:
            return "Hi Crew Control,\n\nRegarding \(context):\n\nCould you please clarify my standby / reserve assignment?"
        case .operational:
            return "Hi Crew Control,\n\nRegarding \(context):\n\nI need assistance with an operational issue."
        }
    }

    private var dutyContext: String {
        guard let item else { return "my current roster" }
        var parts: [String] = []
        if !item.dateText.isEmpty { parts.append(item.dateText) }
        if !item.displayTitle.isEmpty { parts.append(item.displayTitle) }
        if !item.route.isEmpty { parts.append(item.route) }
        if !item.reportLocal.isEmpty { parts.append("CI \(item.reportLocal)") }
        if let aircraft = item.aircraft.first {
            let op = OperatorResolver.resolve(registration: aircraft.aircraftReg)
            if op != .verify { parts.append(op.rawValue) }
            let aircraftText = [aircraftTypeLabel(aircraft.aircraftType), aircraft.aircraftReg]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !aircraftText.isEmpty { parts.append(aircraftText) }
        }
        return parts.isEmpty ? "my current roster" : parts.joined(separator: " • ")
    }

    private func openWhatsApp(message: String?) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "wa.me"
        components.path = "/" + CompanyContacts.crewControlWhatsApp
        if let message, !message.isEmpty {
            components.queryItems = [URLQueryItem(name: "text", value: message)]
        }
        if let url = components.url { UIApplication.shared.open(url) }
    }

    private func openURL(_ value: String) {
        guard let url = URL(string: value) else { return }
        UIApplication.shared.open(url)
    }
}


private struct FleetAircraftDefinition: Identifiable, Hashable {
    let registration: String
    let type: String
    let operatorName: String
    let operatorCode: String
    let seats: String

    var id: String { registration }

    static let all: [FleetAircraftDefinition] = [
        .init(registration: "LY-CAP", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-DAE", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-EKB", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-FAS", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-GYM", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-MAL", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-NOW", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-TAP", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-TEN", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-WIL", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-WIZ", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-WSA", type: "A321", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-CIN", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-DUE", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-SEI", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-TUI", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-UNO", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "9H-GTS", type: "A320", operatorName: "Airhub Airlines", operatorCode: "AIRHUB", seats: "")
    ]
}

private struct FleetLiveSnapshot: Codable, Identifiable {
    let registration: String
    let callsign: String?
    let route: String?
    let latitude: Double?
    let longitude: Double?
    let altitudeFeet: Double?
    let groundSpeedKnots: Double?
    let trackDegrees: Double?
    let onGround: Bool
    let sourceSeenSeconds: Double
    let fetchedAt: Date
    let icaoHex: String?
    let seenPositionSeconds: Double?
    let nacP: Int?
    let nic: Int?
    let radiusContainmentMeters: Double?
    var sourceReferenceAt: Date? = nil
    var groundStateKnown: Bool? = nil
    var verticalRateFeetPerMinute: Double? = nil
    var providerName: String? = nil
    var hasKnownGroundState: Bool { groundStateKnown ?? (onGround || altitudeFeet != nil) }

    var id: String { registration }

    var hasPosition: Bool {
        FleetTrackingPolicy.validCoordinate(latitude: latitude, longitude: longitude)
    }

    var observationAge: TimeInterval {
        FleetTrackingPolicy.age(referenceAt: sourceReferenceAt ?? fetchedAt,
                                seconds: sourceSeenSeconds, now: Date())
    }

    var effectivePositionAge: TimeInterval {
        FleetTrackingPolicy.positionAge(referenceAt: sourceReferenceAt ?? fetchedAt,
                                        messageAge: sourceSeenSeconds,
                                        positionAge: seenPositionSeconds, now: Date())
    }

    var positionQualityText: String {
        if let rc = radiusContainmentMeters, rc > 0 {
            return rc < 1000 ? "Containment \(Int(rc.rounded())) m" : "Containment \(String(format: "%.1f", rc / 1000)) km"
        }
        if let nacP {
            switch nacP {
            case 11: return "< 3 m"
            case 10: return "< 10 m"
            case 9: return "< 30 m"
            case 8: return "< 92 m"
            case 7: return "< 185 m"
            case 6: return "< 556 m"
            case 5: return "< 0.93 km"
            default: break
            }
        }
        return "Unknown accuracy"
    }

    var isFresh: Bool { hasPosition && effectivePositionAge <= 120 }
    var isRecent: Bool { hasPosition && effectivePositionAge <= 900 }
    var isStale: Bool { effectivePositionAge > 900 }

    var isAirborne: Bool {
        hasKnownGroundState && !onGround
    }
}


private struct FleetTrackObservation: Codable, Identifiable {
    let registration: String
    let callsign: String?
    let route: String?
    let latitude: Double?
    let longitude: Double?
    let altitudeFeet: Double?
    let groundSpeedKnots: Double?
    let trackDegrees: Double?
    let onGround: Bool
    let observedAt: Date
    var groundStateKnown: Bool? = nil

    var id: String {
        "\(registration)|\(Int(observedAt.timeIntervalSince1970))"
    }
}

private enum FleetFlightPhase: String {
    case unknown = "Unknown"
    case onGround = "On ground"
    case departing = "Departing"
    case climbing = "Climbing"
    case cruise = "Cruise"
    case descending = "Descending"
    case arriving = "Arriving"
    case airborne = "Airborne"
}

private struct FleetAirportReference {
    let code: String
    let latitude: Double
    let longitude: Double

    static let common: [FleetAirportReference] = [
        .init(code: "TLV", latitude: 32.0005, longitude: 34.8708),
        .init(code: "AUH", latitude: 24.4330, longitude: 54.6511),
        .init(code: "DXB", latitude: 25.2532, longitude: 55.3657),
        .init(code: "LCA", latitude: 34.8751, longitude: 33.6249),
        .init(code: "FCO", latitude: 41.8003, longitude: 12.2389),
        .init(code: "ATH", latitude: 37.9364, longitude: 23.9445),
        .init(code: "BEG", latitude: 44.8184, longitude: 20.3091),
        .init(code: "VNO", latitude: 54.6341, longitude: 25.2858),
        .init(code: "RIX", latitude: 56.9236, longitude: 23.9711),
        .init(code: "KUN", latitude: 54.9639, longitude: 24.0848),
        .init(code: "WAW", latitude: 52.1657, longitude: 20.9671),
        .init(code: "VIE", latitude: 48.1103, longitude: 16.5697),
        .init(code: "BER", latitude: 52.3667, longitude: 13.5033),
        .init(code: "CDG", latitude: 49.0097, longitude: 2.5479),
        .init(code: "AMS", latitude: 52.3105, longitude: 4.7683),
        .init(code: "LHR", latitude: 51.4700, longitude: -0.4543)
    ]
}

private struct FleetAircraftIntelligence {
    let phase: FleetFlightPhase
    let currentRoute: String?
    let previousRoute: String?
    let nearestAirport: String?
    let lastDepartureAt: Date?
    let lastArrivalAt: Date?
    let turnaroundSeconds: TimeInterval?
    let observationCount: Int
}

private func fleetDistanceMeters(
    latitude1: Double,
    longitude1: Double,
    latitude2: Double,
    longitude2: Double
) -> Double {
    let a = CLLocation(latitude: latitude1, longitude: longitude1)
    let b = CLLocation(latitude: latitude2, longitude: longitude2)
    return a.distance(from: b)
}

private struct ADSBLOLResponse: Decodable {
    let ac: [ADSBLOLAircraft]
    let now: Double?
}

private enum FleetProviderError: Error {
    case http(Int)
    case rateLimited(TimeInterval)
    case identityMismatch
}

private struct ADSBLOLAircraft: Decodable {
    let registration: String?
    let verticalRate: Double?
    let groundStateKnown: Bool
    let hex: String?
    let flight: String?
    let lat: Double?
    let lon: Double?
    let gs: Double?
    let track: Double?
    let seen: Double
    let seenPos: Double?
    let nacP: Int?
    let nic: Int?
    let rc: Double?
    let altitudeFeet: Double?
    let onGround: Bool

    enum CodingKeys: String, CodingKey {
        case hex, flight, lat, lon, gs, track, seen, nic, rc
        case registration = "r"
        case verticalRate = "baro_rate"
        case seenPos = "seen_pos"
        case nacP = "nac_p"
        case altBaro = "alt_baro"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        registration = try? container.decodeIfPresent(String.self, forKey: .registration)
        verticalRate = try? container.decodeIfPresent(Double.self, forKey: .verticalRate)
        hex = try? container.decodeIfPresent(String.self, forKey: .hex)
        flight = try container.decodeIfPresent(String.self, forKey: .flight)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lat = try container.decodeIfPresent(Double.self, forKey: .lat)
        lon = try container.decodeIfPresent(Double.self, forKey: .lon)
        gs = try container.decodeIfPresent(Double.self, forKey: .gs)
        track = try container.decodeIfPresent(Double.self, forKey: .track)
        seen = (try? container.decode(Double.self, forKey: .seen)) ?? 31_536_000
        seenPos = try? container.decodeIfPresent(Double.self, forKey: .seenPos)
        nacP = try? container.decodeIfPresent(Int.self, forKey: .nacP)
        nic = try? container.decodeIfPresent(Int.self, forKey: .nic)
        rc = try? container.decodeIfPresent(Double.self, forKey: .rc)

        if let numeric = try? container.decode(Double.self, forKey: .altBaro) {
            altitudeFeet = numeric.isFinite ? numeric : nil
            groundStateKnown = numeric.isFinite
            onGround = false
        } else if let value = try? container.decode(String.self, forKey: .altBaro) {
            altitudeFeet = nil
            onGround = value.lowercased() == "ground"
            groundStateKnown = onGround
        } else {
            altitudeFeet = nil
            groundStateKnown = false
            onGround = false
        }
    }
}

private struct ADSBLOLRouteRequest: Encodable {
    struct Plane: Encodable {
        let callsign: String
        let lat: Double
        let lng: Double
    }
    let planes: [Plane]
}

private struct ADSBLOLRouteResult: Decodable {
    let callsign: String
    let airportCodes: String?
    let plausible: Bool?

    enum CodingKeys: String, CodingKey {
        case callsign
        case iataAirportCodes = "_airport_codes_iata"
        case airportCodes = "airport_codes"
        case plausible
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callsign = (try? container.decode(String.self, forKey: .callsign)) ?? ""
        let iata = try? container.decodeIfPresent(String.self, forKey: .iataAirportCodes)
        let icao = try? container.decodeIfPresent(String.self, forKey: .airportCodes)
        airportCodes = (iata ?? nil) ?? (icao ?? nil)

        if let bool = try? container.decode(Bool.self, forKey: .plausible) {
            plausible = bool
        } else if let number = try? container.decode(Int.self, forKey: .plausible) {
            plausible = number != 0
        } else {
            plausible = nil
        }
    }
}


private struct FleetProviderSpec {
    let name: String
    let baseURL: String
    let registrationPath: String
    let hexPath: String
}

private enum FleetProviderFetchResult {
    case snapshot(FleetLiveSnapshot)
    case empty
    case failed
}

@MainActor
private final class FleetLiveStore: ObservableObject {
    @Published private(set) var snapshots: [String: FleetLiveSnapshot] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var errorText: String?
    @Published private(set) var histories: [String: [FleetTrackObservation]] = [:]

    private let cacheKey = "RAIDORoster.FleetLiveCache.V1"
    private let historyCacheKey = "RAIDORoster.FleetHistory.V2"
    private let maximumHistoryPerAircraft = 720
    private var retryAfter: Date?
    private var providerRetryAfter: [String: Date] = [:]
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private let session: URLSession
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }
    private var intelligenceCache: [String: FleetAircraftIntelligence] = [:]
    private var intelligenceBucket = -1
    private var cacheApplied = false
    private let cacheLoad: Task<([FleetLiveSnapshot], [String: [FleetTrackObservation]]), Never>
    private let cacheWriter = FleetCacheWriter()

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
        cacheLoad = Task.detached(priority: .utility) {
            let defaults = UserDefaults.standard
            let decoder = JSONDecoder()
            let values = defaults.data(forKey: "RAIDORoster.FleetLiveCache.V1")
                .flatMap { try? decoder.decode([FleetLiveSnapshot].self, from: $0) } ?? []
            let history = defaults.data(forKey: "RAIDORoster.FleetHistory.V2")
                .flatMap { try? decoder.decode([String: [FleetTrackObservation]].self, from: $0) } ?? [:]
            return (values, history)
        }
        Task { [weak self] in await self?.loadCache() }
    }

    func refresh(definitions: [FleetAircraftDefinition] = FleetAircraftDefinition.all) async {
        await loadCache()
        // A view-owned manual restart cancels the previous pass. Wait for its
        // cooperative requests to unwind before acquiring the refresh slot.
        while isRefreshing {
            do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return }
        }
        guard !Task.isCancelled, retryAfter.map({ Date() >= $0 }) ?? true else { return }
        isRefreshing = true
        errorText = nil
        defer { isRefreshing = false }

        var fresh: [String: FleetLiveSnapshot] = [:]
        var activeForRoutes: [(registration: String, callsign: String, lat: Double, lon: Double)] = []
        var failures = 0
        var pending: [String: FleetLiveSnapshot] = [:]
        var lastPublish = Date.distantPast
        let report = await FleetRefreshPolicy.run(definitions, operation: { definition in
            do { return (definition.registration, try await self.fetchAircraft(definition.registration), false) }
            catch { return (definition.registration, nil, !Task.isCancelled) }
        }, receive: { result in
            let (registration, snapshot, failed) = result
            if failed { failures += 1 }
            if let snapshot {
                fresh[registration] = snapshot
                pending[registration] = snapshot
                if let callsign = snapshot.callsign, let lat = snapshot.latitude, let lon = snapshot.longitude,
                   !callsign.isEmpty { activeForRoutes.append((registration, callsign, lat, lon)) }
                if Date().timeIntervalSince(lastPublish) >= 1 {
                    self.publish(pending); pending.removeAll(); lastPublish = Date()
                }
            }
        })
        guard !Task.isCancelled else { return }
        publish(pending)

        if !report.timedOut, !Task.isCancelled, !activeForRoutes.isEmpty,
           let routes = try? await fetchRoutes(activeForRoutes) {
            for (registration, route) in routes {
                guard let old = fresh[registration] else { continue }
                fresh[registration] = FleetLiveSnapshot(
                    registration: old.registration,
                    callsign: old.callsign,
                    route: route,
                    latitude: old.latitude,
                    longitude: old.longitude,
                    altitudeFeet: old.altitudeFeet,
                    groundSpeedKnots: old.groundSpeedKnots,
                    trackDegrees: old.trackDegrees,
                    onGround: old.onGround,
                    sourceSeenSeconds: old.sourceSeenSeconds,
                    fetchedAt: old.fetchedAt,
                    icaoHex: old.icaoHex,
                    seenPositionSeconds: old.seenPositionSeconds,
                    nacP: old.nacP,
                    nic: old.nic,
                    radiusContainmentMeters: old.radiusContainmentMeters,
                    sourceReferenceAt: old.sourceReferenceAt,
                    groundStateKnown: old.groundStateKnown,
                    verticalRateFeetPerMinute: old.verticalRateFeetPerMinute,
                    providerName: old.providerName
                )
            }
        }

        guard !Task.isCancelled else { return }
        recordFreshHistory(fresh)

        publish(fresh)
        lastRefresh = Date()
        let savedSnapshots = Array(snapshots.values), savedHistories = histories
        await cacheWriter.save(snapshots: savedSnapshots, histories: savedHistories)
        guard !Task.isCancelled else { return }
        if report.timedOut {
            errorText = "Refresh timed out · showing available observations. Tap refresh to retry."
        } else if failures > 0 {
            errorText = failures == definitions.count ? "Live fleet data unavailable" : "Some aircraft could not be refreshed"
        }
    }

    private func publish(_ fresh: [String: FleetLiveSnapshot]) {
        guard !fresh.isEmpty else { return }
        var merged = snapshots
        for (registration, snapshot) in fresh { merged[registration] = snapshot }
        intelligenceCache.removeAll()
        snapshots = merged
    }

    func snapshot(for registration: String) -> FleetLiveSnapshot? {
        snapshots[registration]
    }

    func history(for registration: String) -> [FleetTrackObservation] {
        histories[registration] ?? []
    }

    func intelligence(for registration: String) -> FleetAircraftIntelligence? {
        let bucket = Int(Date().timeIntervalSince1970 / 15)
        if bucket != intelligenceBucket { intelligenceCache.removeAll(); intelligenceBucket = bucket }
        if let cached = intelligenceCache[registration] { return cached }
        guard let snapshot = snapshots[registration] else { return nil }
        let history = histories[registration] ?? []
        let recent = Array(history.suffix(20))

        let phase = snapshot.isFresh && snapshot.hasKnownGroundState
            ? inferredPhase(snapshot: snapshot, history: recent) : .unknown
        let currentRoute = snapshot.route?.nilIfEmpty
        let previousRoute = history.reversed().compactMap(\.route).first(where: {
            guard let currentRoute else { return true }
            return $0 != currentRoute
        })

        var lastDepartureAt: Date?
        var lastArrivalAt: Date?
        if history.count >= 2 {
            for pair in zip(history, history.dropFirst()) {
                guard FleetTrackingPolicy.canInferTransition(
                    previousAt: pair.0.observedAt, currentAt: pair.1.observedAt,
                    previousKnown: pair.0.groundStateKnown == true,
                    currentKnown: pair.1.groundStateKnown == true,
                    previousCallsign: pair.0.callsign, currentCallsign: pair.1.callsign
                ) else { continue }
                if pair.0.onGround && !pair.1.onGround {
                    lastDepartureAt = pair.1.observedAt
                }
                if !pair.0.onGround && pair.1.onGround {
                    lastArrivalAt = pair.1.observedAt
                }
            }
        }

        var nearestAirport: String?
        if let lat = snapshot.latitude, let lon = snapshot.longitude {
            let nearest = FleetAirportReference.common
                .map { ($0, fleetDistanceMeters(latitude1: lat, longitude1: lon, latitude2: $0.latitude, longitude2: $0.longitude)) }
                .min { $0.1 < $1.1 }
            if let nearest, nearest.1 <= 25_000 {
                nearestAirport = nearest.0.code
            }
        }

        let turnaround: TimeInterval?
        if snapshot.isFresh, snapshot.onGround, let arrival = lastArrivalAt,
           lastDepartureAt.map({ arrival > $0 }) ?? true {
            turnaround = max(0, Date().timeIntervalSince(arrival))
        } else {
            turnaround = nil
        }

        let value = FleetAircraftIntelligence(
            phase: phase,
            currentRoute: currentRoute,
            previousRoute: previousRoute,
            nearestAirport: nearestAirport,
            lastDepartureAt: lastDepartureAt,
            lastArrivalAt: lastArrivalAt,
            turnaroundSeconds: turnaround,
            observationCount: history.count
        )
        intelligenceCache[registration] = value
        return value
    }

    private func inferredPhase(snapshot: FleetLiveSnapshot, history: [FleetTrackObservation]) -> FleetFlightPhase {
        guard snapshot.isFresh, snapshot.hasKnownGroundState else { return .unknown }
        if snapshot.onGround { return .onGround }
        let observedAt = (snapshot.sourceReferenceAt ?? snapshot.fetchedAt)
            .addingTimeInterval(-max(0, snapshot.sourceSeenSeconds))
        let previous = history.last(where: { $0.observedAt < observedAt && $0.callsign == snapshot.callsign })
        let rate = snapshot.verticalRateFeetPerMinute ?? FleetTrackingPolicy.verticalRate(
            previousAltitude: previous?.altitudeFeet, previousAt: previous?.observedAt,
            altitude: snapshot.altitudeFeet, observedAt: observedAt)
        if let rate, rate.isFinite, abs(rate) <= 10_000 {
            if rate > 500 { return .climbing }
            if rate < -500 { return .descending }
            if (snapshot.altitudeFeet ?? 0) >= 20_000 { return .cruise }
        }
        return .airborne
    }

    private func recordFreshHistory(_ fresh: [String: FleetLiveSnapshot]) {
        var updated = histories
        for (registration, snapshot) in fresh {
            guard snapshot.isFresh, snapshot.hasKnownGroundState else { continue }
            let observedAt = (snapshot.sourceReferenceAt ?? snapshot.fetchedAt)
                .addingTimeInterval(-max(snapshot.sourceSeenSeconds, snapshot.seenPositionSeconds ?? 0))
            let observation = FleetTrackObservation(
                registration: registration,
                callsign: snapshot.callsign,
                route: snapshot.route,
                latitude: snapshot.latitude,
                longitude: snapshot.longitude,
                altitudeFeet: snapshot.altitudeFeet,
                groundSpeedKnots: snapshot.groundSpeedKnots,
                trackDegrees: snapshot.trackDegrees,
                onGround: snapshot.onGround,
                observedAt: observedAt,
                groundStateKnown: snapshot.hasKnownGroundState
            )

            var values = updated[registration] ?? []
            if let last = values.last,
               abs(last.observedAt.timeIntervalSince(observation.observedAt)) < 20,
               last.latitude == observation.latitude,
               last.longitude == observation.longitude,
               last.onGround == observation.onGround {
                continue
            }
            values.append(observation)
            values.sort { $0.observedAt < $1.observedAt }
            if values.count > maximumHistoryPerAircraft {
                values.removeFirst(values.count - maximumHistoryPerAircraft)
            }
            updated[registration] = values
        }
        intelligenceCache.removeAll()
        histories = updated
    }

    private let primaryFleetProvider = FleetProviderSpec(
        name: "ADSB.lol", baseURL: "https://api.adsb.lol/v2",
        registrationPath: "reg", hexPath: "hex")
    private let secondaryFleetProvider = FleetProviderSpec(
        name: "adsb.fi", baseURL: "https://opendata.adsb.fi/api/v2",
        registrationPath: "registration", hexPath: "hex")
    private let tertiaryFleetProvider = FleetProviderSpec(
        name: "ADSB One", baseURL: "https://api.adsb.one/v2",
        registrationPath: "reg", hexPath: "icao")

    private func fetchAircraft(_ registration: String) async throws -> FleetLiveSnapshot? {
        let expectedHex = FleetTrackingPolicy.validHex(snapshots[registration]?.icaoHex)
        var lastKnown: FleetLiveSnapshot?

        func remember(_ value: FleetLiveSnapshot) {
            if lastKnown == nil || value.effectivePositionAge < lastKnown!.effectivePositionAge {
                lastKnown = value
            }
        }

        let primary = await fetchAircraft(registration, expectedHex: expectedHex, provider: primaryFleetProvider)
        try Task.checkCancellation()
        if case .snapshot(let value) = primary {
            if value.isFresh { return value }
            remember(value)
        }

        let secondary = await fetchAircraft(registration, expectedHex: expectedHex, provider: secondaryFleetProvider)
        try Task.checkCancellation()
        switch secondary {
        case .snapshot(let value):
            if value.isFresh { return value }
            remember(value)
            return lastKnown
        case .empty:
            // The secondary completed successfully. Retain any older observation
            // with its original timestamp; silence never implies AOG.
            return lastKnown
        case .failed:
            break
        }

        // Tertiary is outage resilience, not a normal third request for every
        // parked aircraft.
        let tertiary = await fetchAircraft(registration, expectedHex: expectedHex, provider: tertiaryFleetProvider)
        try Task.checkCancellation()
        switch tertiary {
        case .snapshot(let value):
            if value.isFresh { return value }
            remember(value)
            return lastKnown
        case .empty: return lastKnown
        case .failed:
            if let lastKnown { return lastKnown }
            if case .empty = primary { return nil }
            throw URLError(.cannotConnectToHost)
        }
    }

    private func fetchAircraft(_ registration: String, expectedHex: String?,
                               provider: FleetProviderSpec) async -> FleetProviderFetchResult {
        if let retry = providerRetryAfter[provider.name], Date() < retry { return .failed }

        let segment = expectedHex == nil ? provider.registrationPath : provider.hexPath
        let identity = expectedHex ?? registration
        guard let encoded = identity.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(provider.baseURL)/\(segment)/\(encoded)") else { return .failed }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("RAIDORoster/2.23.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            if http.statusCode == 429 {
                let delay = FleetTrackingPolicy.retryDelay(http.value(forHTTPHeaderField: "Retry-After"), now: Date())
                providerRetryAfter[provider.name] = Date().addingTimeInterval(delay)
                return .failed
            }
            guard (200..<300).contains(http.statusCode) else { return .failed }

            let result = try await Task.detached { try JSONDecoder().decode(ADSBLOLResponse.self, from: data) }.value
            guard !result.ac.isEmpty else { return .empty }
            guard let aircraft = result.ac.first(where: {
                FleetTrackingPolicy.matches(registration: $0.registration, hex: $0.hex,
                                            requested: registration, expectedHex: expectedHex)
            }) else { return .failed }

            let receivedAt = Date()
            let referenceAt = FleetTrackingPolicy.sourceDate(epoch: result.now, receivedAt: receivedAt)
            let hasPosition = FleetTrackingPolicy.validCoordinate(latitude: aircraft.lat, longitude: aircraft.lon)
            let snapshot = FleetLiveSnapshot(
                registration: registration,
                callsign: aircraft.flight?.isEmpty == false ? aircraft.flight : nil,
                route: nil,
                latitude: hasPosition ? aircraft.lat : nil,
                longitude: hasPosition ? aircraft.lon : nil,
                altitudeFeet: aircraft.altitudeFeet,
                groundSpeedKnots: aircraft.gs,
                trackDegrees: aircraft.track,
                onGround: aircraft.onGround,
                sourceSeenSeconds: referenceAt == nil ? 31_536_000 : aircraft.seen,
                fetchedAt: receivedAt,
                icaoHex: FleetTrackingPolicy.validHex(aircraft.hex),
                seenPositionSeconds: referenceAt == nil ? nil : aircraft.seenPos,
                nacP: aircraft.nacP,
                nic: aircraft.nic,
                radiusContainmentMeters: aircraft.rc,
                sourceReferenceAt: referenceAt,
                groundStateKnown: aircraft.groundStateKnown,
                verticalRateFeetPerMinute: aircraft.verticalRate,
                providerName: provider.name
            )
            return .snapshot(snapshot)
        } catch is CancellationError {
            return .failed
        } catch {
            return .failed
        }
    }

    private func fetchRoutes(
        _ aircraft: [(registration: String, callsign: String, lat: Double, lon: Double)]
    ) async throws -> [String: String] {
        guard let url = URL(string: "https://api.adsb.lol/api/0/routeset") else { return [:] }
        let body = ADSBLOLRouteRequest(planes: aircraft.map {
            .init(callsign: $0.callsign, lat: $0.lat, lng: $0.lon)
        })

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("RAIDORoster/2.17", forHTTPHeaderField: "User-Agent")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return [:] }

        let results = try decoder.decode([ADSBLOLRouteResult].self, from: data)
        var byCallsign: [String: String] = [:]
        for result in results {
            guard result.plausible == true,
                  let route = result.airportCodes,
                  !route.isEmpty,
                  route.lowercased() != "unknown" else { continue }
            byCallsign[result.callsign.trimmingCharacters(in: .whitespacesAndNewlines)] = route
        }

        var output: [String: String] = [:]
        for item in aircraft {
            if let route = byCallsign[item.callsign.trimmingCharacters(in: .whitespacesAndNewlines)] {
                output[item.registration] = route
            }
        }
        return output
    }

    private func loadCache() async {
        let (values, history) = await cacheLoad.value
        guard !cacheApplied else { return }
        cacheApplied = true
        var restored: [String: FleetLiveSnapshot] = [:]
        for value in values {
            if restored[value.registration].map({ $0.fetchedAt > value.fetchedAt }) != true {
                restored[value.registration] = value
            }
        }
        snapshots = restored
        lastRefresh = values.map(\.fetchedAt).max()
        histories = history.mapValues { Array($0.sorted { $0.observedAt < $1.observedAt }.suffix(maximumHistoryPerAircraft)) }
    }
}

private actor FleetCacheWriter {
    func save(snapshots: [FleetLiveSnapshot], histories: [String: [FleetTrackObservation]]) {
        let encoder = JSONEncoder(), defaults = UserDefaults.standard
        if let data = try? encoder.encode(snapshots) { defaults.set(data, forKey: "RAIDORoster.FleetLiveCache.V1") }
        if let data = try? encoder.encode(histories) { defaults.set(data, forKey: "RAIDORoster.FleetHistory.V2") }
    }
}

private enum FleetFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case getjet = "GetJet"
    case airhub = "Airhub"
    var id: String { rawValue }
}

struct FleetView: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @ObservedObject var store: RosterStore
    var tabActive = true
    var showsDismissButton = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var live = FleetLiveStore()
    @State private var query = ""
    @State private var filter: FleetFilter = .all
    @State private var selectedAircraft: FleetAircraftDefinition?
    @State private var showOtherFleet = false

    @State private var currentDutyRegistrations: Set<String> = []
    @State private var rosterIndex = FleetRosterIndex()
    @State private var learnedAircraft: [FleetAircraftDefinition] = []
    @State private var refreshNonce = 0
    @State private var contextTask: Task<Void, Never>?

    private func updateDuty() {
        let rows = store.todayItems + (store.nextDuty.map { [$0] } ?? [])
        currentDutyRegistrations = Set(rows.flatMap(\.aircraft).map {
            FleetTrackingPolicy.normalizedRegistration($0.aircraftReg)
        }.filter { !$0.isEmpty })
    }

    private func updateRosterContext() {
        updateDuty()
        let records = store.items.flatMap(\.flightActivities).map {
            FleetRosterEvidence(aircraftReg: $0.aircraftReg, aircraftType: $0.aircraftType,
                                route: $0.route, startUTC: $0.startUTC, endUTC: $0.endUTC)
        }
        let stations = store.items.flatMap(\.activityList).map(\.station).filter { !$0.isEmpty }
        let rows = store.todayItems + (store.nextDuty.map { [$0] } ?? [])
        let preferred = rows.flatMap(\.activityList).map(\.station).filter { !$0.isEmpty }
        contextTask?.cancel()
        contextTask = Task {
            let index = await Task.detached(priority: .userInitiated) {
                FleetRosterIndex(records, stations: stations, preferred: preferred)
            }.value
            guard !Task.isCancelled else { return }
            rosterIndex = index
            learnedAircraft = rosterLearnedAircraft
        }
    }

    private var rosterLearnedAircraft: [FleetAircraftDefinition] {
        var known = Set(FleetAircraftDefinition.all.map { FleetTrackingPolicy.normalizedRegistration($0.registration) })
        var learned: [FleetAircraftDefinition] = []
        for activity in rosterIndex.activities {
            let registration = FleetTrackingPolicy.canonicalRegistration(activity.aircraftReg)
            let key = FleetTrackingPolicy.normalizedRegistration(registration)
            guard !key.isEmpty, !known.contains(key) else { continue }
            if let stamp = activity.end ?? activity.start,
               Date().timeIntervalSince(stamp) > 30 * 86_400 { continue }
            known.insert(key)
            let rawType = activity.aircraftType.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let type: String
            if rawType.isEmpty { type = "Aircraft" }
            else if rawType.hasPrefix("A") || rawType.hasPrefix("B") { type = rawType }
            else if rawType.count == 3 && rawType.allSatisfy(\.isNumber) { type = "A" + rawType }
            else { type = rawType }
            learned.append(.init(registration: registration, type: type,
                                 operatorName: "RAIDO aircraft", operatorCode: "ROSTER", seats: ""))
        }
        return learned.sorted { $0.registration < $1.registration }
    }

    private var allAircraft: [FleetAircraftDefinition] {
        FleetAircraftDefinition.all + learnedAircraft
    }

    private var rotationAirport: String? { rosterIndex.rotationAirport }
    private var rosterRotationRegistrations: Set<String> { rosterIndex.rotationRegistrations }

    private enum FleetEvidenceBand: Int { case live = 0, recent, aging, historical, old, none }

    private func rosterActivities(for aircraft: FleetAircraftDefinition) -> [FleetRosterEvidence] {
        rosterIndex.byRegistration[FleetTrackingPolicy.normalizedRegistration(aircraft.registration)] ?? []
    }

    private func rosterAge(for aircraft: FleetAircraftDefinition, now: Date = Date()) -> TimeInterval? {
        rosterIndex.latest[FleetTrackingPolicy.normalizedRegistration(aircraft.registration)]
            .map { max(0, now.timeIntervalSince($0)) }
    }

    private func evidenceBand(_ aircraft: FleetAircraftDefinition) -> FleetEvidenceBand {
        guard let age = live.snapshot(for: aircraft.registration)?.effectivePositionAge else { return .none }
        if age <= 90 { return .live }
        if age <= 1200 { return .recent }
        if age <= 10800 { return .aging }
        if age <= 86400 { return .historical }
        return .old
    }

    private var filteredAircraft: [FleetAircraftDefinition] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allAircraft.filter { aircraft in
            let operatorMatches: Bool
            switch filter {
            case .all: operatorMatches = true
            case .getjet: operatorMatches = aircraft.operatorCode == "GETJET"
            case .airhub: operatorMatches = aircraft.operatorCode == "AIRHUB"
            }
            guard operatorMatches else { return false }
            return needle.isEmpty || [aircraft.registration, aircraft.type, aircraft.operatorName]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var refreshAircraft: [FleetAircraftDefinition] {
        allAircraft.sorted { lhs, rhs in
            let l = fleetPriority(lhs)
            let r = fleetPriority(rhs)
            if l != r { return l < r }
            return lhs.registration < rhs.registration
        }
    }

    private var assignedAircraft: [FleetAircraftDefinition] {
        filteredAircraft.filter { currentDutyRegistrations.contains(FleetTrackingPolicy.normalizedRegistration($0.registration)) }
    }

    private var rotationAircraft: [FleetAircraftDefinition] {
        guard rotationAirport != nil else { return [] }
        return filteredAircraft.filter {
            !currentDutyRegistrations.contains(FleetTrackingPolicy.normalizedRegistration($0.registration)) && isRotationRelevant($0)
        }.sorted { lhs, rhs in
            let l = fleetPriority(lhs)
            let r = fleetPriority(rhs)
            if l != r { return l < r }
            return lhs.registration < rhs.registration
        }
    }

    private var activeFleet: [FleetAircraftDefinition] {
        let used = Set((assignedAircraft + rotationAircraft).map {
            FleetTrackingPolicy.normalizedRegistration($0.registration)
        })
        return filteredAircraft.filter {
            !used.contains(FleetTrackingPolicy.normalizedRegistration($0.registration)) &&
            evidenceBand($0).rawValue <= FleetEvidenceBand.historical.rawValue
        }.sorted {
            let la = live.snapshot(for: $0.registration)?.effectivePositionAge ?? .infinity
            let ra = live.snapshot(for: $1.registration)?.effectivePositionAge ?? .infinity
            return la == ra ? $0.registration < $1.registration : la < ra
        }
    }

    private var otherFleet: [FleetAircraftDefinition] {
        let used = Set((assignedAircraft + rotationAircraft + activeFleet).map {
            FleetTrackingPolicy.normalizedRegistration($0.registration)
        })
        return filteredAircraft.filter {
            !used.contains(FleetTrackingPolicy.normalizedRegistration($0.registration))
        }.sorted { $0.registration < $1.registration }
    }

    private func isRotationRelevant(_ aircraft: FleetAircraftDefinition) -> Bool {
        guard let airport = rotationAirport else { return false }
        let key = FleetTrackingPolicy.normalizedRegistration(aircraft.registration)
        if currentDutyRegistrations.contains(key) { return true }
        if let intelligence = live.intelligence(for: aircraft.registration),
           (live.snapshot(for: aircraft.registration)?.effectivePositionAge ?? .infinity) <= 10800 {
            if intelligence.nearestAirport == airport { return true }
            if let route = intelligence.currentRoute,
               FleetTrackingPolicy.rotationRelation(route: route, airport: airport) != .unrelated { return true }
        }
        return rosterRotationRegistrations.contains(key) && (rosterAge(for: aircraft) ?? .infinity) <= 604800
    }

    private func fleetPriority(_ aircraft: FleetAircraftDefinition) -> Int {
        let key = FleetTrackingPolicy.normalizedRegistration(aircraft.registration)
        if currentDutyRegistrations.contains(key) { return 0 }
        guard let airport = rotationAirport else {
            return live.snapshot(for: aircraft.registration).map { $0.isFresh && $0.isAirborne } == true ? 20 : 30
        }
        let intelligence = live.intelligence(for: aircraft.registration)
        if live.snapshot(for: aircraft.registration).map({ $0.isFresh && $0.isAirborne }) == true,
           let route = intelligence?.currentRoute {
            switch FleetTrackingPolicy.rotationRelation(route: route, airport: airport) {
            case .inbound: return 1
            case .outbound: return 3
            case .touches: return 4
            case .unrelated: break
            }
        }
        if live.snapshot(for: aircraft.registration)?.isFresh == true,
           live.snapshot(for: aircraft.registration)?.onGround == true,
           intelligence?.nearestAirport == airport { return 2 }
        if intelligence?.nearestAirport == airport { return 4 }
        if rosterRotationRegistrations.contains(key) { return 5 }
        return live.snapshot(for: aircraft.registration).map { $0.isFresh && $0.isAirborne } == true ? 20 : 30
    }

    private func fleetRoute(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if let pair = FleetTrackingPolicy.routeAirports(raw) {
            return "\(pair.origin) → \(pair.destination)"
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value.replacingOccurrences(of: "-", with: " → ")
    }

    private func fleetAge(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private func rosterStatus(_ aircraft: FleetAircraftDefinition, now: Date = Date()) -> String? {
        let activities = rosterActivities(for: aircraft)
        guard !activities.isEmpty else { return nil }

        if let current = activities.first(where: { a in
            guard let start = a.start, let end = a.end else { return false }
            return now >= start && now < end
        }) {
            return "ROSTER FLIGHT · \(fleetRoute(current.route) ?? "Sector")"
        }

        let future = activities.compactMap { a -> (FleetRosterEvidence, Date)? in
            guard let start = a.start, start > now else { return nil }
            return (a, start)
        }.sorted { $0.1 < $1.1 }
        if let next = future.first, next.1.timeIntervalSince(now) <= 24 * 3600 {
            return "NEXT ROSTER FLIGHT · \(fleetRoute(next.0.route) ?? "Sector") · in \(fleetAge(next.1.timeIntervalSince(now)))"
        }

        let recent = activities.compactMap { a -> (FleetRosterEvidence, Date)? in
            guard let end = a.end, end <= now else { return nil }
            return (a, end)
        }.sorted { $0.1 > $1.1 }
        if let last = recent.first, now.timeIntervalSince(last.1) <= 6 * 3600 {
            return "ROSTER SECTOR ENDED · \(fleetRoute(last.0.route) ?? "Sector") · \(fleetAge(now.timeIntervalSince(last.1))) ago"
        }
        return nil
    }

    private func primaryStatus(_ aircraft: FleetAircraftDefinition, now: Date = Date()) -> String {
        let snapshot = live.snapshot(for: aircraft.registration)
        let intelligence = live.intelligence(for: aircraft.registration)
        let route = fleetRoute(intelligence?.currentRoute ?? snapshot?.route)
        if let snapshot, snapshot.effectivePositionAge <= 90, snapshot.hasKnownGroundState {
            if snapshot.onGround { return intelligence?.nearestAirport.map { "LIVE · ON GROUND · \($0)" } ?? "LIVE · ON GROUND" }
            let raw = intelligence?.phase.rawValue.uppercased() ?? "AIRBORNE"
            let phase = raw == "UNKNOWN" ? "AIRBORNE" : raw
            return route.map { "LIVE · \(phase) · \($0)" } ?? "LIVE · \(phase)"
        }
        if let snapshot, snapshot.effectivePositionAge <= 1200, snapshot.hasKnownGroundState {
            if snapshot.onGround { return "RECENTLY ON GROUND" }
            return route.map { "RECENTLY AIRBORNE · \($0)" } ?? "RECENTLY AIRBORNE"
        }
        if let roster = rosterStatus(aircraft, now: now) { return roster }
        if let snapshot, snapshot.effectivePositionAge <= 10800, snapshot.hasKnownGroundState {
            let age = fleetAge(snapshot.effectivePositionAge)
            return snapshot.onGround ? "LAST SEEN ON GROUND · \(age)" : "LAST SEEN AIRBORNE · \(age)"
        }
        if let snapshot, snapshot.effectivePositionAge <= 86400 { return "LAST OBSERVED · \(fleetAge(snapshot.effectivePositionAge)) ago" }
        if isRotationRelevant(aircraft), let airport = rotationAirport { return "RECENT ROTATION AIRCRAFT · \(airport)" }
        return "NO RECENT TRACKING"
    }

    private func sourceStatus(_ aircraft: FleetAircraftDefinition) -> String {
        guard let snapshot = live.snapshot(for: aircraft.registration) else {
            return rosterStatus(aircraft) == nil ? "No live or recent tracking evidence" : "Roster evidence · live position unavailable"
        }
        let source = snapshot.providerName ?? "public ADS-B"
        var values = [snapshot.isFresh ? "\(source) · \(fleetCompactAge(snapshot.effectivePositionAge))" : "Last ADS-B · \(fleetCompactAge(snapshot.effectivePositionAge)) · \(source)"]
        if let callsign = snapshot.callsign?.trimmingCharacters(in: .whitespacesAndNewlines), !callsign.isEmpty { values.append(callsign) }
        if snapshot.isFresh, !snapshot.onGround, let altitude = snapshot.altitudeFeet { values.append("\(Int(altitude.rounded()).formatted()) ft") }
        if snapshot.isFresh, let speed = snapshot.groundSpeedKnots, speed.isFinite, speed > 30 { values.append("\(Int(speed.rounded())) kt") }
        return values.joined(separator: " · ")
    }

    private func rotationContext(_ aircraft: FleetAircraftDefinition) -> String? {
        guard let airport = rotationAirport else { return nil }
        let intelligence = live.intelligence(for: aircraft.registration)
        let snapshot = live.snapshot(for: aircraft.registration)
        if let route = intelligence?.currentRoute,
           let label = FleetTrackingPolicy.rotationRouteLabel(route: route, airport: airport,
                isFresh: snapshot?.isFresh == true, isAirborne: snapshot?.isAirborne == true) {
            return label
        }
        if live.snapshot(for: aircraft.registration)?.isFresh == true,
           live.snapshot(for: aircraft.registration)?.onGround == true,
           intelligence?.nearestAirport == airport { return "On ground · \(airport)" }
        if intelligence?.nearestAirport == airport { return "Last seen near \(airport)" }
        if rosterRotationRegistrations.contains(FleetTrackingPolicy.normalizedRegistration(aircraft.registration)) {
            return rosterAge(for: aircraft).map { "Roster-used on \(airport) · \(fleetAge($0)) ago" } ?? "Roster-used on \(airport)"
        }
        return nil
    }

    private var rotationTitle: String? {
        guard let airport = rotationAirport else { return nil }
        let names = ["TLV": "Tel Aviv", "AUH": "Abu Dhabi", "BEG": "Belgrade",
                     "VNO": "Vilnius", "RIX": "Riga", "LCA": "Larnaca"]
        if let name = names[airport] { return "CURRENT ROTATION · \(name) · \(airport)" }
        return "CURRENT ROTATION · \(airport)"
    }

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        // Evaluate the sections once per render, not again for every count/row.
        let assignedAircraft = self.assignedAircraft
        let rotationAircraft = self.rotationAircraft
        let activeFleet = self.activeFleet
        let otherFleet = self.otherFleet
        return NavigationStack {
            List {
                HStack(alignment: .top) {
                    IcePageHeading(title: "Fleet", subtitle: "Your aircraft, rotation & live observations")
                    Button { refreshNonce += 1 } label: {
                        if live.isRefreshing { ProgressView().frame(width: 44, height: 44) }
                        else { Image(systemName: "arrow.clockwise").font(.title3).frame(width: 44, height: 44) }
                    }.buttonStyle(.plain).accessibilityLabel("Refresh fleet")
                    if showsDismissButton { Button("Done") { dismiss() }.frame(minHeight: 44) }
                }.padding(.vertical, 8).listRowSeparator(.hidden).listRowBackground(Color.clear)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Registration or aircraft type", text: $query)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .accessibilityLabel("Search Fleet")
                }.font(.subheadline).padding(11).background(MidnightTheme.elevated, in: RoundedRectangle(cornerRadius: 11))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                Section {
                    Picker("Fleet", selection: $filter) {
                        ForEach(FleetFilter.allCases) { value in Text(value.rawValue).tag(value) }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)

                if !assignedAircraft.isEmpty {
                    Section("YOUR CURRENT / NEXT AIRCRAFT") {
                        ForEach(assignedAircraft) { aircraft in
                            FleetAircraftRow(aircraft: aircraft,
                                snapshot: live.snapshot(for: aircraft.registration), isAssigned: true,
                                primaryStatus: { primaryStatus(aircraft) },
                                contextText: { rotationContext(aircraft) },
                                sourceText: { sourceStatus(aircraft) })
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedAircraft = aircraft }
                        }
                    }
                }

                if let rotationTitle, !rotationAircraft.isEmpty {
                    Section(rotationTitle) {
                        ForEach(rotationAircraft) { aircraft in
                            FleetAircraftRow(aircraft: aircraft,
                                snapshot: live.snapshot(for: aircraft.registration), isAssigned: false,
                                primaryStatus: { primaryStatus(aircraft) },
                                contextText: { rotationContext(aircraft) },
                                sourceText: { sourceStatus(aircraft) })
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedAircraft = aircraft }
                        }
                    }
                }

                if activeFleet.isEmpty && otherFleet.isEmpty && assignedAircraft.isEmpty && rotationAircraft.isEmpty {
                    ContentUnavailableView.search(text: query)
                }

                if !activeFleet.isEmpty {
                    Section("ACTIVE / RECENT FLEET") {
                        ForEach(activeFleet) { aircraft in
                            FleetAircraftRow(aircraft: aircraft,
                                snapshot: live.snapshot(for: aircraft.registration), isAssigned: false,
                                primaryStatus: { primaryStatus(aircraft) },
                                sourceText: { sourceStatus(aircraft) })
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedAircraft = aircraft }
                        }
                    }
                }

                if !otherFleet.isEmpty {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Section {
                            DisclosureGroup(isExpanded: $showOtherFleet) {
                                ForEach(otherFleet) { aircraft in
                                    FleetAircraftRow(aircraft: aircraft,
                                        snapshot: live.snapshot(for: aircraft.registration), isAssigned: false,
                                        primaryStatus: { primaryStatus(aircraft) },
                                        sourceText: { sourceStatus(aircraft) })
                                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                                .contentShape(Rectangle())
                                        .onTapGesture { selectedAircraft = aircraft }
                                }
                            } label: {
                                Label("Other fleet · \(otherFleet.count) aircraft", systemImage: "airplane.circle")
                                    .font(.subheadline.weight(.semibold))
                            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                        }
                    } else {
                        Section("OTHER MATCHES") {
                            ForEach(otherFleet) { aircraft in
                                FleetAircraftRow(aircraft: aircraft,
                                    snapshot: live.snapshot(for: aircraft.registration), isAssigned: false,
                                    primaryStatus: { primaryStatus(aircraft) },
                                    sourceText: { sourceStatus(aircraft) })
                                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                                .contentShape(Rectangle())
                                    .onTapGesture { selectedAircraft = aircraft }
                            }
                        }
                    }
                }

                if let error = live.errorText {
                    Text(error).font(.caption).foregroundStyle(.secondary).listRowBackground(Color.clear)
                }

                Section {
                    Text("Live position uses independent public ADS-B networks (ADSB.lol, adsb.fi, with outage fallback). Public ADS-B can be incomplete, delayed or unavailable. Routes and rotation relevance are inferred from public signals and your saved RAIDO roster. AOG, serviceability and standby activation are never inferred; RAIDO / Crew Control remain authoritative for operational status.")
                        .font(.caption).foregroundStyle(.secondary).listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain).midnightCanvas()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedAircraft) { aircraft in
                FleetAircraftDetailView(aircraft: aircraft, live: live,
                    isAssigned: currentDutyRegistrations.contains(FleetTrackingPolicy.normalizedRegistration(aircraft.registration)))
            }
            .onChange(of: store.lastSync, initial: true) { _, _ in updateRosterContext() }
            .onDisappear { contextTask?.cancel() }
            .task(id: "\(tabActive)-\(scenePhase)-\(refreshNonce)-" + allAircraft.map(\.registration).sorted().joined(separator: "|")) {
                guard tabActive, scenePhase == .active else { return }
                updateDuty()
                await live.refresh(definitions: refreshAircraft)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    updateDuty()
                    await live.refresh(definitions: refreshAircraft)
                }
            }
        }
    }
}

private func fleetDuration(_ interval: TimeInterval) -> String {
    let totalMinutes = max(0, Int(interval / 60))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}

private func fleetCompactAge(_ age: TimeInterval) -> String {
    guard age.isFinite else { return "age unknown" }
    let seconds = max(0, Int(age))
    if seconds < 60 { return "\(seconds)s ago" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    if seconds < 86_400 { return "\(seconds / 3600)h ago" }
    return "\(seconds / 86_400)d ago"
}

private struct FleetAircraftRow: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let aircraft: FleetAircraftDefinition
    let snapshot: FleetLiveSnapshot?
    let isAssigned: Bool
    var primaryStatus: (() -> String)? = nil
    var contextText: (() -> String?)? = nil
    var sourceText: (() -> String)? = nil

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        TimelineView(.periodic(from: .now, by: 15)) { _ in
            HStack(spacing: 14) {
                Image(systemName: "airplane")
                    .font(.title2.weight(.regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(aircraft.registration) · \(aircraft.type)")
                        .font(.headline.weight(.semibold))
                    Text(primaryStatus?() ?? "STATUS UNKNOWN")
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if let context = contextText?(), !context.isEmpty {
                        Text(context)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(sourceText?() ?? "Live position unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14).midnightCard(radius: 16)
            .accessibilityElement(children: .combine)
        }
    }
}

@MainActor
private final class FleetAircraftPhotoStore: ObservableObject {
    @Published private(set) var imageURL: URL?
    @Published private(set) var photographer: String?
    @Published private(set) var sourceURL: URL?
    @Published private(set) var isLoading = false

    private let registration: String

    init(registration: String) {
        self.registration = registration
    }

    func load() async {
        guard imageURL == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let encoded = registration.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? registration
        guard let url = URL(string: "https://api.planespotters.net/pub/photos/reg/\(encoded)") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("RAIDORoster/2.23.0", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let photos = root["photos"] as? [[String: Any]],
              let first = photos.first,
              let thumbnail = first["thumbnail"] as? [String: Any],
              let source = thumbnail["src"] as? String,
              let imageURL = URL(string: source) else { return }

        self.imageURL = imageURL
        photographer = first["photographer"] as? String
        if let link = first["link"] as? String {
            sourceURL = URL(string: link)
        }
    }
}

private struct FleetAircraftDetailView: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let aircraft: FleetAircraftDefinition
    @ObservedObject var live: FleetLiveStore
    var snapshot: FleetLiveSnapshot? { live.snapshot(for: aircraft.registration) }
    var intelligence: FleetAircraftIntelligence? { live.intelligence(for: aircraft.registration) }
    let isAssigned: Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var photo: FleetAircraftPhotoStore

    init(aircraft: FleetAircraftDefinition, live: FleetLiveStore, isAssigned: Bool) {
        self.aircraft = aircraft
        self.live = live
        self.isAssigned = isAssigned
        _photo = StateObject(wrappedValue: FleetAircraftPhotoStore(registration: aircraft.registration))
    }

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        TimelineView(.periodic(from: .now, by: 15)) { _ in

        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ZStack(alignment: .bottomLeading) {
                        Group {
                            if let imageURL = photo.imageURL {
                                AsyncImage(url: imageURL) { phase in
                                    if let image = phase.image {
                                        image
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        fleetPhotoPlaceholder
                                    }
                                }
                            } else {
                                fleetPhotoPlaceholder
                            }
                        }
                        .frame(height: 190)
                        .frame(maxWidth: .infinity)
                        .clipped()

                        LinearGradient(
                            colors: [.clear, .black.opacity(0.74)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        .frame(height: 190)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(aircraft.registration)
                                .font(.title.bold().monospaced())
                                .foregroundStyle(.white)
                            Text("\(aircraft.operatorName) • \(aircraft.type)")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.85))
                            if let photographer = photo.photographer {
                                Text("Photo: \(photographer) • Planespotters.net")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.72))
                            }
                        }
                        .padding(16)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                    if isAssigned {
                        Label("Assigned to your current / next rostered duty", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let snapshot {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(snapshot.isFresh ? (snapshot.isAirborne ? "AIRBORNE" : (snapshot.onGround ? "ON GROUND" : "LIVE")) : (snapshot.isRecent ? (snapshot.isAirborne ? "LAST SEEN AIRBORNE" : (snapshot.onGround ? "LAST SEEN ON GROUND" : "RECENTLY SEEN")) : "STALE"))
                                        .font(.caption.bold())
                                        .foregroundStyle(snapshot.isAirborne ? .green : .blue)
                                    Text(snapshot.callsign ?? "No callsign")
                                        .font(.title3.weight(.semibold).monospaced())
                                }
                                Spacer()
                                if let route = snapshot.route {
                                    Text(route)
                                        .font(.headline.monospaced())
                                }
                            }

                            if let lat = snapshot.latitude, let lon = snapshot.longitude {
                                Map(initialPosition: .region(MKCoordinateRegion(
                                    center: .init(latitude: lat, longitude: lon),
                                    latitudinalMeters: snapshot.isAirborne ? 700_000 : 80_000,
                                    longitudinalMeters: snapshot.isAirborne ? 700_000 : 80_000
                                )), interactionModes: [.pan, .zoom]) {
                                    Annotation(aircraft.registration, coordinate: .init(latitude: lat, longitude: lon)) {
                                        Image(systemName: "airplane")
                                            .font(.title2.bold())
                                            .foregroundStyle(.green)
                                            .rotationEffect(.degrees((snapshot.trackDegrees ?? 70) - 90))
                                    }
                                }
                                .mapStyle(.standard)
                                .frame(height: 210)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                            }

                            if let intelligence {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Label("Estimated: " + intelligence.phase.rawValue, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        if let airport = intelligence.nearestAirport {
                                            Text("NEAR \(airport)")
                                                .font(.caption.bold().monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    if let current = intelligence.currentRoute {
                                        LabeledContent("Inferred route", value: current)
                                    }
                                    if let previous = intelligence.previousRoute {
                                        LabeledContent("Earlier inferred route", value: previous)
                                    }
                                    if let turnaround = intelligence.turnaroundSeconds {
                                        LabeledContent("Since detected landing ≈", value: fleetDuration(turnaround))
                                    }
                                    if let arrival = intelligence.lastArrivalAt {
                                        LabeledContent("Landing detected ≈", value: arrival.formatted(date: .omitted, time: .shortened))
                                    }
                                    if let departure = intelligence.lastDepartureAt {
                                        LabeledContent("Takeoff detected ≈", value: departure.formatted(date: .omitted, time: .shortened))
                                    }
                                }
                                .font(.caption)
                                .padding(12)
                                .midnightCard(radius: 14)
                            }

                            HStack(spacing: 0) {
                                FleetMetric(title: "Altitude", value: snapshot.altitudeFeet.map { "\(Int($0.rounded()).formatted()) ft" } ?? "—")
                                Divider().frame(height: 34)
                                FleetMetric(title: "Ground speed", value: snapshot.groundSpeedKnots.map { "\(Int($0.rounded())) kt" } ?? "—")
                                Divider().frame(height: 34)
                                FleetMetric(title: "Track", value: snapshot.trackDegrees.map { "\(Int($0.rounded()))°" } ?? "—")
                            }

                            Text("Position \(fleetCompactAge(snapshot.effectivePositionAge)) • \(snapshot.providerName ?? "public ADS-B")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Text("Position \(snapshot.positionQualityText)")
                                if let hex = snapshot.icaoHex { Text("ICAO \(hex)") }
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .midnightCard(radius: 18)
                    } else {
                        ContentUnavailableView(
                            "Aircraft not currently tracked",
                            systemImage: "antenna.radiowaves.left.and.right.slash",
                            description: Text("Public ADS-B coverage may be unavailable while the aircraft is parked, out of coverage, or not broadcasting a usable position.")
                        )
                        .frame(minHeight: 180)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Aircraft", value: aircraft.type)
                        if !aircraft.seats.isEmpty {
                            LabeledContent("Cabin", value: aircraft.seats)
                        }
                        LabeledContent("Operator", value: aircraft.operatorName)
                        LabeledContent("Registration", value: aircraft.registration)
                    }
                    .font(.subheadline)
                    .padding(14)
                    .midnightCard(radius: 18)

                    Text("Public tracking is situational awareness only. ADS-B does not provide an authoritative GetJet/Airhub operational delay. Confirm roster, aircraft assignment and operational changes in RAIDO or with Crew Control.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .midnightCanvas().navigationTitle("Aircraft")
            .navigationBarTitleDisplayMode(.inline)
            .task { await photo.load() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }

        }
    }

    private var fleetPhotoPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.secondary.opacity(0.20), Color.secondary.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "airplane")
                .font(.system(size: 78, weight: .light))
                .rotationEffect(.degrees(-18))
                .foregroundStyle(.secondary.opacity(0.55))
        }
    }

    private func fleetAge(_ snapshot: FleetLiveSnapshot) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(snapshot.fetchedAt) + snapshot.sourceSeenSeconds))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}

private struct FleetMetric: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let title: String
    let value: String

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SettingsView: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage("RAIDORoster.Theme") private var selectedTheme = "ice"
    @AppStorage("RAIDORoster.Appearance.Ice") private var iceAppearance = "system"
    @AppStorage("RAIDORoster.Appearance.GetJet") private var getJetAppearance = "system"
    @AppStorage("RAIDORoster.Palette.Ice") private var icePalette = "iceBlue"
    @AppStorage("RAIDORoster.Palette.GetJet") private var getJetPalette = "forestGreen"
    private var paletteSelection: Binding<String> {
        Binding(get: { selectedTheme == "getJet" ? getJetPalette : icePalette },
                set: { if selectedTheme == "getJet" { getJetPalette = $0 } else { icePalette = $0 } })
    }
    private var chosenPalette: RaidoPalette {
        RaidoAppearancePreferences.selectedPalette(theme: .init(rawValue: selectedTheme) ?? .ice,
            ice: icePalette, getJet: getJetPalette)
    }
    private var appearanceSelection: Binding<String> {
        Binding(get: { selectedTheme == "getJet" ? getJetAppearance : iceAppearance },
                set: { if selectedTheme == "getJet" { getJetAppearance = $0 } else { iceAppearance = $0 } })
    }
    @AppStorage("RAIDORoster.GroundSpeedUnit") private var groundSpeedUnit = "kt"
    @ObservedObject var store: RosterStore
    @ObservedObject var browser: RosterBrowserModel
    let openPortal: () -> Void
    @State private var confirmClear = false
    @State private var showCrewControl = false
    @StateObject private var calendarExporter = CalendarExporter()
    @StateObject private var reminderScheduler = DutyReminderScheduler()
    @AppStorage("RAIDORoster.AutoCalendarSync") private var autoCalendarSync = true
    @AppStorage("RAIDORoster.RestAwarenessHours") private var restAwarenessHours = 10
    @AppStorage("RAIDORoster.PickupReminderLead") private var pickupReminderLead = 0
    @AppStorage("RAIDORoster.ReportReminderLead") private var reportReminderLead = 0

    @State private var showFleet = false

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $selectedTheme) {
                        ForEach(RaidoTheme.allCases) { theme in Text(theme.title).tag(theme.rawValue) }
                    }.pickerStyle(.segmented)
                    Picker("Mode", selection: appearanceSelection) {
                        ForEach(RaidoAppearance.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                    }.pickerStyle(.segmented)
                    NavigationLink {
                        RaidoPalettePicker(selection: paletteSelection, theme: .init(rawValue: selectedTheme) ?? .ice)
                    } label: {
                        HStack {
                            Text("Color palette")
                            Spacer()
                            Text(chosenPalette.title).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("settings-color-palette")
                    Text("Each theme remembers its own palette and appearance. System follows your iPhone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.listRowBackground(MidnightTheme.surface)

                Section("Earnings") {
                    NavigationLink {
                        EarningsPayProfileView(earnings: EarningsStore.shared,
                            month: store.selectedRosterMonth ?? String(EarningsMath.day(Date()).prefix(7)))
                    } label: {
                        Label("Pay Profile", systemImage: "eurosign.bank.building")
                    }
                    Text("Configure basic salary, block-hour rates, duty-day supplements and daily-payment eligibility. Contract revisions keep historical months intact.")
                        .font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(MidnightTheme.surface)
                Section("Offline roster") {
                    LabeledContent("Cached days", value: "\(store.items.count)")
                    if let month = store.cachedMonth, !month.isEmpty {
                        LabeledContent("Roster month", value: month)
                    }
                    if let date = store.lastSync {
                        LabeledContent("Last sync", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let message = store.validationMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Open RAIDO & sync", action: openPortal)
                    Button("Clear offline cache", role: .destructive) { confirmClear = true }
                }.listRowBackground(MidnightTheme.surface)

                Section("Crew readiness") {
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
                }.listRowBackground(MidnightTheme.surface)

                Section("Apple Calendar") {
                    Toggle("Automatically sync after RAIDO refresh", isOn: $autoCalendarSync)

                    Button {
                        calendarExporter.exportMonth(store.items, month: store.cachedMonth)
                    } label: {
                        Label("Sync roster to Apple Calendar", systemImage: "calendar.badge.plus")
                    }
                    .disabled(!store.hasCache || calendarExporter.isWorking)

                    if let status = store.calendarSyncStatus {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text("Automatic sync mirrors every validated RAIDO roster refresh into Apple Calendar. The manual Sync button also grants Calendar permission the first time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }.listRowBackground(MidnightTheme.surface)


                Section("Duty reminders") {
                    Picker("Pickup reminder", selection: $pickupReminderLead) {
                        Text("Off").tag(0)
                        Text("15 min before").tag(15)
                        Text("30 min before").tag(30)
                        Text("45 min before").tag(45)
                        Text("60 min before").tag(60)
                    }

                    Picker("Report reminder", selection: $reportReminderLead) {
                        Text("Off").tag(0)
                        Text("30 min before").tag(30)
                        Text("60 min before").tag(60)
                        Text("90 min before").tag(90)
                    }

                    Button {
                        reminderScheduler.requestAndSchedule(
                            store.items,
                            pickupLead: pickupReminderLead,
                            reportLead: reportReminderLead
                        )
                    } label: {
                        Label("Apply & schedule reminders", systemImage: "bell.badge")
                    }
                    .disabled(!store.hasCache || reminderScheduler.isWorking)

                    if let status = reminderScheduler.message ?? store.reminderSyncStatus {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task {
                            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                        }
                    } label: {
                        Label("Enable roster change alerts", systemImage: "bell.and.waves.left.and.right")
                    }

                    Text("Reminders and roster-change alerts are local to this iPhone. Change alerts are generated only after a validated RAIDO refresh; there is no background roster polling.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }.listRowBackground(MidnightTheme.surface)


                Section("Portal") {
                    Button("Open RAIDO start page") {
                        browser.openStartPage()
                        openPortal()
                    }
                    Text("RAIDO remains the live source. Roster and Today use the saved offline briefing when there is no connection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }.listRowBackground(MidnightTheme.surface)


                Section("Help & Contacts") {
                    Button {
                        showCrewControl = true
                    } label: {
                        HStack {
                            Label("Crew Control", systemImage: "headphones")
                            Spacer()
                            Text("24/7")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("WhatsApp, phone and email access for urgent short-term roster and operational questions.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }.listRowBackground(MidnightTheme.surface)

                Section("Diagnostics") {
                    DisclosureGroup("Flight Companion state") {
                        Text(TodayLiveFlightLocationManager.shared.companionStateText())
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Button("Copy sanitized RAIDO diagnostics") { browser.copyDiagnostics() }
                    if let status = browser.diagnosticStatus {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Diagnostics redact email addresses, phone numbers, URLs and booking references.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }.listRowBackground(MidnightTheme.surface)

                Section("Units") {
                    Picker("Ground speed", selection: $groundSpeedUnit) {
                        Text("Knots (kt)").tag("kt")
                        Text("Kilometres/hour (km/h)").tag("kmh")
                        Text("Miles/hour (mph)").tag("mph")
                    }

                    Text("Used by Today → Live GPS. Knots remain the aviation default.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }.listRowBackground(MidnightTheme.surface)

                Section("Version") {
                    LabeledContent("RAIDO Roster", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                    Link("Airport time zones · OpenFlights (ODbL)", destination: URL(string: "https://openflights.org/data.html#license")!)
                        .font(.caption)
                }.listRowBackground(MidnightTheme.surface)
            }
            .midnightCanvas().navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Clear the saved offline roster?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Cache", role: .destructive) { store.clearCache() }
            }
            .sheet(isPresented: $showCrewControl) {
                CrewControlSheet(item: store.todayPrimaryItem ?? store.nextDuty)
            }
            .sheet(isPresented: $showFleet) {
                FleetView(store: store)
            }
            .alert("Calendar", isPresented: Binding(
                get: { calendarExporter.message != nil },
                set: { if !$0 { calendarExporter.message = nil } }
            )) {
                Button("OK", role: .cancel) { calendarExporter.message = nil }
            } message: {
                Text(calendarExporter.message ?? "")
            }
            // Settings calendar alert
        }
    }
}

struct DutyHeroCard: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CategoryBadge(category: item.category)
                Spacer()
                if !item.dateText.isEmpty {
                    Text(item.dateText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Text(item.displayTitle).font(.title2.bold()).foregroundStyle(.primary)

            if !item.route.isEmpty {
                Label(item.route, systemImage: "airplane").font(.headline).foregroundStyle(.primary)
            }

            if !item.timeText.isEmpty {
                Label(item.timeText, systemImage: "clock").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .midnightCard(radius: 20)
    }
}

struct RosterRowCard: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem
    var isChanged: Bool = false

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(categoryColor(item.category))
                .frame(width: 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.displayTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    if isChanged {
                        Text("CHANGED")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                    if !item.dateText.isEmpty {
                        Text(item.dateText).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                Text(item.displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .midnightCard(radius: 14)
    }
}

struct RosterDetailView: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem
    @EnvironmentObject private var store: RosterStore
    @StateObject private var calendarExporter = CalendarExporter()

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let change = store.change(for: item.dateISO) {
                    RosterChangeDisclosure(change: change)
                }
                DutyBriefingView(item: item, showTechnical: true)
                BriefingSectionTitle("My note")
                PersonalDutyNoteCard(item: item)
            }
            .padding()
        }
        .midnightCanvas().navigationTitle("Duty")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { calendarExporter.export(item) } label: {
                    Image(systemName: "calendar.badge.plus")
                }
                .disabled(calendarExporter.isWorking)
                .accessibilityLabel("Export duty to Calendar")
            }
        }
        .alert("Calendar", isPresented: Binding(
            get: { calendarExporter.message != nil },
            set: { if !$0 { calendarExporter.message = nil } }
        )) {
            Button("OK", role: .cancel) { calendarExporter.message = nil }
        } message: {
            Text(calendarExporter.message ?? "")
        }
    }
}

struct PersonalDutyNoteCard: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem
    @State private var note = ""

    private var storageKey: String { "RAIDORoster.PersonalNote." + item.id }

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $note)
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(8)
                .midnightCard(radius: 12)

            HStack {
                Label("Stored only on this device", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Clear", role: .destructive) { note = "" }
                        .font(.caption)
                }
            }
        }
        .padding(14)
        .midnightCard(radius: 16)
        .onAppear { note = UserDefaults.standard.string(forKey: storageKey) ?? "" }
        .onChange(of: note) { _, value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                UserDefaults.standard.removeObject(forKey: storageKey)
            } else {
                UserDefaults.standard.set(value, forKey: storageKey)
            }
        }
    }
}


struct RosterChangesView: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @EnvironmentObject private var store: RosterStore
    let changes: [RosterDayChange]

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(changes) { change in
                    RosterChangeCard(change: change)
                }
            }
            .padding()
        }
        .midnightCanvas().navigationTitle("Roster changes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reviewed") {
                    store.dismissChangeNotice()
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }
}


struct RosterChangeDisclosure: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let change: RosterDayChange
    @State private var expanded = false

    private var visibleFields: [RosterChangeField] {
        change.fields.filter { field in
            !(field.oldValue == "—" && field.newValue == "Details changed")
        }
    }

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        if !visibleFields.isEmpty {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        expanded.toggle()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)

                        Text("\(visibleFields.count) roster change\(visibleFields.count == 1 ? "" : "s")")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        Spacer(minLength: 8)

                        Text(expanded ? "Hide" : "View")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)

                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    Divider().padding(.horizontal, 14)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(visibleFields.enumerated()), id: \.offset) { index, field in
                            if index > 0 { Divider() }

                            VStack(alignment: .leading, spacing: 6) {
                                Text(field.label.uppercased())
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)

                                HStack(alignment: .top, spacing: 8) {
                                    Text(field.oldValue)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .strikethrough(field.oldValue != "—")
                                        .fixedSize(horizontal: false, vertical: true)

                                    Image(systemName: "arrow.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 3)

                                    Text(field.newValue)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)

                                    Spacer(minLength: 0)
                                }
                            }
                            .padding(.vertical, 11)
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }
            .midnightCard(radius: 16)
            .sensoryFeedback(.selection, trigger: expanded)
        }
    }
}

struct RosterChangeCard: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let change: RosterDayChange

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("CHANGED", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                Spacer()
                Text(change.dateText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(change.fields.enumerated()), id: \.offset) { index, field in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 5) {
                    Text(field.label.uppercased())
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(field.oldValue)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .strikethrough(field.oldValue != "—")
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(field.newValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .padding(15)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct CategoryBadge: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let category: String

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        Text(prettyCategory(category))
            .font(.caption2.bold())
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(categoryColor(category))
            .background(categoryColor(category).opacity(0.13), in: Capsule())
    }
}

private func prettyCategory(_ category: String) -> String {
    switch category.uppercased() {
    case "POSITIONING": return "POSITION"
    case "RESERVE": return "RES"
    case "STANDBY": return "SBY"
    case "VACATION": return "VAC"
    default: return category.uppercased()
    }
}

private func categoryColor(_ category: String) -> Color {
    switch category.uppercased() {
    case "FLIGHT": return MidnightTheme.accent
    case "POSITIONING": return .indigo
    case "RESERVE": return .orange
    case "STANDBY": return MidnightTheme.standbyInk
    case "OFF", "REST": return MidnightTheme.offInk
    case "DND", "VACATION", "LEAVE": return .teal
    case "TRAINING": return .pink
    default: return .secondary
    }
}

private func timelineIcon(_ category: String) -> String {
    switch category.uppercased() {
    case "POSITIONING": return "airplane.circle"
    case "RESERVE": return "clock"
    case "STANDBY": return "clock"
    case "TRAINING": return "graduationcap"
    case "OFF": return "moon.zzz"
    default: return "circle"
    }
}

private func clockPart(_ value: String) -> String {
    guard !value.isEmpty else { return "" }
    return value.split(separator: " ").last.map(String.init) ?? value
}


private func parseNominalLocalStamp(_ value: String) -> Date? {
    guard !value.isEmpty else { return nil }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: value)
}

private func pickupUTCDate(for activity: RosterActivity) -> Date? {
    let pickup = activity.pickup.uppercased()
    guard let timeRange = pickup.range(of: #"\b([01]?\d|2[0-3]):[0-5]\d\b"#, options: .regularExpression) else { return nil }
    let time = String(pickup[timeRange])

    let startDate = activity.startLT.split(separator: " ").first.map(String.init) ?? ""
    guard startDate.count == 10 else { return nil }
    let year = String(startDate.prefix(4))

    var pickupDateISO = startDate
    if let dateRange = pickup.range(of: #"\b(\d{1,2})\s+(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)\b"#, options: .regularExpression) {
        let token = String(pickup[dateRange]).split(separator: " ")
        if token.count == 2, let day = Int(token[0]) {
            let months = ["JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
                          "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12]
            if let month = months[String(token[1])] {
                pickupDateISO = String(format: "%@-%02d-%02d", year, month, day)
            }
        }
    }

    guard let nominalPickup = parseNominalLocalStamp("\(pickupDateISO) \(time)") else { return nil }

    let anchorPairs = [
        (activity.checkInLT, activity.checkInUTC),
        (activity.startLT, activity.startUTC),
        (activity.endLT, activity.endUTC),
        (activity.checkOutLT, activity.checkOutUTC)
    ]

    let anchors: [(nominal: Date, actualUTC: Date)] = anchorPairs.compactMap { local, utc in
        guard let nominal = parseNominalLocalStamp(local),
              let actual = parseUTCStamp(utc) else { return nil }
        return (nominal, actual)
    }
    guard let nearest = anchors.min(by: {
        abs($0.nominal.timeIntervalSince(nominalPickup)) < abs($1.nominal.timeIntervalSince(nominalPickup))
    }) else { return nil }

    let localOffset = nearest.nominal.timeIntervalSince(nearest.actualUTC)
    return nominalPickup.addingTimeInterval(-localOffset)
}

private func parseUTCStamp(_ value: String) -> Date? {
    guard !value.isEmpty else { return nil }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: value)
}

private func durationText(_ interval: TimeInterval) -> String {
    let minutes = max(0, Int(interval / 60))
    let hours = minutes / 60
    let mins = minutes % 60
    if hours == 0 { return "\(mins)m" }
    return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
}

private func relativeText(from: Date, to: Date) -> String {
    let interval = max(0, to.timeIntervalSince(from))
    return "in \(durationText(interval))"
}

private func activitySortKey(_ activity: RosterActivity) -> String {
    if !activity.startUTC.isEmpty { return activity.startUTC }
    return activity.startLT
}

private func uniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { value in
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !seen.contains(key) else { return false }
        seen.insert(key)
        return true
    }
}

private func uniqueActivities(_ values: [RosterActivity]) -> [RosterActivity] {
    var seen = Set<String>()
    return values.filter { activity in
        let key = "\(activity.code)|\(activity.startLT)|\(activity.endLT)|\(activity.hotelName)"
        guard !seen.contains(key) else { return false }
        seen.insert(key)
        return true
    }
}

private func hotelRange(_ hotel: RosterActivity) -> String {
    let start = hotel.startLT.split(separator: " ").first.map(String.init) ?? ""
    let end = hotel.endLT.split(separator: " ").first.map(String.init) ?? ""
    let station = hotel.station
    var pieces: [String] = []
    if !station.isEmpty { pieces.append(station) }
    if !start.isEmpty && !end.isEmpty { pieces.append(start == end ? start : "\(start) → \(end)") }
    return pieces.joined(separator: " • ")
}


private func historyDateLabel(_ iso: String) -> String {
    let input = DateFormatter()
    input.calendar = Calendar(identifier: .gregorian)
    input.locale = Locale(identifier: "en_US_POSIX")
    input.timeZone = .current
    input.dateFormat = "yyyy-MM-dd"
    guard let date = input.date(from: iso) else { return iso }
    let output = DateFormatter()
    output.locale = Locale(identifier: "en_US_POSIX")
    output.timeZone = .current
    output.dateFormat = "d MMM"
    return output.string(from: date).uppercased()
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// Fleet reliability 2.19.8

// Announcements 2.19.9
func announcementAirline(registration: String) -> AnnouncementAirline {
    AnnouncementAirline.fromRoster(registration: registration,
        operators: Dictionary(uniqueKeysWithValues: FleetAircraftDefinition.all.map { ($0.registration, $0.operatorCode) }))
}

// Monthly earnings 2.20.0
@MainActor
func earningsFlights(store: RosterStore, month: String, now: Date = Date()) -> [EarningsFlight] {
    // Selected snapshot wins. Adjacent archives recover sectors crossing a UTC month boundary.
    var rows = store.rosterViewItems
    for key in store.monthSnapshots.keys.sorted() where key != store.selectedRosterMonth {
        rows += store.monthSnapshots[key]?.items ?? []
    }
    var result: [EarningsFlight] = []
    var seen = Set<String>()
    for row in rows {
        for activity in row.activityList where activity.category.uppercased() == "FLIGHT" {
            let start = parseUTCStamp(activity.startUTC)
            let end = parseUTCStamp(activity.endUTC)
            let day = start.map(EarningsMath.day) ?? row.dateISO ?? ""
            guard day.hasPrefix(month + "-") else { continue }
            let id = [activity.code, activity.route, activity.startUTC.isEmpty ? day + "|" + activity.id : activity.startUTC].joined(separator: "|")
            guard seen.insert(id).inserted else { continue }
            let minutes: Int?
            if let start, let end, end >= start, end.timeIntervalSince(start) <= 86_400 {
                minutes = Int(end.timeIntervalSince(start) / 60)
            } else { minutes = nil }
            let fingerprint = [id, activity.endUTC, activity.aircraftReg].joined(separator: "|")
            result.append(EarningsFlight(id: id, day: day,
                title: [activity.code, activity.route].filter { !$0.isEmpty }.joined(separator: " · "),
                fingerprint: fingerprint, scheduledMinutes: minutes,
                ended: end.map { $0 <= now } ?? (day < EarningsMath.day(now))))
        }
    }
    return result.sorted { $0.day == $1.day ? $0.id < $1.id : $0.day < $1.day }
}

// Daily payments 2.20.1
@MainActor
func earningsDailyLines(store: RosterStore, month: String, record: EarningsMonth, profile: EarningsPayProfile? = nil) -> [EarningsDailyLine] {
    var rows = store.rosterViewItems
    // Only neighboring archives inform location at a month boundary.
    if let start = EarningsMath.date(month + "-01") {
        for offset in [-1, 1] {
            if let date = EarningsMath.utc.date(byAdding: .month, value: offset, to: start) {
                let key = String(EarningsMath.day(date).prefix(7))
                rows += store.monthSnapshots[key]?.items ?? []
            }
        }
    }
    var days: [String: EarningsRosterDay] = [:]
    var events: [EarningsLocationEvent] = []
    var seen = Set<String>()
    for row in rows {
        guard let rowDay = row.dateISO else { continue }
        if days[rowDay] == nil { days[rowDay] = EarningsRosterDay(day: rowDay, categories: []) }
        let activities = row.activityList.filter { !["HOTEL", "EXPENSE", "RELOCATION"].contains($0.category.uppercased()) }
        if activities.isEmpty { days[rowDay]?.categories.insert(row.category.uppercased()) }
        for activity in activities {
            let start = parseUTCStamp(activity.startUTC)
            let end = parseUTCStamp(activity.endUTC)
            let day = start.map(EarningsMath.day) ?? rowDay
            let category = activity.category.uppercased()
            for covered in EarningsDailyPolicy.coveredDays(fallback: rowDay, start: start, end: end) {
                if days[covered] == nil { days[covered] = EarningsRosterDay(day: covered, categories: []) }
                days[covered]?.categories.insert(category)
                if let station = EarningsDailyPolicy.airport(activity.station) { days[covered]?.stations.insert(station) }
            }
            if category == "FLIGHT" || category == "POSITIONING" {
                let (origin, destination) = EarningsDailyPolicy.route(activity.route)
                let departureOrder = activity.startUTC.isEmpty ? day + " 12:00" : activity.startUTC
                let arrivalDay = end.map(EarningsMath.day) ?? day
                let arrivalOrder = activity.endUTC.isEmpty ? day + " 23:59" : activity.endUTC
                let key = [activity.code, activity.route, departureOrder].joined(separator: "|")
                if seen.insert(key).inserted {
                    events.append(EarningsLocationEvent(day: day, order: departureOrder, origin: origin, destination: nil))
                    events.append(EarningsLocationEvent(day: arrivalDay, order: arrivalOrder, origin: nil, destination: destination))
                }
            }
        }
    }
    return EarningsDailyPolicy.lines(month: month, days: Array(days.values), events: events, record: record, profile: profile)
}


// Shared native presentation tokens. Functional models do not depend on this theme.
// V2.29: two native themes, with independent appearance preferences.
private struct RaidoThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = RaidoTheme.ice
}

extension EnvironmentValues {
    var raidoTheme: RaidoTheme {
        get { self[RaidoThemeEnvironmentKey.self] }
        set { self[RaidoThemeEnvironmentKey.self] = newValue }
    }
}

enum MidnightTheme {
    // Build new dynamic colors after theme changes rather than relying on
    // UIKit's cached resolution of a previously-created color in the same mode.
    static var isGetJet: Bool {
        RaidoAppearancePreferences.selectedTheme(UserDefaults.standard.string(forKey: RaidoAppearancePreferences.themeKey) ?? "ice") == .getJet
    }
    static func adaptive(_ dark: UInt32, _ light: UInt32) -> UIColor {
        UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
    static var colorPalette: RaidoPalette {
        let defaults = UserDefaults.standard
        return RaidoAppearancePreferences.selectedPalette(theme: isGetJet ? .getJet : .ice,
            ice: defaults.string(forKey: RaidoAppearancePreferences.icePaletteKey) ?? "iceBlue",
            getJet: defaults.string(forKey: RaidoAppearancePreferences.getJetPaletteKey) ?? "forestGreen")
    }
    private static func tone(_ role: KeyPath<RaidoPaletteColors, UInt32>) -> UIColor {
        let palette = colorPalette
        return adaptive(palette.colors(dark: true)[keyPath: role], palette.colors(dark: false)[keyPath: role])
    }
    // V2.29.2 map polish: retain readable filled actions separately from links.
    static var actionFill: Color { Color(uiColor: tone(\.actionFill)) }
    static var actionInk: Color { .white }
    static var accent: Color { Color(uiColor: tone(\.accent)) }
    static var border: Color { Color(uiColor: tone(\.border)) }
    static var ink: Color { Color(uiColor: tone(\.ink)) }
    static var warning: Color { Color(uiColor: tone(\.warning)) }
    static var warningInk: Color { Color(uiColor: tone(\.warningInk)) }
    static var mapSea: Color { Color(uiColor: tone(\.mapSea)) }
    static var mapLand: Color { Color(uiColor: tone(\.mapLand)) }
    static var mapBorder: Color { Color(uiColor: tone(\.mapBorder)) }
    static var offInk: Color { Color(uiColor: tone(\.offInk)) }
    static var calendarDivider: Color { Color(uiColor: tone(\.calendarDivider)) }
    static var mapLabelInk: Color { Color(uiColor: tone(\.mapLabelInk)) }
    static var backgroundUI: UIColor { tone(\.background) }
    static var background: Color { Color(uiColor: backgroundUI) }
    static var surfaceUI: UIColor { tone(\.surface) }
    static var surface: Color { Color(uiColor: surfaceUI) }
    static var elevatedUI: UIColor { tone(\.elevated) }
    static var elevated: Color { Color(uiColor: elevatedUI) }
    static var highlight: Color { isGetJet ? Color(uiColor: tone(\.highlight)) : actionFill }
    static var selectionInk: Color { isGetJet ? Color(uiColor: tone(\.selectionInk)) : .white }
    static var standbyInk: Color { warningInk }

    @MainActor static func navigationAppearance() -> UINavigationBarAppearance {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = backgroundUI
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor(ink)]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor(ink)]
        return nav
    }
    @MainActor static func tabAppearance() -> UITabBarAppearance {
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = backgroundUI
        tab.shadowColor = UIColor(border)
        return tab
    }
    @MainActor static func configure() {
        let nav = navigationAppearance(), tab = tabAppearance()
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UISegmentedControl.appearance().selectedSegmentTintColor = isGetJet ? surfaceUI : UIColor(actionFill)
        UISegmentedControl.appearance().backgroundColor = elevatedUI
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: isGetJet ? UIColor(accent) : UIColor.white], for: .selected)
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: UIColor(ink)], for: .normal)
    }
}

// Refresh existing UIKit chrome too; do not rebuild ContentView or its models.
struct RaidoChromeRefresh: UIViewRepresentable {
    let theme: RaidoTheme
    let appearance: RaidoAppearance
    let palette: RaidoPalette
    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }
    func updateUIView(_ view: UIView, context: Context) {
        MidnightTheme.configure()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            updateChrome(window)
        }
    }
    private func updateChrome(_ view: UIView) {
        if let nav = view as? UINavigationBar {
            let value = MidnightTheme.navigationAppearance()
            nav.standardAppearance = value; nav.scrollEdgeAppearance = value; nav.compactAppearance = value
            nav.tintColor = UIColor(MidnightTheme.accent)
        } else if let tab = view as? UITabBar {
            let value = MidnightTheme.tabAppearance()
            tab.standardAppearance = value; tab.scrollEdgeAppearance = value
            tab.tintColor = UIColor(MidnightTheme.accent)
        } else if let segment = view as? UISegmentedControl {
            segment.selectedSegmentTintColor = theme == .getJet ? MidnightTheme.surfaceUI : UIColor(MidnightTheme.actionFill)
            segment.backgroundColor = MidnightTheme.elevatedUI
            segment.setTitleTextAttributes([.foregroundColor: theme == .getJet ? UIColor(MidnightTheme.accent) : UIColor.white], for: .selected)
            segment.setTitleTextAttributes([.foregroundColor: UIColor(MidnightTheme.ink)], for: .normal)
        }
        for child in view.subviews { updateChrome(child) }
    }
}

private struct RaidoCanvas: ViewModifier {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var theme
    func body(content: Content) -> some View {
        let _ = raidoColorPalette

        let _ = theme
        return content.scrollContentBackground(.hidden)
            .background(MidnightTheme.background.ignoresSafeArea())
            .toolbarBackground(MidnightTheme.background, for: .navigationBar, .tabBar)
            .toolbarBackground(.visible, for: .navigationBar, .tabBar)
            .tint(MidnightTheme.accent)
    }
}

// Open gutters: short round-ended separators, no enclosing cell boxes.
private struct GetJetCalendarDividers: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let rows: Int
    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        Canvas { context, size in
            guard rows > 0 else { return }
            let width = size.width / 7, height = size.height / CGFloat(rows)
            var path = Path()
            for row in 0..<rows {
                for col in 0..<7 {
                    if col < 6 {
                        let x = CGFloat(col + 1) * width
                        path.move(to: CGPoint(x: x, y: CGFloat(row) * height + 12))
                        path.addLine(to: CGPoint(x: x, y: CGFloat(row + 1) * height - 12))
                    }
                    if row < rows - 1 {
                        let y = CGFloat(row + 1) * height
                        path.move(to: CGPoint(x: CGFloat(col) * width + 7, y: y))
                        path.addLine(to: CGPoint(x: CGFloat(col + 1) * width - 7, y: y))
                    }
                }
            }
            context.stroke(path, with: .color(MidnightTheme.calendarDivider), style: StrokeStyle(lineWidth: 1.15, lineCap: .round))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct GetJetSectorCard: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let sector: RosterActivity
    let crewAction: () -> Void
    private var codes: [String] { TodayGlobalAirportIndex.routeCodes(sector.route) }
    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(spacing: 17) {
            HStack {
                Text(sector.code).font(.caption.weight(.semibold)).tracking(0.5).foregroundStyle(MidnightTheme.accent)
                Spacer(minLength: 5)
                Text([sector.aircraftReg, sector.aircraftType].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(alignment: .center) {
                airport(codes.first ?? "—", alignment: .leading)
                Spacer(minLength: 6)
                VStack(spacing: 5) {
                    Image(systemName: "airplane").font(.system(size: 20, weight: .regular)).foregroundStyle(MidnightTheme.accent)
                    if let start = parseUTCStamp(sector.startUTC), let end = parseUTCStamp(sector.endUTC), end > start {
                        Text(durationText(end.timeIntervalSince(start))).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                airport(codes.last ?? "—", alignment: .trailing)
            }
            HStack(alignment: .firstTextBaseline) {
                time(sector.localStartTime, label: "DEP")
                Spacer(minLength: 4)
                Text("Local times").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                time(sector.localEndTime, label: "ARR")
            }
            Rectangle().fill(MidnightTheme.border.opacity(0.45)).frame(height: 0.5)
            HStack {
                Text("Flight sector").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if !sector.crew.isEmpty {
                    Button(action: crewAction) { Label("Crew", systemImage: "person.2").font(.caption) }
                        .buttonStyle(.plain).frame(minHeight: 32)
                        .accessibilityLabel("View crew for " + sector.code)
                }
            }
        }.padding(19).midnightCard(radius: 24)
    }
    private func airport(_ code: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(code).font(.system(size: 30, weight: .semibold)).tracking(-0.8)
            Text(IceAirportClock.city(for: code)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
    }
    private func time(_ value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value.isEmpty ? "—" : value).font(.system(size: 18, weight: .medium)).monospacedDigit()
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

private struct MidnightCard: ViewModifier {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let radius: CGFloat
    func body(content: Content) -> some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        return content
            .background(MidnightTheme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.025), radius: 12, x: 0, y: 4)
    }
}

extension View {
    func midnightCard(radius: CGFloat = 18) -> some View { modifier(MidnightCard(radius: radius)) }
    func midnightCanvas() -> some View { modifier(RaidoCanvas()) }
}

private struct MidnightQuickAction: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .regular))
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

// Fleet V2 2.23.0

// Fleet status fusion 2.23.0

// Fleet recency 2.23.1

// Fleet hierarchy 2.23.1

// Flight Companion manual persistent hybrid tracking

// Flight Companion V2 adaptive tracking and phase estimator

// Flight Companion automatic roster arming with airport/time gating

// Flight Companion return-flight handoff, ADS-B rendering, lifecycle recovery, and diagnostics

// V2.23.1 Today current-month archive isolation + rich future-month refresh

// Flight Companion V3 offline-resilient shadow engine

// MARK: - Flight Companion V3 offline-resilient shadow engine

private enum FCV3PositionTier: Int, Codable, Comparable {
    case estimated = 0, fused = 1, measured = 2
    static func < (lhs: FCV3PositionTier, rhs: FCV3PositionTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

private enum FCV3Phase: String, Codable {
    case armed, groundMovement, taxiOut, takeoffRoll, airborne, cruise, descent, taxiIn, complete
}

private enum FCV3EvidenceSource: String, Codable {
    case gnss, adsbServer, motionActivity, barometer, roster, manual
}

private enum FCV3EvidenceKind: String, Codable {
    case position, motion, pressureTrend, eventCandidate, rosterChange
}

private struct FCV3Evidence: Codable, Identifiable {
    var id = UUID()
    let t: Date
    let source: FCV3EvidenceSource
    let kind: FCV3EvidenceKind
    var confidence: Double
    var horizontalAccuracyM: Double?
    var speedMps: Double?
    var relativeAltitudeM: Double?
    var climbRateFtMin: Double?
    var activity: String?
    var note: String?
}

private actor FCV3EvidenceLog {
    private let url: URL
    private let encoder = JSONEncoder()
    private var lastPositionWrite: Date?

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil,
                                                  create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("FlightCompanionV3", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("shadow-evidence.jsonl")
        encoder.dateEncodingStrategy = .secondsSince1970
    }

    func append(_ evidence: FCV3Evidence) {
        if evidence.kind == .position {
            if let lastPositionWrite, evidence.t.timeIntervalSince(lastPositionWrite) < 10 { return }
            lastPositionWrite = evidence.t
        }
        guard var line = try? encoder.encode(evidence) else { return }
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}

@MainActor
private final class FlightCompanionV3ShadowEngine: ObservableObject {
    static let shared = FlightCompanionV3ShadowEngine()

    @Published private(set) var phase: FCV3Phase = .armed
    @Published private(set) var climbRateFtMin: Double = 0
    @Published private(set) var activityText = "unknown"
    @Published private(set) var evidenceCount = 0

    private let altimeter = CMAltimeter()
    private let activityManager = CMMotionActivityManager()
    private let log = FCV3EvidenceLog()
    private var altitudeSamples: [(Date, Double)] = []
    private var candidateSince: Date?
    private var enteredPhaseAt = Date()
    private var started = false

    func startShadowObservation() {
        guard !started else { return }
        started = true

        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                self.consumeAltitude(data.relativeAltitude.doubleValue, at: Date())
            }
        }

        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: .main) { [weak self] activity in
                guard let self, let activity else { return }
                let value: String
                if activity.automotive { value = "automotive" }
                else if activity.walking { value = "walking" }
                else if activity.running { value = "running" }
                else if activity.cycling { value = "cycling" }
                else if activity.stationary { value = "stationary" }
                else { value = "unknown" }
                self.activityText = value
                self.record(FCV3Evidence(t: Date(), source: .motionActivity, kind: .motion,
                    confidence: activity.confidence == .high ? 0.8 : (activity.confidence == .medium ? 0.55 : 0.3),
                    activity: value))
                self.evaluate(now: Date())
            }
        }
    }

    func recordGNSS(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0 else { return }
        let accuracy = location.horizontalAccuracy
        let confidence: Double
        if accuracy <= 30 { confidence = 0.95 }
        else if accuracy <= 100 { confidence = 0.75 }
        else if accuracy <= 300 { confidence = 0.35 }
        else { return }
        record(FCV3Evidence(t: location.timestamp, source: .gnss, kind: .position,
            confidence: confidence, horizontalAccuracyM: accuracy,
            speedMps: location.speed >= 0 ? location.speed : nil))
    }

    private func consumeAltitude(_ meters: Double, at now: Date) {
        altitudeSamples.append((now, meters))
        altitudeSamples.removeAll { now.timeIntervalSince($0.0) > 30 }
        guard altitudeSamples.count >= 3,
              let first = altitudeSamples.first,
              let last = altitudeSamples.last else { return }
        let dt = last.0.timeIntervalSince(first.0)
        guard dt >= 10 else { return }
        climbRateFtMin = ((last.1 - first.1) * 3.28084) / (dt / 60.0)
        record(FCV3Evidence(t: now, source: .barometer, kind: .pressureTrend,
            confidence: min(0.95, 0.45 + min(abs(climbRateFtMin) / 2500.0, 0.5)),
            relativeAltitudeM: meters, climbRateFtMin: climbRateFtMin))
        evaluate(now: now)
    }

    private func evaluate(now: Date) {
        let moving = activityText == "automotive" || activityText == "unknown"
        let flat = abs(climbRateFtMin) < 300
        let climbing = climbRateFtMin > 1000
        let descending = climbRateFtMin < -500

        var proposed: FCV3Phase?
        var dwell: TimeInterval = 0
        switch phase {
        case .armed:
            if moving { proposed = .groundMovement; dwell = 20 }
        case .groundMovement:
            if moving && flat { proposed = .taxiOut; dwell = 15 }
        case .taxiOut:
            // Without foreground device-motion or measured speed, remain conservative.
            if climbing { proposed = .airborne; dwell = 15 }
        case .takeoffRoll:
            if climbing { proposed = .airborne; dwell = 15 }
        case .airborne:
            if abs(climbRateFtMin) < 300 { proposed = .cruise; dwell = 60 }
        case .cruise:
            if descending { proposed = .descent; dwell = 60 }
        case .descent:
            if flat && moving { proposed = .taxiIn; dwell = 30 }
        case .taxiIn:
            if activityText == "stationary" { proposed = .complete; dwell = 60 }
        case .complete:
            break
        }

        guard let proposed else { candidateSince = nil; return }
        if candidateSince == nil { candidateSince = now }
        if now.timeIntervalSince(candidateSince ?? now) >= dwell {
            phase = proposed
            enteredPhaseAt = now
            candidateSince = nil
            record(FCV3Evidence(t: now, source: .barometer, kind: .eventCandidate,
                confidence: 0.7, note: "shadow phase -> \(proposed.rawValue)"))
        }
    }

    private func record(_ evidence: FCV3Evidence) {
        evidenceCount += 1
        Task { await log.append(evidence) }
    }

    var diagnosticText: String {
        [
            "version=2.23.1-flight-companion-v3-shadow",
            "mode=observation-only",
            "phase=\(phase.rawValue)",
            "activity=\(activityText)",
            "baroFtMin=\(Int(climbRateFtMin.rounded()))",
            "evidence=\(evidenceCount)",
            "networkRequired=false-for-sensor-observation",
            "controlsLiveTracking=false"
        ].joined(separator: "\n")
    }
}

// V2.23.1 Flight Companion V3 sensor evidence observer (shadow mode)

// V2.26 validated sensor/session driver

// V2.26.1 bounded Fleet refresh

// V2.28 Ice presentation. The saved roster and tracking policies remain authoritative.
private struct IcePageHeading: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let title: String
    let subtitle: String
    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 30, weight: .semibold)).tracking(-0.8)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IceToolRow: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 21, weight: .regular))
                .foregroundStyle(MidnightTheme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.weight(.medium)).foregroundStyle(.tertiary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).midnightCard(radius: 16)
    }
}

private enum IceAirportClock {
    private static let records: [String: [String]] = {
        guard let url = Bundle.main.url(forResource: "AirportTimeZones", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return result
    }()
    static func zone(for code: String) -> TimeZone? {
        let identifier = CrewCompanionTimeZones.airport[code] ?? records[code]?.last
        return identifier.flatMap(TimeZone.init(identifier:))
    }
    static func city(for code: String) -> String {
        records[code]?.first?.nilIfEmpty ?? code
    }
    static func rosterLocalClock(_ date: Date, item: RosterItem) -> String {
        guard let first = item.operationalActivities.first else { return "Time unavailable" }
        let code = TodayGlobalAirportIndex.routeCodes(first.route).first ?? first.station.uppercased()
        if let zone = zone(for: code) { return crewCompanionClock(date, timeZone: zone) }
        // Preserve the roster's explicit LT/UTC offset when an airport has no
        // known time zone. Never silently substitute the phone's current zone.
        for (localStamp, utcStamp) in [(first.checkInLT, first.checkInUTC), (first.startLT, first.startUTC)] {
            if let local = parseUTCStamp(localStamp), let utc = parseUTCStamp(utcStamp) {
                return crewCompanionClock(date.addingTimeInterval(local.timeIntervalSince(utc)), timeZone: TimeZone(secondsFromGMT: 0)!)
            }
        }
        return "Time unavailable"
    }
}

private struct IceDestinationClock: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem
    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        TimelineView(.everyMinute) { context in
            let code = crewCompanionDestinationCode(item, at: context.date)
            let zone = code.flatMap { IceAirportClock.zone(for: $0) }
            let sector = crewCompanionSector(item, at: context.date)
            VStack(alignment: .leading, spacing: 3) {
                Text(code.map { IceAirportClock.city(for: $0) } ?? "Destination")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(zone.map { crewCompanionClock(context.date, timeZone: $0) } ?? "—:—")
                    .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                if let end = sector.flatMap({ parseUTCStamp($0.endUTC) }), let zone {
                    Text("Arrive " + crewCompanionClock(end, timeZone: zone))
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(zone == nil ? "Time zone unavailable" : "Destination local time")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(11).frame(minWidth: 108, alignment: .leading).midnightCard(radius: 13)
                .accessibilityElement(children: .combine)
        }
    }
}

private struct IcePickupCard: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem
    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        if !item.preDutyPickupDisplay.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(item.pickups, id: \.self) { Text($0) }
                    ForEach(item.transferNotes, id: \.self) { Text($0) }
                    ForEach(groupedHotelDisplayRows(item.hotelAssignments)) { row in
                        Text(row.title)
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 10)
            } label: {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(compactPickupClock(item.preDutyPickupDisplay))
                            .font(.system(size: 28, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(MidnightTheme.accent)
                        Text("PICKUP").font(.caption2).foregroundStyle(.secondary)
                    }.frame(minWidth: 76, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Crew transport", systemImage: "car.side").font(.subheadline.weight(.semibold))
                        if let pickup = item.preDutyPickupUTCDate {
                            TimelineView(.everyMinute) { context in
                                Text(pickup > context.date ? calendarPickupCountdown(from: context.date, to: pickup) : "Scheduled pickup")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Transport details").font(.caption).foregroundStyle(.secondary)
                        }
                    }.foregroundStyle(.primary)
                }.padding(.vertical, 4)
            }.padding(15).midnightCard(radius: MidnightTheme.isGetJet ? 22 : 16)
        }
    }
}

private struct IceReadinessView: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem
    @ObservedObject var store: RosterStore
    @AppStorage("RAIDORoster.RestAwarenessHours") private var restAwarenessHours = 10
    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: 9) {
                if let reference = store.precautionReferenceDate(for: item),
                   let cutoff = store.alcoholPrecautionCutoff(for: item), context.date < reference {
                    let active = context.date >= cutoff
                    DisclosureGroup {
                        Text("12 hours before pickup, or report when pickup is unavailable. Company policy remains authoritative.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "wineglass").font(.system(size: 18))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Alcohol precaution").font(.subheadline.weight(.semibold))
                                Text(active ? "Active · until " + IceAirportClock.rosterLocalClock(reference, item: item)
                                     : "Starts " + IceAirportClock.rosterLocalClock(cutoff, item: item))
                                    .font(.caption)
                            }
                            Spacer(minLength: 0)
                        }.foregroundStyle(active ? MidnightTheme.warningInk : MidnightTheme.accent)
                    }.tint(active ? MidnightTheme.warningInk : MidnightTheme.accent)
                        .padding(13).background(active ? MidnightTheme.warning : MidnightTheme.surface,
                                                in: RoundedRectangle(cornerRadius: 13))
                }
                if let previous = store.previousOperationalDuty(before: item),
                   let release = previous.dutyEndUTCDate,
                   let target = store.precautionReferenceDate(for: item), target > release {
                    let interval = target.timeIntervalSince(release)
                    DisclosureGroup {
                        Text("From previous release to pickup or report. Awareness threshold: \(restAwarenessHours) hours.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    } label: {
                        Label("Rest · \(durationText(interval)) available", systemImage: "bed.double")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(interval < Double(restAwarenessHours * 3600) ? MidnightTheme.warningInk : .secondary)
                    }.padding(12).midnightCard(radius: 13)
                }
            }
        }
    }
}

private struct IceDutyAgenda: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem
    var onCalendarExport: (() -> Void)? = nil
    var canExport = true
    @State private var crewSector: RosterActivity?
    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your duty").font(.headline)
                Spacer()
                Text(item.aircraft.first?.aircraftType ?? prettyCategory(item.category))
                    .font(.caption).foregroundStyle(.secondary)
                if let onCalendarExport {
                    Menu {
                        Button("Sync duty to Calendar", systemImage: "calendar.badge.plus", action: onCalendarExport)
                            .disabled(!canExport)
                    } label: { Image(systemName: "ellipsis").frame(width: 36, height: 44) }
                        .accessibilityLabel("Duty options")
                }
            }
            if let first = item.operationalActivities.first, !first.localCheckInTime.isEmpty {
                agendaRow(time: first.localCheckInTime, title: "Report", detail: first.station, arrival: "", sector: nil)
            }
            ForEach(item.operationalActivities) { activity in
                let codes = TodayGlobalAirportIndex.routeCodes(activity.route)
                if MidnightTheme.isGetJet && activity.isFlight && codes.count >= 2 {
                    GetJetSectorCard(sector: activity) { crewSector = activity }
                } else {
                agendaRow(time: activity.localStartTime,
                          title: activity.isFlight && codes.count >= 2 ? codes.joined(separator: " → ") : activity.title,
                          detail: activity.isFlight ? activity.code : activity.description,
                          arrival: activity.localEndTime, sector: activity.isFlight ? activity : nil)
                }
            }
            if let last = item.operationalActivities.last, !last.localCheckOutTime.isEmpty {
                agendaRow(time: last.localCheckOutTime, title: "Release", detail: "Duty complete", arrival: "", sector: nil)
            }
            if item.operationalActivities.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.displayTitle).font(.subheadline.weight(.semibold))
                    if !item.timeText.isEmpty { Text(item.timeText).font(.caption).foregroundStyle(.secondary) }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).midnightCard(radius: 13)
            }
        }.sheet(item: $crewSector) { sector in
            NavigationStack {
                ScrollView { CrewCard(item: sectorItem(sector)).padding() }.midnightCanvas().navigationTitle("Crew · " + sector.code)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { crewSector = nil } } }
            }
        }
    }
    private func sectorItem(_ sector: RosterActivity) -> RosterItem {
        RosterItem(id: item.id, index: item.index, dateISO: item.dateISO, dateText: item.dateText,
                   category: item.category, title: item.title, route: sector.route, timeText: sector.timeText,
                   rawText: sector.rawText, cells: [], activities: [sector], activeHotels: nil)
    }
    private func agendaRow(time: String, title: String, detail: String, arrival: String, sector: RosterActivity?) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text(time).font(.caption.weight(.semibold)).monospacedDigit()
                .frame(width: 47, alignment: .leading).padding(.top, 14)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 3)
                    if let sector, !sector.crew.isEmpty {
                        Button { crewSector = sector } label: { Image(systemName: "person.2") }
                            .buttonStyle(.plain).frame(minWidth: 30, minHeight: 24)
                            .accessibilityLabel("View crew for " + sector.code)
                    }
                }
                if !arrival.isEmpty || !detail.isEmpty {
                    Text([arrival.isEmpty ? "" : (sector == nil ? "End " : "Arrive ") + arrival, detail].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading).midnightCard(radius: 13)
        }
    }
}

private struct IceSelectedRosterDay: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let item: RosterItem
    let isChanged: Bool
    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.dateISO.flatMap(rosterCalendarDate)?.formatted(.dateTime.weekday(.wide).day().month(.wide)) ?? item.dateText)
                        .font(.headline)
                    Text("Local times" + (isChanged ? " · Roster changed" : "")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if item.sectorCount > 0 { Text("\(item.sectorCount) sectors").font(.caption).foregroundStyle(.secondary) }
            }
            IcePickupCard(item: item)
            IceDutyAgenda(item: item)
            NavigationLink { RosterDetailView(item: item) } label: {
                Label("Full briefing & notes", systemImage: "doc.text").font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }.padding(.top, 12)
    }
}

struct TodayView: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @ObservedObject var store: RosterStore
    let openPortal: () -> Void
    @StateObject private var calendarExporter = CalendarExporter()
    private enum CompanionSheet: String, Identifiable {
        case crewControl, announcements, documents
        var id: String { rawValue }
    }
    @State private var activeSheet: CompanionSheet?
    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if store.isCacheValidated, let item = store.todayPrimaryItem, TodayRouteMapCard.canDisplay(item) {
                        TodayRouteMapCard(item: item, iceHeader: true)
                    } else {
                        IcePageHeading(title: "Today", subtitle: Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 22)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        if store.isCacheValidated, let item = store.todayPrimaryItem {
                            IcePickupCard(item: item)
                            IceReadinessView(item: item, store: store)
                            IceDutyAgenda(item: item, onCalendarExport: { calendarExporter.export(item) }, canExport: !calendarExporter.isWorking)
                            TodayPersonalNoteDisclosure(item: item)
                            if let sector = crewCompanionSector(item, at: Date()) {
                                HStack { Text("My position").font(.caption).foregroundStyle(.secondary); Spacer()
                                    CrewCompanionRolePicker(dutyID: item.id, sectorID: sector.id).id(sector.id) }
                            }
                            if !item.aircraft.isEmpty {
                                DisclosureGroup("Aircraft") { AircraftCard(item: item).padding(.top, 8) }
                                    .font(.subheadline).padding(13).midnightCard(radius: 13)
                            }
                            if !item.hotelAssignments.isEmpty || !item.transferNotes.isEmpty {
                                DisclosureGroup("Hotel & transport") { LogisticsCard(item: item).padding(.top, 8) }
                                    .font(.subheadline).padding(13).midnightCard(radius: 13)
                            }
                            if !item.dayNotes.isEmpty || !item.activityNotes.isEmpty {
                                DisclosureGroup("Duty notes") { NotesCard(item: item).padding(.top, 8) }
                                    .font(.subheadline).padding(13).midnightCard(radius: 13)
                            }
                            if let next = store.nextOperationalDuty(after: item), let interval = store.restInterval(after: item, before: next) {
                                RestToNextDutyCard(next: next, interval: interval)
                            }
                        } else {
                            ContentUnavailableView(store.hasCache ? "Roster needs a resync" : "Import your roster", systemImage: "calendar.badge.exclamationmark",
                                description: Text("Open Live RAIDO while online to save your duty briefing."))
                            Button("Open Live RAIDO", action: openPortal).raidoPrimaryAction()
                        }
                        HStack(spacing: 9) {
                            MidnightQuickAction(title: "Announcements", symbol: "megaphone") { activeSheet = .announcements }
                            MidnightQuickAction(title: "Crew Control", symbol: "headphones") { activeSheet = .crewControl }
                            MidnightQuickAction(title: "Documents", symbol: "lock.doc") { activeSheet = .documents }
                        }.padding(.top, 5)
                        SyncFreshnessStrip(store: store)
                    }.padding(.horizontal, 18).padding(.bottom, 20)
                }
            }.midnightCanvas().toolbar(.hidden, for: .navigationBar)
                .sheet(item: $activeSheet) { sheet in
                    switch sheet {
                    case .crewControl: CrewControlSheet(item: store.todayPrimaryItem ?? store.nextDuty)
                    case .announcements: AnnouncementsView(item: store.isCacheValidated ? store.todayPrimaryItem : nil)
                    case .documents: CrewDocumentsView()
                    }
                }
                .alert("Calendar", isPresented: Binding(get: { calendarExporter.message != nil }, set: { if !$0 { calendarExporter.message = nil } })) {
                    Button("OK", role: .cancel) { calendarExporter.message = nil }
                } message: { Text(calendarExporter.message ?? "") }
        }
    }
}

private struct IceMoreView: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @ObservedObject var store: RosterStore
    @ObservedObject var browser: RosterBrowserModel
    let openPortal: () -> Void
    private enum Destination: String, Identifiable {
        case earnings, documents, announcements, manuals, settings, crew
        var id: String { rawValue }
    }
    @State private var destination: Destination?
    @State private var pendingPortal = false
    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    IcePageHeading(title: "More", subtitle: "Your crew essentials").padding(.bottom, 14)
                    Button(action: openPortal) { IceToolRow(title: "Live RAIDO", subtitle: "Open the original crew portal", symbol: "globe") }
                    Text("Crew tools").font(.headline).padding(.top, 15).padding(.bottom, 3)
                    tool("Earnings", "Monthly pay, block hours & pay profiles", "eurosign.circle", .earnings)
                    tool("Crew Documents", "Your private document vault", "lock.doc", .documents)
                    tool("Announcements", "Scripts for your aircraft and airline", "megaphone", .announcements)
                    tool("Manuals", "Access through the live company portal", "book.closed", .manuals)
                    tool("Crew Control", "Phone, WhatsApp & email", "headphones", .crew)
                    Text("Preferences").font(.headline).padding(.top, 15).padding(.bottom, 3)
                    tool("Settings", "Appearance, reminders, units & diagnostics", "gearshape", .settings)
                    SyncFreshnessStrip(store: store)
                }.buttonStyle(.plain).padding(18)
            }.midnightCanvas().toolbar(.hidden, for: .navigationBar)
                .sheet(item: $destination, onDismiss: {
                    if pendingPortal { pendingPortal = false; openPortal() }
                }) { selected in
                    switch selected {
                    case .earnings:
                        NavigationStack {
                            MonthlyEarningsView(roster: store, earnings: EarningsStore.shared,
                                month: store.selectedRosterMonth ?? String(EarningsMath.day(Date()).prefix(7)))
                                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { destination = nil } } }
                        }
                    case .documents: CrewDocumentsView()
                    case .announcements: AnnouncementsView(item: store.isCacheValidated ? store.todayPrimaryItem : nil)
                    case .crew: CrewControlSheet(item: store.todayPrimaryItem ?? store.nextDuty)
                    case .settings: SettingsView(store: store, browser: browser) { pendingPortal = true; destination = nil }
                    case .manuals:
                        NavigationStack {
                            VStack(spacing: 18) {
                                Image(systemName: "book.closed").font(.system(size: 40)).foregroundStyle(MidnightTheme.accent)
                                Text("Company manuals").font(.title2.weight(.semibold))
                                Text("Open Live RAIDO to access your company’s manuals. Documents saved in Crew Documents remain available offline.")
                                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                Button("Open Live RAIDO") { pendingPortal = true; destination = nil }.raidoPrimaryAction()
                            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).midnightCanvas()
                                .navigationTitle("Manuals").navigationBarTitleDisplayMode(.inline)
                                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { destination = nil } } }
                        }
                    }
                }
        }
    }
    private func tool(_ title: String, _ subtitle: String, _ symbol: String, _ target: Destination) -> some View {
        Button { destination = target } label: { IceToolRow(title: title, subtitle: subtitle, symbol: symbol) }
    }
}

private enum OfflineMapPlaces {
    static let labels: [OfflinePlaceLabel] = {
        guard let url = Bundle.main.url(forResource: "OfflinePlaceLabels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalogue = try? JSONDecoder().decode(OfflinePlaceCatalogue.self, from: data) else { return [] }
        return catalogue.labels
    }()

    static func draw(in context: inout GraphicsContext, size: CGSize,
                     viewport: OfflineAviationMapViewport, zoom: CGFloat, pan: CGSize,
                     airports: [CLLocationCoordinate2D], aircraft: CLLocationCoordinate2D?) {
        let screenRoute = airports.map { viewport.point(for: $0, in: size, zoom: zoom, pan: pan) }
        var protected = screenRoute.map { CGRect(x: $0.x - 24, y: $0.y - 14, width: 48, height: 44) }
        if let aircraft {
            let point = viewport.point(for: aircraft, in: size, zoom: zoom, pan: pan)
            protected.append(CGRect(x: point.x - 26, y: point.y - 26, width: 52, height: 52))
        }
        var resolved: [String: GraphicsContext.ResolvedText] = [:]
        var candidates: [MapLabelLayout.Candidate] = []
        for place in labels {
            let point = viewport.point(for: .init(latitude: place.latitude, longitude: place.longitude), in: size, zoom: zoom, pan: pan)
            guard point.x > 8, point.x < size.width - 8, point.y > 8, point.y < size.height - 8 else { continue }
            let title: String
            let priority: Int
            let font: Font
            switch place.kind {
            case .water: title = place.name; priority = 0; font = .system(size: 11, weight: .regular).italic()
            case .country: title = place.name.uppercased(); priority = 1; font = .system(size: 10, weight: .medium)
            case .capital: title = "⋆ " + place.name; priority = 2; font = .system(size: 10, weight: .medium)
            case .landmark: title = "△ " + place.name; priority = 3; font = .system(size: 10)
            case .city: title = "· " + place.name; priority = 4; font = .system(size: 10)
            }
            let text = context.resolve(Text(title).font(font).tracking(place.kind == .country ? 0.7 : 0)
                .foregroundStyle(MidnightTheme.mapLabelInk))
            let measure = text.measure(in: CGSize(width: 180, height: 30))
            let rect = CGRect(x: point.x - measure.width / 2, y: point.y - measure.height / 2, width: measure.width, height: measure.height)
            resolved[place.id] = text
            candidates.append(.init(id: place.id, name: place.name, priority: priority, rank: place.rank, rect: rect))
        }
        for candidate in MapLabelLayout.select(candidates, size: size, protected: protected, route: screenRoute, limit: size.height < 220 ? 5 : 11) {
            if let text = resolved[candidate.id] {
                context.draw(text, at: CGPoint(x: candidate.rect.midX, y: candidate.rect.midY), anchor: .center)
            }
        }
    }
}

extension View {
    func raidoPrimaryAction() -> some View {
        buttonStyle(.borderedProminent).tint(MidnightTheme.actionFill).foregroundStyle(MidnightTheme.actionInk)
    }
}

// V2.29.3 offline map interaction
// UIKit arbitrates the map recognizers against an enclosing UIScrollView.
// Pan and pinch may cooperate with each other, never with page scrolling.
private struct OfflineMapInteractionSurface: UIViewRepresentable {
    @Binding var zoom: CGFloat
    @Binding var pan: CGSize
    let interactive: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let drag = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.drag(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        drag.delegate = context.coordinator
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(drag)
        view.addGestureRecognizer(pinch)
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "offline-map-interaction"
        view.accessibilityLabel = "Offline route map"
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        view.isUserInteractionEnabled = interactive
        #if DEBUG
        view.accessibilityValue = String(format: "zoom=%.3f;panX=%.1f;panY=%.1f", Double(zoom), Double(pan.width), Double(pan.height))
        #else
        view.accessibilityValue = "Zoom \(Int((zoom * 100).rounded())) percent"
        #endif
        view.accessibilityHint = "Drag to pan. Pinch to zoom. Swipe up to collapse. Tap the handle to toggle."
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: OfflineMapInteractionSurface
        private var panOrigin = CGSize.zero
        private var zoomOrigin: CGFloat = 1
        init(_ parent: OfflineMapInteractionSurface) { self.parent = parent }

        @objc func drag(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began { panOrigin = parent.pan }
            guard recognizer.state == .began || recognizer.state == .changed || recognizer.state == .ended else { return }
            let delta = recognizer.translation(in: recognizer.view)
            parent.pan = CGSize(width: panOrigin.width + delta.x, height: panOrigin.height + delta.y)
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .began { zoomOrigin = parent.zoom }
            guard recognizer.state == .began || recognizer.state == .changed || recognizer.state == .ended else { return }
            parent.zoom = min(7, max(1, zoomOrigin * recognizer.scale))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            gestureRecognizer.view === other.view &&
                ((gestureRecognizer is UIPanGestureRecognizer && other is UIPinchGestureRecognizer) ||
                 (gestureRecognizer is UIPinchGestureRecognizer && other is UIPanGestureRecognizer))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            // Lazy failure priority applies only to our actual enclosing page,
            // and disappears when this surface is removed or noninteractive.
            guard parent.interactive, let scroll = other.view as? UIScrollView,
                  other === scroll.panGestureRecognizer, let view = gestureRecognizer.view else { return false }
            return view.isDescendant(of: scroll)
        }
    }
}

// V2.29.5 blended map disclosure
private struct MapHeaderTapControl: UIViewRepresentable {
    let expanded: Bool
    let onToggle: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        button.accessibilityIdentifier = "today-map-handle"
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        button.accessibilityLabel = expanded ? "Collapse flight map" : "Expand flight map"
        button.accessibilityValue = expanded ? "Expanded" : "Collapsed"
    }
    final class Coordinator: NSObject {
        var parent: MapHeaderTapControl
        init(_ parent: MapHeaderTapControl) { self.parent = parent }
        @objc func tap() { parent.onToggle() }
    }
}

// Disclosure owns its direction before scrolling begins; it never waits for
// the page to bounce and never snaps contentOffset after a simultaneous scroll.
private struct TodayMapDisclosureObserver: UIViewRepresentable {
    let expanded: Bool
    let onToggle: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.connect = { [weak coordinator = context.coordinator] view in coordinator?.attach(from: view) }
        return view
    }
    func updateUIView(_ view: AttachmentView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach(from: view)
    }
    static func dismantleUIView(_ view: AttachmentView, coordinator: Coordinator) {
        coordinator.detach()
        view.connect = nil
    }
    final class AttachmentView: UIView {
        var connect: ((UIView) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); connect?(self) }
        override func layoutSubviews() { super.layoutSubviews(); connect?(self) }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TodayMapDisclosureObserver
        private weak var scroll: UIScrollView?
        private var beganExpanded = false
        private var originalBounces = true
        private lazy var drag = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        init(_ parent: TodayMapDisclosureObserver) { self.parent = parent }
        func attach(from view: UIView) {
            var ancestor = view.superview
            while let current = ancestor {
                if let found = current as? UIScrollView {
                    guard scroll !== found else { return }
                    detach()
                    scroll = found
                    originalBounces = found.bounces
                    found.bounces = false
                    drag.name = "raido.map.disclosure"
                    drag.delegate = self
                    drag.maximumNumberOfTouches = 1
                    drag.cancelsTouchesInView = true
                    found.addGestureRecognizer(drag)
                    return
                }
                ancestor = current.superview
            }
        }
        func detach() {
            scroll?.removeGestureRecognizer(drag)
            scroll?.bounces = originalBounces
            scroll = nil
        }
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let scroll else { return false }
            let velocity = drag.velocity(in: scroll)
            guard abs(velocity.y) > abs(velocity.x) * 1.4 else { return false }
            // Down expands at the top. Up collapses an open header. Ordinary
            // upward agenda scrolling and downward map pans remain available.
            if parent.expanded { return velocity.y < 0 }
            return velocity.y > 0 && scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 1
        }
        @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began { beganExpanded = parent.expanded }
            guard recognizer.state == .ended, let scroll else { return }
            let delta = recognizer.translation(in: scroll)
            guard let destination = MapExpansionGesture.destination(expanded: beganExpanded,
                horizontal: delta.x, vertical: delta.y), destination != parent.expanded else { return }
            // Let the map's simultaneous pan finish before reset-to-overview.
            // Otherwise its final sample can overwrite the collapse reset.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.expanded != destination else { return }
                self.parent.onToggle()
            }
        }
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            guard let scroll else { return false }
            // The map can pan independently, but the page must stay still.
            return other !== scroll.panGestureRecognizer
        }
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other === scroll?.panGestureRecognizer
        }
    }
}

// V2.29.7 coordinated colour palettes.
private struct RaidoPaletteEnvironmentKey: EnvironmentKey {
    static let defaultValue = RaidoPalette.iceBlue
}
extension EnvironmentValues {
    var raidoPalette: RaidoPalette {
        get { self[RaidoPaletteEnvironmentKey.self] }
        set { self[RaidoPaletteEnvironmentKey.self] = newValue }
    }
}

private struct RaidoPalettePicker: View {
    @Environment(\.raidoPalette) private var currentPalette
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: String
    let theme: RaidoTheme
    private var selected: RaidoPalette { RaidoPalette(rawValue: selection) ?? .defaultPalette(for: theme) }
    var body: some View {
        let _ = currentPalette
        List {
            Section {
                ForEach(RaidoPalette.allCases) { palette in
                    Button {
                        selection = palette.rawValue
                    } label: {
                        HStack(spacing: 14) {
                            preview(palette).frame(width: 80, height: 58)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(palette.title).font(.subheadline.weight(.semibold)).foregroundStyle(MidnightTheme.ink)
                                Text(palette.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 2)
                            if palette == selected {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(MidnightTheme.accent)
                            }
                        }.padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("palette-option-" + palette.rawValue)
                        .accessibilityLabel(palette.title + ". " + palette.subtitle)
                        .accessibilityValue(palette == selected ? "Selected" : "Not selected")
                        .listRowBackground(MidnightTheme.surface)
                }
            } footer: {
                Text("Saved for " + theme.title + ". Your light, dark or system setting stays the same.")
            }
        }.listStyle(.insetGrouped).midnightCanvas().navigationTitle("Color palette")
    }
    private func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    private func preview(_ palette: RaidoPalette) -> some View {
        let colors = palette.colors(dark: colorScheme == .dark)
        return HStack(spacing: 6) {
            Text("12").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color(colors.selectionInk)).frame(width: 27, height: 27)
                .background(color(colors.highlight), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(color(colors.accent)).frame(width: 22, height: 3)
                Capsule().fill(color(colors.offInk)).frame(width: 16, height: 2)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(color(colors.background), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(color(colors.border), lineWidth: 0.8))
            .accessibilityHidden(true)
    }
}
