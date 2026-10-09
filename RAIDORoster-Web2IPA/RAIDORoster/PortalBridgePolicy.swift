import Foundation
import CoreFoundation

/// Shared by native navigation and message validation. Never trusts page-provided validity.
enum PortalBridgePolicy {
    static let schemaVersion = 1
    static let portalHost = "gjt.noc.vmc.navblue.cloud"
    static let maximumBytes = 4 * 1024 * 1024
    enum Navigation: Equatable { case portal, external, blocked }
    enum Rejection: String, Error { case format, schema, size, origin, date, fields }

    static func isPortal(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == portalHost &&
        (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }
    static func acceptsOrigin(scheme: String, host: String, port: Int, mainFrame: Bool) -> Bool {
        mainFrame && scheme.lowercased() == "https" && host.lowercased() == portalHost && (port == 0 || port == 443)
    }
    static func navigation(_ url: URL, userTapped: Bool, popup: Bool) -> Navigation {
        if isPortal(url), !popup { return .portal }
        guard userTapped, let scheme = url.scheme?.lowercased(), url.user == nil, url.password == nil else { return .blocked }
        if scheme == "https", let host = url.host, !host.isEmpty { return .external }
        if ["mailto", "tel"].contains(scheme), !url.absoluteString.dropFirst(scheme.count + 1).isEmpty { return .external }
        return .blocked
    }
    static func day(_ value: String) -> Bool {
        guard value.range(of: #"^20\d{2}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return false }
        return calendar.component(.year, from: date) == parts[0] && calendar.component(.month, from: date) == parts[1] && calendar.component(.day, from: date) == parts[2]
    }
    static func stamp(_ value: String) -> Bool {
        if value.isEmpty { return true }
        guard value.count == 16, day(String(value.prefix(10))) else { return false }
        let clock = String(value.suffix(5))
        return value[value.index(value.startIndex, offsetBy: 10)] == " " && clock.range(of: #"^(?:[01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil
    }
    private static func envelope(_ body: Any) throws -> [String: Any] {
        guard let payload = body as? [String: Any] else { throw Rejection.format }
        guard let number = payload["schemaVersion"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(schemaVersion) else { throw Rejection.schema }
        // Bound structure before serializing, including arbitrary nested extra fields.
        var values: [(Any, Int)] = [(payload, 0)], nodes = 0
        while let (value, depth) = values.popLast() {
            nodes += 1; guard nodes <= 100_000, depth <= 12 else { throw Rejection.size }
            if let string = value as? String { guard string.utf8.count <= 128_000 else { throw Rejection.size } }
            else if let array = value as? [Any] { guard array.count <= 5_000 else { throw Rejection.size }; values.append(contentsOf: array.map { ($0, depth + 1) }) }
            else if let object = value as? [String: Any] { guard object.count <= 100 else { throw Rejection.size }; values.append(contentsOf: object.values.map { ($0, depth + 1) }) }
        }
        guard JSONSerialization.isValidJSONObject(payload) else { throw Rejection.format }
        guard try JSONSerialization.data(withJSONObject: payload).count <= maximumBytes else { throw Rejection.size }
        return payload
    }
    private static func strings(_ object: [String: Any], limits: [String: Int]) throws {
        for (key, maximum) in limits {
            if let value = object[key] {
                guard let text = value as? String, text.utf8.count <= maximum else { throw Rejection.fields }
            }
        }
    }
    private static func activity(_ value: [String: Any]) throws {
        try strings(value, limits: ["id": 512, "code": 80, "category": 40, "title": 1_000, "route": 120,
            "station": 20, "aircraftReg": 30, "aircraftType": 40, "aircraftVersion": 120, "aircraftPhone": 120,
            "hotelName": 1_000, "pickup": 1_000, "description": 65_536, "rawText": 128_000,
            "transferNote": 65_536, "activityNote": 65_536, "dayNote": 65_536])
        guard !(value["title"] as? String ?? "").isEmpty || !(value["code"] as? String ?? "").isEmpty else { throw Rejection.fields }
        for key in ["checkInLT", "checkInUTC", "startLT", "startUTC", "endLT", "endUTC", "checkOutLT", "checkOutUTC"] {
            if let raw = value[key] { guard let text = raw as? String, stamp(text) else { throw Rejection.date } }
        }
        if let raw = value["crew"] {
            guard let crew = raw as? [[String: Any]], crew.count <= 100 else { throw Rejection.fields }
            for member in crew { try strings(member, limits: ["role": 40, "code": 40, "name": 500, "country": 100, "phone": 120]) }
        }
    }
    static func snapshot(_ body: Any, allowSparse: Bool = false) throws -> [String: Any] {
        let payload = try envelope(body)
        guard let source = payload["sourceURL"] as? String, let url = URL(string: source), isPortal(url),
              url.path.lowercased().hasSuffix("/humanresourceroster.aspx") else { throw Rejection.origin }
        if payload["error"] != nil { throw Rejection.format }
        try strings(payload, limits: ["pageTitle": 1_000, "monthlyBLH": 20])
        guard let rows = payload["rows"] as? [[String: Any]], ((allowSparse ? 1 : 5)...400).contains(rows.count),
              let validation = payload["validation"] as? [String: Any],
              let month = validation["month"] as? String,
              month.range(of: #"^20\d{2}-(?:0[1-9]|1[0-2])$"#, options: .regularExpression) != nil,
              validation["datedRows"] as? Int == rows.count else { throw Rejection.format }
        try strings(validation, limits: ["parser": 100, "message": 1_000])
        var ids = Set<String>()
        for row in rows {
            guard let date = row["dateISO"] as? String, day(date),
                  let id = row["id"] as? String, !id.isEmpty, ids.insert(id).inserted,
                  let rawText = row["rawText"] as? String, !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Rejection.date }
            try strings(row, limits: ["id": 512, "dateText": 100, "category": 40, "title": 1_000,
                "route": 120, "timeText": 500, "rawText": 128_000])
            for key in ["activities", "activeHotels"] {
                if let raw = row[key], !(raw is NSNull) {
                    guard let values = raw as? [[String: Any]], values.count <= 100 else { throw Rejection.fields }
                    for value in values { try activity(value) }
                }
            }
            if let raw = row["cells"] {
                guard let cells = raw as? [String], cells.count <= 128, cells.allSatisfy({ $0.utf8.count <= 65_536 }) else { throw Rejection.fields }
            }
        }
        // A page boolean is corroboration only, after independent native checks.
        guard validation["isValid"] as? Bool == true else { throw Rejection.format }
        return payload
    }
    static func calendarFeed(_ body: Any) throws -> [String: Any] {
        let payload = try envelope(body)
        guard payload["source"] as? String == "n-oc-webcal", let events = payload["events"] as? [[String: Any]],
              (1...3_000).contains(events.count) else { throw Rejection.format }
        for event in events {
            guard let date = event["dateISO"] as? String, day(date) else { throw Rejection.date }
            try strings(event, limits: ["uid": 1_000, "summary": 2_000, "description": 65_536, "startLocal": 5, "endLocal": 5])
            for key in ["startUTC", "endUTC"] {
                guard let value = event[key] as? String, !value.isEmpty, stamp(value) else { throw Rejection.date }
            }
            for key in ["startLocal", "endLocal"] {
                if let value = event[key] as? String, !value.isEmpty,
                   value.range(of: #"^(?:[01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) == nil { throw Rejection.date }
            }
        }
        return payload
    }
}
