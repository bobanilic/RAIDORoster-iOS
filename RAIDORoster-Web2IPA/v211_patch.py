from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.11 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# -----------------------------------------------------------------------------
# Persistent, field-level roster changes + RAIDO-derived crew-history archive.
# Crew history stores duty occurrences only; historical phone numbers are never
# retained. Matching prefers RAIDO crew code and falls back to normalized name.
# -----------------------------------------------------------------------------
models = r'''
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

struct CrewHistoryOccurrence: Codable, Equatable, Identifiable {
    let id: String
    let crewKey: String
    let code: String
    let name: String
    let role: String
    let dateISO: String
    let sectors: Int
    let dutyEndUTC: String
}

struct CrewHistoryMonth: Codable, Equatable {
    let month: String
    let occurrences: [CrewHistoryOccurrence]
}

struct CrewHistorySummary: Equatable {
    let duties: Int
    let sectors: Int
    let lastFlownISO: String
}

'''
content = replace_once(
    content,
    '''struct SummaryMetric: Identifiable {
''',
    models + '''struct SummaryMetric: Identifiable {
''',
    "V2.11 models"
)

# RosterStore state. Change state and history are loaded separately so they
# survive normal app restarts while remaining independently clearable.
content = replace_once(
    content,
    '''    @Published private(set) var snapshot: RosterSnapshot?
    @Published var changeNotice: String?
    @Published private(set) var changedDates: Set<String> = []
    @Published var calendarSyncStatus: String?
    @Published var reminderSyncStatus: String?

    private let calendar = Calendar.current
    private let automaticCalendarExporter = CalendarExporter()
    private let automaticReminderScheduler = DutyReminderScheduler()
''',
    '''    @Published private(set) var snapshot: RosterSnapshot?
    @Published var changeNotice: String?
    @Published private(set) var changedDates: Set<String> = []
    @Published private(set) var latestChanges: [RosterDayChange] = []
    @Published private(set) var crewHistoryMonths: [String: CrewHistoryMonth] = [:]
    @Published var calendarSyncStatus: String?
    @Published var reminderSyncStatus: String?

    private let calendar = Calendar.current
    private let automaticCalendarExporter = CalendarExporter()
    private let automaticReminderScheduler = DutyReminderScheduler()
''',
    "RosterStore V2.11 state"
)

content = replace_once(
    content,
    '''    init() { load() }
''',
    '''    init() {
        load()
        loadChangeState()
        loadCrewHistory()
    }
''',
    "RosterStore V2.11 init"
)

# Index every valid RAIDO month before deciding whether it should become the
# active offline roster. Older months are history-only when a current-month
# cache is already present, preventing historical browsing from overwriting the
# live roster or creating false change alerts / Calendar updates.
content = replace_once(
    content,
    '''        let old = snapshot
        let newSnapshot = RosterSnapshot(
''',
    '''        indexCrewHistory(month: validation.month, items: parsed)

        let currentMonth = currentMonthKey()
        if validation.month < currentMonth,
           snapshot?.validation?.month == currentMonth {
            return
        }

        let old = snapshot
        let newSnapshot = RosterSnapshot(
''',
    "history-only older month ingest"
)

old_change_block = '''        changedDates = []
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
            changedDates = Set(dates.filter { oldMap[$0] != newMap[$0] })
            let changed = changedDates.count
            changeNotice = changed > 0 ? "Roster updated • \\(changed) changed day\\(changed == 1 ? "" : "s")" : "Roster updated"
        }

        snapshot = newSnapshot
        save(newSnapshot)
'''
new_change_block = '''        if let old,
           old.validation?.month == validation.month,
           normalized(old.items) != normalized(parsed) {
            let changes = buildDayChanges(old: old.items, new: parsed)
            if !changes.isEmpty {
                latestChanges = changes
                changedDates = Set(changes.map(\\.dateISO))
                let changed = changes.count
                changeNotice = "Roster changed • \\(changed) day\\(changed == 1 ? "" : "s")"
                saveChangeState()
                notifyRosterChanges(changes)
            }
        }

        snapshot = newSnapshot
        save(newSnapshot)
'''
content = replace_once(content, old_change_block, new_change_block, "persistent detailed change detection")

