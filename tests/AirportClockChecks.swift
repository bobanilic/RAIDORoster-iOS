import Foundation

@main struct AirportClockChecks {
    static func main() throws {
        let records = try JSONDecoder().decode([String: [String]].self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        precondition(records.count > 5000)
        for (code, row) in records {
            precondition(code.count == 3 && row.count == 2)
            precondition(TimeZone(identifier: row[1]) != nil, "Invalid time zone: \(code) \(row)")
        }
        func offset(_ code: String, _ stamp: String) -> Int {
            let date = ISO8601DateFormatter().date(from: stamp)!
            return TimeZone(identifier: records[code]![1])!.secondsFromGMT(for: date)
        }
        precondition(offset("TLV", "2026-07-01T12:00:00Z") == 10800)
        precondition(offset("TLV", "2026-12-01T12:00:00Z") == 7200)
        precondition(offset("PFO", "2026-07-01T12:00:00Z") == 10800)
        precondition(offset("PFO", "2026-12-01T12:00:00Z") == 7200)
        precondition(offset("AUH", "2026-12-01T12:00:00Z") == 14400)
        precondition(offset("KTM", "2026-12-01T12:00:00Z") == 20700)
        precondition(offset("JFK", "2026-12-01T12:00:00Z") == -18000)
        precondition(records["ZZZ"] == nil)
        print("Passed airport clocks: \(records.count) identifiers, summer/winter DST, fixed and fractional offsets, unknown code")
    }
}
