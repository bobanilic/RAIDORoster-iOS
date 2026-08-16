from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "RAIDORoster"
CONTENT = SRC / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.8 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# V2.8 is deliberately native-only. The proven RAIDO parser is untouched.
if "import UserNotifications" not in content:
    content = content.replace("import EventKit\n", "import EventKit\nimport UserNotifications\n", 1)

# -----------------------------------------------------------------------------
# Local duty reminders. No server, push provider, background polling or new
# RAIDO script: notifications are regenerated from the validated offline cache.
# -----------------------------------------------------------------------------
reminder_support = r'''
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
'''

content = replace_once(
    content,
    '''@MainActor
final class CalendarExporter: ObservableObject {
''',
    reminder_support + '''\n@MainActor
final class CalendarExporter: ObservableObject {
''',
    "DutyReminderScheduler"
)

# Pre-duty pickup convenience values. The post-flight hotel pickup is excluded.
content = replace_once(
    content,
    '''    func nextPickup(at now: Date) -> PickupStatus? {
''',
    '''    var preDutyPickupUTCDate: Date? {
        let all = activityList.compactMap { activity -> (Date, String)? in
            guard !activity.pickup.isEmpty, let date = pickupUTCDate(for: activity) else { return nil }
            return (date, activity.pickup)
        }
        guard !all.isEmpty else { return nil }
        if let dutyStart = dutyStartUTCDate {
            return all.filter { $0.0 <= dutyStart }.sorted { $0.0 < $1.0 }.last?.0
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
''',
    "pre-duty pickup"
)

# -----------------------------------------------------------------------------
# Month statistics and rest calculation use timestamps already in the cache.
# -----------------------------------------------------------------------------
content = replace_once(
    content,
    '''struct SummaryMetric: Identifiable {
    let label: String
    let value: Int
    var id: String { label }
}
''',
    '''struct SummaryMetric: Identifiable {
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
''',
    "OperationalMetric"
)

content = replace_once(
    content,
    '''    var summaryMetrics: [SummaryMetric] {
''',
    '''    var operationalMetrics: [OperationalMetric] {
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
''',
    "operational metrics and rest"
)

# Reminder scheduler is refreshed whenever a valid RAIDO roster is ingested.
content = replace_once(
    content,
    '''    @Published var calendarSyncStatus: String?

    private let calendar = Calendar.current
    private let automaticCalendarExporter = CalendarExporter()
''',
    '''    @Published var calendarSyncStatus: String?
    @Published var reminderSyncStatus: String?

    private let calendar = Calendar.current
    private let automaticCalendarExporter = CalendarExporter()
    private let automaticReminderScheduler = DutyReminderScheduler()
''',
    "RosterStore reminder state"
)

content = replace_once(
    content,
    '''        if autoCalendar {
            automaticCalendarExporter.syncMonthIfAuthorized(parsed, month: validation.month) { [weak self] status in
                self?.calendarSyncStatus = status
            }
        }
''',
    '''        if autoCalendar {
            automaticCalendarExporter.syncMonthIfAuthorized(parsed, month: validation.month) { [weak self] status in
                self?.calendarSyncStatus = status
            }
        }

        let pickupLead = UserDefaults.standard.integer(forKey: "RAIDORoster.PickupReminderLead")
        let reportLead = UserDefaults.standard.integer(forKey: "RAIDORoster.ReportReminderLead")
        automaticReminderScheduler.syncIfAuthorized(parsed, pickupLead: pickupLead, reportLead: reportLead) { [weak self] status in
            self?.reminderSyncStatus = status
        }
''',
    "automatic reminder refresh"
)

content = replace_once(
    content,
    '''        calendarSyncStatus = nil
        try? FileManager.default.removeItem(at: cacheURL)
''',
    '''        calendarSyncStatus = nil
        reminderSyncStatus = nil
        automaticReminderScheduler.clearRosterReminders()
        try? FileManager.default.removeItem(at: cacheURL)
''',
    "clear reminder state"
)

