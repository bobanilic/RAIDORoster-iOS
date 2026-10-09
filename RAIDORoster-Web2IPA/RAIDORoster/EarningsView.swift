import SwiftUI

@MainActor
final class EarningsStore: ObservableObject {
    static let shared = EarningsStore()
    @Published private(set) var archive = EarningsArchive()
    @Published private(set) var payProfiles = EarningsPayProfileArchive()
    @Published private(set) var error: String?
    private let persistence = EarningsPersistence()
    private let profilePersistence = EarningsPayProfilePersistence()
    private var readable = true
    init() {
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
    }
    func record(_ month: String) -> EarningsMonth {
        if let saved = archive.months[month] { return saved }
        var value = EarningsMonth()
        if let earlier = archive.months.keys.filter({ $0 < month }).sorted().last {
            value.rates = archive.months[earlier]!.rates
            value.homeAirport = archive.months[earlier]!.homeAirport
        }
        return value
    }
    func change(_ month: String, _ update: (inout EarningsMonth) -> Void) {
        guard readable else { return }
        var next = archive
        var record = self.record(month)
        update(&record); next.months[month] = record
        do { try persistence.save(next); archive = next; error = nil }
        catch { self.error = "Earnings changes could not be saved. Please try again." }
    }
    func addTrip(_ days: [String]) {
        guard readable else { return }
        var next = archive
        for (month, values) in Dictionary(grouping: days, by: { String($0.prefix(7)) }) {
            var record = self.record(month)
            record.perDiemDays.formUnion(values)
            for day in values { record.dailyOverrides?[day] = nil }
            next.months[month] = record
        }
        do { try persistence.save(next); archive = next; error = nil }
        catch { self.error = "Trip dates could not be saved. Please try again." }
    }
}

struct MonthlyEarningsCard: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @ObservedObject var roster: RosterStore
    @ObservedObject var earnings: EarningsStore
    let month: String
    @State private var hideAmount = true
    @Environment(\.scenePhase) private var scenePhase
    private var flights: [EarningsFlight] { earningsFlights(store: roster, month: month) }
    private var profile: EarningsPayProfile { earnings.profile(month) }
    private var daily: [EarningsDailyLine] { earningsDailyLines(store: roster, month: month, record: earnings.record(month), profile: profile) }
    private var raidoBLHMinutes: Int? {
        guard roster.selectedRosterMonth == month,
              let value = roster.rosterViewSnapshot?.monthlyBLH else { return nil }
        return EarningsMath.parseMonthlyBLH(value)
    }
    private var summary: EarningsSummary { EarningsMath.summarize(month: month, flights: flights, record: EarningsDailyPolicy.recordForCalculation(earnings.record(month), lines: daily, profile: profile), authoritativeBLHMinutes: raidoBLHMinutes, profile: profile) }

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        HStack(spacing: 12) {
            NavigationLink {
                MonthlyEarningsView(roster: roster, earnings: earnings, month: month)
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Text(EarningsMath.monthTitle(month)).font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(EarningsMath.hours(summary.estimatedMinutes)).font(.title3.bold().monospacedDigit())
                            Text(raidoBLHMinutes == nil ? "Block hours · estimate" : "Block hours · RAIDO").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(earnings.error != nil ? "Unavailable" : hideAmount ? "••••" : EarningsMath.money(summary.totalCents))
                                .font(.headline.monospacedDigit())
                            Text("Monthly earnings ›").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Block pay + \(daily.filter(\.paid).count) daily payments")
                        .font(.caption2).foregroundStyle(.secondary)
                    if daily.contains(where: \.needsReview) {
                        Text("Some daily payments need review").font(.caption2).foregroundStyle(.orange)
                    }
                }.foregroundStyle(.primary)
            }.buttonStyle(.plain)
            Button { hideAmount.toggle() } label: {
                Image(systemName: hideAmount ? "eye.slash" : "eye")
                    .frame(width: 44, height: 44).foregroundStyle(.secondary)
            }.buttonStyle(.plain).accessibilityLabel(hideAmount ? "Show earnings amount" : "Hide earnings amount")
        }
        .padding(14)
        .midnightCard(radius: 16)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { hideAmount = true }
        }
        .onDisappear { hideAmount = true }
    }
}

