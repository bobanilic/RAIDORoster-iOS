import Foundation

// Compare the current default Pay Profile against the frozen pre-profile
// engine output in fixtures/legacy-earnings.json. Never uses real roster data.
@main
struct PayProfileParityChecks {
    static func main() throws {
        let month = "2026-09"
        var results: [[String: Int]] = []
        let categories: [Set<String>] = [
            ["FLIGHT"], ["STANDBY"], ["POSITIONING"], ["OFF"], ["OTHER"],
            ["RESERVE"], ["DND"], ["RESERVE", "FLIGHT"]
        ]
        for away in [false, true] {
            for category in categories {
                let day = "2026-09-05"
                var record = EarningsMonth()
                record.homeAirport = "BEG"
                record.perDiemDays = [day] // Includes stale paid RES dates.
                record.dailyOverrides = [day: true]
                record.adjustments = [
                    EarningsAdjustment(kind: .standby, note: "Synthetic", cents: 5000),
                    EarningsAdjustment(kind: .reimbursement, note: "Synthetic", cents: 1234),
                    EarningsAdjustment(kind: .deduction, note: "Synthetic", cents: 1000)
                ]
                let station = away ? "TLV" : "BEG"
                let days = [EarningsRosterDay(day: day, categories: category, stations: [station])]
                let events = [EarningsLocationEvent(day: day, order: day, origin: station, destination: station)]
                let flights = category.contains("FLIGHT") ? [
                    EarningsFlight(id: "A", day: day, title: "Synthetic", fingerprint: "v1", scheduledMinutes: 91, ended: true),
                    EarningsFlight(id: "A", day: day, title: "Synthetic duplicate", fingerprint: "v1", scheduledMinutes: 91, ended: true),
                    EarningsFlight(id: "B", day: day, title: "Synthetic", fingerprint: "v1", scheduledMinutes: 83, ended: true)
                ] : []
                record.flights["A"] = EarningsFlightEdit(fingerprint: "v1", actualMinutes: 100, role: .scc, lineCheck: true)
                for manual in [false, true] {
                    if !manual { record.dailyOverrides = nil; record.perDiemDays = [] }
                    else { record.dailyOverrides = [day: true]; record.perDiemDays = [day] }
                    let blhCases: [Int?] = [nil, 4434]
                    for blh in blhCases {
                        #if PAY_PROFILE
                        let profile = EarningsPayProfile.legacy(rates: record.rates, homeAirport: record.homeAirport)
                        let lines = EarningsDailyPolicy.lines(month: month, days: days, events: events, record: record, profile: profile)
                        let projected = EarningsDailyPolicy.recordForCalculation(record, lines: lines, profile: profile)
                        let sum = EarningsMath.summarize(month: month, flights: flights, record: projected, authoritativeBLHMinutes: blh, profile: profile)
                        let implicit = EarningsMath.summarize(month: month, flights: flights, record: projected, authoritativeBLHMinutes: blh)
                        precondition(sum == implicit, "Implicit default must match explicit legacy profile")
                        #else
                        let lines = EarningsDailyPolicy.lines(month: month, days: days, events: events, record: record)
                        let projected = EarningsDailyPolicy.recordForCalculation(record, lines: lines)
                        let sum = EarningsMath.summarize(month: month, flights: flights, record: projected, authoritativeBLHMinutes: blh)
                        #endif
                        results.append([
                            "total": sum.totalCents, "flight": sum.flightCents,
                            "daily": sum.perDiemCents, "lineCheck": sum.lineCheckCents,
                            "adjustment": sum.adjustmentCents, "reimbursement": sum.reimbursementCents,
                            "scheduled": sum.scheduledMinutes, "confirmed": sum.confirmedMinutes,
                            "estimated": sum.estimatedMinutes, "missing": sum.missingFlights,
                            "unconfirmed": sum.unconfirmedFlights, "review": sum.reviewCount,
                            "paidDays": lines.filter(\.paid).count,
                            "reviewDays": lines.filter(\.needsReview).count
                        ])
                    }
                }
            }
        }
        #if PAY_PROFILE
        try configuredChecks()
        #endif
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(results), as: UTF8.self))
    }

    #if PAY_PROFILE
    static func configuredChecks() throws {
        let day = "2026-09-05"
        var profile = EarningsPayProfile.legacy(rates: EarningsRates(), homeAirport: "BEG")
        profile.basicSalaryCents = 80000 // Disabled, even with a stored amount.
        profile.dutyDayEnabled = true
        profile.dutyDayCents = 4500
        profile.flightAwayDaily = false
        let flights = [
            EarningsFlight(id: "A", day: day, title: "Synthetic", fingerprint: "v1", scheduledMinutes: 90, ended: true),
            EarningsFlight(id: "B", day: day, title: "Synthetic", fingerprint: "v1", scheduledMinutes: 90, ended: true),
            EarningsFlight(id: "OLD", day: "2026-08-31", title: "Synthetic", fingerprint: "v1", scheduledMinutes: 90, ended: true)
        ]
        let days = [EarningsRosterDay(day: day, categories: ["FLIGHT"], stations: ["TLV"])]
        let record = EarningsMonth()
        let daily = EarningsDailyPolicy.lines(month: "2026-09", days: days, events: [], record: record, profile: profile)
        let projected = EarningsDailyPolicy.recordForCalculation(record, lines: daily, profile: profile)
        let sum = EarningsMath.summarize(month: "2026-09", flights: flights, record: projected, profile: profile)
        precondition(sum.basicSalaryCents == 0 && sum.dutyDayCents == 4500, "Independent supplement once per month-scoped flight day")
        precondition(sum.perDiemCents == 0 && sum.flightCents == 7500 && sum.totalCents == 12000, "Daily toggle must not alter BLH or supplement")
        profile.basicSalaryEnabled = true
        let withSalary = EarningsMath.summarize(month: "2026-09", flights: flights, record: projected, profile: profile)
        precondition(withSalary.totalCents == sum.totalCents + 80000, "Salary stacks exactly once")
        let reserve = [EarningsRosterDay(day: day, categories: ["RESERVE"], stations: ["TLV"])]
        var oldOverride = record
        oldOverride.dailyOverrides = [day: true]
        precondition(!EarningsDailyPolicy.lines(month: "2026-09", days: reserve, events: [], record: oldOverride, profile: profile)[0].paid, "Disabled reserve beats stale override")
        profile.reserveDaily = true
        oldOverride.dailyOverrides = [day: false]
        precondition(EarningsDailyPolicy.lines(month: "2026-09", days: reserve, events: [], record: oldOverride, profile: profile)[0].paid, "Enabled reserve policy remains deterministic")

        let legacy = EarningsPayProfile.legacy(rates: record.rates, homeAirport: record.homeAirport)
        var archive = EarningsPayProfileArchive()
        archive.save(legacy, effectiveMonth: "2026-01")
        archive.save(profile, effectiveMonth: "2026-10")
        let restored = try JSONDecoder().decode(EarningsPayProfileArchive.self, from: JSONEncoder().encode(archive))
        let historical = EarningsMath.summarize(month: "2026-09", flights: flights, record: record, profile: restored.profile(for: "2026-09"))
        precondition(historical.basicSalaryCents == 0 && historical.dutyDayCents == 0 && historical.flightCents == 7500, "Persisted future revision must preserve historical calculation")
        precondition(restored.profile(for: "2026-10") == profile, "Effective revision applies at boundary")
    }
    #endif
}
