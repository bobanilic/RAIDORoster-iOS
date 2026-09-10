import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct PayProfileChecks {
    static func main() {
        let rates = EarningsRates(cc: 2500, scc: 3125, perDiem: 5000, lineCheck: 3500)
        let legacy = EarningsPayProfile.legacy(rates: rates, homeAirport: "BEG")
        expect(legacy.ccBlockRateCents == 2500, "legacy CC rate")
        expect(legacy.sccBlockRateCents == 3125, "legacy SCC rate")
        expect(legacy.dailyAllowanceCents == 5000, "legacy daily allowance")
        expect(legacy.lineCheckCents == 3500, "legacy line check")
        expect(legacy.homeAirport == "BEG", "legacy home airport")
        expect(!legacy.basicSalaryEnabled && legacy.basicSalaryCents == 0, "legacy basic salary remains disabled")
        expect(!legacy.flightHomeDaily, "legacy home-base flight has no daily payment")
        expect(legacy.flightAwayDaily, "legacy away flight has daily payment")
        expect(legacy.standbyDaily, "legacy standby is paid")
        expect(legacy.positioningDaily, "legacy positioning is paid")
        expect(legacy.offAwayDaily, "legacy OFF away is paid")
        expect(!legacy.reserveDaily, "legacy reserve remains unpaid")
        expect(!legacy.absenceDaily, "legacy absences remain unpaid")
        expect(!legacy.dutyDayEnabled && legacy.dutyDayCents == 0, "legacy has no duty-day supplement")
        expect(EarningsPayProfileEngine.legacyCompatible(legacy, rates: rates, homeAirport: "BEG"), "legacy profile must exactly reproduce current policy")

        var configured = legacy
        configured.basicSalaryEnabled = true
        configured.basicSalaryCents = 80000
        configured.dutyDayEnabled = true
        configured.dutyDayCents = 4500
        configured.reserveDaily = true
        configured.rank = .jcc
        configured.currency = "USD"
        expect(EarningsPayProfileEngine.basicSalary(configured) == 80000, "basic salary component")
        expect(EarningsPayProfileEngine.dutySupplement(flightDays: 7, profile: configured) == 31500, "duty-day supplement")
        expect(configured.normalizedCurrency == "USD", "currency normalization")

        var archive = EarningsPayProfileArchive()
        var first = legacy
        first.ccBlockRateCents = 1200
        archive.save(first, effectiveMonth: "2026-01")
        var second = configured
        second.ccBlockRateCents = 2500
        archive.save(second, effectiveMonth: "2026-08")
        expect(archive.profile(for: "2025-12") == nil, "profile must not apply before effective date")
        expect(archive.profile(for: "2026-07")?.ccBlockRateCents == 1200, "older profile applies to older month")
        expect(archive.profile(for: "2026-08")?.ccBlockRateCents == 2500, "new revision applies on effective month")
        expect(archive.profile(for: "2027-01")?.ccBlockRateCents == 2500, "latest revision carries forward")

        var replacement = second
        replacement.ccBlockRateCents = 2600
        archive.save(replacement, effectiveMonth: "2026-08")
        expect(archive.revisions.count == 2, "same effective month replaces instead of duplicating")
        expect(archive.profile(for: "2026-09")?.ccBlockRateCents == 2600, "replacement revision wins")

        print("Pay Profile: 24 checks passed")
    }
}