private enum EarningsEditor: Identifiable {
    case rates, trip, adjustment, payment, flight(EarningsFlight)
    var id: String {
        switch self {
        case .rates: return "rates"
        case .trip: return "trip"
        case .adjustment: return "adjustment"
        case .payment: return "payment"
        case .flight(let flight): return flight.id
        }
    }
}

struct MonthlyEarningsView: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @ObservedObject var roster: RosterStore
    @ObservedObject var earnings: EarningsStore
    let month: String
    @State private var editor: EarningsEditor?
    @State private var removePayment = false
    private var flights: [EarningsFlight] { earningsFlights(store: roster, month: month) }
    private var record: EarningsMonth { earnings.record(month) }
    private var profile: EarningsPayProfile { earnings.profile(month) }
    private var daily: [EarningsDailyLine] { earningsDailyLines(store: roster, month: month, record: record, profile: profile) }
    private var raidoBLHMinutes: Int? {
        guard roster.selectedRosterMonth == month,
              let value = roster.rosterViewSnapshot?.monthlyBLH else { return nil }
        return EarningsMath.parseMonthlyBLH(value)
    }
    private var summary: EarningsSummary { EarningsMath.summarize(month: month, flights: flights, record: EarningsDailyPolicy.recordForCalculation(record, lines: daily, profile: profile), authoritativeBLHMinutes: raidoBLHMinutes, profile: profile) }
    private var isPast: Bool { month < String(EarningsMath.day(Date()).prefix(7)) }

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        List {
            if let error = earnings.error { Section { Text(error).foregroundStyle(.orange) }.listRowBackground(MidnightTheme.surface) }
            Section {
                LabeledContent("Estimated total", value: EarningsMath.money(summary.totalCents)).font(.headline)
                LabeledContent("Payment window", value: EarningsMath.paymentWindow(month))
                if !roster.isCacheValidated || roster.rosterViewSnapshot == nil {
                    Text("Roster needs a resync. Cached figures may be incomplete.").foregroundStyle(.orange)
                }
                if flights.isEmpty { Text("No flight sectors available for this month.").foregroundStyle(.secondary) }
                if summary.missingFlights > 0 { Text("\(summary.missingFlights) flight(s) have missing times and are excluded from the hours estimate.").foregroundStyle(.orange) }
                if summary.reviewCount > 0 { Text("\(summary.reviewCount) saved flight edit(s) need review after a roster change. Unmatched edits are excluded.").foregroundStyle(.orange) }
            } header: { Text(EarningsMath.monthTitle(month)) } footer: {
                Text("Monthly estimate before personal taxes. Scheduled sectors remain estimates until actual block time is confirmed. Reimbursements are shown separately below.")
            }.listRowBackground(MidnightTheme.surface)
            Section("Block hours") {
                LabeledContent("Scheduled", value: EarningsMath.hours(summary.scheduledMinutes))
                LabeledContent("Confirmed actual", value: EarningsMath.hours(summary.confirmedMinutes))
                LabeledContent(raidoBLHMinutes == nil ? "Used in estimate" : "RAIDO BLH", value: EarningsMath.hours(summary.estimatedMinutes))
                Text(raidoBLHMinutes == nil ? "\(summary.unconfirmedFlights) sector(s) still use unconfirmed roster times." : "Monthly BLH is taken directly from RAIDO; sector times are shown only for detail.").font(.caption).foregroundStyle(.secondary)
                ForEach(flights) { flight in
                    Button { editor = .flight(flight) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(flight.title).foregroundStyle(.primary)
                                Text(flight.day).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(flightLabel(flight)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                if summary.reviewCount > 0 {
                    Button("Discard unmatched flight edits", role: .destructive) {
                        earnings.change(month) { record in
                            record.flights = record.flights.filter { key, edit in flights.contains { $0.id == key && $0.fingerprint == edit.fingerprint } }
                        }
                    }
                }
            }.listRowBackground(MidnightTheme.surface)
            Section("Breakdown") {
                if (summary.basicSalaryCents ?? 0) > 0 { LabeledContent("Basic salary", value: EarningsMath.money(summary.basicSalaryCents ?? 0, currency: profile.normalizedCurrency)) }
                LabeledContent("Block-hour pay", value: EarningsMath.money(summary.flightCents, currency: profile.normalizedCurrency))
                if (summary.dutyDayCents ?? 0) > 0 { LabeledContent("Duty-day supplement", value: EarningsMath.money(summary.dutyDayCents ?? 0, currency: profile.normalizedCurrency)) }
                LabeledContent("Line-check fees", value: EarningsMath.money(summary.lineCheckCents, currency: profile.normalizedCurrency))
                LabeledContent("Daily pay · \(daily.filter(\.paid).count) days", value: EarningsMath.money(summary.perDiemCents, currency: profile.normalizedCurrency))
                LabeledContent("Extra pay / deductions", value: EarningsMath.money(summary.adjustmentCents))
                LabeledContent("Reimbursements", value: EarningsMath.money(summary.reimbursementCents))
                Text("Rates and eligibility are configured in Settings → Earnings → Pay Profile.").font(.caption).foregroundStyle(.secondary)
            }.listRowBackground(MidnightTheme.surface)
            Section {
                LabeledContent("Paid days", value: "\(daily.filter(\.paid).count) × \(EarningsMath.money(record.rates.perDiem))")
                LabeledContent("Unpaid days", value: "\(daily.filter { !$0.paid && !$0.needsReview }.count)")
                if daily.contains(where: \.needsReview) {
                    Text("\(daily.filter(\.needsReview).count) day(s) need a location check and are not included yet.").foregroundStyle(.orange)
                }
                DisclosureGroup("Review daily payments") {
                    ForEach(daily) { line in
                        Toggle(isOn: Binding(get: { line.paid }, set: { paid in
                            earnings.change(month) { record in
                                var overrides = record.dailyOverrides ?? [:]
                                overrides[line.day] = paid; record.dailyOverrides = overrides
                            }
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(line.day) · \(line.category)")
                                Text(line.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(line.reserveOnly)
                        .swipeActions {
                            Button("Automatic") {
                                earnings.change(month) {
                                    $0.dailyOverrides?[line.day] = nil
                                    $0.perDiemDays.remove(line.day)
                                }
                            }.tint(.blue)
                        }
                    }
                }
                Button("Add away-trip dates manually", systemImage: "calendar.badge.plus") { editor = .trip }
            } header: { Text("Daily payments · UTC") } footer: {
                Text("Away from home base: one EUR50 daily payment on eligible roster days. At home base: STB and positioning receive the daily payment; FLIGHT receives BLH only. OFF at home and RES anywhere are unpaid. Home airport: \(record.homeAirport ?? "BEG"). Route-based location estimates can be corrected above. Swipe a date to restore automatic calculation.")
            }.listRowBackground(MidnightTheme.surface)
            Section("Other payments") {
                Button("Add payment or adjustment", systemImage: "plus.circle") { editor = .adjustment }
                if record.adjustments.contains(where: { $0.kind == .standby }) && daily.contains(where: { $0.category == "STANDBY" && $0.paid }) {
                    Text("Previous manual standby amounts are excluded because standby is already counted in daily pay. Remove those entries, or re-enter a genuine additional payment as Extra pay.").font(.caption).foregroundStyle(.orange)
                }
                ForEach(record.adjustments) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(item.kind.label, value: EarningsMath.money(item.signedCents))
                        Text(item.note).font(.caption).foregroundStyle(.secondary)
                    }.swipeActions { Button("Remove", role: .destructive) { earnings.change(month) { $0.adjustments.removeAll { $0.id == item.id } } } }
                }
            }.listRowBackground(MidnightTheme.surface)
            if isPast {
                Section("Monthly payment") {
                    if let payment = record.payment {
                        LabeledContent("Received", value: EarningsMath.money(payment.cents))
                        LabeledContent("Date", value: EarningsMath.day(payment.receivedDate))
                        LabeledContent("Estimate when recorded", value: EarningsMath.money(payment.estimate.totalCents))
                        LabeledContent("Received minus estimate", value: EarningsMath.money(payment.cents - payment.estimate.totalCents))
                        if payment.estimate != summary { Text("The current estimate has changed since this payment was recorded. The saved comparison is preserved.").font(.caption).foregroundStyle(.secondary) }
                        Button("Edit received payment") { editor = .payment }
                        Button("Remove payment record", role: .destructive) { removePayment = true }
                    } else {
                        Text("Not recorded").foregroundStyle(.secondary)
                        Button("Record monthly payment", systemImage: "checkmark.circle") { editor = .payment }
                    }
                }.listRowBackground(MidnightTheme.surface)
            }
        }
        .midnightCanvas().navigationTitle("Monthly earnings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove the saved payment?", isPresented: $removePayment, titleVisibility: .visible) {
            Button("Remove payment", role: .destructive) { earnings.change(month) { $0.payment = nil } }
        }
        .sheet(item: $editor) { destination in
            NavigationStack {
                switch destination {
                case .rates: EarningsRatesEditor(earnings: earnings, month: month, rates: record.rates)
                case .trip: EarningsTripEditor(earnings: earnings, month: month)
                case .adjustment: EarningsAdjustmentEditor(earnings: earnings, month: month)
                case .payment: EarningsPaymentEditor(earnings: earnings, month: month, summary: summary, payment: record.payment)
                case .flight(let flight): EarningsFlightEditor(earnings: earnings, month: month, flight: flight, edit: record.flights[flight.id])
                }
            }
        }
    }
    private func flightLabel(_ flight: EarningsFlight) -> String {
        if let edit = record.flights[flight.id], edit.fingerprint == flight.fingerprint,
           let minutes = edit.actualMinutes, flight.ended { return EarningsMath.hours(minutes) + " ✓" }
        return flight.scheduledMinutes.map { EarningsMath.hours($0) + " est." } ?? "Missing"
    }
}

private struct EarningsRatesEditor: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @ObservedObject var earnings: EarningsStore
    let month: String
    @Environment(\.dismiss) private var dismiss
    @State private var cc: String
    @State private var scc: String
    @State private var perDiem: String
    @State private var lineCheck: String
    @State private var homeAirport: String
    init(earnings: EarningsStore, month: String, rates: EarningsRates) {
        self.earnings = earnings; self.month = month
        _homeAirport = State(initialValue: earnings.record(month).homeAirport ?? "BEG")
        _cc = State(initialValue: EarningsMath.amountText(rates.cc)); _scc = State(initialValue: EarningsMath.amountText(rates.scc))
        _perDiem = State(initialValue: EarningsMath.amountText(rates.perDiem)); _lineCheck = State(initialValue: EarningsMath.amountText(rates.lineCheck))
    }
    private var values: [Int]? {
        let v = [cc, scc, perDiem, lineCheck].compactMap(EarningsMath.parseAmount)
        return v.count == 4 ? v : nil
    }
    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        Form {
            Section("EUR · " + EarningsMath.monthTitle(month)) {
                moneyField("JCC / CC per hour", text: $cc)
                moneyField("SCC per hour", text: $scc)
                moneyField("Per paid day", text: $perDiem)
                TextField("Home airport · IATA", text: $homeAirport).textInputAutocapitalization(.characters).autocorrectionDisabled()
                moneyField("Instructor line check / sector", text: $lineCheck)
            }.listRowBackground(MidnightTheme.surface)
            Section { Text("Rates are personal and saved per month. New months inherit the most recent earlier saved rates. Earlier saved months keep their own rates. A briefing role never changes your pay role automatically.") }.listRowBackground(MidnightTheme.surface)
        }.midnightCanvas().navigationTitle("Pay rates")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") {
                guard let v = values else { return }
                earnings.change(month) {
                    $0.rates = EarningsRates(cc: v[0], scc: v[1], perDiem: v[2], lineCheck: v[3])
                    $0.homeAirport = EarningsDailyPolicy.airport(homeAirport)
                }
                if earnings.error == nil { dismiss() }
            }.disabled(values == nil || EarningsDailyPolicy.airport(homeAirport) == nil) }
        }
    }
}

