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
        guard jsonMatched else { return "Native JSON changed from capture; timing comparison is inconclusive." }
        if case .unavailable(let issue) = before { return "Before request: " + issue.message + " Timing is inconclusive." }
        if case .unavailable(let issue) = after { return "After request: " + issue.message + " Timing is inconclusive." }
        guard case .ready(let first) = before, case .ready(let last) = after, first == last else {
            return "Portal timing records changed across the native request; timing comparison is inconclusive."
        }
        return compare(native, reference: last).message
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
            guard value.version == 1, value.valid, value.month == month,
                  value.sourceURL.utf8.count <= 2048, let url = URL(string: value.sourceURL),
                  PortalBridgePolicy.isPortal(url), url.path.lowercased().hasSuffix("/humanresourceroster.aspx"),
                  (1...3000).contains(value.activities.count) else { throw Failure.referenceUnavailable }
            for activity in value.activities {
                guard NativeRAIDOWire.calendarDay(activity.day), activity.day.hasPrefix(month + "-"),
                      activity.code.utf8.count <= 80, activity.category.utf8.count <= 40, activity.route.utf8.count <= 120,
                      [activity.startLT, activity.startUTC, activity.endLT, activity.endUTC].allSatisfy(NativeRAIDOTiming.validStamp) else {
                    throw Failure.referenceUnavailable
                }
            }
            // DOM order can change without a timing change. Preserve duplicates
            // so normalization cannot manufacture a unique activity identity.
            let ordered = value.activities.sorted {
                [$0.day, $0.code, $0.category, $0.route, $0.startLT, $0.startUTC, $0.endLT, $0.endUTC]
                    .lexicographicallyPrecedes([$1.day, $1.code, $1.category, $1.route, $1.startLT, $1.startUTC, $1.endLT, $1.endUTC])
            }
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

    private struct Key: Hashable { let day: String; let code: String; let departure: String; let arrival: String }
    private static func normalized(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
    private static func airport(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = normalized(value)
        guard result.utf8.count == 3, result.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return result
    }
    private static func key(day: String, activity: NativeRAIDOWire.Activity) -> Key? {
        guard let dep = airport(activity.departure), let arr = airport(activity.arrival), !normalized(activity.activity).isEmpty else { return nil }
        return Key(day: day, code: normalized(activity.activity), departure: dep, arrival: arr)
    }
    private static func key(_ activity: ReferenceActivity) -> Key? {
        guard ["FLIGHT", "POSITIONING"].contains(normalized(activity.category)), !normalized(activity.code).isEmpty else { return nil }
        let route = activity.route.components(separatedBy: "→")
        guard route.count == 2, let dep = airport(route[0]), let arr = airport(route[1]) else { return nil }
        return Key(day: activity.day, code: normalized(activity.code), departure: dep, arrival: arr)
    }

    static func compare(_ native: NativeRAIDOWire.Decoded, reference: Reference) -> Result {
        var nativeGroups: [Key: [NativeRAIDOWire.Activity]] = [:], portalGroups: [Key: [ReferenceActivity]] = [:]
        for day in native.days {
            for activity in day.day.details?.activities ?? [] {
                if let key = key(day: day.calendarDay, activity: activity) { nativeGroups[key, default: []].append(activity) }
            }
        }
        for activity in reference.activities {
            if let key = key(activity) { portalGroups[key, default: []].append(activity) }
        }
        var result = Result()
        for key in Set(nativeGroups.keys).union(portalGroups.keys) {
            let n = nativeGroups[key] ?? [], p = portalGroups[key] ?? []
            guard n.count == 1, p.count == 1 else {
                result.unpaired = true
                if n.count > 1 || p.count > 1 { result.ambiguous += 1 }
                continue
            }
            result.paired += 1
            check(n[0].validFrom, local: p[0].startLT, utc: p[0].startUTC, result: &result)
            check(n[0].validTo, local: p[0].endLT, utc: p[0].endUTC, result: &result)
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
    if (!p || p.version !== 1 || p.month !== month || p.valid !== true || !Array.isArray(p.activities)) return fail('invalid-payload');
    if (p.activities.length < 1) return fail('no-flight-records');
    if (p.activities.length > 3000) return fail('limit');
    // Project again at the bridge: unexpected extra fields never cross to Swift.
    const activities = p.activities.map(a => ({day:a.day,code:a.code,category:a.category,route:a.route,
      startLT:a.startLT,startUTC:a.startUTC,endLT:a.endLT,endUTC:a.endUTC}));
    const text = JSON.stringify({version:1,sourceURL:location.href,month:p.month,valid:true,activities});
    return new TextEncoder().encode(text).byteLength <= 1024*1024 ? text : fail('limit');
    """#
}
