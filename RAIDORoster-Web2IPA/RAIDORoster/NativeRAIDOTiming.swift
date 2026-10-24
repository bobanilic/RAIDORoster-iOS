import Foundation

/// Read-only, minute-level evidence. No result selects a time-zone policy or
/// creates domain roster activities. Native validity bounds keep their API names.
enum NativeRAIDOTiming {
    enum Failure: Error { case referenceUnavailable }

    enum ReferenceIssue: String, CaseIterable, Sendable {
        case pageUnavailable = "page-unavailable"
        case extractorUnavailable = "extractor-unavailable"
        case auth, loading, mismatch, format, limit
        case noFlightRecords = "no-flight-records"
        case scriptFailure = "script-failure"
        case invalidPayload = "invalid-payload"
        case pageChanged = "page-changed"

        var message: String {
            switch self {
            case .pageUnavailable: return "Live RAIDO is not on a supported roster page."
            case .extractorUnavailable: return "The portal timing inspector is unavailable; refresh Live RAIDO."
            case .auth: return "The live portal requires sign-in."
            case .loading: return "The live portal remained busy during the bounded readiness check."
            case .mismatch: return "The displayed portal month differs from the captured request."
            case .format: return "The portal's displayed month or activity layout was not recognized."
            case .limit: return "The live timing reference exceeds the supported limits."
            case .noFlightRecords: return "No flight/positioning records were parsed in the displayed month."
            case .scriptFailure: return "The read-only portal timing script could not complete."
            case .invalidPayload: return "The portal timing reference failed field or format validation."
            case .pageChanged: return "The portal page changed during timing inspection."
            }
        }
    }

    enum Observation: Equatable, Sendable {
        case ready(Reference)
        case unavailable(ReferenceIssue)

        static func parse(_ data: Data, month: String) -> Self {
            do {
                guard data.count <= 1024 * 1024 else { return .unavailable(.limit) }
                let object = try NativeRAIDOContract.boundedJSON(data)
                if let object = object as? [String: Any], let raw = object["issue"] as? String {
                    return .unavailable(ReferenceIssue(rawValue: raw) ?? .invalidPayload)
                }
                return .ready(try Reference.parse(data, month: month))
            } catch { return .unavailable(.invalidPayload) }
        }
    }

    static func message(_ native: NativeRAIDOWire.Decoded, before: Observation, after: Observation, jsonMatched: Bool) -> String {
        assessment(native, before: before, after: after, jsonMatched: jsonMatched).timing
    }

    struct Assessment: Sendable {
        let timing: String
        let fields: String
        static func unavailable(_ reason: String) -> Self {
            Self(timing: reason, fields: "Flight field checks: A stable matched native/portal comparison is required; nothing imported.")
        }
    }

    static func assessment(_ native: NativeRAIDOWire.Decoded, before: Observation, after: Observation, jsonMatched: Bool) -> Assessment {
        guard jsonMatched else { return .unavailable("Native JSON changed from capture; timing comparison is inconclusive.") }
        if case .unavailable(let issue) = before { return .unavailable("Before request: " + issue.message + " Timing is inconclusive.") }
        if case .unavailable(let issue) = after { return .unavailable("After request: " + issue.message + " Timing is inconclusive.") }
        guard case .ready(let first) = before, case .ready(let last) = after, first == last else {
            return .unavailable("Portal timing records changed across the native request; timing comparison is inconclusive.")
        }
        let pairing = pair(native, reference: last)
        return Assessment(timing: compare(pairing).message, fields: NativeRAIDOFlightValidation.assess(pairing).summary)
    }

    struct ReferenceActivity: Decodable, Equatable, Sendable {
        let day: String
        let code: String
        let category: String
        let route: String
        let startLT: String
        let startUTC: String
        let endLT: String
        let endUTC: String
        let checkInLT: String?
        let checkInUTC: String?
        let checkOutLT: String?
        let checkOutUTC: String?

        var orderingFields: [String] {
            [day, code, category, route, startLT, startUTC, endLT, endUTC,
             checkInLT ?? "", checkInUTC ?? "", checkOutLT ?? "", checkOutUTC ?? ""]
        }
    }

