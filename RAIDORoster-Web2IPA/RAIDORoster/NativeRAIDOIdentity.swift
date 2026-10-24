import Foundation

/// Read-only source normalization and independent identity matching. Every
/// occurrence is retained as provenance; no result is a persisted roster item.
enum NativeRAIDOIdentity {
    static let nonFlightCategories = ["STANDBY", "RESERVE", "OFF", "DND", "TRAINING", "VACATION", "LEAVE", "REST", "HOTEL", "EXPENSE", "RELOCATION"]
    struct Record {
        let activity: NativeRAIDOWire.Activity
        let digest: Data?
        var containerDays: Set<String>
        var occurrences: Int
    }
    struct Normalized {
        var records: [Record] = []
        var groupedCopies = false
        var conflictingIDs = false
        var repeatedWithinDay = false
        var limit = false
    }
    private struct Fingerprint: Hashable { let id: Int64; let digest: Data }
    private struct Route: Hashable { let code: String; let departure: String; let arrival: String }
    private struct DateCode: Hashable { let day: String; let code: String }
    private struct DateRoute: Hashable { let day: String; let route: Route }
    struct Match { let record: Int; let portal: Int; let monthUnique: Bool }
    struct LocalCandidate {
        let source: Record
        let category: String
        let start: String
        let end: String
    }
    struct Assessment {
        var flights = NativeRAIDOTiming.Pairing()
        var normalized = Normalized()
        var matches: [Match] = []
        var localCandidates: [LocalCandidate] = []
        var usedMonthUnique = false
        var ambiguous = false
        var unmatchedNative = false
        var unmatchedPortal = false
        var independentDayAgreement = false
        var dayUnresolved = false
        var limit = false
        var incompleteSource = false
        var nonFlightMessages: [String] = []

        var summary: String {
            if limit { return "Roster identity: Analysis limits reached; all extended mapping remains unverified. No import." }
            var source = normalized.groupedCopies
                ? "Exact copies across distinct day buckets were grouped for comparison; original occurrences retained."
                : "No cross-day exact-copy groups were established."
            if normalized.conflictingIDs { source += " Conflicting native IDs were kept separate." }
            if normalized.repeatedWithinDay { source += " Repeated records within one day were kept separate." }
            if incompleteSource { source += " Some day activity details are missing; roster coverage is unverified." }
            var identity = usedMonthUnique ? "Identities unique across the response and visible page were matched without dates or times." : "No response-unique fallback identities were established."
            if ambiguous { identity += " Ambiguous identities remain unpaired." }
            if unmatchedNative { identity += " Some native source records remain unmatched." }
            if unmatchedPortal { identity += " Some displayed portal records remain unmatched." }
            var days = independentDayAgreement
                ? "Independently paired activity dates agree with portal LT despite different container-day labels."
                : "No independent container-day correction was established."
            if dayUnresolved { days += " Some day-label differences remain unresolved." }
            let candidate = localCandidates.isEmpty
                ? "No validated local-field candidates were prepared."
                : "Validated local-field candidates were prepared for paired records; source display strings were preserved."
            return (["Source normalization: " + source, "Roster identity: " + identity, "Day assignment: " + days,
                "Local mapping: " + candidate + " No UTC conversion or canonical roster was produced."] + nonFlightMessages +
                ["Mapping scope: All visible activity categories assessed; unresolved source records retained. No import or cache write."]).joined(separator: "\n")
        }
    }

    static func normalize(_ native: NativeRAIDOWire.Decoded) -> Normalized {
        var result = Normalized(), groups: [Fingerprint: [Record]] = [:], idDigests: [Int64: Set<Data>] = [:]
        var count = 0
        for day in native.days {
            for (index, activity) in (day.day.details?.activities ?? []).enumerated() {
                count += 1
                guard count <= 6000 else { result.limit = true; result.records = []; return result }
                let digests = day.recordDigests
                let digest = digests?.count == day.day.details?.activities?.count ? digests?[index] : nil
                let record = Record(activity: activity, digest: digest, containerDays: [day.calendarDay], occurrences: 1)
                if let digest, digest.count == 32, activity.id > 0 {
                    groups[Fingerprint(id: activity.id, digest: digest), default: []].append(record)
                    idDigests[activity.id, default: []].insert(digest)
                } else { result.records.append(record) }
            }
        }
        for (key, values) in groups {
            let days = Set(values.flatMap { $0.containerDays })
            let conflict = (idDigests[key.id]?.count ?? 0) != 1
            if conflict { result.conflictingIDs = true }
            if days.count < values.count { result.repeatedWithinDay = true }
            if values.count > 1, !conflict, days.count == values.count {
                var grouped = values[0]; grouped.containerDays = days; grouped.occurrences = values.count
                result.records.append(grouped); result.groupedCopies = true
            } else { result.records.append(contentsOf: values) }
        }
        return result
    }

