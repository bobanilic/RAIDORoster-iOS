import Foundation

private func parseNominalLocalStamp(_ value: String) -> Date? {
    // This is intentionally a nominal GMT stamp; the paired LT/UTC anchors
    // supply the offset below. Reuse the identical bounded roster parser.
    RosterTimestamp.parse(value)
}

func pickupUTCDate(for activity: RosterActivity) -> Date? {
    let pickup = activity.pickup.uppercased()
    guard let timeRange = pickup.range(of: #"\b([01]?\d|2[0-3]):[0-5]\d\b"#, options: .regularExpression) else { return nil }
    let time = String(pickup[timeRange])

    let startDate = activity.startLT.split(separator: " ").first.map(String.init) ?? ""
    guard startDate.count == 10 else { return nil }
    let year = String(startDate.prefix(4))

    var pickupDateISO = startDate
    if let dateRange = pickup.range(of: #"\b(\d{1,2})\s+(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)\b"#, options: .regularExpression) {
        let token = String(pickup[dateRange]).split(separator: " ")
        if token.count == 2, let day = Int(token[0]) {
            let months = ["JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
                          "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12]
            if let month = months[String(token[1])] {
                pickupDateISO = String(format: "%@-%02d-%02d", year, month, day)
            }
        }
    }

    guard let nominalPickup = parseNominalLocalStamp("\(pickupDateISO) \(time)") else { return nil }

    let anchorPairs = [
        (activity.checkInLT, activity.checkInUTC),
        (activity.startLT, activity.startUTC),
        (activity.endLT, activity.endUTC),
        (activity.checkOutLT, activity.checkOutUTC)
    ]

    let anchors: [(nominal: Date, actualUTC: Date)] = anchorPairs.compactMap { local, utc in
        guard let nominal = parseNominalLocalStamp(local),
              let actual = parseUTCStamp(utc) else { return nil }
        return (nominal, actual)
    }
    guard let nearest = anchors.min(by: {
        abs($0.nominal.timeIntervalSince(nominalPickup)) < abs($1.nominal.timeIntervalSince(nominalPickup))
    }) else { return nil }

    let localOffset = nearest.nominal.timeIntervalSince(nearest.actualUTC)
    return nominalPickup.addingTimeInterval(-localOffset)
}

func parseUTCStamp(_ value: String) -> Date? {
    RosterTimestamp.parse(value)
}

func durationText(_ interval: TimeInterval) -> String {
    let minutes = max(0, Int(interval / 60))
    let hours = minutes / 60
    let mins = minutes % 60
    if hours == 0 { return "\(mins)m" }
    return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
}

func relativeText(from: Date, to: Date) -> String {
    let interval = max(0, to.timeIntervalSince(from))
    return "in \(durationText(interval))"
}

func uniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { value in
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !seen.contains(key) else { return false }
        seen.insert(key)
        return true
    }
}

func compactPickupClock(_ display: String) -> String {
    let parts = display.components(separatedBy: .whitespacesAndNewlines)
    if let clock = parts.first(where: { token in
        token.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil
    }) {
        return clock
    }
    return display
}

func rosterStandbyPeriod(code: String, details: String) -> String? {
    let evidence = (code + " " + details).uppercased()
    for (period, word) in [("M", "MORNING"), ("A", "AFTERNOON"), ("N", "NIGHT")] {
        let pattern = "\\b" + word + "(?=\\b|[0-9])|\\bSTB[ _-]*" + period + "(?=\\b|[0-9])"
        if evidence.range(of: pattern, options: .regularExpression) != nil { return period }
    }
    return nil
}

func aircraftTypeLabel(_ value: String) -> String {
    let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !raw.isEmpty else { return "" }
    let compact = raw.replacingOccurrences(of: " ", with: "")

    if compact.hasPrefix("A") || compact.hasPrefix("B") { return raw }
    if ["318", "319", "320", "321", "330", "340", "350", "380"].contains(compact) {
        return "A" + compact
    }
    if compact.hasPrefix("73") || compact.hasPrefix("7M") {
        return "B" + compact
    }
    return raw
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

