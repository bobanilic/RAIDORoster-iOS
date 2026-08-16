from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "RAIDORoster"
CONTENT = SRC / "ContentView.swift"
JS = SRC / "RosterEnhancements.js"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.7 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# -----------------------------------------------------------------------------
# Crew country badge. This is the country inferred from the contact telephone
# prefix, not an authoritative nationality. Old V2.6 caches remain decodable
# because the new field is optional.
# -----------------------------------------------------------------------------
content = replace_once(
    content,
    '''struct CrewMember: Codable, Equatable, Identifiable {
    let role: String
    let code: String
    let name: String
''',
    '''struct CrewMember: Codable, Equatable, Identifiable {
    let role: String
    let code: String
    let name: String
    let country: String?
''',
    "CrewMember country"
)

content = replace_once(
    content,
    '''            return CrewMember(role: role, code: code, name: name)
''',
    '''            return CrewMember(
                role: role,
                code: code,
                name: name,
                country: member["country"] as? String
            )
''',
    "crew parser country"
)

# -----------------------------------------------------------------------------
# Pickup countdown. Convert RAIDO local pickup time to UTC using the nearest
# local/UTC timestamp pair on that activity, which also handles sectors whose
# departure and arrival airports use different local time zones.
# -----------------------------------------------------------------------------
pickup_method = '''
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
'''

content = replace_once(
    content,
    '''    func liveStatus(at now: Date) -> DutyStatus? {
''',
    pickup_method + '''
    func liveStatus(at now: Date) -> DutyStatus? {
''',
    "RosterItem pickup method"
)

content = replace_once(
    content,
    '''struct DutyStatus {
    let label: String
    let title: String
    let subtitle: String
    let systemImage: String
}
''',
    '''struct DutyStatus {
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
''',
    "PickupStatus"
)

# -----------------------------------------------------------------------------
# CalendarExporter: silent full-month synchronization for validated RAIDO
# refreshes. It never triggers a permission prompt automatically; the user
# grants access once through the normal manual Sync button.
# -----------------------------------------------------------------------------
calendar_anchor = '''    private func requestAccess() async -> Bool {
'''
auto_calendar_method = '''    func syncMonthIfAuthorized(_ items: [RosterItem], month: String?, completion: @escaping (String) -> Void) {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            completion("Calendar permission required • use Sync once")
            return
        }

        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
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
                try eventStore.commit()
                completion("Calendar synced • \\(selected.count) days • \\(created) added • \\(updated) updated")
            } catch {
                completion("Calendar sync failed: \\(error.localizedDescription)")
            }
        }
    }

'''
content = replace_once(content, calendar_anchor, auto_calendar_method + calendar_anchor, "silent Calendar sync")

# -----------------------------------------------------------------------------
# RosterStore: remember changed dates for visual markers and mirror every valid
# RAIDO refresh into Apple Calendar when automatic sync is enabled.
# -----------------------------------------------------------------------------
content = replace_once(
    content,
    '''    @Published private(set) var snapshot: RosterSnapshot?
    @Published var changeNotice: String?

    private let calendar = Calendar.current
''',
    '''    @Published private(set) var snapshot: RosterSnapshot?
    @Published var changeNotice: String?
    @Published private(set) var changedDates: Set<String> = []
    @Published var calendarSyncStatus: String?

    private let calendar = Calendar.current
    private let automaticCalendarExporter = CalendarExporter()
''',
    "RosterStore published state"
)

old_change_block = '''        if let old, normalized(old.items) != normalized(parsed) {
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
            changeNotice = changed > 0 ? "Roster updated • \\(changed) changed day\\(changed == 1 ? "" : "s")" : "Roster updated"
        }

        snapshot = newSnapshot
        save(newSnapshot)
'''
new_change_block = '''        changedDates = []
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

        let autoCalendar = UserDefaults.standard.object(forKey: "RAIDORoster.AutoCalendarSync") as? Bool ?? true
        if autoCalendar {
            automaticCalendarExporter.syncMonthIfAuthorized(parsed, month: validation.month) { [weak self] status in
                self?.calendarSyncStatus = status
            }
        }
'''
content = replace_once(content, old_change_block, new_change_block, "change markers and auto Calendar sync")

content = replace_once(
    content,
    '''    func dismissChangeNotice() { changeNotice = nil }
''',
    '''    func dismissChangeNotice() {
        changeNotice = nil
        changedDates = []
    }
''',
    "dismiss changed dates"
)

