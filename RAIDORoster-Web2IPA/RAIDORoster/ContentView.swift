import SwiftUI

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

    var summary: [(String, Int)] {
        let groups = Dictionary(grouping: items, by: { $0.category.uppercased() })
        let preferred = ["FLIGHT", "POSITIONING", "RESERVE", "STANDBY", "OFF", "DND", "TRAINING"]
        return preferred.compactMap { key in
            guard let count = groups[key]?.count, count > 0 else { return nil }
            return (key, count)
        }
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
                cells: row["cells"] as? [String] ?? []
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
                if let date = item.dateISO { oldMap[date] = "\(item.category)|\(item.rawText)" }
            }
            var newMap: [String: String] = [:]
            for item in parsed {
                if let date = item.dateISO { newMap[date] = "\(item.category)|\(item.rawText)" }
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

    private func normalized(_ items: [RosterItem]) -> [String] {
        items.map { "\($0.dateISO ?? "")|\($0.category)|\($0.rawText)" }
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

                        if !store.summary.isEmpty {
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
                if store.hasCache, !store.isCacheValidated {
                    Text("Open RAIDO once after this update to rebuild the cache correctly.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
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
            Text("Open RAIDO, enter the mobile roster normally, and the app will save one dated activity for each roster day.")
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
            ForEach(store.summary, id: \.0) { category, count in
                VStack(spacing: 5) {
                    Text("\(count)").font(.title2.bold())
                    Text(prettyCategory(category))
                        .font(.caption.weight(.medium))
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
                VStack(alignment: .leading, spacing: 14) {
                    Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.title2.bold())

                    if !store.isCacheValidated {
                        validationWarning
                    } else if store.todayItems.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "calendar.badge.exclamationmark")
                                .font(.system(size: 38))
                                .foregroundStyle(.secondary)
                            Text("No roster row matched today").font(.headline)
                            Text("The current month is cached, but today's dated row was not found. Open RAIDO to sync again.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Open RAIDO", action: openPortal).buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 50)
                    } else {
                        ForEach(store.todayItems) { item in
                            NavigationLink { RosterDetailView(item: item) } label: { DutyHeroCard(item: item) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Today")
        }
    }

    private var validationWarning: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text(store.hasCache ? "Roster needs one clean resync" : "Roster not cached").font(.headline)
            Text(store.hasCache ? "V2.1 no longer trusts the old undated cache. Open the current RAIDO month once and Today will be rebuilt from dated rows." : "Open RAIDO to import your roster first.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open RAIDO", action: openPortal).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }
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
                    Text("The RAIDO tab is the live portal. If there is no internet, use the native Roster and Today tabs instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Diagnostics") {
                    Button("Copy sanitized RAIDO diagnostics") { browser.copyDiagnostics() }
                    if let status = browser.diagnosticStatus {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Copies only roster-page structure and visible roster text. It does not include password fields, cookies, or stored credentials.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Version") {
                    LabeledContent("RAIDO Roster", value: "2.1")
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
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    CategoryBadge(category: item.category)
                    Text(item.displayTitle).font(.title2.bold())
                    if !item.dateText.isEmpty { Label(item.dateText, systemImage: "calendar") }
                    if !item.route.isEmpty { Label(item.route, systemImage: "airplane") }
                    if !item.timeText.isEmpty { Label(item.timeText, systemImage: "clock") }
                }
                .padding(.vertical, 6)
            }

            if !item.cells.isEmpty {
                Section("RAIDO fields") {
                    ForEach(Array(item.cells.enumerated()), id: \.offset) { index, value in
                        LabeledContent("Field \(index + 1)", value: value)
                    }
                }
            }

            Section("Original roster day") {
                Text(item.rawText).textSelection(.enabled)
            }
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
