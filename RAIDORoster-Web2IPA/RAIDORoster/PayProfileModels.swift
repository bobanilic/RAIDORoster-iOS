import Foundation

enum EarningsRankPreset: String, Codable, CaseIterable, Identifiable {
    case jcc, cc, scc, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .jcc: return "JCC"
        case .cc: return "CC"
        case .scc: return "SCC"
        case .custom: return "Custom"
        }
    }
}

struct EarningsPayProfile: Codable, Equatable {
    var name: String = "My Pay Profile"
    var rank: EarningsRankPreset = .cc
    var currency: String = "EUR"
    var homeAirport: String = "BEG"
    var defaultRole: EarningsRole = .cc

    var basicSalaryEnabled = false
    var basicSalaryCents = 0

    var ccBlockRateCents = 2500
    var sccBlockRateCents = 3125
    var lineCheckCents = 3500

    var dailyAllowanceCents = 5000
    var dutyDayEnabled = false
    var dutyDayCents = 0

    var flightHomeDaily = false
    var flightAwayDaily = true
    var standbyDaily = true
    var positioningDaily = true
    var offAwayDaily = true
    var reserveDaily = false
    var absenceDaily = false

    func blockRate(_ role: EarningsRole) -> Int {
        role == .cc ? ccBlockRateCents : sccBlockRateCents
    }

    var normalizedCurrency: String {
        let value = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return value.count == 3 ? value : "EUR"
    }

    static func legacy(rates: EarningsRates, homeAirport: String?) -> EarningsPayProfile {
        EarningsPayProfile(
            name: "Current contract",
            rank: .cc,
            currency: "EUR",
            homeAirport: homeAirport ?? "BEG",
            defaultRole: .cc,
            basicSalaryEnabled: false,
            basicSalaryCents: 0,
            ccBlockRateCents: rates.cc,
            sccBlockRateCents: rates.scc,
            lineCheckCents: rates.lineCheck,
            dailyAllowanceCents: rates.perDiem,
            dutyDayEnabled: false,
            dutyDayCents: 0,
            flightHomeDaily: false,
            flightAwayDaily: true,
            standbyDaily: true,
            positioningDaily: true,
            offAwayDaily: true,
            reserveDaily: false,
            absenceDaily: false
        )
    }
}

struct EarningsPayProfileRevision: Codable, Equatable, Identifiable {
    var effectiveMonth: String
    var profile: EarningsPayProfile
    var id: String { effectiveMonth }
}

struct EarningsPayProfileArchive: Codable, Equatable {
    var version = 1
    var revisions: [EarningsPayProfileRevision] = []

    func profile(for month: String) -> EarningsPayProfile? {
        revisions
            .filter { $0.effectiveMonth <= month }
            .sorted { $0.effectiveMonth < $1.effectiveMonth }
            .last?.profile
    }

    mutating func save(_ profile: EarningsPayProfile, effectiveMonth: String) {
        revisions.removeAll { $0.effectiveMonth == effectiveMonth }
        revisions.append(EarningsPayProfileRevision(effectiveMonth: effectiveMonth, profile: profile))
        revisions.sort { $0.effectiveMonth < $1.effectiveMonth }
    }
}

final class EarningsPayProfilePersistence {
    private let defaults: UserDefaults
    private let key = "RAIDORoster.Earnings.PayProfiles.V1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() throws -> EarningsPayProfileArchive {
        guard let data = defaults.data(forKey: key) else { return EarningsPayProfileArchive() }
        let value = try JSONDecoder().decode(EarningsPayProfileArchive.self, from: data)
        guard value.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }

    func save(_ archive: EarningsPayProfileArchive) throws {
        defaults.set(try JSONEncoder().encode(archive), forKey: key)
    }
}

enum EarningsPayProfileEngine {
    static func basicSalary(_ profile: EarningsPayProfile) -> Int {
        profile.basicSalaryEnabled ? max(0, profile.basicSalaryCents) : 0
    }

    static func dutySupplement(flightDays: Int, profile: EarningsPayProfile) -> Int {
        guard profile.dutyDayEnabled, flightDays > 0 else { return 0 }
        return flightDays * max(0, profile.dutyDayCents)
    }

    static func legacyCompatible(_ profile: EarningsPayProfile, rates: EarningsRates, homeAirport: String?) -> Bool {
        profile == .legacy(rates: rates, homeAirport: homeAirport)
    }
}

extension EarningsMath {
    static func money(_ cents: Int, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return formatter.string(from: NSDecimalNumber(value: cents).dividing(by: 100)) ?? "\(currency.uppercased()) \(cents / 100)"
    }
}