content = replace_once(
    content,
    '''        snapshot = nil
        changeNotice = nil
        try? FileManager.default.removeItem(at: cacheURL)
''',
    '''        snapshot = nil
        changeNotice = nil
        changedDates = []
        calendarSyncStatus = nil
        try? FileManager.default.removeItem(at: cacheURL)
''',
    "clear V2.7 state"
)

# -----------------------------------------------------------------------------
# Roster UI: mark the exact days changed by the newest RAIDO refresh.
# -----------------------------------------------------------------------------
content = replace_once(
    content,
    '''                                NavigationLink { RosterDetailView(item: item) } label: { RosterRowCard(item: item) }
''',
    '''                                NavigationLink { RosterDetailView(item: item) } label: {
                                    RosterRowCard(
                                        item: item,
                                        isChanged: store.changedDates.contains(item.dateISO ?? "")
                                    )
                                }
''',
    "changed roster row"
)

content = replace_once(
    content,
    '''struct RosterRowCard: View {
    let item: RosterItem

    var body: some View {
''',
    '''struct RosterRowCard: View {
    let item: RosterItem
    var isChanged: Bool = false

    var body: some View {
''',
    "RosterRowCard changed property"
)

content = replace_once(
    content,
    '''                HStack {
                    Text(item.displayTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Spacer()
''',
    '''                HStack {
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
''',
    "changed badge"
)

# -----------------------------------------------------------------------------
# Today: surface next pickup above the normal duty status.
# -----------------------------------------------------------------------------
content = replace_once(
    content,
    '''            if item.isOperationalDuty, !item.operationalActivities.isEmpty {
                DutyLiveStatusCard(item: item)
''',
    '''            if item.isOperationalDuty, !item.operationalActivities.isEmpty {
                if !item.pickups.isEmpty {
                    PickupCountdownCard(item: item)
                }
                DutyLiveStatusCard(item: item)
''',
    "pickup card insertion"
)

pickup_card = '''
struct PickupCountdownCard: View {
    let item: RosterItem

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let pickup = item.nextPickup(at: context.date) {
                HStack(spacing: 12) {
                    Image(systemName: "car.fill")
                        .font(.title3)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PICKUP • \\(relativeText(from: context.date, to: pickup.date))")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(pickup.displayTime)
                            .font(.headline.monospacedDigit())
                        if !pickup.subtitle.isEmpty {
                            Text(pickup.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

'''
content = replace_once(content, '''struct DutyLiveStatusCard: View {
''', pickup_card + '''struct DutyLiveStatusCard: View {
''', "PickupCountdownCard")

# -----------------------------------------------------------------------------
# Crew list: compact inferred-country chip.
# -----------------------------------------------------------------------------
content = replace_once(
    content,
    '''                    Spacer()
                }
                .padding(.vertical, 9)
''',
    '''                    Spacer()
                    if let country = member.country, !country.isEmpty {
                        Text(country)
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.10), in: Capsule())
                            .accessibilityLabel("Phone country \\(country)")
                    }
                }
                .padding(.vertical, 9)
''',
    "crew country chip"
)

# -----------------------------------------------------------------------------
# Settings terminology + automatic Calendar toggle/status. Manual Sync remains
# as a safe fallback and as the one-time Calendar permission trigger.
# -----------------------------------------------------------------------------
content = replace_once(
    content,
    '''    @State private var confirmClear = false
    @StateObject private var calendarExporter = CalendarExporter()
''',
    '''    @State private var confirmClear = false
    @StateObject private var calendarExporter = CalendarExporter()
    @AppStorage("RAIDORoster.AutoCalendarSync") private var autoCalendarSync = true
''',
    "auto Calendar setting"
)

old_calendar_section = '''                Section("Calendar") {
                    Button {
                        calendarExporter.exportMonth(store.items, month: store.cachedMonth)
                    } label: {
                        Label("Export / update roster month", systemImage: "calendar.badge.plus")
                    }
                    .disabled(!store.hasCache || calendarExporter.isWorking)
                    Text("Repeated exports update RAIDO Roster events instead of creating duplicates.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
'''
new_calendar_section = '''                Section("Apple Calendar") {
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
                }
'''
content = replace_once(content, old_calendar_section, new_calendar_section, "Calendar settings wording")

content = content.replace('accessibilityLabel("Export today\'s duty to Calendar")', 'accessibilityLabel("Sync today\'s duty to Calendar")')
content = content.replace('accessibilityLabel("Export duty to Calendar")', 'accessibilityLabel("Sync duty to Calendar")')
content = content.replace('LabeledContent("RAIDO Roster", value: "2.6")', 'LabeledContent("RAIDO Roster", value: "2.7")', 1)

