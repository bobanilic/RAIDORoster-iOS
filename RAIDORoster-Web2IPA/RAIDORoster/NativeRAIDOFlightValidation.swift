import Foundation

/// Independent evidence for the next importer gates. Compact clocks and their
/// optional signed suffixes are hypotheses tested against explicit portal dates;
/// they never select dates, time zones, or pair identities for an import.
enum NativeRAIDOFlightValidation {
    struct CompactClock: Equatable {
        let clock: String
        let signedDay: Int?

        init?(_ raw: String) {
            guard raw.utf8.count <= 7 else { return nil }
            let bytes = Array(raw.utf8)
            guard bytes.count == 4 || (6...7).contains(bytes.count),
                  bytes.prefix(4).allSatisfy({ (48...57).contains($0) }),
                  let hour = Int(raw.prefix(2)), let minute = Int(raw.dropFirst(2).prefix(2)),
                  hour < 24, minute < 60 else { return nil }
            if bytes.count == 4 { signedDay = nil }
            else {
                guard bytes[4] == 43 || bytes[4] == 45,
                      bytes.dropFirst(5).allSatisfy({ (48...57).contains($0) }),
                      let offset = Int(raw.dropFirst(4)), abs(offset) <= 31 else { return nil }
                signedDay = offset
            }
            clock = String(raw.prefix(2)) + ":" + String(raw.dropFirst(2).prefix(2))
        }
    }

    struct ClockResult: Equatable {
        var localOnly = 0
        var utcOnly = 0
        var coincident = 0
        var different = 0
        var dayDifference = 0
        var absentNative = false
        var absentPortal = false
        var unsupported = false
        var clockOnly = false
        var signedDay = false
        var ambiguousAnchor = false

        var message: String {
            var parts: [String] = []
            if different > 0 { parts.append("Some supported values differ from both portal LT and UTC.") }
            if dayDifference > 0 { parts.append("Some clocks match but the roster-day offset hypothesis differs.") }
            if localOnly > 0 && utcOnly > 0 { parts.append("Supported values show mixed LT/UTC evidence.") }
            else if localOnly > 0 { parts.append("Supported values agree with portal LT.") }
            else if utcOnly > 0 { parts.append("Supported values agree with portal UTC.") }
            if coincident > 0 { parts.append("Some LT/UTC readings are indistinguishable.") }
            if unsupported { parts.append("Unrecognized compact forms remain undecoded.") }
            if absentNative { parts.append("Some native values are absent.") }
            if absentPortal { parts.append("Some portal LT/UTC references are absent.") }
            if clockOnly { parts.append("Plain clocks do not establish calendar dates.") }
            if signedDay { parts.append("Signed suffixes were tested as roster-day offsets only; this is not an import rule.") }
            if ambiguousAnchor { parts.append("A repeated source record has no unique container-day anchor for its suffix.") }
            return parts.isEmpty ? "No comparable values were observed." : parts.joined(separator: " ")
        }
    }

    struct Assessment {
        let matching: String
        var std = ClockResult(), sta = ClockResult(), checkIn = ClockResult(), checkOut = ClockResult()
        var overnightObserved = false
        var overnight = NativeRAIDOTiming.Result()
        var orderUnknown = false
        var orderDifferent = false
        var hasPairs = false
        var orderObserved = false

        var summary: String {
            let night = overnightObserved ? overnight.message : "No paired overnight records were observed; not verified."
            var order = "Paired portal UTC event ordering is consistent."
            if orderDifferent { order = "Some paired portal UTC event ordering is inconsistent; unresolved." }
            if orderUnknown { order += " Some ordering checks lack explicit UTC fields." }
            if !orderObserved { order = "No complete portal UTC leg ordering was available." }
            if !hasPairs { order = "No paired flight records; not verified." }
            return ["Activity matching: " + matching, "STD: " + std.message, "STA: " + sta.message,
                "Check-in: " + checkIn.message, "Check-out: " + checkOut.message,
                "Overnight validity: " + night, "Portal event order: " + order,
                "Scope: Uniquely paired flights/positioning only; full roster parity and import dates remain unverified."].joined(separator: "\n")
        }
    }

    // All inputs below came through the strict Reference parser. Gregorian UTC
    // arithmetic here measures calendar-label differences; it does not interpret
    // a local timestamp as an operational absolute time or use the device zone.
    private static func dayNumber(_ day: String) -> Int? {
        guard NativeRAIDOWire.calendarDay(day) else { return nil }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let value = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return Int(value.timeIntervalSince1970 / 86400)
    }

