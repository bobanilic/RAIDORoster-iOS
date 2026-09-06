import SwiftUI

@MainActor
final class EarningsStore: ObservableObject {
    @Published private(set) var archive = EarningsArchive()
    @Published private(set) var error: String?
    private let persistence = EarningsPersistence()
    private var readable = true
    init() {
        do { archive = try persistence.load() }
        catch { readable = false; self.error = "Saved earnings could not be read. Your saved data has been retained." }
    }
    func record(_ month: String) -> EarningsMonth {
        if let saved = archive.months[month] { return saved }
        var value = EarningsMonth()
        if let earlier = archive.months.keys.filter({ $0 < month }).sorted().last {
            value.rates = archive.months[earlier]!.rates
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
            record.perDiemDays.formUnion(values); next.months[month] = record
        }
        do { try persistence.save(next); archive = next; error = nil }
        catch { self.error = "Trip dates could not be saved. Please try again." }
    }
}

struct MonthlyEarningsCard: View {
    @ObservedObject var roster: RosterStore
    @ObservedObject var earnings: EarningsStore
    let month: String
    @AppStorage("RAIDORoster.Earnings.HideAmount") private var hideAmount = false
    private var flights: [EarningsFlight] { earningsFlights(store: roster, month: month) }
    private var summary: EarningsSummary { EarningsMath.summarize(month: month, flights: flights, record: earnings.record(month)) }

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink {
                MonthlyEarningsView(roster: roster, earnings: earnings, month: month)
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Text(EarningsMath.monthTitle(month)).font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(EarningsMath.hours(summary.estimatedMinutes)).font(.title3.bold().monospacedDigit())
                            Text("Block hours · estimate").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(earnings.error != nil ? "Unavailable" : hideAmount ? "••••" : EarningsMath.money(summary.totalCents))
                                .font(.headline.monospacedDigit())
                            Text("Monthly earnings ›").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.foregroundStyle(.primary)
            }.buttonStyle(.plain)
            Button { hideAmount.toggle() } label: {
                Image(systemName: hideAmount ? "eye.slash" : "eye")
                    .frame(width: 44, height: 44).foregroundStyle(.secondary)
            }.buttonStyle(.plain).accessibilityLabel(hideAmount ? "Show earnings amount" : "Hide earnings amount")
        }
        .padding(14)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
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

private struct MonthlyEarningsView: View {
    @ObservedObject var roster: RosterStore
    @ObservedObject var earnings: EarningsStore
    let month: String
    @State private var editor: EarningsEditor?
    @State private var removePayment = false
    private var flights: [EarningsFlight] { earningsFlights(store: roster, month: month) }
    private var record: EarningsMonth { earnings.record(month) }
    private var summary: EarningsSummary { EarningsMath.summarize(month: month, flights: flights, record: record) }
    private var isPast: Bool { month < String(EarningsMath.day(Date()).prefix(7)) }

    var body: some View {
        List {
            if let error = earnings.error { Section { Text(error).foregroundStyle(.orange) } }
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
            }
            Section("Block hours") {
                LabeledContent("Scheduled", value: EarningsMath.hours(summary.scheduledMinutes))
                LabeledContent("Confirmed actual", value: EarningsMath.hours(summary.confirmedMinutes))
                LabeledContent("Used in estimate", value: EarningsMath.hours(summary.estimatedMinutes))
                Text("\(summary.unconfirmedFlights) sector(s) still use unconfirmed roster times.").font(.caption).foregroundStyle(.secondary)
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
            }
            Section("Breakdown") {
                LabeledContent("Block-hour pay", value: EarningsMath.money(summary.flightCents))
                LabeledContent("Line-check fees", value: EarningsMath.money(summary.lineCheckCents))
                LabeledContent("Per diems · \(record.perDiemDays.count) days", value: EarningsMath.money(summary.perDiemCents))
                LabeledContent("Extra pay / deductions", value: EarningsMath.money(summary.adjustmentCents))
                LabeledContent("Reimbursements", value: EarningsMath.money(summary.reimbursementCents))
                Button("Edit this month’s rates", systemImage: "slider.horizontal.3") { editor = .rates }
            }
            Section {
                Button("Add eligible away-trip dates", systemImage: "calendar.badge.plus") { editor = .trip }
                if record.perDiemDays.isEmpty { Text("No per-diem dates confirmed yet.").foregroundStyle(.secondary) }
                ForEach(record.perDiemDays.sorted(), id: \.self) { day in
                    LabeledContent(day, value: EarningsMath.money(record.rates.perDiem))
                        .swipeActions { Button("Remove", role: .destructive) { earnings.change(month) { $0.perDiemDays.remove(day) } } }
                }
            } header: { Text("Per-diem dates · UTC") } footer: {
                Text("Confirm eligible operational days on trips away from home base. Same-day trips do not qualify under this preset. Review arrival, return, rest and reserve dates; swipe to remove exceptions. Trip dates spanning months are assigned to each month once.")
            }
            Section("Other payments") {
                Button("Add payment or adjustment", systemImage: "plus.circle") { editor = .adjustment }
                ForEach(record.adjustments) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(item.kind.label, value: EarningsMath.money(item.signedCents))
                        Text(item.note).font(.caption).foregroundStyle(.secondary)
                    }.swipeActions { Button("Remove", role: .destructive) { earnings.change(month) { $0.adjustments.removeAll { $0.id == item.id } } } }
                }
            }
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
                }
            }
        }
        .navigationTitle("Monthly earnings")
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
    @ObservedObject var earnings: EarningsStore
    let month: String
    @Environment(\.dismiss) private var dismiss
    @State private var cc: String
    @State private var scc: String
    @State private var perDiem: String
    @State private var lineCheck: String
    init(earnings: EarningsStore, month: String, rates: EarningsRates) {
        self.earnings = earnings; self.month = month
        _cc = State(initialValue: EarningsMath.amountText(rates.cc)); _scc = State(initialValue: EarningsMath.amountText(rates.scc))
        _perDiem = State(initialValue: EarningsMath.amountText(rates.perDiem)); _lineCheck = State(initialValue: EarningsMath.amountText(rates.lineCheck))
    }
    private var values: [Int]? {
        let v = [cc, scc, perDiem, lineCheck].compactMap(EarningsMath.parseAmount)
        return v.count == 4 ? v : nil
    }
    var body: some View {
        Form {
            Section("EUR · " + EarningsMath.monthTitle(month)) {
                moneyField("JCC / CC per hour", text: $cc)
                moneyField("SCC per hour", text: $scc)
                moneyField("Per eligible day", text: $perDiem)
                moneyField("Instructor line check / sector", text: $lineCheck)
            }
            Section { Text("Rates are personal and saved per month. New months inherit the most recent earlier saved rates. Earlier saved months keep their own rates. A briefing role never changes your pay role automatically.") }
        }.navigationTitle("Pay rates")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") {
                guard let v = values else { return }
                earnings.change(month) { $0.rates = EarningsRates(cc: v[0], scc: v[1], perDiem: v[2], lineCheck: v[3]) }
                if earnings.error == nil { dismiss() }
            }.disabled(values == nil) }
        }
    }
}