# -----------------------------------------------------------------------------
# Roster home: useful totals without turning the main screen into analytics.
# -----------------------------------------------------------------------------
content = replace_once(
    content,
    '''                        if !store.summaryMetrics.isEmpty {
                            sectionTitle("Month overview")
                            summaryGrid
                        }

                        sectionTitle("Upcoming")
''',
    '''                        if !store.summaryMetrics.isEmpty {
                            sectionTitle("Month overview")
                            summaryGrid
                        }

                        if !store.operationalMetrics.isEmpty {
                            sectionTitle("Operational totals")
                            OperationalMetricsGrid(metrics: store.operationalMetrics)
                        }

                        sectionTitle("Upcoming")
''',
    "operational totals insertion"
)

operational_grid = r'''
struct OperationalMetricsGrid: View {
    let metrics: [OperationalMetric]

    var body: some View {
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
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}

'''
content = replace_once(content, '''struct TodayView: View {
''', operational_grid + '''struct TodayView: View {
''', "OperationalMetricsGrid")

# Today: show factual rest time to the next known duty. No FTL compliance claim.
content = replace_once(
    content,
    '''                    } else if let item = store.todayItems.first {
                        DutyBriefingView(item: item, showTechnical: false)
                    } else {
''',
    '''                    } else if let item = store.todayItems.first {
                        DutyBriefingView(item: item, showTechnical: false)
                        if let next = store.nextOperationalDuty(after: item),
                           let interval = store.restInterval(after: item, before: next) {
                            BriefingSectionTitle("Next duty")
                            RestToNextDutyCard(next: next, interval: interval)
                        }
                    } else {
''',
    "rest card insertion"
)

rest_card = r'''
struct RestToNextDutyCard: View {
    let next: RosterItem
    let interval: TimeInterval

    var body: some View {
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
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }
}

'''
content = replace_once(content, '''struct DutyBriefingView: View {
''', rest_card + '''struct DutyBriefingView: View {
''', "RestToNextDutyCard")

# -----------------------------------------------------------------------------
# Private per-duty notes. These stay in UserDefaults and are never sent to
# RAIDO, diagnostics or Apple Calendar.
# -----------------------------------------------------------------------------
content = replace_once(
    content,
    '''        ScrollView {
            DutyBriefingView(item: item, showTechnical: true)
                .padding()
        }
''',
    '''        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DutyBriefingView(item: item, showTechnical: true)
                BriefingSectionTitle("My note")
                PersonalDutyNoteCard(item: item)
            }
            .padding()
        }
''',
    "personal note detail"
)

personal_note = r'''
struct PersonalDutyNoteCard: View {
    let item: RosterItem
    @State private var note = ""

    private var storageKey: String { "RAIDORoster.PersonalNote." + item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $note)
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

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
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
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

'''
content = replace_once(content, '''struct CategoryBadge: View {
''', personal_note + '''struct CategoryBadge: View {
''', "PersonalDutyNoteCard")

# -----------------------------------------------------------------------------
# Settings: reminder lead times and one explicit permission/schedule action.
# -----------------------------------------------------------------------------
content = replace_once(
    content,
    '''    @StateObject private var calendarExporter = CalendarExporter()
    @AppStorage("RAIDORoster.AutoCalendarSync") private var autoCalendarSync = true
''',
    '''    @StateObject private var calendarExporter = CalendarExporter()
    @StateObject private var reminderScheduler = DutyReminderScheduler()
    @AppStorage("RAIDORoster.AutoCalendarSync") private var autoCalendarSync = true
    @AppStorage("RAIDORoster.PickupReminderLead") private var pickupReminderLead = 0
    @AppStorage("RAIDORoster.ReportReminderLead") private var reportReminderLead = 0
''',
    "reminder settings state"
)

reminder_section = r'''
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

                    Text("Reminders are local to this iPhone and are automatically refreshed after a valid RAIDO roster sync. They do not require a server or background roster polling.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

'''
content = replace_once(content, '''                Section("Portal") {
''', reminder_section + '''                Section("Portal") {
''', "Duty reminder settings section")

content = content.replace('LabeledContent("RAIDO Roster", value: "2.7")', 'LabeledContent("RAIDO Roster", value: "2.8")', 1)

CONTENT.write_text(content)

# Version only; notification APIs do not require a new entitlement or plist key.
pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 7;", "CURRENT_PROJECT_VERSION = 8;")
pbx = pbx.replace("MARKETING_VERSION = 2.7;", "MARKETING_VERSION = 2.8;")
PBX.write_text(pbx)

print("V2.8 patch applied")