    private static func code(_ value: String) -> String? {
        guard value.utf8.count <= 80 else { return nil }
        let key = NativeRAIDOTiming.normalized(value)
        return key.isEmpty ? nil : key
    }
    private static func route(_ activity: NativeRAIDOWire.Activity) -> Route? {
        guard let c = code(activity.activity), let dep = NativeRAIDOTiming.airport(activity.departure),
              let arr = NativeRAIDOTiming.airport(activity.arrival) else { return nil }
        return Route(code: c, departure: dep, arrival: arr)
    }
    private static func route(_ activity: NativeRAIDOTiming.ReferenceActivity) -> Route? {
        let parts = activity.route.components(separatedBy: "→")
        guard parts.count == 2, let c = code(activity.code), let dep = NativeRAIDOTiming.airport(parts[0]),
              let arr = NativeRAIDOTiming.airport(parts[1]) else { return nil }
        return Route(code: c, departure: dep, arrival: arr)
    }
    private static func isFlight(_ activity: NativeRAIDOTiming.ReferenceActivity) -> Bool {
        ["FLIGHT", "POSITIONING"].contains(activity.category)
    }
    private static func paired(_ record: Record, _ portal: NativeRAIDOTiming.ReferenceActivity) -> NativeRAIDOTiming.Pair {
        let r = route(record.activity)
        let key = NativeRAIDOTiming.Key(day: record.containerDays.sorted().first ?? portal.day,
            code: code(record.activity.activity) ?? "", departure: r?.departure ?? "", arrival: r?.arrival ?? "")
        return NativeRAIDOTiming.Pair(key: key, native: record.activity, portal: portal,
            multipleContainerDays: record.containerDays.count != 1)
    }
    private static func localBounds(_ pair: NativeRAIDOTiming.Pair) -> Bool {
        var subset = NativeRAIDOTiming.Pairing(); subset.pairs = [pair]
        let value = NativeRAIDOTiming.compare(subset)
        return value.localOnly + value.coincident == 2 && value.utcOnly == 0 && value.different == 0 &&
            value.missing == 0 && value.precision == 0 && value.explicitZone == 0
    }

