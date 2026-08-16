import SwiftUI

struct CrewMember: Codable, Equatable, Identifiable {
    let role: String
    let code: String
    let name: String

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
        if !aircraftType.isEmpty {
            pieces.append(aircraftType.hasPrefix("A") ? aircraftType : "A\(aircraftType)")
        }
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
        return flightActivities.flatMap(\.crew).filter { member in
            guard !seen.contains(member.id) else { return false }
            seen.insert(member.id)
            return true
        }
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
}

struct SummaryMetric: Identifiable {
    let label: String
    let value: Int
    var id: String { label }
}

@MainActor
final class RosterStore: ObservableObject {
    @Published private(set) var snapshot: RosterSnapshot?
    @Published var changeNotice: String?

    private let calendar = Calendar.current
    private let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init() { load() }

    var items: [RosterItem] { snapshot?.items ?? [] }
    var lastSync: Date? { snapshot?.capturedAt }
    var hasCache: Bool { !(snapshot?.items.isEmpty ?? true) }
    var isCacheValidated: Bool { snapshot?.validation?.isValid == true }
    var validationMessage: String? { snapshot?.validation?.message }
    var cachedMonth: String? { snapshot?.validation?.month }

    var todayItems: [RosterItem] {
        let key = isoDay.string(from: Date())
        return items.filter { $0.dateISO == key }
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
        return items.compactMap { item -> (RosterItem, Date)? in
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

        var seenDates = Set<String>()
        let parsed: [RosterItem] = rawRows.enumerated().compactMap { offset, row in
            let text = (row["rawText"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let dateISO = row["dateISO"] as? String,
                  !dateISO.isEmpty,
                  !seenDates.contains(dateISO) else { return nil }
            seenDates.insert(dateISO)

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
            validation: validation
        )

        if let old, normalized(old.items) != normalized(parsed) {
            var oldMap: [String: String] = [:]
            for item in old.items {
                if let date = item.dateISO { oldMap[date] = normalizedItem(item) }
            }
            var newMap: [String: String] = [:]
            for item in parsed {
                if let date = item.dateISO { newMap[date] = normalizedItem(item) }
            }
            let dates = Set(oldMap.keys).union(newMap.keys)
            let changed = dates.filter { oldMap[$0] != newMap[$0] }.count
            changeNotice = changed > 0 ? "Roster updated • \(changed) changed day\(changed == 1 ? "" : "s")" : "Roster updated"
        }

        snapshot = newSnapshot
        save(newSnapshot)
    }

    func dismissChangeNotice() { changeNotice = nil }

    func clearCache() {
        snapshot = nil
        changeNotice = nil
        try? FileManager.default.removeItem(at: cacheURL)
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
            return CrewMember(role: role, code: code, name: name)
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
            "\($0.id)|\($0.transferNote)|\($0.activityNote)|\($0.dayNote)|\($0.aircraftReg)"
        }.joined(separator: "~")
        return "\(item.dateISO ?? "")|\(item.category)|\(item.rawText)|\(detail)"
    }

    private var cacheURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("RAIDORoster", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("roster-cache.json")
    }

    private func save(_ snapshot: RosterSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        snapshot = try? decoder.decode(RosterSnapshot.self, from: data)
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

enum MainTab: Hashable { case roster, today, portal, settings }

struct ContentView: View {
    @StateObject private var appState = AppState()
    @State private var selectedTab: MainTab = .roster

    var body: some View {
        TabView(selection: $selectedTab) {
            RosterHomeView(store: appState.rosterStore) { selectedTab = .portal }
                .tabItem { Label("Roster", systemImage: "calendar") }
                .tag(MainTab.roster)

            TodayView(store: appState.rosterStore) { selectedTab = .portal }
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag(MainTab.today)

            PortalView(model: appState.browser, store: appState.rosterStore) { selectedTab = .roster }
                .tabItem { Label("RAIDO", systemImage: "airplane") }
                .tag(MainTab.portal)

            SettingsView(store: appState.rosterStore, browser: appState.browser) { selectedTab = .portal }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
    }
}

struct RosterHomeView: View {
    @ObservedObject var store: RosterStore
    let openPortal: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    statusHeader

                    if let notice = store.changeNotice {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            Text(notice).font(.subheadline.weight(.semibold))
                            Spacer()
                            Button { store.dismissChangeNotice() } label: { Image(systemName: "xmark") }
                        }
                        .padding(14)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }

                    if !store.hasCache {
                        emptyState
                    } else {
                        if let duty = store.nextDuty {
                            sectionTitle("Next duty")
                            NavigationLink { RosterDetailView(item: duty) } label: { DutyHeroCard(item: duty) }
                                .buttonStyle(.plain)
                        }

                        if !store.summaryMetrics.isEmpty {
                            sectionTitle("Month overview")
                            summaryGrid
                        }

                        sectionTitle("Upcoming")
                        VStack(spacing: 10) {
                            ForEach(Array(store.upcomingItems.prefix(31))) { item in
                                NavigationLink { RosterDetailView(item: item) } label: { RosterRowCard(item: item) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("RAIDO Roster")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: openPortal) { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Open RAIDO and sync")
                }
            }
        }
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
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
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
            Button("Open RAIDO", action: openPortal).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
            ForEach(store.summaryMetrics) { metric in
                VStack(spacing: 5) {
                    Text("\(metric.value)").font(.title2.bold())
                    Text(metric.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline).padding(.top, 2)
    }
}

struct TodayView: View {
    @ObservedObject var store: RosterStore
    let openPortal: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.title2.bold())

                    if !store.isCacheValidated {
                        validationWarning
                    } else if let item = store.todayItems.first {
                        DutyBriefingView(item: item, showTechnical: false)
                    } else {
                        emptyToday
                    }
                }
                .padding()
            }
            .navigationTitle("Today")
        }
    }

    private var emptyToday: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("No roster row matched today").font(.headline)
            Text("Open RAIDO to synchronize the current roster.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Open RAIDO", action: openPortal).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    private var validationWarning: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text(store.hasCache ? "Roster needs a resync" : "Roster not cached").font(.headline)
            Text("Open RAIDO once while online to rebuild the offline duty briefing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open RAIDO", action: openPortal).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }
}