content = replace_once(
    content,
    '''    func dismissChangeNotice() {
        changeNotice = nil
        changedDates = []
    }
''',
    '''    func dismissChangeNotice() {
        changeNotice = nil
        changedDates = []
        latestChanges = []
        try? FileManager.default.removeItem(at: changeStateURL)
    }

    func change(for dateISO: String?) -> RosterDayChange? {
        guard let dateISO else { return nil }
        return latestChanges.first { $0.dateISO == dateISO }
    }

    func crewHistory(for member: CrewMember) -> CrewHistorySummary? {
        let key = crewHistoryKey(code: member.code, name: member.name)
        let now = Date()
        let today = isoDay.string(from: now)
        let matches = crewHistoryMonths.values
            .flatMap(\\.occurrences)
            .filter { occurrence in
                guard occurrence.crewKey == key else { return false }
                if let end = parseUTCStamp(occurrence.dutyEndUTC) { return end <= now }
                return occurrence.dateISO < today
            }

        guard !matches.isEmpty else { return nil }
        let uniqueByDay = Dictionary(grouping: matches, by: \\.dateISO)
        let duties = uniqueByDay.count
        let sectors = uniqueByDay.values.reduce(0) { total, values in
            total + (values.map(\\.sectors).max() ?? 0)
        }
        let last = matches.map(\\.dateISO).max() ?? ""
        return CrewHistorySummary(duties: duties, sectors: sectors, lastFlownISO: last)
    }
''',
    "V2.11 dismiss + lookup"
)

content = replace_once(
    content,
    '''        snapshot = nil
        changeNotice = nil
        changedDates = []
        calendarSyncStatus = nil
        reminderSyncStatus = nil
        automaticReminderScheduler.clearRosterReminders()
        try? FileManager.default.removeItem(at: cacheURL)
''',
    '''        snapshot = nil
        changeNotice = nil
        changedDates = []
        latestChanges = []
        crewHistoryMonths = [:]
        calendarSyncStatus = nil
        reminderSyncStatus = nil
        automaticReminderScheduler.clearRosterReminders()
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.removeItem(at: changeStateURL)
        try? FileManager.default.removeItem(at: crewHistoryURL)
''',
    "clear V2.11 local data"
)

# Change fingerprint now includes every field that matters operationally. Phone
# numbers are deliberately excluded so a contact-format change cannot generate
# a CHANGED alert and no private phone data enters change history.
content = replace_once(
    content,
    '''    private func normalizedItem(_ item: RosterItem) -> String {
        let detail = item.activityList.map {
            "\\($0.id)|\\($0.transferNote)|\\($0.activityNote)|\\($0.dayNote)|\\($0.aircraftReg)"
        }.joined(separator: "~")
        return "\\(item.dateISO ?? "")|\\(item.category)|\\(item.rawText)|\\(detail)"
    }
''',
    '''    private func normalizedItem(_ item: RosterItem) -> String {
        let detail = item.activityList.map {
            let crew = $0.crew.map { "\\($0.role):\\($0.code):\\($0.name)" }.joined(separator: ",")
            return "\\($0.id)|\\($0.transferNote)|\\($0.activityNote)|\\($0.dayNote)|\\($0.pickup)|\\($0.aircraftReg)|\\($0.aircraftType)|\\($0.checkInUTC)|\\($0.checkOutUTC)|\\(crew)"
        }.joined(separator: "~")
        return "\\(item.dateISO ?? "")|\\(item.category)|\\(item.title)|\\(item.route)|\\(item.timeText)|\\(detail)"
    }
''',
    "rich roster fingerprint"
)

