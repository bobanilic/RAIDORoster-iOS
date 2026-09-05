import Foundation

// Deterministic policy shared by the native Fleet UI and its regression checks.
// These rules assess observations; they never determine dispatchability or AOG.
enum FleetTrackingPolicy {
    static func normalizedRegistration(_ value: String) -> String {
        value.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func validHex(_ value: String?) -> String? {
        guard let value, value.count == 6,
              value.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return value.uppercased()
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