    struct Reference: Decodable, Equatable, Sendable {
        let version: Int
        let sourceURL: String
        let month: String
        let valid: Bool
        let activities: [ReferenceActivity]

        static func parse(_ data: Data, month: String) throws -> Self {
            guard data.count <= 1024 * 1024 else { throw Failure.referenceUnavailable }
            _ = try NativeRAIDOContract.boundedJSON(data)
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard (1...2).contains(value.version), value.valid, value.month == month,
                  value.sourceURL.utf8.count <= 2048, let url = URL(string: value.sourceURL),
                  PortalBridgePolicy.isPortal(url), url.path.lowercased().hasSuffix("/humanresourceroster.aspx"),
                  (1...3000).contains(value.activities.count) else { throw Failure.referenceUnavailable }
            for activity in value.activities {
                guard NativeRAIDOWire.calendarDay(activity.day), activity.day.hasPrefix(month + "-"),
                      activity.code.utf8.count <= 80, activity.category.utf8.count <= 40, activity.route.utf8.count <= 120,
                      [activity.startLT, activity.startUTC, activity.endLT, activity.endUTC].allSatisfy(NativeRAIDOTiming.validStamp) else {
                    throw Failure.referenceUnavailable
                }
                let duty = [activity.checkInLT, activity.checkInUTC, activity.checkOutLT, activity.checkOutUTC]
                guard duty.allSatisfy({ $0.map(NativeRAIDOTiming.validStamp) ?? (value.version == 1) }) else {
                    throw Failure.referenceUnavailable
                }
            }
            // DOM order can change without a timing change. Preserve duplicates
            // so normalization cannot manufacture a unique activity identity.
            let ordered = value.activities.sorted { $0.orderingFields.lexicographicallyPrecedes($1.orderingFields) }
            return Self(version: value.version, sourceURL: value.sourceURL, month: value.month, valid: value.valid, activities: ordered)
        }
    }

    private static func validStamp(_ value: String) -> Bool {
        if value.isEmpty { return true }
        guard value.utf8.count == 16, value.utf8.allSatisfy({ $0 < 128 }),
              NativeRAIDOWire.calendarDay(String(value.prefix(10))) else { return false }
        return PortalBridgePolicy.stamp(value)
    }

    struct Result: Equatable, Sendable {
        var paired = 0
        var ambiguous = 0
        var unpaired = false
        var localOnly = 0
        var utcOnly = 0
        var coincident = 0
        var different = 0
        var missing = 0
        var precision = 0
        var explicitZone = 0

        var message: String {
            if paired == 0 { return "No uniquely paired flight/positioning records; timing basis is undetermined." }
            if explicitZone > 0 { return "Paired timestamps have explicit zones requiring separate normalization; inconclusive." }
            if precision > 0 { return "Native timestamp precision exceeds the portal's minute precision; inconclusive." }
            if missing > 0 { return "Paired portal records lack required LT/UTC timings; inconclusive." }
            if different > 0 { return "Paired validity fields differ from portal start/end minutes; semantics remain unresolved." }
            if localOnly > 0 && utcOnly > 0 { return "Paired fields show mixed LT/UTC evidence; semantics remain unresolved." }
            let coverage = unpaired || ambiguous > 0 ? " Other records are unpaired or ambiguous." : ""
            if utcOnly > 0 { return "Unambiguous paired validity fields agree with portal UTC minutes." + coverage + " Evidence only; no import." }
            if localOnly > 0 { return "Unambiguous paired validity fields agree with portal LT minutes." + coverage + " Evidence only; no import." }
            return "Portal LT and UTC coincide in the paired fields; timing basis is indistinguishable."
        }
    }

    struct Key: Hashable { let day: String; let code: String; let departure: String; let arrival: String }
    struct Pair { let key: Key; let native: NativeRAIDOWire.Activity; let portal: ReferenceActivity }
    struct Pairing {
        var pairs: [Pair] = []
        var ambiguous = 0
        var unpaired = false
        var nativeOnly = false
        var portalOnly = false
        var routeDifference = false
        var dayDifference = false
        var excludedNative = false
        var invalidPortalRoute = false