helpers = r'''
    private func buildDayChanges(old: [RosterItem], new: [RosterItem]) -> [RosterDayChange] {
        let oldMap = Dictionary(uniqueKeysWithValues: old.compactMap { item in item.dateISO.map { ($0, item) } })
        let newMap = Dictionary(uniqueKeysWithValues: new.compactMap { item in item.dateISO.map { ($0, item) } })
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

            if before?.transferNotes != after?.transferNotes || before?.activityNotes != after?.activityNotes || before?.dayNotes != after?.dayNotes {
                fields.append(.init(label: "Notes / transfer", oldValue: "Previous details", newValue: "Updated details"))
            }

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
        let flights = item.flightActivities.map(\\.code).filter { !$0.isEmpty }
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
            member.role.isEmpty ? member.name : "\\(member.role) \\(member.name)"
        }.joined(separator: ", ")
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
                ? "Roster changed • \\(changes[0].dateText)"
                : "Roster changed • \\(changes.count) days"
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
            pieces.append("\\(field.label): \\(field.oldValue) → \\(field.newValue)")
        }
        var body = pieces.joined(separator: " • ")
        if changes.count > 1 { body += " • +\\(changes.count - 1) more day\\(changes.count == 2 ? "" : "s")" }
        if body.count > 300 { body = String(body.prefix(297)) + "…" }
        return body.isEmpty ? "Open RAIDO Roster to review the changes." : body
    }

    private func crewHistoryKey(code: String, name: String) -> String {
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !cleanCode.isEmpty { return "CODE:" + cleanCode }
        let cleanName = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
        return "NAME:" + cleanName
    }

    private func indexCrewHistory(month: String, items: [RosterItem]) {
        guard !month.isEmpty else { return }
        var occurrences: [CrewHistoryOccurrence] = []

        for item in items where item.sectorCount > 0 {
            guard let dateISO = item.dateISO else { continue }
            var byCrew: [String: (member: CrewMember, sectors: Int)] = [:]

            for flight in item.flightActivities {
                var seenOnSector = Set<String>()
                for member in flight.crew {
                    let key = crewHistoryKey(code: member.code, name: member.name)
                    guard !key.hasSuffix("NAME:"), !seenOnSector.contains(key) else { continue }
                    seenOnSector.insert(key)
                    if let existing = byCrew[key] {
                        byCrew[key] = (existing.member, existing.sectors + 1)
                    } else {
                        byCrew[key] = (member, 1)
                    }
                }
            }

            let endUTC = item.operationalActivities.reversed().compactMap { activity in
                activity.checkOutUTC.nilIfEmpty ?? activity.endUTC.nilIfEmpty
            }.first ?? ""

            for (key, value) in byCrew {
                occurrences.append(CrewHistoryOccurrence(
                    id: "\\(month)|\\(dateISO)|\\(key)",
                    crewKey: key,
                    code: value.member.code,
                    name: value.member.name,
                    role: value.member.role,
                    dateISO: dateISO,
                    sectors: value.sectors,
                    dutyEndUTC: endUTC
                ))
            }
        }

        crewHistoryMonths[month] = CrewHistoryMonth(month: month, occurrences: occurrences)
        saveCrewHistory()
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
    private var crewHistoryURL: URL { storageFolderURL.appendingPathComponent("crew-history.json") }

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
        latestChanges = bundle.changes
        changedDates = Set(bundle.changes.map(\\.dateISO))
        let count = bundle.changes.count
        changeNotice = "Roster changed • \\(count) day\\(count == 1 ? "" : "s")"
    }

    private func saveCrewHistory() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(crewHistoryMonths) { try? data.write(to: crewHistoryURL, options: .atomic) }
    }

    private func loadCrewHistory() {
        guard let data = try? Data(contentsOf: crewHistoryURL) else { return }
        crewHistoryMonths = (try? JSONDecoder().decode([String: CrewHistoryMonth].self, from: data)) ?? [:]
    }

'''
content = replace_once(
    content,
    '''    private var cacheURL: URL {
''',
    helpers + '''    private var cacheURL: URL {
''',
    "V2.11 store helpers"
)

# Use the same application-support folder for the existing roster cache.
content = replace_once(
    content,
    '''    private var cacheURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("RAIDORoster", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("roster-cache.json")
    }
''',
    '''    private var cacheURL: URL {
        storageFolderURL.appendingPathComponent("roster-cache.json")
    }
''',
    "shared storage folder"
)

# -----------------------------------------------------------------------------
# Main UI: expose RosterStore to nested duty/crew views without plumbing it
# through every existing initializer.
# -----------------------------------------------------------------------------
content = replace_once(
    content,
    '''            SettingsView(store: appState.rosterStore, browser: appState.browser) { selectedTab = .portal }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
''',
    '''            SettingsView(store: appState.rosterStore, browser: appState.browser) { selectedTab = .portal }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
        .environmentObject(appState.rosterStore)
''',
    "RosterStore environment"
)

# Change banner gets a compact Review route while keeping dismiss independent.
content = replace_once(
    content,
    '''                    if let notice = store.changeNotice {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            Text(notice).font(.subheadline.weight(.semibold))
                            Spacer()
                            Button { store.dismissChangeNotice() } label: { Image(systemName: "xmark") }
                        }
                        .padding(14)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
''',
    '''                    if let notice = store.changeNotice {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            Text(notice).font(.subheadline.weight(.semibold))
                            Spacer()
                            if !store.latestChanges.isEmpty {
                                NavigationLink("Review") {
                                    RosterChangesView(changes: store.latestChanges)
                                }
                                .font(.caption.bold())
                            }
                            Button { store.dismissChangeNotice() } label: { Image(systemName: "xmark") }
                        }
                        .padding(14)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
''',
    "review changes banner"
)

