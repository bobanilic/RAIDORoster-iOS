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
        // User's September calendar: 15 flight days, 4 standby, 2 POS,
        // 5 away OFF, 1 OTHER, 3 home OFF. Synthetic sector durations preserve 73:54 total.
        let flightDays = [1,3,5,7,8,10,11,13,14,15,18,19,22,24,25]
        let standbyDays = [6,12,20,23]
        let posDays = [26,30]
        var septemberDays: [EarningsRosterDay] = []
        var septemberEvents: [EarningsLocationEvent] = []
        var septemberFlights: [EarningsFlight] = []
        for n in 1...30 {
            let day = String(format: "2026-09-%02d", n)
            let category = flightDays.contains(n) ? "FLIGHT" : standbyDays.contains(n) ? "STANDBY" : posDays.contains(n) ? "POSITIONING" : n == 4 ? "OTHER" : "OFF"
            septemberDays.append(EarningsRosterDay(day: day, categories: [category]))
            if category == "FLIGHT" || category == "POSITIONING" {
                let origin = n == 30 ? "BEG" : "TLV"
                let destination = n == 26 ? "BEG" : "TLV"
                septemberEvents.append(EarningsLocationEvent(day: day, order: day + " 12:00", origin: origin, destination: nil))
                septemberEvents.append(EarningsLocationEvent(day: day, order: day + " 20:00", origin: nil, destination: destination))
            }
            if category == "FLIGHT" { septemberFlights.append(flight("S" + day, day: day, minutes: n == 25 ? 234 : 300)) }
        }
        var september = EarningsMonth()
        let daily = EarningsDailyPolicy.lines(month: "2026-09", days: septemberDays, events: septemberEvents, record: september)
        expect(daily.filter(\.paid).count == 27, "September has 27 daily payments")
        expect(daily.filter { !$0.paid }.map(\.day) == ["2026-09-27", "2026-09-28", "2026-09-29"], "Return home excludes exactly three OFF days")
        expect(daily.filter { $0.category == "STANDBY" && $0.paid }.count == 4, "Four paid standby days")
        expect(daily.filter { $0.category == "POSITIONING" && $0.paid }.count == 2, "Both positioning days paid")
        expect(daily.filter { $0.category == "OFF" && $0.paid }.count == 5, "OFF away earns daily compensation")
        let septemberTotal = EarningsMath.summarize(month: "2026-09", flights: septemberFlights, record: EarningsDailyPolicy.recordForCalculation(september, lines: daily))
        expect(septemberTotal.estimatedMinutes == 4434 && septemberTotal.flightCents == 184750, "73:54 at EUR25 = EUR1847.50")
        expect(septemberTotal.perDiemCents == 135000 && septemberTotal.totalCents == 319750, "September regression: EUR3197.50")
        september.perDiemDays = Set(daily.filter(\.paid).map(\.day))
        let union = EarningsDailyPolicy.lines(month: "2026-09", days: septemberDays, events: septemberEvents, record: september)
        expect(union.filter(\.paid).count == 27, "Manual trip and automatic days never stack")
        september.adjustments = [EarningsAdjustment(kind: .standby, note: "Old manual standby", cents: 20000)]
        expect(EarningsMath.summarize(month: "2026-09", flights: septemberFlights, record: EarningsDailyPolicy.recordForCalculation(september, lines: union)).totalCents == 319750, "Legacy standby entry cannot duplicate automatic standby")
        septemberDays[3].categories = ["RESERVE"]
        september.dailyOverrides = ["2026-09-04": true]
        let reserve = EarningsDailyPolicy.lines(month: "2026-09", days: septemberDays, events: septemberEvents, record: september)
        expect(reserve.first { $0.day == "2026-09-04" }!.paid == false, "RES unpaid even away with old trip or paid override")
        expect(reserve.filter(\.paid).count == 26, "RES reduces eligible daily count")
        let reserveTotal = EarningsMath.summarize(month: "2026-09", flights: septemberFlights, record: EarningsDailyPolicy.recordForCalculation(september, lines: reserve))
        expect(reserveTotal.totalCents == 314750, "One RES removes exactly EUR50")
        septemberDays[3].categories = ["RESERVE", "FLIGHT"]
        expect(EarningsDailyPolicy.lines(month: "2026-09", days: septemberDays, events: septemberEvents, record: EarningsMonth()).first { $0.day == "2026-09-04" }!.paid, "Activated reserve with a real flight pays once")
        let unknown = [EarningsRosterDay(day: "2026-09-09", categories: ["OFF"])]
        expect(EarningsDailyPolicy.lines(month: "2026-09", days: unknown, events: [], record: EarningsMonth()).first!.needsReview, "Unknown OFF location is not silently paid")
        let homeOff = [EarningsRosterDay(day: "2026-09-09", categories: ["OFF"], stations: ["BEG"])]
        expect(!EarningsDailyPolicy.lines(month: "2026-09", days: homeOff, events: [], record: EarningsMonth()).first!.paid, "Explicit home OFF is unpaid")
        var correction = EarningsMonth(); correction.dailyOverrides = ["2026-09-09": true]
        expect(EarningsDailyPolicy.lines(month: "2026-09", days: unknown, events: [], record: correction).first!.paid, "Crew can correct an unknown day")
        correction.dailyOverrides = ["2026-09-02": false]
        expect(!EarningsDailyPolicy.lines(month: "2026-09", days: septemberDays, events: septemberEvents, record: correction).first { $0.day == "2026-09-02" }!.paid, "Unpaid correction survives automatic regeneration")
        let conflicting = [EarningsLocationEvent(day: "2026-09-08", order: "2026-09-08", origin: nil, destination: "TLV"), EarningsLocationEvent(day: "2026-09-10", order: "2026-09-10", origin: "BEG", destination: nil)]
        expect(EarningsDailyPolicy.lines(month: "2026-09", days: unknown, events: conflicting, record: EarningsMonth()).first!.needsReview, "Conflicting route locations require review")
        expect(EarningsDailyPolicy.route("TLV → BEG").1 == "BEG", "Roster arrow route parsed")
        expect(EarningsDailyPolicy.airport("BEG123") == nil, "Home airport must be a three-letter code")
        let oldMonthData = try JSONEncoder().encode(EarningsMonth())
        let migrated = try JSONDecoder().decode(EarningsMonth.self, from: oldMonthData)
        expect(migrated.homeAirport == nil && migrated.dailyOverrides == nil, "Legacy monthly records decode with optional daily settings")
        print("Passed \(checks) earnings checks")
    }
}
