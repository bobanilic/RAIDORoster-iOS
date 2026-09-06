import Foundation

@main
struct EarningsChecks {
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1
        }
        func flight(_ id: String, day: String = "2026-09-05", minutes: Int? = 90, ended: Bool = true, fingerprint: String = "v1") -> EarningsFlight {
            EarningsFlight(id: id, day: day, title: id, fingerprint: fingerprint, scheduledMinutes: minutes, ended: ended)
        }
        expect(EarningsMath.parseHours("1:30") == 90, "Minutes, not decimal hours")
        expect(EarningsMath.parseHours("1:60") == nil, "Reject malformed minutes")
        expect(EarningsMath.parseHours("1.30") == nil, "Reject ambiguous decimal duration")
        expect(EarningsMath.parseHours("-1:00") == nil, "Reject negative duration")
        expect(EarningsMath.parseHours("25:00") == nil, "Reject impossible sector duration")
        expect(EarningsMath.parseAmount("31,25") == 3125, "Comma decimal input")
        expect(EarningsMath.parseAmount("25.00") == 2500, "Exact currency cents")
        expect(EarningsMath.parseAmount("25.001") == nil, "No silent money truncation")
        expect(EarningsMath.parseAmount("-10") == nil, "Adjustment sign comes from type")
        expect(EarningsMath.parseAmount("nan") == nil, "No nonfinite pay")
        expect(EarningsMath.parseAmount("1000001") == nil, "Bound money input")
        expect(EarningsMath.date("2026-02-30") == nil, "Reject normalized invalid dates")
        expect(EarningsMath.date("2028-02-29") != nil, "Leap day accepted")
        expect(EarningsMath.paymentWindow("2026-12").contains("2027"), "December payment rolls to January")
        expect(EarningsMath.paymentWindow("2026-09").hasPrefix("10–15"), "Payment window is 10–15 following month")
        let a = EarningsMath.date("2026-08-30")!, b = EarningsMath.date("2026-09-02")!
        expect(EarningsMath.eligibleTripDays(start: a, end: b) == ["2026-08-30", "2026-08-31", "2026-09-01", "2026-09-02"], "UTC cross-month trip dates")
        expect(EarningsMath.eligibleTripDays(start: a, end: a).isEmpty, "Same-day trip excluded")
        expect(EarningsMath.eligibleTripDays(start: b, end: a).isEmpty, "Reversed trip rejected")
        var record = EarningsMonth()
        var result = EarningsMath.summarize(month: "2026-09", flights: [flight("A"), flight("A"), flight("B", day: "2026-08-31")], record: record)
        expect(result.flightCents == 3750 && result.scheduledMinutes == 90, "Dedupe sectors, scope month, 90 minutes at EUR25")
        expect(result.confirmedMinutes == 0 && result.unconfirmedFlights == 1, "Elapsed flight not automatically actual")
        record.flights["A"] = EarningsFlightEdit(fingerprint: "v1", actualMinutes: 100, role: .scc, lineCheck: true)
        result = EarningsMath.summarize(month: "2026-09", flights: [flight("A")], record: record)
        expect(result.flightCents == 5208, "Actual minutes replace schedule and SCC cents round correctly")
        expect(result.confirmedMinutes == 100 && result.scheduledMinutes == 90, "Actual and schedule remain separate")
        expect(result.lineCheckCents == 3500, "Qualifying instructor sector fee")
        result = EarningsMath.summarize(month: "2026-09", flights: [flight("A", ended: false)], record: record)
        expect(result.confirmedMinutes == 0 && result.estimatedMinutes == 90, "Future flight cannot have confirmed actuals")
        result = EarningsMath.summarize(month: "2026-09", flights: [flight("A", fingerprint: "v2")], record: record)
        expect(result.reviewCount == 1 && result.flightCents == 3750 && result.lineCheckCents == 0, "Changed source invalidates prior edit and flags review")
        result = EarningsMath.summarize(month: "2026-09", flights: [], record: record)
        expect(result.reviewCount == 1 && result.flightCents == 0, "Removed flight contributes no ghost pay")
        result = EarningsMath.summarize(month: "2026-09", flights: [flight("C", minutes: nil)], record: EarningsMonth())
        expect(result.missingFlights == 1 && result.flightCents == 0, "Missing times produce an explicit incomplete estimate")
        record.perDiemDays = Set(EarningsMath.eligibleTripDays(start: a, end: b))
        record.perDiemDays.insert("2026-09-01")
        record.perDiemDays.insert("2026-09-40")
        record.adjustments = [EarningsAdjustment(kind: .standby, note: "Agreed", cents: 5000), EarningsAdjustment(kind: .reimbursement, note: "Taxi", cents: 1234), EarningsAdjustment(kind: .deduction, note: "Correction", cents: 1000)]
        result = EarningsMath.summarize(month: "2026-09", flights: [], record: record)
        expect(result.perDiemCents == 10000, "Per diems deduplicated, validated, split by month")
        expect(result.adjustmentCents == 4000 && result.reimbursementCents == 1234, "Reimbursements and deductions distinct")
        expect(result.totalCents == 15234, "Exact final cash estimate")
        record.payment = EarningsPayment(cents: 15000, receivedDate: b, estimate: result)
        record.rates.perDiem = 6000
        let revised = EarningsMath.summarize(month: "2026-09", flights: [], record: record)
        expect(revised.totalCents != record.payment!.estimate.totalCents, "Paid comparison stays frozen when rates change")
        let suite = "RAIDO.EarningsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = EarningsPersistence(defaults: defaults)
        var archive = EarningsArchive(); archive.months["2026-09"] = record
        try persistence.save(archive)
        let loaded = try EarningsPersistence(defaults: UserDefaults(suiteName: suite)!).load()
        expect(loaded.months["2026-09"]!.payment!.cents == 15000, "Received payment persists")
        expect(loaded.months["2026-09"]!.payment!.estimate == result, "Saved comparison persists independently")
        expect(loaded.months["2026-09"]!.flights["A"]!.actualMinutes == 100, "Actual block-time override survives relaunch")
        expect(loaded.months["2026-08"] == nil, "Month edits do not create unrelated month payments")
        defaults.set(Data("corrupt".utf8), forKey: "RAIDORoster.Earnings.V1")
        expect((try? persistence.load()) == nil, "Corruption cannot silently reset pay records")
        print("Passed \(checks) earnings checks")
    }
}
