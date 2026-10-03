import Foundation

@main struct FleetRefreshChecks {
    @MainActor static func main() async {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        var running = 0, peak = 0, received: [Int] = []
        let started = Date()
        let parallel = await FleetRefreshPolicy.run(Array(0..<12), budget: 2, operation: { value in
            running += 1; peak = max(peak, running)
            try? await Task.sleep(nanoseconds: 30_000_000)
            running -= 1
            return value
        }, receive: { received.append($0) })
        check(peak == 4, "network concurrency is bounded at four")
        check(running == 0 && parallel.completed == 12 && !parallel.timedOut, "all completed jobs are drained")
        check(Set(received) == Set(0..<12), "each result is delivered exactly once")
        check(Date().timeIntervalSince(started) < 0.30, "requests overlap instead of waiting serially")

        received = []
        let deadlineStarted = Date()
        let timeout = await FleetRefreshPolicy.run(Array(0..<40), budget: 0.08, operation: { value in
            do { try await Task.sleep(nanoseconds: value == 0 ? 5_000_000 : 5_000_000_000) }
            catch { }
            return value
        }, receive: { received.append($0) })
        check(timeout.timedOut && timeout.completed == 1, "deadline preserves only completed observations")
        check(received == [0], "partial results arrive before slower aircraft finish")
        check(Date().timeIntervalSince(deadlineStarted) < 0.5, "stalled jobs cancel promptly")

        var cancelledResults = 0
        let task = Task { @MainActor in
            await FleetRefreshPolicy.run(Array(0..<40), operation: { value in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return value
            }, receive: { _ in cancelledResults += 1 })
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        let cancelled = await task.value
        check(cancelled.completed == 0 && cancelledResults == 0, "background cancellation never publishes cancelled results")
        let recovery = await FleetRefreshPolicy.run([42], operation: { $0 }, receive: { received.append($0) })
        check(recovery.completed == 1 && !recovery.timedOut && received.last == 42, "another refresh works after cancellation")
        let empty = await FleetRefreshPolicy.run([Int](), operation: { $0 }, receive: { _ in })
        check(empty.completed == 0 && !empty.timedOut, "empty fleet returns immediately")

        let rows = (0..<5_000).map { value in
            FleetRosterEvidence(aircraftReg: value % 2 == 0 ? "LY-ABC" : "LY XYZ", aircraftType: "320",
                                route: "TLV-LCA", startUTC: "2026-10-03 10:00", endUTC: "2026-10-03 12:00")
        }
        let indexStarted = Date()
        let index = FleetRosterIndex(rows, stations: ["TLV"], preferred: ["TLV"])
        check(index.activities.count == 5_000 && index.byRegistration.count == 2, "large roster indexed without losing activities")
        check(index.byRegistration["LYABC"]?.count == 2_500, "registration aliases share an index key")
        check(index.rotationAirport == "TLV" && index.rotationRegistrations == Set(["LYABC", "LYXYZ"]), "rotation evidence preserved")
        check(index.latest["LYABC"] == index.activities.first?.end, "latest observation cached")
        check(index.activities.first?.start != nil && index.activities.first?.end != nil, "UTC timestamps parsed once into evidence")
        check(Date().timeIntervalSince(indexStarted) < 2, "5,000 roster activities index within two seconds")
        let bad = FleetRosterIndex([FleetRosterEvidence(aircraftReg: "", aircraftType: "", route: "", startUTC: "invalid", endUTC: "")])
        check(bad.byRegistration.isEmpty && bad.latest.isEmpty && bad.activities[0].start == nil, "malformed roster cannot create false dated evidence")
        print("Passed \(checks) Fleet responsiveness checks")
    }
}