        var message: String {
            var reasons: [String] = []
            if ambiguous > 0 { reasons.append("Repeated flight identities were skipped.") }
            if routeDifference { reasons.append("Some same-day activity codes have different routes.") }
            if dayDifference { reasons.append("Some activity/route identities have different roster-day labels.") }
            if nativeOnly { reasons.append("Some native routed records have no portal flight counterpart.") }
            if portalOnly { reasons.append("Some portal flights have no native counterpart.") }
            if invalidPortalRoute { reasons.append("Some portal flight routes are unsupported.") }
            if excludedNative { reasons.append("Native records without a usable code/route identity are outside this flight-only check.") }
            if reasons.isEmpty { reasons.append(pairs.isEmpty ? "No flight identities were paired." : "All routed identities in this check paired uniquely.") }
            return reasons.joined(separator: " ")
        }
    }
    private struct DayCode: Hashable { let day: String; let code: String }
    private struct CodeRoute: Hashable { let code: String; let departure: String; let arrival: String }
    // Match the existing HTML parser's whitespace compaction. Preserve token
    // boundaries: "AB 123" must never be guessed to mean "AB123".
    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").uppercased()
    }
    private static func airport(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 32 else { return nil }
        let result = normalized(value)
        guard result.utf8.count == 3, result.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return result
    }
    private static func key(day: String, activity: NativeRAIDOWire.Activity) -> Key? {
        guard activity.activity.utf8.count <= 80, let dep = airport(activity.departure), let arr = airport(activity.arrival),
              !normalized(activity.activity).isEmpty else { return nil }
        return Key(day: day, code: normalized(activity.activity), departure: dep, arrival: arr)
    }
    private static func key(_ activity: ReferenceActivity) -> Key? {
        guard ["FLIGHT", "POSITIONING"].contains(normalized(activity.category)), !normalized(activity.code).isEmpty else { return nil }
        let route = activity.route.components(separatedBy: "→")
        guard route.count == 2, let dep = airport(route[0]), let arr = airport(route[1]) else { return nil }
        return Key(day: activity.day, code: normalized(activity.code), departure: dep, arrival: arr)
    }

    static func compare(_ native: NativeRAIDOWire.Decoded, reference: Reference) -> Result {
        compare(pair(native, reference: reference))
    }

    static func pair(_ native: NativeRAIDOWire.Decoded, reference: Reference) -> Pairing {
        var nativeGroups: [Key: [NativeRAIDOWire.Activity]] = [:], portalGroups: [Key: [ReferenceActivity]] = [:]
        var result = Pairing()
        for day in native.days {
            for activity in day.day.details?.activities ?? [] {
                if let key = key(day: day.calendarDay, activity: activity) { nativeGroups[key, default: []].append(activity) }
                else { result.excludedNative = true }
            }
        }
        for activity in reference.activities {
            if let key = key(activity) { portalGroups[key, default: []].append(activity) }
            else if ["FLIGHT", "POSITIONING"].contains(normalized(activity.category)) {
                result.invalidPortalRoute = true; result.unpaired = true
            }
        }
        let nDay = Set(nativeGroups.keys.map { DayCode(day: $0.day, code: $0.code) })
        let pDay = Set(portalGroups.keys.map { DayCode(day: $0.day, code: $0.code) })
        let nRoute = Set(nativeGroups.keys.map { CodeRoute(code: $0.code, departure: $0.departure, arrival: $0.arrival) })
        let pRoute = Set(portalGroups.keys.map { CodeRoute(code: $0.code, departure: $0.departure, arrival: $0.arrival) })
        for key in Set(nativeGroups.keys).union(portalGroups.keys) {
            let n = nativeGroups[key] ?? [], p = portalGroups[key] ?? []
            guard n.count == 1, p.count == 1 else {
                result.unpaired = true
                if n.count > 1 || p.count > 1 { result.ambiguous += 1 }
                if !n.isEmpty && !p.isEmpty { continue }
                let otherDay = n.isEmpty ? nDay : pDay, otherRoute = n.isEmpty ? nRoute : pRoute
                let route = otherDay.contains(DayCode(day: key.day, code: key.code))
                let day = otherRoute.contains(CodeRoute(code: key.code, departure: key.departure, arrival: key.arrival))
                if route { result.routeDifference = true }
                if day { result.dayDifference = true }
                if !route && !day {
                    if p.isEmpty { result.nativeOnly = true }
                    if n.isEmpty { result.portalOnly = true }
                }
                continue
            }
            result.pairs.append(Pair(key: key, native: n[0], portal: p[0]))
        }
        return result
    }

    static func compare(_ pairing: Pairing) -> Result {
        var result = Result()
        result.paired = pairing.pairs.count; result.unpaired = pairing.unpaired; result.ambiguous = pairing.ambiguous
        for pair in pairing.pairs {
            check(pair.native.validFrom, local: pair.portal.startLT, utc: pair.portal.startUTC, result: &result)
            check(pair.native.validTo, local: pair.portal.endLT, utc: pair.portal.endUTC, result: &result)
        }
        return result
    }

    private static func check(_ timestamp: NativeRAIDOWire.Timestamp, local: String, utc: String, result: inout Result) {
        guard timestamp.zoneSuffix == nil else { result.explicitZone += 1; return }
        let seconds = timestamp.rawValue.dropFirst(17).prefix(2)
        let fraction = timestamp.rawValue.dropFirst(19).filter { $0 != "." }
        guard seconds == "00", fraction.allSatisfy({ $0 == "0" }) else { result.precision += 1; return }
        guard !local.isEmpty, !utc.isEmpty else { result.missing += 1; return }
        let minute = timestamp.calendarDay + " " + String(timestamp.rawValue.dropFirst(11).prefix(5))
        switch (minute == local, minute == utc) {
        case (true, false): result.localOnly += 1
        case (false, true): result.utcOnly += 1
        case (true, true): result.coincident += 1
        case (false, false): result.different += 1
        }
    }

    // Calls the dedicated read-only inspector; never extractNow(), post(), or
    // history.inspect/navigate/discover(). Failures expose fixed codes only.
    static let referenceScript = #"""
    const fail = issue => JSON.stringify({issue});
    if (window !== top || location.protocol !== 'https:' || location.hostname !== 'gjt.noc.vmc.navblue.cloud' ||
        (location.port && location.port !== '443') || !/\/HumanResourceRoster\.aspx$/i.test(location.pathname)) return fail('page-unavailable');
    const inspector = window.RAIDOPlus?.history?.timingReference;
    if (typeof inspector !== 'function') return fail('extractor-unavailable');
    let r;
    try { r = inspector(month); } catch (_) { return fail('script-failure'); }
    if (!r || r.kind !== 'ready') {
      const allowed = ['auth','loading','mismatch','format','limit','no-flight-records'];
      return fail(allowed.includes(r?.kind) ? r.kind : 'invalid-payload');
    }
    const p = r.payload;
    if (!p || p.version !== 2 || p.month !== month || p.valid !== true || !Array.isArray(p.activities)) return fail('invalid-payload');
    if (p.activities.length < 1) return fail('no-flight-records');
    if (p.activities.length > 3000) return fail('limit');
    const fields = ['day','code','category','route','startLT','startUTC','endLT','endUTC','checkInLT','checkInUTC','checkOutLT','checkOutUTC'];
    if (p.activities.some(a => !a || fields.some(key => typeof a[key] !== 'string'))) return fail('invalid-payload');
    // Project again at the bridge: unexpected extra fields never cross to Swift.
    const activities = p.activities.map(a => ({day:a.day,code:a.code,category:a.category,route:a.route,
      startLT:a.startLT,startUTC:a.startUTC,endLT:a.endLT,endUTC:a.endUTC,
      checkInLT:a.checkInLT,checkInUTC:a.checkInUTC,checkOutLT:a.checkOutLT,checkOutUTC:a.checkOutUTC}));
    const text = JSON.stringify({version:2,sourceURL:location.href,month:p.month,valid:true,activities});
    return new TextEncoder().encode(text).byteLength <= 1024*1024 ? text : fail('limit');
    """#
}
