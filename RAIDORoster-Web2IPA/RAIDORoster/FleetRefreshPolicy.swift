import Foundation

/// Cooperative jobs must propagate cancellation. Fleet's URLSession also has
/// an eight-second resource timeout, including servers that drip-feed bytes.
enum FleetRefreshPolicy {
    private enum Event<Value> { case value(Value), deadline }
    struct Report { let completed: Int; let timedOut: Bool }

    @MainActor
    static func run<Input, Output>(
        _ inputs: [Input], limit: Int = 4, budget: TimeInterval = 30,
        operation: @escaping @MainActor (Input) async -> Output,
        receive: @escaping @MainActor (Output) -> Void
    ) async -> Report {
        guard !inputs.isEmpty, !Task.isCancelled else { return Report(completed: 0, timedOut: false) }
        return await withTaskGroup(of: Event<Output>.self) { group in
            group.addTask {
                do { try await Task.sleep(nanoseconds: UInt64(max(0, budget) * 1_000_000_000)) }
                catch { }
                return .deadline
            }
            var next = 0, completed = 0, timedOut = false
            for _ in 0..<min(max(1, limit), inputs.count) {
                let item = inputs[next]; next += 1
                group.addTask { .value(await operation(item)) }
            }
            while let event = await group.next() {
                guard !Task.isCancelled else { break }
                switch event {
                case .deadline:
                    timedOut = true
                case .value(let value):
                    completed += 1
                    receive(value)
                    if completed == inputs.count { break }
                    if next < inputs.count {
                        let item = inputs[next]; next += 1
                        group.addTask { .value(await operation(item)) }
                    }
                }
                if timedOut || completed == inputs.count { break }
            }
            group.cancelAll()
            return Report(completed: completed, timedOut: timedOut)
        }
    }
}

struct FleetRosterEvidence: Sendable {
    let aircraftReg: String
    let aircraftType: String
    let route: String
    let startUTC: String
    let endUTC: String
    var start: Date? = nil
    var end: Date? = nil
}

/// Build only when the roster changes. Never parse timestamps or scan the
/// entire roster from a row, a comparator, or a search keystroke.
struct FleetRosterIndex: Sendable {
    var activities: [FleetRosterEvidence] = []
    var byRegistration: [String: [FleetRosterEvidence]] = [:]
    var latest: [String: Date] = [:]
    var rotationAirport: String?
    var rotationRegistrations: Set<String> = []

    init(_ input: [FleetRosterEvidence] = [], stations: [String] = [], preferred: [String] = []) {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var parsed: [String: Date] = [:]
        func date(_ raw: String) -> Date? {
            if let value = parsed[raw] { return value }
            guard !raw.isEmpty, let value = formatter.date(from: raw) else { return nil }
            parsed[raw] = value
            return value
        }
        rotationAirport = FleetTrackingPolicy.dominantRotationAirport(
            routes: input.map(\.route), stations: stations, preferredAirports: preferred)
        for var activity in input {
            activity.start = date(activity.startUTC); activity.end = date(activity.endUTC)
            activities.append(activity)
            let key = FleetTrackingPolicy.normalizedRegistration(activity.aircraftReg)
            guard !key.isEmpty else { continue }
            byRegistration[key, default: []].append(activity)
            if let stamp = activity.end ?? activity.start {
                latest[key] = max(latest[key] ?? .distantPast, stamp)
            }
            if let airport = rotationAirport,
               FleetTrackingPolicy.rotationRelation(route: activity.route, airport: airport) != .unrelated {
                rotationRegistrations.insert(key)
            }
        }
    }
}
