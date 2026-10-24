import Foundation

/// The observed GetRoster wire structure only. These types do not produce a
/// RosterSnapshot, infer duty classifications, or write imported data.
enum NativeRAIDOWire {
    enum Failure: Error, Equatable {
        case malformed, identityMismatch, monthMismatch, emptyRoster, invalidDay, duplicateDay
    }

    private static func calendarDay(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes.enumerated().allSatisfy({ index, byte in
            index == 4 || index == 7 ? byte == 45 : (48...57).contains(byte)
        }) else { return false }
        return PortalBridgePolicy.day(value)
    }

    /// A calendar timestamp, kept verbatim. No Date conversion or device-timezone
    /// fallback is available: a timestamp without a zone is not an absolute time.
    struct Timestamp: Decodable, Equatable, Sendable {
        let rawValue: String
        let calendarDay: String
        let zoneSuffix: String?

        init(_ raw: String) throws {
            let pattern = #"^20\d{2}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,9})?(Z|[+-](?:0\d|1[0-4]):?[0-5]\d)?$"#
            guard raw.utf8.count <= 80, raw.utf8.allSatisfy({ $0 < 128 }),
                  let match = raw.range(of: pattern, options: .regularExpression),
                  match.lowerBound == raw.startIndex, match.upperBound == raw.endIndex,
                  NativeRAIDOWire.calendarDay(String(raw.prefix(10))) else { throw Failure.malformed }
            let tail = String(raw.dropFirst(19))
            let zone: String?
            if raw.hasSuffix("Z") { zone = "Z" }
            else if let index = tail.firstIndex(where: { $0 == "+" || $0 == "-" }) {
                let value = String(tail[index...]), digits = value.dropFirst().filter { $0 != ":" }
                guard let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)),
                      hours * 60 + minutes <= 14 * 60 else { throw Failure.malformed }
                zone = value
            } else { zone = nil }
            rawValue = raw; calendarDay = String(raw.prefix(10)); zoneSuffix = zone
        }

        init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    }

    struct Note: Decodable, Equatable, Sendable {
        let text: String
        let textColor: String?
        let backgroundColor: String?
        enum CodingKeys: String, CodingKey { case text = "Note", textColor = "TextColor", backgroundColor = "BackgroundColor" }
    }

    indirect enum DetailValue: Decodable, Equatable, Sendable {
        case absent, text(String), record(Detail)
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .absent }
            else if let value = try? container.decode(String.self) { self = .text(value) }
            else { self = .record(try container.decode(Detail.self)) }
        }
    }

    struct Detail: Decodable, Equatable, Sendable {
        let id: String?
        let label: String?
        let color: String?
        let value: DetailValue?
        let values: [Detail]?
        enum CodingKeys: String, CodingKey { case id = "Id", label = "Label", color = "Color", value = "Value", values = "Values" }
    }

    struct Activity: Decodable, Equatable, Sendable {
        let id: Int64
        let activity: String
        let departure: String?
        let arrival: String?
        let std: String?
        let sta: String?
        let checkIn: String?
        let checkOut: String?
        let validFrom: Timestamp
        let validTo: Timestamp
        let details: [Detail]?
        // JumpSeatInfo contains person records, but is not assumed to be the
        // operating-crew list. Unidentified fields remain outside this decoder.
        enum CodingKeys: String, CodingKey {
            case id = "Id", activity = "Activity", departure = "Dep", arrival = "Arr", std = "STD", sta = "STA"
            case checkIn = "CheckIn", checkOut = "CheckOut", validFrom = "ValidFrom", validTo = "ValidTo", details = "Details"
        }
    }

    struct DayDetails: Decodable, Equatable, Sendable {
        let activities: [Activity]?
        enum CodingKeys: String, CodingKey { case activities = "ActivityDetails" }
    }

    struct Day: Decodable, Equatable, Sendable {
        let details: DayDetails?
        let notes: [Note]?
        enum CodingKeys: String, CodingKey { case details = "Details", notes = "Notes" }
    }

    struct Entry: Equatable, Sendable {
        let calendarDay: String
        let day: Day
    }

    struct Decoded: Equatable, Sendable {
        let responseDate: Timestamp
        let days: [Entry]
        var hasUnspecifiedActivityZone: Bool {
            days.contains { $0.day.details?.activities?.contains { $0.validFrom.zoneSuffix == nil || $0.validTo.zoneSuffix == nil } == true }
        }
        var hasMissingActivityDetails: Bool { days.contains { $0.day.details?.activities == nil } }
    }

    private struct Root: Decodable { let d: Payload }
    private struct Payload: Decodable {
        let date: Timestamp
        let hrId: Int64
        let username: String
        let roster: Month
        enum CodingKeys: String, CodingKey { case date = "Date", hrId = "HrId", username = "Username", roster = "Roster" }
    }
    private struct Month: Decodable {
        let days: [String: Day]
        enum CodingKeys: String, CodingKey { case days = "Days" }
    }
    private struct Request: Decodable {
        let hrId: Identity
    }
    private enum Identity: Decodable {
        case decimal(String)
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int64.self), value > 0 { self = .decimal(String(value)) }
            else {
                let value = try container.decode(String.self)
                guard !value.isEmpty, value.utf8.count <= 20, value.utf8.allSatisfy({ (48...57).contains($0) }) else { throw Failure.malformed }
                let normalized = String(value.drop(while: { $0 == "0" }))
                guard !normalized.isEmpty else { throw Failure.malformed }
                self = .decimal(normalized)
            }
        }
        var value: String { switch self { case .decimal(let value): return value } }
    }

    static func decode(_ data: Data, for contract: NativeRAIDOContract) throws -> Decoded {
        // Check size/depth/node limits before JSONDecoder traverses the data.
        _ = try NativeRAIDOContract.boundedJSON(data)
        let payload: Payload, request: Request
        do {
            payload = try JSONDecoder().decode(Root.self, from: data).d
            request = try JSONDecoder().decode(Request.self, from: contract.body)
        } catch { throw Failure.malformed }
        guard payload.hrId > 0, String(payload.hrId) == request.hrId.value else { throw Failure.identityMismatch }
        guard !payload.roster.days.isEmpty else { throw Failure.emptyRoster }
        guard payload.roster.days.count <= 62 else { throw Failure.malformed }
        var entries: [Entry] = [], seen = Set<String>()
        for key in payload.roster.days.keys.sorted() {
            let day: String
            if calendarDay(key) { day = key }
            else if let stamp = try? Timestamp(key) { day = stamp.calendarDay }
            else { throw Failure.invalidDay }
            guard day.hasPrefix(contract.month + "-") else { throw Failure.monthMismatch }
            guard seen.insert(day).inserted else { throw Failure.duplicateDay }
            entries.append(Entry(calendarDay: day, day: payload.roster.days[key]!))
        }
        return Decoded(responseDate: payload.date, days: entries)
    }

    /// Fixed messages only; neither thrown errors nor private field values are
    /// copied into diagnostics. The decoded model is discarded after assessment.
    static func assessment(_ data: Data, for contract: NativeRAIDOContract) -> String {
        do {
            let decoded = try decode(data, for: contract)
            if decoded.hasMissingActivityDetails { return "Partial wire structure: some days lack activity details. Nothing imported." }
            if decoded.hasUnspecifiedActivityZone { return "Known wire fields decoded. Activity timestamp zones are unspecified; nothing imported." }
            return "Known wire fields decoded. Operational mapping and time semantics remain unverified; nothing imported."
        } catch Failure.identityMismatch { return "Wire response HR identity differs from the request; rejected." }
        catch Failure.monthMismatch { return "Wire response includes another month; rejected." }
        catch Failure.emptyRoster { return "Wire response has no day records; not treated as an empty imported roster." }
        catch { return "Wire structure is unsupported or incomplete; nothing imported." }
    }
}
