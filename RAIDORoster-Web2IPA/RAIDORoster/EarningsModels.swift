import Foundation

enum EarningsRole: String, Codable, CaseIterable, Identifiable {
    case cc, scc
    var id: String { rawValue }
    var label: String { self == .cc ? "JCC / CC" : "SCC" }
}

struct EarningsRates: Codable, Equatable {
    var cc = 2500
    var scc = 3125
    var perDiem = 5000
    var lineCheck = 3500
    func hourly(_ role: EarningsRole) -> Int { role == .cc ? cc : scc }
}

struct EarningsFlight: Identifiable {
    let id: String
    let day: String
    let title: String
    let fingerprint: String
    let scheduledMinutes: Int?
    let ended: Bool
}

struct EarningsFlightEdit: Codable {
    var fingerprint: String
    var actualMinutes: Int?
    var role: EarningsRole = .cc
    var lineCheck = false
}

enum EarningsAdjustmentKind: String, Codable, CaseIterable, Identifiable {
    case extra, standby, reimbursement, deduction
    var id: String { rawValue }
    var label: String {
        switch self {
        case .extra: return "Extra pay / bonus"
        case .standby: return "Standby payment"
        case .reimbursement: return "Reimbursement"
        case .deduction: return "Deduction"
        }
    }
}

struct EarningsAdjustment: Codable, Identifiable {
    var id = UUID().uuidString
    var kind: EarningsAdjustmentKind
    var note: String
    var cents: Int
    var signedCents: Int { kind == .deduction ? -cents : cents }
}

struct EarningsSummary: Codable, Equatable {
    var scheduledMinutes = 0
    var confirmedMinutes = 0
    var estimatedMinutes = 0
    var flightCents = 0
    var perDiemCents = 0
    var lineCheckCents = 0
    var adjustmentCents = 0
    var reimbursementCents = 0
    var missingFlights = 0
    var reviewCount = 0
    var unconfirmedFlights = 0
    var totalCents: Int { flightCents + perDiemCents + lineCheckCents + adjustmentCents + reimbursementCents }
}

struct EarningsPayment: Codable {
    var cents: Int
    var receivedDate: Date
    var estimate: EarningsSummary
}

struct EarningsMonth: Codable {
    var rates = EarningsRates()
    var flights: [String: EarningsFlightEdit] = [:]
    var perDiemDays: Set<String> = []
    var adjustments: [EarningsAdjustment] = []
    var payment: EarningsPayment?
}

struct EarningsArchive: Codable {
    var version = 1
    var months: [String: EarningsMonth] = [:]
}

enum EarningsMath {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    static func day(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let d = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])), self.day(d) == day else { return nil }
        return d
    }
    static func monthTitle(_ month: String) -> String {
        guard let date = date(month + "-01") else { return month }
        let formatter = DateFormatter()
        formatter.calendar = utc; formatter.timeZone = utc.timeZone
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }
    static func paymentWindow(_ month: String) -> String {
        guard let first = date(month + "-01"), let next = utc.date(byAdding: .month, value: 1, to: first) else { return "Unknown payment window" }
        return "10–15 " + monthTitle(String(day(next).prefix(7)))
    }
    static func money(_ cents: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency; formatter.currencyCode = "EUR"
        return formatter.string(from: NSDecimalNumber(value: cents).dividing(by: 100)) ?? "EUR \(cents / 100)"
    }
    static func amountText(_ cents: Int) -> String { String(format: "%d.%02d", cents / 100, abs(cents % 100)) }
    static func parseAmount(_ text: String) -> Int? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard clean.range(of: "^[0-9]{1,7}(\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
              let decimal = Decimal(string: clean, locale: Locale(identifier: "en_US_POSIX")), decimal <= 1_000_000 else { return nil }
        return NSDecimalNumber(decimal: decimal * 100).intValue
    }
    static func hours(_ minutes: Int) -> String { String(format: "%d:%02d", minutes / 60, minutes % 60) }
    static func parseHours(_ text: String) -> Int? {
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0].allSatisfy(\.isNumber), pieces[1].count == 2,
              let h = Int(pieces[0]), let m = Int(pieces[1]), h >= 0, h <= 24, m >= 0, m < 60,
              h * 60 + m <= 1440 else { return nil }
        return h * 60 + m
    }
    static func hourlyPay(minutes: Int, rate: Int) -> Int {
        // Integer cents, round half-up once per rate group, never HH.MM arithmetic.
        (minutes * rate + 30) / 60
    }
    static func eligibleTripDays(start: Date, end: Date) -> [String] {
        let a = utc.startOfDay(for: start), b = utc.startOfDay(for: end)
        guard b > a, let distance = utc.dateComponents([.day], from: a, to: b).day, distance <= 366 else { return [] }
        return (0...distance).compactMap { utc.date(byAdding: .day, value: $0, to: a).map(day) }
    }
    static func summarize(month: String, flights: [EarningsFlight], record: EarningsMonth) -> EarningsSummary {
        var result = EarningsSummary()
        var minutesByRate: [Int: Int] = [:]
        var seen = Set<String>()
        for flight in flights where flight.day.hasPrefix(month + "-") && seen.insert(flight.id).inserted {
            if let minutes = flight.scheduledMinutes { result.scheduledMinutes += minutes }
            let saved = record.flights[flight.id]
            let changed = saved.map { $0.fingerprint != flight.fingerprint } ?? false
            if changed { result.reviewCount += 1 }
            let edit = changed ? nil : saved
            let actual = flight.ended ? edit?.actualMinutes : nil
            if let actual { result.confirmedMinutes += actual } else { result.unconfirmedFlights += 1 }
            if let minutes = actual ?? flight.scheduledMinutes {
                result.estimatedMinutes += minutes
                minutesByRate[record.rates.hourly(edit?.role ?? .cc), default: 0] += minutes
            } else { result.missingFlights += 1 }
            if edit?.lineCheck == true { result.lineCheckCents += record.rates.lineCheck }
        }
        result.reviewCount += record.flights.keys.filter { !seen.contains($0) }.count
        result.flightCents = minutesByRate.reduce(0) { $0 + hourlyPay(minutes: $1.value, rate: $1.key) }
        result.perDiemCents = record.perDiemDays.filter { $0.hasPrefix(month + "-") && date($0) != nil }.count * record.rates.perDiem
        for adjustment in record.adjustments {
            if adjustment.kind == .reimbursement { result.reimbursementCents += adjustment.signedCents }
            else { result.adjustmentCents += adjustment.signedCents }
        }
        return result
    }
}

final class EarningsPersistence {
    private let defaults: UserDefaults
    private let key = "RAIDORoster.Earnings.V1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() throws -> EarningsArchive {
        guard let data = defaults.data(forKey: key) else { return EarningsArchive() }
        let archive = try JSONDecoder().decode(EarningsArchive.self, from: data)
        guard archive.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return archive
    }
    func save(_ archive: EarningsArchive) throws {
        defaults.set(try JSONEncoder().encode(archive), forKey: key)
    }
}
