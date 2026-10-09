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
    // Optional preserves decoding of payment snapshots saved before Pay Profile.
    var basicSalaryCents: Int?
    var dutyDayCents: Int?
    var missingFlights = 0
    var reviewCount = 0
    var unconfirmedFlights = 0
    var totalCents: Int {
        flightCents + perDiemCents + lineCheckCents + adjustmentCents + reimbursementCents
            + (basicSalaryCents ?? 0) + (dutyDayCents ?? 0)
    }
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
    // Optional fields preserve decoding of existing 2.20.0 records and paid comparisons.
    var homeAirport: String?
    var dailyOverrides: [String: Bool]?
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
    static func parseMonthlyBLH(_ text: String) -> Int? {
        let pieces = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0].allSatisfy(\.isNumber), pieces[1].count == 2,
              let h = Int(pieces[0]), let m = Int(pieces[1]), h >= 0, h <= 300, m >= 0, m < 60 else { return nil }
        return h * 60 + m
    }
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
    static func summarize(month: String, flights: [EarningsFlight], record: EarningsMonth, authoritativeBLHMinutes: Int? = nil, profile: EarningsPayProfile? = nil) -> EarningsSummary {
        var result = EarningsSummary()
        let active = profile ?? .legacy(rates: record.rates, homeAirport: record.homeAirport)
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
                minutesByRate[active.blockRate(edit?.role ?? active.defaultRole), default: 0] += minutes
            } else { result.missingFlights += 1 }
            if edit?.lineCheck == true { result.lineCheckCents += active.lineCheckCents }
        }
        result.reviewCount += record.flights.keys.filter { !seen.contains($0) }.count
        if let authoritativeBLHMinutes {
            // RAIDO/N-OC monthly BLH is authoritative for CC block pay. Individual sector edits
            // remain available for review/line-check metadata, but do not replace RAIDO's total.
            result.estimatedMinutes = authoritativeBLHMinutes
            result.flightCents = hourlyPay(minutes: authoritativeBLHMinutes, rate: active.blockRate(active.defaultRole))
        } else {
            result.flightCents = minutesByRate.reduce(0) { $0 + hourlyPay(minutes: $1.value, rate: $1.key) }
        }
        result.perDiemCents = record.perDiemDays.filter { $0.hasPrefix(month + "-") && date($0) != nil }.count * active.dailyAllowanceCents
        result.basicSalaryCents = EarningsPayProfileEngine.basicSalary(active)
        let flightDays = Set(flights.filter { $0.day.hasPrefix(month + "-") }.map(\.day)).count
        result.dutyDayCents = EarningsPayProfileEngine.dutySupplement(flightDays: flightDays, profile: active)
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

struct EarningsLocationEvent {
    let day: String
    let order: String
    let origin: String?
    let destination: String?
}

struct EarningsRosterDay {
    let day: String
    var categories: Set<String>
    var stations: Set<String> = []
}

struct EarningsDailyLine: Identifiable {
    var id: String { day }
    let day: String
    let category: String
    let paid: Bool
    let reason: String
    let needsReview: Bool
    let reserveOnly: Bool
}