private struct EarningsFlightEditor: View {
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
        Form {
            Section {
                Text(flight.title); Text(flight.day).foregroundStyle(.secondary)
                LabeledContent("Roster estimate", value: flight.scheduledMinutes.map(EarningsMath.hours) ?? "Missing times")
                Toggle("Use confirmed actual block time", isOn: $confirmed).disabled(!flight.ended)
                if confirmed { TextField("Actual block time · H:MM", text: $actual).keyboardType(.numbersAndPunctuation) }
                if !flight.ended { Text("Actual hours can be confirmed after the rostered sector ends.").font(.caption).foregroundStyle(.secondary) }
            } footer: { Text("Enter off-block to on-block duration. Roster times are not automatically treated as actual, and live fleet positions are not used for pay.") }
            Section {
                Picker("Contractual pay role", selection: $role) { ForEach(EarningsRole.allCases) { Text($0.label).tag($0) } }
                Toggle("Qualifying instructor line check", isOn: $lineCheck)
            } footer: { Text("Select SCC only when its pay rate applies to you. A deputy assignment alone does not change your contractual rate.") }
        }.navigationTitle("Sector hours & pay")
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
        Form {
            Section {
                DatePicker("Leave home base · UTC", selection: $start, displayedComponents: .date)
                DatePicker("Return home base · UTC", selection: $end, in: start..., displayedComponents: .date)
            }
            Section {
                if days.isEmpty { Text("Choose an overnight trip of up to one year. Same-day trips are excluded.").foregroundStyle(.secondary) }
                ForEach(days, id: \.self) { day in
                    Toggle(day, isOn: Binding(get: { !excluded.contains(day) }, set: { on in
                        if on { excluded.remove(day) } else { excluded.insert(day) }
                    }))
                }
            } header: { Text("Confirm eligible operational days") } footer: {
                Text("Dates are suggestions from the trip you enter. Turn off any non-payable dates before adding. Existing dates will not be counted twice. Each UTC date goes to its own calendar month.")
            }
        }.environment(\.timeZone, EarningsMath.utc.timeZone)
        .navigationTitle("Per-diem dates")
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
    @ObservedObject var earnings: EarningsStore
    let month: String
    @Environment(\.dismiss) private var dismiss
    @State private var kind: EarningsAdjustmentKind = .extra
    @State private var amount = ""
    @State private var note = ""
    var body: some View {
        Form {
            Picker("Payment type", selection: $kind) { ForEach(EarningsAdjustmentKind.allCases) { Text($0.label).tag($0) } }
            moneyField("Amount · EUR", text: $amount)
            TextField("Description", text: $note)
            Text("Add agreed payments only. Standby and reserve are not assigned an automatic rate.").font(.caption).foregroundStyle(.secondary)
        }.navigationTitle("Add adjustment")
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
        Form {
            moneyField("Received · EUR", text: $amount)
            DatePicker("Received on", selection: $date, in: ...Date(), displayedComponents: .date)
            LabeledContent("Saved comparison estimate", value: EarningsMath.money(original?.estimate.totalCents ?? summary.totalCents))
            Text("This records the monthly payment you received. The comparison estimate is saved so later roster or rate changes do not rewrite this payment record.").font(.caption).foregroundStyle(.secondary)
        }.environment(\.timeZone, EarningsMath.utc.timeZone)
        .navigationTitle("Monthly payment")
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