    static func assess(_ native: NativeRAIDOWire.Decoded, reference: NativeRAIDOTiming.Reference) -> Assessment {
        var result = Assessment(); result.normalized = normalize(native)
        result.incompleteSource = native.hasMissingActivityDetails
        guard !result.normalized.limit else { result.limit = true; return result }
        let records = result.normalized.records, portal = reference.allActivities
        var nc: [String: [Int]] = [:], pc: [String: [Int]] = [:], nr: [Route: [Int]] = [:], pr: [Route: [Int]] = [:]
        var nd: [DateCode: [Int]] = [:], ndr: [DateRoute: [Int]] = [:]
        for (index, record) in records.enumerated() {
            guard let c = code(record.activity.activity) else { continue }
            nc[c, default: []].append(index)
            let r = route(record.activity)
            if let r { nr[r, default: []].append(index) }
            for day in record.containerDays {
                nd[DateCode(day: day, code: c), default: []].append(index)
                if let r { ndr[DateRoute(day: day, route: r), default: []].append(index) }
            }
        }
        for (index, p) in portal.enumerated() {
            if let c = code(p.code) { pc[c, default: []].append(index) }
            if isFlight(p), let r = route(p) { pr[r, default: []].append(index) }
        }
        var usedN = Set<Int>(), usedP = Set<Int>()
        for (index, p) in portal.enumerated() {
            let candidates: [Int], opposite: [Int]
            if isFlight(p), let r = route(p) { candidates = nr[r] ?? []; opposite = pr[r] ?? [] }
            else if !isFlight(p), let c = code(p.code) { candidates = nc[c] ?? []; opposite = pc[c] ?? [] }
            else { continue }
            if candidates.count == 1, opposite.count == 1, !usedN.contains(candidates[0]) {
                usedN.insert(candidates[0]); usedP.insert(index)
                result.matches.append(Match(record: candidates[0], portal: index, monthUnique: true))
                result.usedMonthUnique = true
            }
        }
        // Compute degrees in the complete candidate graph, before removing any
        // accepted pair. Greedy removal must not make an ambiguous pair unique.
        var edges: [[Int]] = Array(repeating: [], count: portal.count), nDegree: [Int: Int] = [:], edgeCount = 0
        for (index, p) in portal.enumerated() {
            let candidates: [Int]
            if isFlight(p), let r = route(p) { candidates = ndr[DateRoute(day: p.day, route: r)] ?? [] }
            else if !isFlight(p), let c = code(p.code) { candidates = nd[DateCode(day: p.day, code: c)] ?? [] }
            else { continue }
            edgeCount += candidates.count
            guard edgeCount <= 20000 else {
                result.limit = true; result.matches = []; result.flights = .init(); return result
            }
            edges[index] = candidates
            for n in candidates { nDegree[n, default: 0] += 1 }
        }
        for (p, candidates) in edges.enumerated() where candidates.count == 1 {
            let n = candidates[0]
            if nDegree[n] == 1, !usedN.contains(n), !usedP.contains(p) {
                usedN.insert(n); usedP.insert(p); result.matches.append(Match(record: n, portal: p, monthUnique: false))
            }
        }
        result.ambiguous = edges.enumerated().contains { p, candidates in
            !usedP.contains(p) && (candidates.count > 1 || candidates.contains { (nDegree[$0] ?? 0) > 1 })
        }
        for (index, p) in portal.enumerated() where !usedP.contains(index) {
            if isFlight(p), let r = route(p), !(nr[r] ?? []).isEmpty {
                if (nr[r]?.count ?? 0) > 1 || (pr[r]?.count ?? 0) > 1 { result.ambiguous = true }
                if edges[index].isEmpty { result.dayUnresolved = true }
            }
        }
        result.unmatchedNative = usedN.count != records.count; result.unmatchedPortal = usedP.count != portal.count
        var categories: [String: NativeRAIDOTiming.Pairing] = [:]
        for match in result.matches {
            let record = records[match.record], p = portal[match.portal], pair = paired(record, p)
            if isFlight(p) { result.flights.pairs.append(pair) }
            else { categories[p.category, default: .init()].pairs.append(pair) }
            let local = localBounds(pair)
            if !record.containerDays.contains(p.day) {
                if match.monthUnique && local { result.independentDayAgreement = true }
                else { result.dayUnresolved = true }
            }
            if local, isFlight(p) || nonFlightCategories.contains(p.category) {
                result.localCandidates.append(LocalCandidate(source: record, category: p.category,
                    start: record.activity.validFrom.calendarDay + " " + String(record.activity.validFrom.rawValue.dropFirst(11).prefix(5)),
                    end: record.activity.validTo.calendarDay + " " + String(record.activity.validTo.rawValue.dropFirst(11).prefix(5))))
            }
        }
        result.flights.portalOnly = portal.enumerated().contains { isFlight($0.element) && !usedP.contains($0.offset) }
        result.flights.invalidPortalRoute = portal.contains { isFlight($0) && route($0) == nil }
        result.flights.nativeOnly = records.enumerated().contains { !usedN.contains($0.offset) && route($0.element.activity) != nil }
        result.flights.excludedNative = records.enumerated().contains { !usedN.contains($0.offset) && route($0.element.activity) == nil }
        result.flights.unpaired = result.flights.portalOnly || result.flights.nativeOnly
        result.flights.ambiguous = portal.enumerated().contains { index, p in
            guard isFlight(p), !usedP.contains(index), let r = route(p) else { return false }
            return edges[index].count > 1 || (nr[r]?.count ?? 0) > 1 || (pr[r]?.count ?? 0) > 1
        } ? 1 : 0
        for category in nonFlightCategories where portal.contains(where: { $0.category == category }) {
            let group = categories[category] ?? .init()
            var message = group.pairs.isEmpty ? "No unique native identity established." : NativeRAIDOTiming.compare(group).message
            if portal.enumerated().contains(where: { $0.element.category == category && !usedP.contains($0.offset) }) {
                message += " Some displayed records remain unmatched."
            }
            result.nonFlightMessages.append(category + ": " + message)
        }
        if portal.contains(where: { !isFlight($0) && !nonFlightCategories.contains($0.category) }) {
            result.nonFlightMessages.append("Other duties: Classification remains unverified; no policy inferred.")
        }
        return result
    }
}