enum EarningsDailyPolicy {
    static func airport(_ value: String) -> String? {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return key.count == 3 && key.allSatisfy { $0.isASCII && $0.isLetter } ? key : nil
    }
    static func route(_ value: String) -> (String?, String?) {
        let parts = value.uppercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count == 3 }
        guard parts.count == 2 else { return (nil, nil) }
        return (airport(parts[0]), airport(parts[1]))
    }
    static func coveredDays(fallback: String, start: Date?, end: Date?) -> [String] {
        guard let start else { return [fallback] }
        let first = EarningsMath.utc.startOfDay(for: start)
        guard let end, end > start, end.timeIntervalSince(start) <= 31 * 86_400 else { return [EarningsMath.day(start)] }
        // An end exactly at midnight belongs to the preceding interval, not another paid day.
        let last = EarningsMath.utc.startOfDay(for: end.addingTimeInterval(-1))
        let count = EarningsMath.utc.dateComponents([.day], from: first, to: last).day ?? 0
        return (0...max(0, count)).compactMap { EarningsMath.utc.date(byAdding: .day, value: $0, to: first).map(EarningsMath.day) }
    }
    static func lines(month: String, days: [EarningsRosterDay], events: [EarningsLocationEvent], record: EarningsMonth, profile: EarningsPayProfile? = nil) -> [EarningsDailyLine] {
        let active = profile ?? .legacy(rates: record.rates, homeAirport: record.homeAirport)
        let home = airport(active.homeAirport)
        let sortedEvents = events.sorted { $0.order < $1.order }
        let grouped = Dictionary(grouping: days.filter { EarningsMath.date($0.day) != nil }, by: \.day)
        let allDays = Set(grouped.keys).union(record.perDiemDays).union((record.dailyOverrides ?? [:]).keys)
        return allDays.filter { $0.hasPrefix(month + "-") && EarningsMath.date($0) != nil }.sorted().map { day in
            let rows = grouped[day] ?? []
            let categories = rows.reduce(into: Set<String>()) { $0.formUnion($1.categories.map { $0.uppercased() }) }
            let isFlight = categories.contains("FLIGHT")
            let isStandby = categories.contains("STANDBY") || categories.contains("STB")
            let isPositioning = categories.contains("POSITIONING") || categories.contains("POS")
            let direct = isFlight || isStandby || isPositioning
            let reserve = !direct && !categories.isDisjoint(with: ["RES", "RESERVE"])
            let label = isFlight ? "FLIGHT" : isStandby ? "STANDBY" : isPositioning ? "POSITIONING" : categories.sorted().joined(separator: " / ")

            if reserve {
                return EarningsDailyLine(day: day, category: "RES", paid: active.reserveDaily,
                    reason: active.reserveDaily ? "Reserve · daily payment" : "Reserve · unpaid",
                    needsReview: false, reserveOnly: true)
            }

            // Explicit crew correction is authoritative for every non-RES day.
            if let override = record.dailyOverrides?[day] {
                return EarningsDailyLine(day: day, category: label, paid: override, reason: override ? "Manually included" : "Manually excluded", needsReview: false, reserveOnly: false)
            }

            if !categories.isDisjoint(with: ["DND", "VACATION", "LEAVE", "SICK", "SICKNESS"]) {
                return EarningsDailyLine(day: day, category: label, paid: active.absenceDaily,
                    reason: active.absenceDaily ? "Absence · daily payment" : "Unpaid absence",
                    needsReview: false, reserveOnly: false)
            }

            if isStandby {
                return EarningsDailyLine(day: day, category: "STANDBY", paid: active.standbyDaily,
                    reason: active.standbyDaily ? "Standby · daily payment" : "Standby · unpaid",
                    needsReview: false, reserveOnly: false)
            }

            if isPositioning {
                return EarningsDailyLine(day: day, category: "POSITIONING", paid: active.positioningDaily,
                    reason: active.positioningDaily ? "Positioning · daily payment" : "Positioning · unpaid",
                    needsReview: false, reserveOnly: false)
            }

            // Resolve whether the crew member was at home base or away. Same-day first-origin/last-destination
            // is strongest evidence: a home-base round trip starts and finishes at home and gets no per diem.
            let sameDay = sortedEvents.filter { $0.day == day }
            let firstOrigin = sameDay.compactMap(\.origin).first
            let lastDestination = sameDay.compactMap(\.destination).last
            var location: String?
            var away: Bool?
            if let home {
                if firstOrigin == home && lastDestination == home {
                    location = home; away = false
                } else if let origin = firstOrigin, origin != home {
                    location = origin; away = true
                } else if let destination = lastDestination, destination != home {
                    location = destination; away = true
                }
            }

            if away == nil {
                let previous = sortedEvents.last { $0.day <= day && $0.destination != nil }
                let next = sortedEvents.first { $0.day >= day && $0.origin != nil }
                func nearby(_ other: String) -> Bool {
                    guard let a = EarningsMath.date(day), let b = EarningsMath.date(other) else { return false }
                    return abs(a.timeIntervalSince(b)) <= 7 * 86_400
                }
                let before = previous.flatMap { nearby($0.day) ? $0.destination : nil }
                let after = next.flatMap { nearby($0.day) ? $0.origin : nil }
                let stations = rows.reduce(into: Set<String>()) { $0.formUnion($1.stations.compactMap(airport)) }
                if let before, let after, before == after { location = before }
                else if let before, after == nil { location = before }
                else if let after, before == nil { location = after }
                else if stations.count == 1 { location = stations.first }
                if let home, let location { away = location != home }
            }

            // FLIGHT at home base earns only block-hour pay. Any flight day away from home also earns the daily payment.
            if isFlight {
                if away == true {
                    return EarningsDailyLine(day: day, category: "FLIGHT", paid: active.flightAwayDaily, reason: active.flightAwayDaily ? "Flight duty away from home · \(location ?? "away")" : "Away flight · daily payment disabled", needsReview: false, reserveOnly: false)
                }
                if away == false {
                    return EarningsDailyLine(day: day, category: "FLIGHT", paid: active.flightHomeDaily, reason: active.flightHomeDaily ? "Home-base flight · daily payment" : "Home-base flight duty · BLH only", needsReview: false, reserveOnly: false)
                }
                if record.perDiemDays.contains(day) {
                    return EarningsDailyLine(day: day, category: "FLIGHT", paid: active.flightAwayDaily, reason: active.flightAwayDaily ? "Confirmed away duty date" : "Away flight · daily payment disabled", needsReview: false, reserveOnly: false)
                }
                return EarningsDailyLine(day: day, category: "FLIGHT", paid: false, reason: "Duty location unclear · review", needsReview: true, reserveOnly: false)
            }

            // OFF/other non-absence days receive per diem whenever the crew member remains outside home base.
            if away == true {
                return EarningsDailyLine(day: day, category: label, paid: active.offAwayDaily, reason: active.offAwayDaily ? "Away from home · \(location ?? "away")" : "Away day · daily payment disabled", needsReview: false, reserveOnly: false)
            }
            if away == false {
                return EarningsDailyLine(day: day, category: label, paid: false, reason: "At home · \(home ?? "home") · unpaid", needsReview: false, reserveOnly: false)
            }
            if record.perDiemDays.contains(day) {
                return EarningsDailyLine(day: day, category: label, paid: active.offAwayDaily, reason: active.offAwayDaily ? "Confirmed away date" : "Away day · daily payment disabled", needsReview: false, reserveOnly: false)
            }
            return EarningsDailyLine(day: day, category: label, paid: false, reason: "Location unclear · review", needsReview: true, reserveOnly: false)
        }
    }
    static func recordForCalculation(_ record: EarningsMonth, lines: [EarningsDailyLine], profile: EarningsPayProfile? = nil) -> EarningsMonth {
        var result = record
        let active = profile ?? .legacy(rates: record.rates, homeAirport: record.homeAirport)
        result.rates = EarningsRates(cc: active.ccBlockRateCents, scc: active.sccBlockRateCents,
                                     perDiem: active.dailyAllowanceCents, lineCheck: active.lineCheckCents)
        result.homeAirport = active.homeAirport
        result.perDiemDays = Set(lines.filter(\.paid).map(\.day))
        if lines.contains(where: { $0.category == "STANDBY" && $0.paid }) {
            result.adjustments.removeAll { $0.kind == .standby }
        }
        return result
    }
}