private struct EarningsFlightEditor: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @ObservedObject var earnings: EarningsStore
    let month: String
    let flight: EarningsFlight
    @Environment(\.dismiss) private var dismiss
    @State private var actual: String
    @State private var confirmed: Bool
    @State private var role: EarningsRole
    @State private var lineCheck: Bool
    init(earnings: EarningsStore, month: String, flight: EarningsFlight, edit: EarningsFlightEdit?) {
        self.earnings = earnings; self.month = month; self.flight = flight
        let valid = edit?.fingerprint == flight.fingerprint ? edit : nil
        _actual = State(initialValue: EarningsMath.hours(valid?.actualMinutes ?? flight.scheduledMinutes ?? 0))
        _confirmed = State(initialValue: valid?.actualMinutes != nil && flight.ended)
        _role = State(initialValue: valid?.role ?? .cc); _lineCheck = State(initialValue: valid?.lineCheck ?? false)
    }
    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        Form {
            Section {
                Text(flight.title); Text(flight.day).foregroundStyle(.secondary)
                LabeledContent("Roster estimate", value: flight.scheduledMinutes.map(EarningsMath.hours) ?? "Missing times")
                Toggle("Use confirmed actual block time", isOn: $confirmed).disabled(!flight.ended)
                if confirmed { TextField("Actual block time · H:MM", text: $actual).keyboardType(.numbersAndPunctuation) }
                if !flight.ended { Text("Actual hours can be confirmed after the rostered sector ends.").font(.caption).foregroundStyle(.secondary) }
            } footer: { Text("Enter off-block to on-block duration. Roster times are not automatically treated as actual, and live fleet positions are not used for pay.") }.listRowBackground(MidnightTheme.surface)
            Section {
                Picker("Contractual pay role", selection: $role) { ForEach(EarningsRole.allCases) { Text($0.label).tag($0) } }
                Toggle("Qualifying instructor line check", isOn: $lineCheck)
            } footer: { Text("Select SCC only when its pay rate applies to you. A deputy assignment alone does not change your contractual rate.") }.listRowBackground(MidnightTheme.surface)
        }.midnightCanvas().navigationTitle("Sector hours & pay")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") {
                earnings.change(month) { $0.flights[flight.id] = EarningsFlightEdit(fingerprint: flight.fingerprint, actualMinutes: confirmed ? EarningsMath.parseHours(actual) : nil, role: role, lineCheck: lineCheck) }
                if earnings.error == nil { dismiss() }
            }.disabled(confirmed && EarningsMath.parseHours(actual) == nil) }
        }
    }
}