# -----------------------------------------------------------------------------
# Pickup date helpers.
# -----------------------------------------------------------------------------
helpers = '''
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
    guard let timeRange = pickup.range(of: #"\\b([01]?\\d|2[0-3]):[0-5]\\d\\b"#, options: .regularExpression) else { return nil }
    let time = String(pickup[timeRange])

    let startDate = activity.startLT.split(separator: " ").first.map(String.init) ?? ""
    guard startDate.count == 10 else { return nil }
    let year = String(startDate.prefix(4))

    var pickupDateISO = startDate
    if let dateRange = pickup.range(of: #"\\b(\\d{1,2})\\s+(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)\\b"#, options: .regularExpression) {
        let token = String(pickup[dateRange]).split(separator: " ")
        if token.count == 2, let day = Int(token[0]) {
            let months = ["JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
                          "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12]
            if let month = months[String(token[1])] {
                pickupDateISO = String(format: "%@-%02d-%02d", year, month, day)
            }
        }
    }

    guard let nominalPickup = parseNominalLocalStamp("\\(pickupDateISO) \\(time)") else { return nil }

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

'''
content = replace_once(content, '''private func parseUTCStamp(_ value: String) -> Date? {
''', helpers + '''private func parseUTCStamp(_ value: String) -> Date? {
''', "pickup helpers")

CONTENT.write_text(content)

# -----------------------------------------------------------------------------
# Parser metadata only: keep the proven activity parser untouched, but infer a
# compact phone-country code while the phone number is already visible in the
# Crew On Board text. The phone itself is still discarded and never cached.
# -----------------------------------------------------------------------------
js = JS.read_text()
country_helper = r'''
  const PHONE_COUNTRIES = [
    ['971','AE'], ['420','CZ'], ['421','SK'], ['351','PT'], ['352','LU'], ['353','IE'],
    ['354','IS'], ['355','AL'], ['356','MT'], ['357','CY'], ['358','FI'], ['359','BG'],
    ['370','LT'], ['371','LV'], ['372','EE'], ['373','MD'], ['374','AM'], ['375','BY'],
    ['376','AD'], ['377','MC'], ['378','SM'], ['380','UA'], ['381','RS'], ['382','ME'],
    ['383','XK'], ['385','HR'], ['386','SI'], ['387','BA'], ['389','MK'], ['995','GE'],
    ['994','AZ'], ['972','IL'], ['996','KG'], ['998','UZ'], ['30','GR'], ['31','NL'],
    ['32','BE'], ['33','FR'], ['34','ES'], ['36','HU'], ['39','IT'], ['40','RO'],
    ['41','CH'], ['43','AT'], ['44','GB'], ['45','DK'], ['46','SE'], ['47','NO'],
    ['48','PL'], ['49','DE'], ['90','TR']
  ];

  function phoneCountry(value) {
    const digits = String(value || '').replace(/\D/g, '');
    if (!digits) return '';
    const hit = PHONE_COUNTRIES.find(([prefix]) => digits.startsWith(prefix));
    return hit?.[1] || '';
  }

'''
js = replace_once(js, '''  function crewMembers(segment) {
''', country_helper + '''  function crewMembers(segment) {
''', "phone country helper")

js = replace_once(
    js,
    '''      let chunk = block.slice(item.end, matches[i + 1]?.index ?? block.length);
      chunk = chunk
        .replace(/\\s+[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}.*$/i, '')
        .replace(/\\s+\\+?\\d[\\d\\s().-]{7,}\\d.*$/i, '')
        .trim();
''',
    '''      let chunk = block.slice(item.end, matches[i + 1]?.index ?? block.length);
      const phone = chunk.match(/\\+\\d[\\d\\s().-]{7,}\\d/)?.[0] || '';
      chunk = chunk
        .replace(/\\s+[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}.*$/i, '')
        .replace(/\\s+\\+?\\d[\\d\\s().-]{7,}\\d.*$/i, '')
        .trim();
''',
    "crew phone capture"
)

js = replace_once(
    js,
    '''      return { role: item.role, code: item.code, name };
''',
    '''      return { role: item.role, code: item.code, name, country: phoneCountry(phone) };
''',
    "crew country output"
)
JS.write_text(js)

# Bundle version only. No new entitlement or framework is required.
pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 6;", "CURRENT_PROJECT_VERSION = 7;")
pbx = pbx.replace("MARKETING_VERSION = 2.6;", "MARKETING_VERSION = 2.7;")
PBX.write_text(pbx)

print("V2.7 patch applied")