struct DutyBriefingView: View {
    let item: RosterItem
    let showTechnical: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DutyHeroCard(item: item)

            if item.isOperationalDuty, !item.operationalActivities.isEmpty {
                DutyLiveStatusCard(item: item)
                DutyMetricsGrid(item: item)
                BriefingSectionTitle("Duty timeline")
                DutyTimelineCard(item: item)
            }

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
    let item: RosterItem

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let status = item.liveStatus(at: context.date) {
                HStack(spacing: 12) {
                    Image(systemName: status.systemImage)
                        .font(.title3)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.label)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(status.title)
                            .font(.headline)
                        if !status.subtitle.isEmpty {
                            Text(status.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

struct DutyMetricsGrid: View {
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                VStack(spacing: 4) {
                    Text(metric.1).font(.headline.monospacedDigit())
                    Text(metric.0).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

struct DutyTimelineCard: View {
    let item: RosterItem

    var body: some View {
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
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct TimelinePoint: View {
    let time: String
    let title: String
    let subtitle: String
    var trailing: String = ""
    let icon: String

    var body: some View {
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

struct LogisticsCard: View {
    let item: RosterItem

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(item.pickups, id: \.self) { pickup in
                InfoRow(icon: "car.fill", title: "Pickup", value: pickup)
            }

            ForEach(item.hotelAssignments) { hotel in
                InfoRow(
                    icon: "bed.double.fill",
                    title: hotel.hotelName.isEmpty ? hotel.title : hotel.hotelName,
                    value: hotelRange(hotel)
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
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct NotesCard: View {
    let item: RosterItem

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(item.dayNotes, id: \.self) { note in
                NoteBlock(title: "Day note", icon: "calendar.badge.exclamationmark", text: note)
            }
            ForEach(item.activityNotes, id: \.self) { note in
                NoteBlock(title: "Activity note", icon: "note.text", text: note)
            }
        }
        .padding(15)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct NoteBlock: View {
    let title: String
    let icon: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
            Text(text).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

struct AircraftCard: View {
    let item: RosterItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(item.aircraft) { aircraft in
                HStack(spacing: 12) {
                    Image(systemName: "airplane.circle.fill").font(.title2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(aircraft.aircraftDisplay.isEmpty ? "Aircraft" : aircraft.aircraftDisplay)
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
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct CrewCard: View {
    let item: RosterItem

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(item.crewMembers.enumerated()), id: \.offset) { index, member in
                HStack(spacing: 12) {
                    Text(member.role)
                        .font(.caption.bold())
                        .frame(width: 38)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.name).font(.subheadline.weight(.medium))
                        if !member.code.isEmpty {
                            Text(member.code).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 9)
                if index < item.crewMembers.count - 1 { Divider().padding(.leading, 50) }
            }
        }
        .padding(.horizontal, 15)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct InfoRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
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
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.headline).padding(.top, 2) }
}

struct PortalView: View {
    @ObservedObject var model: RosterBrowserModel
    @ObservedObject var store: RosterStore
    let openRoster: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                RosterWebView(model: model).ignoresSafeArea(edges: .bottom)

                if let error = model.loadError {
                    Color(uiColor: .systemBackground).ignoresSafeArea()
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
                            Button("View Offline Roster", action: openRoster).buttonStyle(.borderedProminent)
                        }
                        Button("Try RAIDO Again") { model.reload() }.buttonStyle(.bordered)
                    }
                    .padding(28)
                }
            }
            .navigationTitle(model.pageTitle.isEmpty ? "RAIDO" : model.pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { model.goBack() } label: { Image(systemName: "chevron.backward") }
                        .disabled(!model.canGoBack)
                    Button { model.goToday() } label: { Image(systemName: "calendar.circle") }
                        .accessibilityLabel("Scroll RAIDO to today")
                    Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: RosterStore
    @ObservedObject var browser: RosterBrowserModel
    let openPortal: () -> Void
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
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
                }

                Section("Portal") {
                    Button("Open RAIDO start page") {
                        browser.openStartPage()
                        openPortal()
                    }
                    Text("RAIDO remains the live source. Roster and Today use the saved offline briefing when there is no connection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Diagnostics") {
                    Button("Copy sanitized RAIDO diagnostics") { browser.copyDiagnostics() }
                    if let status = browser.diagnosticStatus {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Diagnostics redact email addresses, phone numbers, URLs and booking references.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Version") {
                    LabeledContent("RAIDO Roster", value: "2.4")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Clear the saved offline roster?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Cache", role: .destructive) { store.clearCache() }
            }
        }
    }
}

struct DutyHeroCard: View {
    let item: RosterItem

    var body: some View {
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
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct RosterRowCard: View {
    let item: RosterItem

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(categoryColor(item.category))
                .frame(width: 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.displayTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
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
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct RosterDetailView: View {
    let item: RosterItem

    var body: some View {
        ScrollView {
            DutyBriefingView(item: item, showTechnical: true)
                .padding()
        }
        .navigationTitle("Duty")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CategoryBadge: View {
    let category: String

    var body: some View {
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
    case "FLIGHT": return .blue
    case "POSITIONING": return .indigo
    case "RESERVE": return .orange
    case "STANDBY": return .purple
    case "OFF", "REST": return .green
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