private struct EarningsTripEditor: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @ObservedObject var earnings: EarningsStore
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date
    @State private var excluded = Set<String>()
    init(earnings: EarningsStore, month: String) {
        self.earnings = earnings
        let day = EarningsMath.date(month + "-01") ?? Date()
        _start = State(initialValue: day); _end = State(initialValue: day)
    }
    private var days: [String] { EarningsMath.eligibleTripDays(start: start, end: end) }
    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        Form {
            Section {
                DatePicker("Leave home base · UTC", selection: $start, displayedComponents: .date)
                DatePicker("Return home base · UTC", selection: $end, in: start..., displayedComponents: .date)
            }.listRowBackground(MidnightTheme.surface)
            Section {
                if days.isEmpty { Text("Choose an overnight trip of up to one year. Same-day trips are excluded.").foregroundStyle(.secondary) }
                ForEach(days, id: \.self) { day in
                    Toggle(day, isOn: Binding(get: { !excluded.contains(day) }, set: { on in
                        if on { excluded.remove(day) } else { excluded.insert(day) }
                    }))
                }
            } header: { Text("Confirm paid away days") } footer: {
                Text("RES dates are always excluded by the monthly calculation. Dates are suggestions from the trip you enter. Turn off any non-payable dates before adding. Existing dates will not be counted twice. Each UTC date goes to its own calendar month.")
            }.listRowBackground(MidnightTheme.surface)
        }.environment(\.timeZone, EarningsMath.utc.timeZone)
        .midnightCanvas().navigationTitle("Per-diem dates")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Confirm days") {
                earnings.addTrip(days.filter { !excluded.contains($0) })
                if earnings.error == nil { dismiss() }
            }.disabled(days.isEmpty || days.allSatisfy { excluded.contains($0) }) }
        }
    }
}