    static func compareClock(_ raw: String?, local: String?, utc: String?, rosterDay: String?) -> ClockResult {
        var result = ClockResult()
        guard let raw, !raw.isEmpty else {
            result.absentNative = (local?.isEmpty == false || utc?.isEmpty == false)
            return result
        }
        guard let value = CompactClock(raw) else { result.unsupported = true; return result }
        guard let local, let utc, !local.isEmpty, !utc.isEmpty else { result.absentPortal = true; return result }
        // Keep this pure seam strict even when exercised outside the bridge.
        guard local.utf8.count == 16, utc.utf8.count == 16,
              local.utf8.allSatisfy({ $0 < 128 }), utc.utf8.allSatisfy({ $0 < 128 }),
              NativeRAIDOWire.calendarDay(String(local.prefix(10))), NativeRAIDOWire.calendarDay(String(utc.prefix(10))),
              PortalBridgePolicy.stamp(local), PortalBridgePolicy.stamp(utc) else { result.absentPortal = true; return result }
        let ltClock = value.clock == String(local.suffix(5)), utcClock = value.clock == String(utc.suffix(5))
        var lt = ltClock, z = utcClock
        if let offset = value.signedDay {
            result.signedDay = true
            guard let rosterDay else { result.ambiguousAnchor = true; return result }
            guard let base = dayNumber(rosterDay), let l = dayNumber(String(local.prefix(10))), let u = dayNumber(String(utc.prefix(10))) else {
                result.dayDifference = 1; return result
            }
            lt = lt && l - base == offset; z = z && u - base == offset
            if (ltClock || utcClock) && !lt && !z { result.dayDifference = 1; return result }
        } else { result.clockOnly = true }
        switch (lt, z) {
        case (true, false): result.localOnly = 1
        case (false, true): result.utcOnly = 1
        case (true, true): result.coincident = 1
        case (false, false): result.different = 1
        }
        return result
    }

    private static func merge(_ value: ClockResult, into total: inout ClockResult) {
        total.localOnly += value.localOnly; total.utcOnly += value.utcOnly; total.coincident += value.coincident
        total.different += value.different; total.dayDifference += value.dayDifference
        total.absentNative = total.absentNative || value.absentNative; total.absentPortal = total.absentPortal || value.absentPortal
        total.unsupported = total.unsupported || value.unsupported; total.clockOnly = total.clockOnly || value.clockOnly
        total.signedDay = total.signedDay || value.signedDay
        total.ambiguousAnchor = total.ambiguousAnchor || value.ambiguousAnchor
    }

    static func assess(_ pairing: NativeRAIDOTiming.Pairing) -> Assessment {
        var result = Assessment(matching: pairing.message)
        result.hasPairs = !pairing.pairs.isEmpty
        var nights = NativeRAIDOTiming.Pairing()
        if pairing.pairs.isEmpty { result.orderUnknown = true }
        for pair in pairing.pairs {
            let p = pair.portal, n = pair.native
            let day: String? = pair.multipleContainerDays ? nil : pair.key.day
            merge(compareClock(n.std, local: p.startLT, utc: p.startUTC, rosterDay: day), into: &result.std)
            merge(compareClock(n.sta, local: p.endLT, utc: p.endUTC, rosterDay: day), into: &result.sta)
            merge(compareClock(n.checkIn, local: p.checkInLT, utc: p.checkInUTC, rosterDay: day), into: &result.checkIn)
            merge(compareClock(n.checkOut, local: p.checkOutLT, utc: p.checkOutUTC, rosterDay: day), into: &result.checkOut)
            let dutyStart = p.checkInLT.flatMap { $0.isEmpty ? nil : $0 } ?? p.startLT
            let dutyEnd = p.checkOutLT.flatMap { $0.isEmpty ? nil : $0 } ?? p.endLT
            if (!p.startLT.isEmpty && !p.endLT.isEmpty && p.startLT.prefix(10) != p.endLT.prefix(10)) ||
                (!p.startUTC.isEmpty && !p.endUTC.isEmpty && p.startUTC.prefix(10) != p.endUTC.prefix(10)) ||
                (!dutyStart.isEmpty && !dutyEnd.isEmpty && dutyStart.prefix(10) != dutyEnd.prefix(10)) {
                nights.pairs.append(pair)
            }
            let ci = p.checkInUTC ?? "", co = p.checkOutUTC ?? ""
            if p.startUTC.isEmpty || p.endUTC.isEmpty { result.orderUnknown = true }
            else {
                result.orderObserved = true
                if p.endUTC < p.startUTC { result.orderDifferent = true }
            }
            // CI/CO can be duty-envelope values repeated across several sectors.
            // Verify each bounds this leg; do not require them on every sector.
            if !ci.isEmpty && !p.startUTC.isEmpty && ci > p.startUTC { result.orderDifferent = true }
            if !co.isEmpty && !p.endUTC.isEmpty && co < p.endUTC { result.orderDifferent = true }
            if ci.isEmpty || co.isEmpty { result.orderUnknown = true }
        }
        result.overnightObserved = !nights.pairs.isEmpty
        result.overnight = NativeRAIDOTiming.compare(nights)
        return result
    }
}
