import Foundation

// Deterministic policy shared by the native Fleet UI and its regression checks.
// These rules assess observations; they never determine dispatchability or AOG.
enum FleetTrackingPolicy {
    enum RotationRelation: String, Equatable {
        case inbound
        case outbound
        case touches
        case unrelated
    }

    static func normalizedRegistration(_ value: String) -> String {
        value.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func validHex(_ value: String?) -> String? {
        guard let value, value.count == 6,
              value.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return value.uppercased()
    }

    static func validAirport(_ value: String) -> String? {
        let airport = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard airport.count == 3,
              airport.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return airport
    }

    static func routeAirports(_ value: String) -> (origin: String, destination: String)? {
        let parts = value.uppercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .compactMap(validAirport)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    static func rotationRelation(route: String, airport: String) -> RotationRelation {
        guard let target = validAirport(airport), let pair = routeAirports(route) else { return .unrelated }
        if pair.destination == target && pair.origin != target { return .inbound }
        if pair.origin == target && pair.destination != target { return .outbound }
        if pair.origin == target || pair.destination == target { return .touches }
        return .unrelated
    }

    static func dominantRotationAirport(routes: [String], stations: [String], preferredAirports: [String]) -> String? {
        var scores: [String: Int] = [:]
        func add(_ airport: String?, weight: Int) {
            guard let airport else { return }
            scores[airport, default: 0] += weight
        }

        for route in routes {
            guard let pair = routeAirports(route) else { continue }
            add(pair.origin, weight: 1)
            add(pair.destination, weight: 1)
        }
        for station in stations { add(validAirport(station), weight: 3) }
        for airport in preferredAirports { add(validAirport(airport), weight: 6) }

        let ranked = scores.sorted(by: {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        })
        guard let best = ranked.first, best.value >= 3,
              ranked.count == 1 || best.value > ranked[1].value else { return nil }
        return best.key
    }

    static func rotationRouteLabel(route: String, airport: String,
                                   isFresh: Bool, isAirborne: Bool) -> String? {
        let relation = rotationRelation(route: route, airport: airport)
        guard relation != .unrelated else { return nil }
        guard isFresh && isAirborne else { return "Last reported route · \(route)" }
        switch relation {
        case .inbound: return "Likely inbound \(airport) · \(route)"
        case .outbound: return "Likely outbound \(airport) · \(route)"
        case .touches: return "Possible rotation route · \(route)"
        case .unrelated: return nil
        }
    }

    static func validCoordinate(latitude: Double?, longitude: Double?) -> Bool {
        guard let latitude, let longitude else { return false }
        return latitude.isFinite && longitude.isFinite &&
            (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    static func sourceDate(epoch: Double?, receivedAt: Date) -> Date? {
        guard let epoch, epoch.isFinite else { return nil }
        // Provider wrappers differ: support epoch seconds and milliseconds.
        let seconds = epoch > 100_000_000_000 ? epoch / 1_000 : epoch
        guard seconds >= 946_684_800,
              seconds <= receivedAt.timeIntervalSince1970 + 30 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func age(referenceAt: Date, seconds: Double?, now: Date) -> TimeInterval {
        guard let seconds, seconds.isFinite, seconds >= 0,
              referenceAt.timeIntervalSince1970.isFinite,
              now.timeIntervalSince(referenceAt) >= -30 else { return .infinity }
        return max(0, now.timeIntervalSince(referenceAt)) + seconds
    }

    static func positionAge(referenceAt: Date, messageAge: Double,
                            positionAge: Double?, now: Date) -> TimeInterval {
        max(age(referenceAt: referenceAt, seconds: messageAge, now: now),
            age(referenceAt: referenceAt, seconds: positionAge, now: now))
    }

    static func retryDelay(_ header: String?, now: Date) -> TimeInterval {
        guard let header else { return 300 }
        if let seconds = Double(header), seconds.isFinite, seconds >= 0 {
            return max(60, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return 300 }
        return max(60, date.timeIntervalSince(now))
    }

    static func matches(registration: String?, hex: String?, requested: String,
                        expectedHex: String?) -> Bool {
        let expected = validHex(expectedHex)
        if let registration, !normalizedRegistration(registration).isEmpty {
            guard normalizedRegistration(registration) == normalizedRegistration(requested) else { return false }
            // A changed hex requires reconciliation, not automatic reassignment.
            return expected == nil || validHex(hex) == expected
        }
        return expected != nil && validHex(hex) == expected
    }

    static func verticalRate(previousAltitude: Double?, previousAt: Date?,
                             altitude: Double?, observedAt: Date) -> Double? {
        guard let previousAltitude, let previousAt, let altitude,
              previousAltitude.isFinite, altitude.isFinite else { return nil }
        let elapsed = observedAt.timeIntervalSince(previousAt)
        guard elapsed >= 5 && elapsed <= 180 else { return nil }
        let rate = (altitude - previousAltitude) * 60 / elapsed
        return abs(rate) <= 10_000 ? rate : nil
    }

    static func canInferTransition(previousAt: Date, currentAt: Date,
                                    previousKnown: Bool, currentKnown: Bool,
                                    previousCallsign: String?, currentCallsign: String?) -> Bool {
        let gap = currentAt.timeIntervalSince(previousAt)
        guard previousKnown, currentKnown, gap > 0, gap <= 180,
              let a = previousCallsign?.trimmingCharacters(in: .whitespacesAndNewlines),
              let b = currentCallsign?.trimmingCharacters(in: .whitespacesAndNewlines),
              !a.isEmpty, a == b else { return false }
        return true
    }
}