private struct EarningsAdjustmentEditor: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @ObservedObject var earnings: EarningsStore
    let month: String
    @Environment(\.dismiss) private var dismiss
    @State private var kind: EarningsAdjustmentKind = .extra
    @State private var amount = ""
    @State private var note = ""
    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        Form {
            Picker("Payment type", selection: $kind) { ForEach(EarningsAdjustmentKind.allCases.filter { $0 != .standby }) { Text($0.label).tag($0) } }
            moneyField("Amount · EUR", text: $amount)
            TextField("Description", text: $note)
            Text("Standby is already included once in daily pay. RES is unpaid. Add only genuine extra payments here.").font(.caption).foregroundStyle(.secondary)
        }.midnightCanvas().navigationTitle("Add adjustment")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Add") {
                guard let cents = EarningsMath.parseAmount(amount) else { return }
                earnings.change(month) { $0.adjustments.append(EarningsAdjustment(kind: kind, note: note.trimmingCharacters(in: .whitespacesAndNewlines), cents: cents)) }
                if earnings.error == nil { dismiss() }
            }.disabled((EarningsMath.parseAmount(amount) ?? 0) <= 0 || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
    }
}

private struct EarningsPaymentEditor: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @ObservedObject var earnings: EarningsStore
    let month: String
    let summary: EarningsSummary
    let original: EarningsPayment?
    @Environment(\.dismiss) private var dismiss
    @State private var amount: String
    @State private var date: Date
    init(earnings: EarningsStore, month: String, summary: EarningsSummary, payment: EarningsPayment?) {
        self.earnings = earnings; self.month = month; self.summary = summary; self.original = payment
        _amount = State(initialValue: payment.map { EarningsMath.amountText($0.cents) } ?? "")
        _date = State(initialValue: payment?.receivedDate ?? Date())
    }
    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        Form {
            moneyField("Received · EUR", text: $amount)
            DatePicker("Received on", selection: $date, in: ...Date(), displayedComponents: .date)
            LabeledContent("Saved comparison estimate", value: EarningsMath.money(original?.estimate.totalCents ?? summary.totalCents))
            Text("This records the monthly payment you received. The comparison estimate is saved so later roster or rate changes do not rewrite this payment record.").font(.caption).foregroundStyle(.secondary)
        }.environment(\.timeZone, EarningsMath.utc.timeZone)
        .midnightCanvas().navigationTitle("Monthly payment")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save payment") {
                guard let cents = EarningsMath.parseAmount(amount) else { return }
                earnings.change(month) { $0.payment = EarningsPayment(cents: cents, receivedDate: date, estimate: original?.estimate ?? summary) }
                if earnings.error == nil { dismiss() }
            }.disabled(EarningsMath.parseAmount(amount) == nil) }
        }
    }
}

private func moneyField(_ label: String, text: Binding<String>) -> some View {
    HStack {
        Text(label)
        Spacer()
        TextField("0.00", text: text).multilineTextAlignment(.trailing).keyboardType(.decimalPad).frame(maxWidth: 120)
            .accessibilityLabel(label)
    }
}


struct EarningsPayProfileView: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
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
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        Form {
            Section {
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
            } header: {
                Text("Pay Profile")
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

            Section {
                profileMoneyField("Amount per eligible day", cents: $profile.dailyAllowanceCents)
                Toggle("Flight · home base", isOn: $profile.flightHomeDaily)
                Toggle("Flight · away", isOn: $profile.flightAwayDaily)
                Toggle("Standby", isOn: $profile.standbyDaily)
                Toggle("Positioning", isOn: $profile.positioningDaily)
                Toggle("OFF / other day away", isOn: $profile.offAwayDaily)
                Toggle("Reserve", isOn: $profile.reserveDaily)
                Toggle("DND / leave / sickness", isOn: $profile.absenceDaily)
            } header: {
                Text("Daily allowance")
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