# Detailed duty view automatically shows the field-level diff for a CHANGED day.
old_detail = '''struct RosterDetailView: View {
    let item: RosterItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DutyBriefingView(item: item, showTechnical: true)
                BriefingSectionTitle("My note")
                PersonalDutyNoteCard(item: item)
            }
            .padding()
        }
        .navigationTitle("Duty")
        .navigationBarTitleDisplayMode(.inline)
    }
}
'''
new_detail = '''struct RosterDetailView: View {
    let item: RosterItem
    @EnvironmentObject private var store: RosterStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let change = store.change(for: item.dateISO) {
                    BriefingSectionTitle("Roster change")
                    RosterChangeCard(change: change)
                }
                DutyBriefingView(item: item, showTechnical: true)
                BriefingSectionTitle("My note")
                PersonalDutyNoteCard(item: item)
            }
            .padding()
        }
        .navigationTitle("Duty")
        .navigationBarTitleDisplayMode(.inline)
    }
}
'''
content = replace_once(content, old_detail, new_detail, "changed duty detail")

change_views = r'''
struct RosterChangesView: View {
    let changes: [RosterDayChange]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(changes) { change in
                    RosterChangeCard(change: change)
                }
            }
            .padding()
        }
        .navigationTitle("Roster changes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RosterChangeCard: View {
    let change: RosterDayChange

    var body: some View {
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

'''
content = replace_once(
    content,
    '''struct CategoryBadge: View {
''',
    change_views + '''struct CategoryBadge: View {
''',
    "roster change views"
)

# Crew expanded contact now includes RAIDO-derived flying history. No history is
# generated from button taps or app sessions; it comes from indexed roster data.
content = replace_once(
    content,
    '''struct CrewCard: View {
    let item: RosterItem
    @State private var expandedCrewID: String?
''',
    '''struct CrewCard: View {
    let item: RosterItem
    @EnvironmentObject private var store: RosterStore
    @State private var expandedCrewID: String?
''',
    "CrewCard history store"
)

content = replace_once(
    content,
    '''                                .buttonStyle(.bordered)
                                .accessibilityLabel("Copy crew phone number")
                            }
                        }
                        .padding(.leading, 50)
''',
    '''                                .buttonStyle(.bordered)
                                .accessibilityLabel("Copy crew phone number")
                            }

                            if let history = store.crewHistory(for: member), history.duties > 0 {
                                Divider()
                                HStack(spacing: 10) {
                                    Image(systemName: "person.2.fill")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Together from RAIDO")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("\\(history.duties) dut\\(history.duties == 1 ? "y" : "ies") • \\(history.sectors) sector\\(history.sectors == 1 ? "" : "s")")
                                            .font(.subheadline.weight(.semibold))
                                        if !history.lastFlownISO.isEmpty {
                                            Text("Last flown \\(historyDateLabel(history.lastFlownISO))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                        }
                        .padding(.leading, 50)
''',
    "crew RAIDO history UI"
)

# Settings remains compact: show archive coverage and an explicit way to grant
# the same iOS notification permission used by roster-change alerts.
content = replace_once(
    content,
    '''                    LabeledContent("Cached days", value: "\\(store.items.count)")
''',
    '''                    LabeledContent("Cached days", value: "\\(store.items.count)")
                    LabeledContent("Crew history months", value: "\\(store.crewHistoryMonths.count)")
''',
    "crew history coverage"
)

content = replace_once(
    content,
    '''                    Text("Reminders are local to this iPhone and are automatically refreshed after a valid RAIDO roster sync. They do not require a server or background roster polling.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
''',
    '''                    Button {
                        Task {
                            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                        }
                    } label: {
                        Label("Enable roster change alerts", systemImage: "bell.and.waves.left.and.right")
                    }

                    Text("Reminders and roster-change alerts are local to this iPhone. Change alerts are generated only after a validated RAIDO refresh; there is no background roster polling.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
''',
    "change notification permission"
)

# Global display helper for the compact crew-history date.
history_date_helper = r'''
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

'''
content = replace_once(
    content,
    '''private extension String {
''',
    history_date_helper + '''private extension String {
''',
    "history date helper"
)

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.10.2")',
    'LabeledContent("RAIDO Roster", value: "2.11")',
    1
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 12;", "CURRENT_PROJECT_VERSION = 13;")
pbx = pbx.replace("MARKETING_VERSION = 2.10.2;", "MARKETING_VERSION = 2.11;")
PBX.write_text(pbx)

print("V2.11 detailed roster changes + RAIDO-derived crew history applied")
