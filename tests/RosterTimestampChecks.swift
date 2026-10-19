import Foundation

@main struct RosterTimestampChecks {
    static func legacy(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: value)
    }
    static func main() {
        let values = ["", "bad", "2026-02-30 12:00", "2026-10-20 25:00",
                      "2024-02-29 23:59", "2026-03-29 00:30", "2026-10-25 01:30",
                      "2026-12-31 23:59", "2027-01-01 00:00", "2026-10-20 08:30"]
        let expected = values.map(legacy)
        for index in values.indices {
            precondition(RosterTimestamp.parse(values[index]) == expected[index], "Timestamp compatibility: " + values[index])
        }
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            let offset = index % values.count
            precondition(RosterTimestamp.parse(values[offset]) == expected[offset], "Concurrent timestamp parsing")
        }
        let stamps = (0..<48).map { "2026-10-20 " + String(format: "%02d:%02d", $0 / 2, ($0 % 2) * 30) }
        let count = 1_000
        let baselineStart = Date()
        var baseline: TimeInterval = 0
        for index in 0..<count { baseline += legacy(stamps[index % stamps.count])!.timeIntervalSince1970 }
        let baselineTime = Date().timeIntervalSince(baselineStart)
        let cachedStart = Date()
        var cached: TimeInterval = 0
        for index in 0..<count { cached += RosterTimestamp.parse(stamps[index % stamps.count])!.timeIntervalSince1970 }
        let cachedTime = Date().timeIntervalSince(cachedStart)
        precondition(baseline == cached, "Benchmark must retain identical dates")
        print("Passed timestamp compatibility and 1000 concurrent lookups")
        print(String(format: "Timestamp benchmark (1000 lookups, 48 stamps): legacy %.3f ms; bounded cache %.3f ms; ratio %.2fx", baselineTime * 1000, cachedTime * 1000, baselineTime / max(cachedTime, 0.000001)))
        // Record measured timings; do not impose a hardware-dependent threshold.
    }
}
