import Foundation
import Combine
import EventKit
import UserNotifications
import os

@MainActor
final class RosterStore: ObservableObject {
    @Published private(set) var snapshot: RosterSnapshot?
    @Published private(set) var monthSnapshots: [String: RosterSnapshot] = [:]
    @Published var selectedRosterMonthKey: String?
    @Published var changeNotice: String?
    @Published private(set) var portalFormatWarning: String?
    @Published private(set) var rosterSourceURL: URL?
    private(set) var cacheGeneration = UUID()

    private func reportPortalFormatFailure(_ error: Error) {
        portalFormatWarning = hasCache
            ? "Portal format changed · your saved roster is retained. Open Live RAIDO to retry."
            : "Portal format changed. Open Live RAIDO to retry."
        Logger(subsystem: "com.bobanilic.raidoroster", category: "Roster").error("Roster payload rejected: \(String(describing: error), privacy: .public)")
    }
    @Published private(set) var changedDates: Set<String> = []
    @Published private(set) var latestChanges: [RosterDayChange] = []
    @Published var calendarSyncStatus: String?
    @Published var reminderSyncStatus: String?

    private let calendar = Calendar.current
    private let automaticCalendarExporter = CalendarExporter()
    private let automaticReminderScheduler = DutyReminderScheduler()
    private let storageFolderOverride: URL?
    private let automaticSideEffects: Bool
    private let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(storageFolderURL: URL? = nil, automaticSideEffects: Bool = true) {
        storageFolderOverride = storageFolderURL
        self.automaticSideEffects = automaticSideEffects
        load()
        loadChangeState()
        do {
            if let value = try ProtectedJSONFile<String>(url: rosterSourceCacheURL).load(),
               let url = URL(string: value), RosterMonthCachePolicy.isRosterURL(url) { rosterSourceURL = url }
        } catch { DeviceCacheStorage.report("Load roster source", error: error) }
        try? FileManager.default.removeItem(at: self.storageFolderURL.appendingPathComponent("crew-history.json"))
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

    @discardableResult
    func ingest(messageBody: Any, archiveOnly: Bool = false, expectedMonth: String? = nil) -> Bool {
        let checked: [String: Any]
        do { checked = try PortalBridgePolicy.snapshot(messageBody, allowSparse: archiveOnly && expectedMonth != nil) }
        catch { if !archiveOnly { reportPortalFormatFailure(error) }; return false }
        let payload = checked
        guard let rawRows = payload["rows"] as? [[String: Any]],
              let validationPayload = payload["validation"] as? [String: Any] else { return false }

        let validation = RosterValidation(
            isValid: validationPayload["isValid"] as? Bool ?? false,
            parser: validationPayload["parser"] as? String ?? "unknown",
            month: validationPayload["month"] as? String ?? "",
            datedRows: validationPayload["datedRows"] as? Int ?? 0,
            message: validationPayload["message"] as? String ?? "Roster parse incomplete"
        )

        guard validation.isValid, expectedMonth == nil || validation.month == expectedMonth else { return false }
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

        guard parsed.count >= (archiveOnly && expectedMonth != nil ? 1 : 5),
              parsed.count == validation.datedRows,
              parsed.allSatisfy({ $0.dateISO != nil }) else { return false }

        let old = snapshot
        let newSnapshot = RosterSnapshot(
            capturedAt: Date(),
            sourceURL: payload["sourceURL"] as? String ?? "",
            pageTitle: payload["pageTitle"] as? String ?? "RAIDO",
            items: parsed,
            validation: validation,
            monthlyBLH: (payload["monthlyBLH"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )

        if archiveOnly {
            monthSnapshots[validation.month] = newSnapshot
            // Importing history never changes the visible month or change-review state.
            if snapshot == nil || validation.month == currentRosterMonthKey() {
                snapshot = newSnapshot
                save(newSnapshot)
            }
            saveMonthSnapshots()
            return true
        }

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
                if automaticSideEffects { notifyRosterChanges(changes) }
            }
        }

        portalFormatWarning = nil
        snapshot = newSnapshot
        save(newSnapshot)
        let archiveKey = monthKey(for: newSnapshot)
        selectedRosterMonthKey = validation.month.isEmpty ? archiveKey : validation.month
        monthSnapshots[archiveKey] = newSnapshot
        selectedRosterMonthKey = archiveKey
        saveMonthSnapshots()

        guard automaticSideEffects else { return true }
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
        return true
    }

    func rememberRosterSourceURL(_ url: URL) {
        guard RosterMonthCachePolicy.isRosterURL(url) else { return }
        rosterSourceURL = url
        do { try ProtectedJSONFile<String>(url: rosterSourceCacheURL).save(url.absoluteString) }
        catch { DeviceCacheStorage.report("Save roster source", error: error) }
    }

    func ingestCalendarFeed(messageBody: Any) {
        let checked: [String: Any]
        do { checked = try PortalBridgePolicy.calendarFeed(messageBody) }
        catch {
            Logger(subsystem: "com.bobanilic.raidoroster", category: "Roster").error("Calendar payload rejected: \(String(describing: error), privacy: .public)")
            return
        }
        let payload = checked
        guard let rawEvents = payload["events"] as? [[String: Any]],
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
        cacheGeneration = UUID()
        rosterSourceURL = nil
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
        try? FileManager.default.removeItem(at: rosterSourceCacheURL)
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
        if let folder = storageFolderOverride {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("RAIDORoster", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private var changeStateURL: URL { storageFolderURL.appendingPathComponent("roster-changes.json") }

    private func saveChangeState() {
        let bundle = RosterChangeBundle(capturedAt: Date(), changes: latestChanges)
        do { try ProtectedJSONFile<RosterChangeBundle>(url: changeStateURL).save(bundle) }
        catch { DeviceCacheStorage.report("Save roster changes", error: error) }
    }

    private func loadChangeState() {
        let loaded: RosterChangeBundle?
        do { loaded = try ProtectedJSONFile<RosterChangeBundle>(url: changeStateURL).load() }
        catch { DeviceCacheStorage.report("Load roster changes", error: error); return }
        guard let bundle = loaded, !bundle.changes.isEmpty else { return }
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

    private var rosterSourceCacheURL: URL { storageFolderURL.appendingPathComponent("roster-source.json") }

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
        do { try ProtectedJSONFile<[String: RosterSnapshot]>(url: monthCacheURL).save(monthSnapshots) }
        catch { DeviceCacheStorage.report("Save roster months", error: error) }
    }

    private func save(_ snapshot: RosterSnapshot) {
        do { try ProtectedJSONFile<RosterSnapshot>(url: cacheURL).save(snapshot) }
        catch { DeviceCacheStorage.report("Save roster", error: error) }
    }

    private func load() {
        var archiveReadable = true
        do { monthSnapshots = try ProtectedJSONFile<[String: RosterSnapshot]>(url: monthCacheURL).load() ?? [:] }
        catch { archiveReadable = false; DeviceCacheStorage.report("Load roster months", error: error) }
        do {
            if let latest = try ProtectedJSONFile<RosterSnapshot>(url: cacheURL).load() {
                snapshot = latest
                let key = monthKey(for: latest)
                monthSnapshots[key] = latest
                selectedRosterMonthKey = key
            }
        } catch { DeviceCacheStorage.report("Load roster", error: error) }
        if snapshot == nil, let key = monthSnapshots.keys.sorted().last {
            snapshot = monthSnapshots[key]
            selectedRosterMonthKey = key
        }
        normalizeMonthArchive()
        // An unreadable archive must never be replaced with a partial or empty one.
        if archiveReadable { saveMonthSnapshots() }
    }

}
