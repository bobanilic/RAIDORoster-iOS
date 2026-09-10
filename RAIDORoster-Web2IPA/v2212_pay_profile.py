"""V2.22.0: effective-dated configurable Pay Profile + cleaner Today shortcuts."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent
APP = ROOT / "RAIDORoster"

def once(s, old, new, label):
    count = s.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one anchor, found {count}: {old[:120]}")
    return s.replace(old, new, 1)

# ---- Earnings model integration -------------------------------------------------
p = APP / "EarningsModels.swift"
s = p.read_text()

s = once(s,
'''    var reimbursementCents = 0
    var missingFlights = 0''',
'''    var reimbursementCents = 0
    // Optional preserves decoding of payment snapshots saved before Pay Profile.
    var basicSalaryCents: Int?
    var dutyDayCents: Int?
    var missingFlights = 0''',
"summary components")
s = once(s,
'''    var totalCents: Int { flightCents + perDiemCents + lineCheckCents + adjustmentCents + reimbursementCents }''',
'''    var totalCents: Int {
        flightCents + perDiemCents + lineCheckCents + adjustmentCents + reimbursementCents
            + (basicSalaryCents ?? 0) + (dutyDayCents ?? 0)
    }''',
"summary total")

s = once(s,
'''    static func summarize(month: String, flights: [EarningsFlight], record: EarningsMonth, authoritativeBLHMinutes: Int? = nil) -> EarningsSummary {
        var result = EarningsSummary()''',
'''    static func summarize(month: String, flights: [EarningsFlight], record: EarningsMonth, authoritativeBLHMinutes: Int? = nil, profile: EarningsPayProfile? = nil) -> EarningsSummary {
        var result = EarningsSummary()
        let active = profile ?? .legacy(rates: record.rates, homeAirport: record.homeAirport)''',
"summary signature")
s = s.replace('minutesByRate[record.rates.hourly(edit?.role ?? .cc), default: 0] += minutes',
              'minutesByRate[active.blockRate(edit?.role ?? active.defaultRole), default: 0] += minutes')
s = s.replace('result.lineCheckCents += record.rates.lineCheck', 'result.lineCheckCents += active.lineCheckCents')
s = s.replace('rate: record.rates.hourly(.cc)', 'rate: active.blockRate(active.defaultRole)')
s = once(s,
'''        result.perDiemCents = record.perDiemDays.filter { $0.hasPrefix(month + "-") && date($0) != nil }.count * record.rates.perDiem
        for adjustment in record.adjustments {''',
'''        result.perDiemCents = record.perDiemDays.filter { $0.hasPrefix(month + "-") && date($0) != nil }.count * active.dailyAllowanceCents
        result.basicSalaryCents = EarningsPayProfileEngine.basicSalary(active)
        let flightDays = Set(flights.filter { $0.day.hasPrefix(month + "-") }.map(\\.day)).count
        result.dutyDayCents = EarningsPayProfileEngine.dutySupplement(flightDays: flightDays, profile: active)
        for adjustment in record.adjustments {''',
"summary pay profile")

s = once(s,
'''    static func lines(month: String, days: [EarningsRosterDay], events: [EarningsLocationEvent], record: EarningsMonth) -> [EarningsDailyLine] {
        let home = airport(record.homeAirport ?? "BEG")''',
'''    static func lines(month: String, days: [EarningsRosterDay], events: [EarningsLocationEvent], record: EarningsMonth, profile: EarningsPayProfile? = nil) -> [EarningsDailyLine] {
        let active = profile ?? .legacy(rates: record.rates, homeAirport: record.homeAirport)
        let home = airport(active.homeAirport)''',
"daily profile signature")
s = once(s,
'''            // RES is never payable, including away from home and despite stale/manual paid dates.
            if reserve { return EarningsDailyLine(day: day, category: "RES", paid: false, reason: "Reserve · unpaid", needsReview: false, reserveOnly: true) }''',
'''            if reserve {
                return EarningsDailyLine(day: day, category: "RES", paid: active.reserveDaily,
                    reason: active.reserveDaily ? "Reserve · daily payment" : "Reserve · unpaid",
                    needsReview: false, reserveOnly: true)
            }''',
"reserve profile")
s = once(s,
'''            if !categories.isDisjoint(with: ["DND", "VACATION", "LEAVE", "SICK", "SICKNESS"]) {
                return EarningsDailyLine(day: day, category: label, paid: false, reason: "Unpaid absence", needsReview: false, reserveOnly: false)
            }''',
'''            if !categories.isDisjoint(with: ["DND", "VACATION", "LEAVE", "SICK", "SICKNESS"]) {
                return EarningsDailyLine(day: day, category: label, paid: active.absenceDaily,
                    reason: active.absenceDaily ? "Absence · daily payment" : "Unpaid absence",
                    needsReview: false, reserveOnly: false)
            }''',
"absence profile")
s = once(s,
'''            // Payroll practice confirmed by the crew member: STB receives the EUR50 daily payment even at home base.
            if isStandby {
                return EarningsDailyLine(day: day, category: "STANDBY", paid: true, reason: "Standby · daily payment", needsReview: false, reserveOnly: false)
            }''',
'''            if isStandby {
                return EarningsDailyLine(day: day, category: "STANDBY", paid: active.standbyDaily,
                    reason: active.standbyDaily ? "Standby · daily payment" : "Standby · unpaid",
                    needsReview: false, reserveOnly: false)
            }''',
"standby profile")
s = once(s,
'''            // Positioning is treated as a paid operational day. It does not earn block-hour pay.
            if isPositioning {
                return EarningsDailyLine(day: day, category: "POSITIONING", paid: true, reason: "Positioning · daily payment", needsReview: false, reserveOnly: false)
            }''',
'''            if isPositioning {
                return EarningsDailyLine(day: day, category: "POSITIONING", paid: active.positioningDaily,
                    reason: active.positioningDaily ? "Positioning · daily payment" : "Positioning · unpaid",
                    needsReview: false, reserveOnly: false)
            }''',
"positioning profile")
s = s.replace('return EarningsDailyLine(day: day, category: "FLIGHT", paid: true, reason: "Flight duty away from home · \\(location ?? "away")", needsReview: false, reserveOnly: false)',
              'return EarningsDailyLine(day: day, category: "FLIGHT", paid: active.flightAwayDaily, reason: active.flightAwayDaily ? "Flight duty away from home · \\(location ?? "away")" : "Away flight · daily payment disabled", needsReview: false, reserveOnly: false)')
s = s.replace('return EarningsDailyLine(day: day, category: "FLIGHT", paid: false, reason: "Home-base flight duty · BLH only", needsReview: false, reserveOnly: false)',
              'return EarningsDailyLine(day: day, category: "FLIGHT", paid: active.flightHomeDaily, reason: active.flightHomeDaily ? "Home-base flight · daily payment" : "Home-base flight duty · BLH only", needsReview: false, reserveOnly: false)')
s = s.replace('return EarningsDailyLine(day: day, category: "FLIGHT", paid: true, reason: "Confirmed away duty date", needsReview: false, reserveOnly: false)',
              'return EarningsDailyLine(day: day, category: "FLIGHT", paid: active.flightAwayDaily, reason: active.flightAwayDaily ? "Confirmed away duty date" : "Away flight · daily payment disabled", needsReview: false, reserveOnly: false)')
s = s.replace('return EarningsDailyLine(day: day, category: label, paid: true, reason: "Away from home · \\(location ?? "away")", needsReview: false, reserveOnly: false)',
              'return EarningsDailyLine(day: day, category: label, paid: active.offAwayDaily, reason: active.offAwayDaily ? "Away from home · \\(location ?? "away")" : "Away day · daily payment disabled", needsReview: false, reserveOnly: false)')
s = s.replace('return EarningsDailyLine(day: day, category: label, paid: true, reason: "Confirmed away date", needsReview: false, reserveOnly: false)',
              'return EarningsDailyLine(day: day, category: label, paid: active.offAwayDaily, reason: active.offAwayDaily ? "Confirmed away date" : "Away day · daily payment disabled", needsReview: false, reserveOnly: false)')
s = once(s,
'''    static func recordForCalculation(_ record: EarningsMonth, lines: [EarningsDailyLine]) -> EarningsMonth {
        var result = record
        result.perDiemDays = Set(lines.filter(\\.paid).map(\\.day))''',
'''    static func recordForCalculation(_ record: EarningsMonth, lines: [EarningsDailyLine], profile: EarningsPayProfile? = nil) -> EarningsMonth {
        var result = record
        let active = profile ?? .legacy(rates: record.rates, homeAirport: record.homeAirport)
        result.rates = EarningsRates(cc: active.ccBlockRateCents, scc: active.sccBlockRateCents,
                                     perDiem: active.dailyAllowanceCents, lineCheck: active.lineCheckCents)
        result.homeAirport = active.homeAirport
        result.perDiemDays = Set(lines.filter(\\.paid).map(\\.day))''',
"calculation projection")
p.write_text(s)

# ---- Earnings store + UI --------------------------------------------------------
p = APP / "EarningsView.swift"
s = p.read_text()
s = once(s,
'''final class EarningsStore: ObservableObject {
    @Published private(set) var archive = EarningsArchive()
    @Published private(set) var error: String?
    private let persistence = EarningsPersistence()''',
'''final class EarningsStore: ObservableObject {
    static let shared = EarningsStore()
    @Published private(set) var archive = EarningsArchive()
    @Published private(set) var payProfiles = EarningsPayProfileArchive()
    @Published private(set) var error: String?
    private let persistence = EarningsPersistence()
    private let profilePersistence = EarningsPayProfilePersistence()''',
"shared earnings store")
s = once(s,
'''    init() {
        do { archive = try persistence.load() }
        catch { readable = false; self.error = "Saved earnings could not be read. Your saved data has been retained." }
    }''',
'''    init() {
        do { archive = try persistence.load() }
        catch { readable = false; self.error = "Saved earnings could not be read. Your saved data has been retained." }
        do { payProfiles = try profilePersistence.load() }
        catch { self.error = "Saved Pay Profile could not be read. Existing earnings data was retained." }
    }
    func profile(_ month: String) -> EarningsPayProfile {
        payProfiles.profile(for: month) ?? .legacy(rates: record(month).rates, homeAirport: record(month).homeAirport)
    }
    func saveProfile(_ profile: EarningsPayProfile, effectiveMonth: String) {
        guard effectiveMonth.range(of: "^[0-9]{4}-[0-9]{2}$", options: .regularExpression) != nil,
              EarningsMath.date(effectiveMonth + "-01") != nil else {
            error = "Enter the effective month as YYYY-MM."
            return
        }
        var next = payProfiles
        next.save(profile, effectiveMonth: effectiveMonth)
        do { try profilePersistence.save(next); payProfiles = next; error = nil }
        catch { self.error = "Pay Profile could not be saved. Please try again." }
    }''',
"pay profile persistence")

# Use the shared store so Settings changes refresh Roster immediately.
s = s.replace('@StateObject private var earnings = EarningsStore()', '@ObservedObject private var earnings = EarningsStore.shared')

# Card uses effective profile.
s = once(s,
'''    private var flights: [EarningsFlight] { earningsFlights(store: roster, month: month) }
    private var daily: [EarningsDailyLine] { earningsDailyLines(store: roster, month: month, record: earnings.record(month)) }''',
'''    private var flights: [EarningsFlight] { earningsFlights(store: roster, month: month) }
    private var profile: EarningsPayProfile { earnings.profile(month) }
    private var daily: [EarningsDailyLine] { earningsDailyLines(store: roster, month: month, record: earnings.record(month), profile: profile) }''',
"card profile")
s = s.replace('EarningsDailyPolicy.recordForCalculation(earnings.record(month), lines: daily), authoritativeBLHMinutes: raidoBLHMinutes)',
              'EarningsDailyPolicy.recordForCalculation(earnings.record(month), lines: daily, profile: profile), authoritativeBLHMinutes: raidoBLHMinutes, profile: profile)', 1)
# Detail uses effective profile.
s = once(s,
'''    private var record: EarningsMonth { earnings.record(month) }
    private var daily: [EarningsDailyLine] { earningsDailyLines(store: roster, month: month, record: record) }''',
'''    private var record: EarningsMonth { earnings.record(month) }
    private var profile: EarningsPayProfile { earnings.profile(month) }
    private var daily: [EarningsDailyLine] { earningsDailyLines(store: roster, month: month, record: record, profile: profile) }''',
"detail profile")
s = s.replace('EarningsDailyPolicy.recordForCalculation(record, lines: daily), authoritativeBLHMinutes: raidoBLHMinutes)',
              'EarningsDailyPolicy.recordForCalculation(record, lines: daily, profile: profile), authoritativeBLHMinutes: raidoBLHMinutes, profile: profile)', 1)
# Existing rate editor would conflict with an effective-dated profile; point users to the single source of truth.
s = s.replace('Button("Edit this month’s rates", systemImage: "slider.horizontal.3") { editor = .rates }',
              'Text("Rates and eligibility are configured in Settings → Earnings → Pay Profile.").font(.caption).foregroundStyle(.secondary)')
# Show the two new components in the breakdown.
s = once(s,
'''                LabeledContent("Block-hour pay", value: EarningsMath.money(summary.flightCents))
                LabeledContent("Line-check fees", value: EarningsMath.money(summary.lineCheckCents))''',
'''                if (summary.basicSalaryCents ?? 0) > 0 { LabeledContent("Basic salary", value: EarningsMath.money(summary.basicSalaryCents ?? 0, currency: profile.normalizedCurrency)) }
                LabeledContent("Block-hour pay", value: EarningsMath.money(summary.flightCents, currency: profile.normalizedCurrency))
                if (summary.dutyDayCents ?? 0) > 0 { LabeledContent("Duty-day supplement", value: EarningsMath.money(summary.dutyDayCents ?? 0, currency: profile.normalizedCurrency)) }
                LabeledContent("Line-check fees", value: EarningsMath.money(summary.lineCheckCents, currency: profile.normalizedCurrency))''',
"breakdown profile components")
s = s.replace('LabeledContent("Daily pay · \\(daily.filter(\\.paid).count) days", value: EarningsMath.money(summary.perDiemCents))',
              'LabeledContent("Daily pay · \\(daily.filter(\\.paid).count) days", value: EarningsMath.money(summary.perDiemCents, currency: profile.normalizedCurrency))')
s = s.replace('Text("Monthly earnings")', 'Text("Monthly earnings")')

s += r'''

struct EarningsPayProfileView: View {
    @ObservedObject var earnings: EarningsStore
    let month: String
    @Environment(\.dismiss) private var dismiss
    @State private var profile: EarningsPayProfile
    @State private var effectiveMonth: String

    init(earnings: EarningsStore, month: String) {
        self.earnings = earnings
        self.month = month
        _profile = State(initialValue: earnings.profile(month))
        _effectiveMonth = State(initialValue: month)
    }

    private var validMonth: Bool {
        effectiveMonth.range(of: "^[0-9]{4}-[0-9]{2}$", options: .regularExpression) != nil &&
        EarningsMath.date(effectiveMonth + "-01") != nil &&
        EarningsDailyPolicy.airport(profile.homeAirport) != nil &&
        profile.currency.trimmingCharacters(in: .whitespacesAndNewlines).count == 3
    }

    private var sampleTotal: Int {
        EarningsPayProfileEngine.basicSalary(profile)
        + EarningsMath.hourlyPay(minutes: 360, rate: profile.blockRate(profile.defaultRole))
        + (profile.flightAwayDaily ? profile.dailyAllowanceCents : 0)
        + EarningsPayProfileEngine.dutySupplement(flightDays: 1, profile: profile)
    }

    var body: some View {
        Form {
            Section("Pay Profile") {
                TextField("Profile name", text: $profile.name)
                Picker("Rank", selection: $profile.rank) {
                    ForEach(EarningsRankPreset.allCases) { Text($0.label).tag($0) }
                }
                Picker("Default BLH role", selection: $profile.defaultRole) {
                    ForEach(EarningsRole.allCases) { Text($0.label).tag($0) }
                }
                TextField("Home base · IATA", text: $profile.homeAirport)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("Currency · ISO", text: $profile.currency)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("Effective month · YYYY-MM", text: $effectiveMonth)
                    .keyboardType(.numbersAndPunctuation)
            } footer: {
                Text("Saving a new effective month creates a new contract revision. Older months keep the rules that were effective then.")
            }

            Section("Fixed pay") {
                Toggle("Basic monthly salary", isOn: $profile.basicSalaryEnabled)
                if profile.basicSalaryEnabled { profileMoneyField("Basic salary", cents: $profile.basicSalaryCents) }
                Toggle("Flight duty-day supplement", isOn: $profile.dutyDayEnabled)
                if profile.dutyDayEnabled { profileMoneyField("Per flight duty day", cents: $profile.dutyDayCents) }
            }

            Section("Block-hour pay") {
                profileMoneyField("JCC / CC per BLH", cents: $profile.ccBlockRateCents)
                profileMoneyField("SCC per BLH", cents: $profile.sccBlockRateCents)
                profileMoneyField("Instructor line check / sector", cents: $profile.lineCheckCents)
            }

            Section("Daily allowance") {
                profileMoneyField("Amount per eligible day", cents: $profile.dailyAllowanceCents)
                Toggle("Flight · home base", isOn: $profile.flightHomeDaily)
                Toggle("Flight · away", isOn: $profile.flightAwayDaily)
                Toggle("Standby", isOn: $profile.standbyDaily)
                Toggle("Positioning", isOn: $profile.positioningDaily)
                Toggle("OFF / other day away", isOn: $profile.offAwayDaily)
                Toggle("Reserve", isOn: $profile.reserveDaily)
                Toggle("DND / leave / sickness", isOn: $profile.absenceDaily)
            } footer: {
                Text("These switches control the daily allowance only. Block-hour pay and duty-day supplements are calculated separately, so components can stack.")
            }

            Section("Calculation preview") {
                LabeledContent("Example", value: "6:00 BLH · 1 away flight day")
                LabeledContent("Estimated pay", value: EarningsMath.money(sampleTotal, currency: profile.normalizedCurrency))
                if profile.basicSalaryEnabled { Text("Preview includes the full monthly basic salary.").font(.caption).foregroundStyle(.secondary) }
            }

            if !earnings.payProfiles.revisions.isEmpty {
                Section("Contract history") {
                    ForEach(earnings.payProfiles.revisions.sorted { $0.effectiveMonth > $1.effectiveMonth }) { revision in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(revision.profile.name.isEmpty ? "Pay Profile" : revision.profile.name)
                                Text("Effective " + revision.effectiveMonth).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(EarningsMath.money(revision.profile.ccBlockRateCents, currency: revision.profile.normalizedCurrency) + "/BLH")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .midnightCanvas()
        .navigationTitle("Pay Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    profile.homeAirport = profile.homeAirport.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    profile.currency = profile.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    earnings.saveProfile(profile, effectiveMonth: effectiveMonth)
                    if earnings.error == nil { dismiss() }
                }.disabled(!validMonth)
            }
        }
    }

    @ViewBuilder private func profileMoneyField(_ title: String, cents: Binding<Int>) -> some View {
        TextField(title, value: Binding<Double>(
            get: { Double(cents.wrappedValue) / 100.0 },
            set: { cents.wrappedValue = max(0, Int(($0 * 100).rounded())) }
        ), format: .number.precision(.fractionLength(0...2)))
        .keyboardType(.decimalPad)
    }
}
'''
p.write_text(s)

# ---- Today + Settings -----------------------------------------------------------
p = APP / "ContentView.swift"
s = p.read_text()
# Shared EarningsStore for Roster and Settings.
s = s.replace('@StateObject private var earnings = EarningsStore()', '@ObservedObject private var earnings = EarningsStore.shared')
# Forward profile through daily policy helper.
s = once(s,
'''func earningsDailyLines(store: RosterStore, month: String, record: EarningsMonth) -> [EarningsDailyLine] {''',
'''func earningsDailyLines(store: RosterStore, month: String, record: EarningsMonth, profile: EarningsPayProfile? = nil) -> [EarningsDailyLine] {''',
"daily helper signature")
s = once(s,
'''    return EarningsDailyPolicy.lines(month: month, days: Array(days.values), events: events, record: record)''',
'''    return EarningsDailyPolicy.lines(month: month, days: Array(days.values), events: events, record: record, profile: profile)''',
"daily helper call")

# Compact Today actions: keep the known working Announcements shortcut and Crew Control visible.
old_actions = '''                    HStack(spacing: 10) {
                        MidnightQuickAction(title: "Announcements", symbol: "megaphone.fill") { activeSheet = .announcements }
                        MidnightQuickAction(title: "Fleet", symbol: "airplane") { activeSheet = .fleet }
                        MidnightQuickAction(title: "Crew Control", symbol: "person.2.fill") { activeSheet = .crewControl }
                    }'''
new_actions = '''                    HStack(spacing: 8) {
                        MidnightQuickAction(title: "Announcements", symbol: "megaphone.fill") { activeSheet = .announcements }
                        MidnightQuickAction(title: "Crew Control", symbol: "person.2.fill") { activeSheet = .crewControl }
                        Menu {
                            Button("Documents", systemImage: "lock.doc") { activeSheet = .documents }
                            Button("Fleet", systemImage: "airplane") { activeSheet = .fleet }
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "ellipsis.circle").font(.system(size: 22, weight: .medium)).foregroundStyle(MidnightTheme.accent)
                                Text("More").font(.caption.weight(.medium)).foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .padding(.horizontal, 4).padding(.vertical, 4)
                            .midnightCard(radius: 15)
                            .contentShape(RoundedRectangle(cornerRadius: 15))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("More crew tools")
                    }'''
s = once(s, old_actions, new_actions, "Today quick actions")
# Remove the redundant Documents toolbar icon now that Documents lives under More.
doc_toolbar = '''                ToolbarItem(placement: .topBarTrailing) {
                    Button { activeSheet = .documents } label: {
                        Image(systemName: "doc.text").frame(minWidth: 32, minHeight: 44)
                    }.accessibilityLabel("Documents")
                }
'''
s = once(s, doc_toolbar, '', "Documents toolbar")
# Tighten Today vertical rhythm without touching detail-card internals.
a = s.index('struct TodayView:'); b = s.index('struct RestToNextDutyCard:', a)
t = s[a:b]
t = t.replace('VStack(alignment: .leading, spacing: 18)', 'VStack(alignment: .leading, spacing: 12)', 1)
s = s[:a] + t + s[b:]

# Settings: Documents is a tool, not configuration. Replace it with Earnings -> Pay Profile.
a = s.index('struct SettingsView:'); b = s.index('struct DutyHeroCard:', a)
t = s[a:b]
t = t.replace('    @State private var showDocuments = false\n', '')
doc_section = '''                Section("Crew documents") {
                    Button { showDocuments = true } label: {
                        Label("Documents", systemImage: "lock.doc")
                    }
                    Text("Passports, certificates, medical records and vaccinations, stored privately on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(MidnightTheme.surface)
'''
t = once(t, doc_section, '''                Section("Earnings") {
                    NavigationLink {
                        EarningsPayProfileView(earnings: EarningsStore.shared,
                            month: store.selectedRosterMonth ?? String(EarningsMath.day(Date()).prefix(7)))
                    } label: {
                        Label("Pay Profile", systemImage: "eurosign.bank.building")
                    }
                    Text("Configure basic salary, block-hour rates, duty-day supplements and daily-payment eligibility. Contract revisions keep historical months intact.")
                        .font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(MidnightTheme.surface)
''', "Settings Earnings section")
t = t.replace('            .sheet(isPresented: $showDocuments) { CrewDocumentsView() }\n', '')
s = s[:a] + t + s[b:]

# Version bump across generated native files.
s = s.replace('2.21.0', '2.22.0')
p.write_text(s)

# ---- Project + version ----------------------------------------------------------
p = ROOT / "RAIDORoster.xcodeproj/project.pbxproj"
s = p.read_text()
name = 'PayProfileModels.swift'
a_id, b_id = 'A222000000000000000001', 'B222000000000000000001'
if name not in s:
    s = once(s, '/* End PBXBuildFile section */', f'{a_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {b_id} /* {name} */; }};\n/* End PBXBuildFile section */', 'PBX build file')
    s = once(s, '/* End PBXFileReference section */', f'{b_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */', 'PBX reference')
    marker = 'B00000000000000000000002 /* ContentView.swift */,'
    s = once(s, marker, marker + f'\n {b_id} /* {name} */,', 'PBX group')
    marker = 'A00000000000000000000002 /* ContentView.swift in Sources */,'
    s = once(s, marker, marker + f' {a_id} /* {name} in Sources */,', 'PBX sources')
s = s.replace('MARKETING_VERSION = 2.21.0;', 'MARKETING_VERSION = 2.22.0;')
p.write_text(s)

print('V2.22.0 configurable Pay Profile + compact Today tools integrated')
