from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"

content = CONTENT.read_text()

# -----------------------------------------------------------------------------
# V2.19.7 — persistent fleet/tail intelligence.
# Preserve per-registration observations, infer flight phase and transitions,
# retain route history, and expose turnaround / previous-sector context.
# -----------------------------------------------------------------------------

snapshot_marker = 'private struct ADSBLOLResponse: Decodable {'
idx = content.find(snapshot_marker)
if idx < 0:
    raise RuntimeError('V2.19.7 ADSB response marker not found')

if 'private struct FleetTrackObservation:' not in content:
    support = r'''
private struct FleetTrackObservation: Codable, Identifiable {
    let registration: String
    let callsign: String?
    let route: String?
    let latitude: Double?
    let longitude: Double?
    let altitudeFeet: Double?
    let groundSpeedKnots: Double?
    let trackDegrees: Double?
    let onGround: Bool
    let observedAt: Date

    var id: String {
        "\(registration)|\(Int(observedAt.timeIntervalSince1970))"
    }
}

private enum FleetFlightPhase: String {
    case unknown = "Unknown"
    case onGround = "On ground"
    case departing = "Departing"
    case climbing = "Climbing"
    case cruise = "Cruise"
    case descending = "Descending"
    case arriving = "Arriving"
    case airborne = "Airborne"
}

private struct FleetAirportReference {
    let code: String
    let latitude: Double
    let longitude: Double

    static let common: [FleetAirportReference] = [
        .init(code: "TLV", latitude: 32.0005, longitude: 34.8708),
        .init(code: "LCA", latitude: 34.8751, longitude: 33.6249),
        .init(code: "FCO", latitude: 41.8003, longitude: 12.2389),
        .init(code: "ATH", latitude: 37.9364, longitude: 23.9445),
        .init(code: "BEG", latitude: 44.8184, longitude: 20.3091),
        .init(code: "VNO", latitude: 54.6341, longitude: 25.2858),
        .init(code: "RIX", latitude: 56.9236, longitude: 23.9711),
        .init(code: "KUN", latitude: 54.9639, longitude: 24.0848),
        .init(code: "WAW", latitude: 52.1657, longitude: 20.9671),
        .init(code: "VIE", latitude: 48.1103, longitude: 16.5697),
        .init(code: "BER", latitude: 52.3667, longitude: 13.5033),
        .init(code: "CDG", latitude: 49.0097, longitude: 2.5479),
        .init(code: "AMS", latitude: 52.3105, longitude: 4.7683),
        .init(code: "LHR", latitude: 51.4700, longitude: -0.4543)
    ]
}

private struct FleetAircraftIntelligence {
    let phase: FleetFlightPhase
    let currentRoute: String?
    let previousRoute: String?
    let nearestAirport: String?
    let lastDepartureAt: Date?
    let lastArrivalAt: Date?
    let turnaroundSeconds: TimeInterval?
    let observationCount: Int
}

private func fleetDistanceMeters(
    latitude1: Double,
    longitude1: Double,
    latitude2: Double,
    longitude2: Double
) -> Double {
    let a = CLLocation(latitude: latitude1, longitude: longitude1)
    let b = CLLocation(latitude: latitude2, longitude: longitude2)
    return a.distance(from: b)
}

'''
    content = content[:idx] + support + content[idx:]

# FleetLiveStore state.
store_start = content.find('private final class FleetLiveStore: ObservableObject {')
store_end = content.find('\nprivate enum FleetFilter:', store_start)
if store_start < 0 or store_end < 0:
    raise RuntimeError('V2.19.7 FleetLiveStore boundaries not found')
store = content[store_start:store_end]

if '@Published private(set) var histories:' not in store:
    anchor = '    @Published private(set) var completedCount = 0\n'
    if anchor not in store:
        raise RuntimeError('V2.19.7 completedCount anchor not found')
    store = store.replace(anchor, anchor + '    @Published private(set) var histories: [String: [FleetTrackObservation]] = [:]\n', 1)

if 'private let historyCacheKey' not in store:
    anchor = '    private let cacheKey = "RAIDORoster.FleetLiveCache.V1"\n'
    if anchor not in store:
        raise RuntimeError('V2.19.7 cache key anchor not found')
    store = store.replace(anchor, anchor + '    private let historyCacheKey = "RAIDORoster.FleetHistory.V2"\n    private let maximumHistoryPerAircraft = 720\n', 1)

# Record only freshly fetched observations after route enrichment, before merge.
merge_anchor = '''        // Preserve a previous observation for aircraft that are not currently\n        // visible to ADS-B, but never make it look live: the UI marks its age.\n        var merged = snapshots\n'''
if merge_anchor not in store:
    raise RuntimeError('V2.19.7 fresh merge anchor not found')
if 'recordFreshHistory(fresh)' not in store:
    store = store.replace(merge_anchor, '        recordFreshHistory(fresh)\n\n' + merge_anchor, 1)

# Public history/intelligence accessors before fetchAircraft.
fetch_marker = '    private func fetchAircraft(_ registration: String) async throws -> FleetLiveSnapshot? {\n'
idx2 = store.find(fetch_marker)
if idx2 < 0:
    raise RuntimeError('V2.19.7 fetchAircraft marker not found')
if 'func intelligence(for registration:' not in store:
    helpers = r'''    func history(for registration: String) -> [FleetTrackObservation] {
        histories[registration] ?? []
    }

    func intelligence(for registration: String) -> FleetAircraftIntelligence? {
        guard let snapshot = snapshots[registration] else { return nil }
        let history = histories[registration] ?? []
        let recent = Array(history.suffix(20))

        let phase = inferredPhase(snapshot: snapshot, history: recent)
        let currentRoute = snapshot.route?.nilIfEmpty
        let previousRoute = history.reversed().compactMap(\.route).first(where: {
            guard let currentRoute else { return true }
            return $0 != currentRoute
        })

        var lastDepartureAt: Date?
        var lastArrivalAt: Date?
        if history.count >= 2 {
            for pair in zip(history, history.dropFirst()) {
                if pair.0.onGround && !pair.1.onGround {
                    lastDepartureAt = pair.1.observedAt
                }
                if !pair.0.onGround && pair.1.onGround {
                    lastArrivalAt = pair.1.observedAt
                }
            }
        }

        var nearestAirport: String?
        if let lat = snapshot.latitude, let lon = snapshot.longitude {
            let nearest = FleetAirportReference.common
                .map { ($0, fleetDistanceMeters(latitude1: lat, longitude1: lon, latitude2: $0.latitude, longitude2: $0.longitude)) }
                .min { $0.1 < $1.1 }
            if let nearest, nearest.1 <= 25_000 {
                nearestAirport = nearest.0.code
            }
        }

        let turnaround: TimeInterval?
        if snapshot.onGround, let arrival = lastArrivalAt {
            turnaround = max(0, Date().timeIntervalSince(arrival))
        } else {
            turnaround = nil
        }

        return FleetAircraftIntelligence(
            phase: phase,
            currentRoute: currentRoute,
            previousRoute: previousRoute,
            nearestAirport: nearestAirport,
            lastDepartureAt: lastDepartureAt,
            lastArrivalAt: lastArrivalAt,
            turnaroundSeconds: turnaround,
            observationCount: history.count
        )
    }

    private func inferredPhase(snapshot: FleetLiveSnapshot, history: [FleetTrackObservation]) -> FleetFlightPhase {
        if snapshot.onGround { return .onGround }
        let altitude = snapshot.altitudeFeet ?? 0
        let speed = snapshot.groundSpeedKnots ?? 0

        let previousAltitude = history.dropLast().reversed().compactMap(\.altitudeFeet).first
        let delta = previousAltitude.map { altitude - $0 } ?? 0

        if altitude < 3_500 {
            if delta > 250 || speed > 140 { return .departing }
            if delta < -250 { return .arriving }
            return .airborne
        }
        if delta > 500 { return .climbing }
        if delta < -500 { return .descending }
        if altitude >= 20_000 { return .cruise }
        return .airborne
    }

    private func recordFreshHistory(_ fresh: [String: FleetLiveSnapshot]) {
        for (registration, snapshot) in fresh {
            let observedAt = snapshot.fetchedAt.addingTimeInterval(-max(0, snapshot.sourceSeenSeconds))
            let observation = FleetTrackObservation(
                registration: registration,
                callsign: snapshot.callsign,
                route: snapshot.route,
                latitude: snapshot.latitude,
                longitude: snapshot.longitude,
                altitudeFeet: snapshot.altitudeFeet,
                groundSpeedKnots: snapshot.groundSpeedKnots,
                trackDegrees: snapshot.trackDegrees,
                onGround: snapshot.onGround,
                observedAt: observedAt
            )

            var values = histories[registration] ?? []
            if let last = values.last,
               abs(last.observedAt.timeIntervalSince(observation.observedAt)) < 20,
               last.latitude == observation.latitude,
               last.longitude == observation.longitude,
               last.onGround == observation.onGround {
                continue
            }
            values.append(observation)
            values.sort { $0.observedAt < $1.observedAt }
            if values.count > maximumHistoryPerAircraft {
                values.removeFirst(values.count - maximumHistoryPerAircraft)
            }
            histories[registration] = values
        }
        saveHistory()
    }

'''
    store = store[:idx2] + helpers + store[idx2:]

# Load/save history alongside snapshot cache.
load_start = store.find('    private func loadCache() {')
load_end = store.find('    private func saveCache() {', load_start)
if load_start < 0 or load_end < 0:
    raise RuntimeError('V2.19.7 cache methods not found')
load_block = store[load_start:load_end]
if 'historyCacheKey' not in load_block:
    # Insert immediately before loadCache closes.
    close = load_block.rfind('    }\n')
    if close < 0:
        raise RuntimeError('V2.19.7 loadCache close not found')
    addition = '''        if let historyData = UserDefaults.standard.data(forKey: historyCacheKey),\n           let savedHistory = try? decoder.decode([String: [FleetTrackObservation]].self, from: historyData) {\n            histories = savedHistory\n        }\n'''
    load_block = load_block[:close] + addition + load_block[close:]
    store = store[:load_start] + load_block + store[load_end:]

if 'private func saveHistory()' not in store:
    save_start = store.find('    private func saveCache() {')
    save_end = store.find('\n    }', save_start)
    if save_start < 0 or save_end < 0:
        raise RuntimeError('V2.19.7 saveCache boundary not found')
    save_end += len('\n    }')
    helper = r'''

    private func saveHistory() {
        guard let data = try? encoder.encode(histories) else { return }
        UserDefaults.standard.set(data, forKey: historyCacheKey)
    }
'''
    store = store[:save_end] + helper + store[save_end:]

content = content[:store_start] + store + content[store_end:]

# Detail sheet receives intelligence/history context.
old_sheet = '''                FleetAircraftDetailView(\n                    aircraft: aircraft,\n                    snapshot: live.snapshot(for: aircraft.registration),\n                    isAssigned: currentDutyRegistrations.contains(normalizedRegistration(aircraft.registration))\n                )\n'''
new_sheet = '''                FleetAircraftDetailView(\n                    aircraft: aircraft,\n                    snapshot: live.snapshot(for: aircraft.registration),\n                    intelligence: live.intelligence(for: aircraft.registration),\n                    isAssigned: currentDutyRegistrations.contains(normalizedRegistration(aircraft.registration))\n                )\n'''
if old_sheet not in content:
    raise RuntimeError('V2.19.7 Fleet detail sheet marker not found')
content = content.replace(old_sheet, new_sheet, 1)

# Add intelligence property to detail view.
detail_marker = '''private struct FleetAircraftDetailView: View {\n    let aircraft: FleetAircraftDefinition\n    let snapshot: FleetLiveSnapshot?\n    let isAssigned: Bool\n'''
if detail_marker not in content:
    raise RuntimeError('V2.19.7 Fleet detail properties marker not found')
content = content.replace(detail_marker, '''private struct FleetAircraftDetailView: View {\n    let aircraft: FleetAircraftDefinition\n    let snapshot: FleetLiveSnapshot?\n    let intelligence: FleetAircraftIntelligence?\n    let isAssigned: Bool\n''', 1)

# Put operational intelligence directly above the existing metrics.
metric_anchor = '''                            HStack(spacing: 0) {\n                                FleetMetric(title: "Altitude", value: snapshot.altitudeFeet.map { "\\(Int($0.rounded()).formatted()) ft" } ?? "—")\n'''
if metric_anchor not in content:
    raise RuntimeError('V2.19.7 Fleet metrics anchor not found')
intelligence_ui = r'''                            if let intelligence {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Label(intelligence.phase.rawValue, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        if let airport = intelligence.nearestAirport {
                                            Text("NEAR \(airport)")
                                                .font(.caption.bold().monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    if let current = intelligence.currentRoute {
                                        LabeledContent("Current sector", value: current)
                                    }
                                    if let previous = intelligence.previousRoute {
                                        LabeledContent("Previous sector", value: previous)
                                    }
                                    if let turnaround = intelligence.turnaroundSeconds {
                                        LabeledContent("On ground", value: fleetDuration(turnaround))
                                    }
                                    if let arrival = intelligence.lastArrivalAt {
                                        LabeledContent("Last landing", value: arrival.formatted(date: .omitted, time: .shortened))
                                    }
                                    if let departure = intelligence.lastDepartureAt {
                                        LabeledContent("Last takeoff", value: departure.formatted(date: .omitted, time: .shortened))
                                    }
                                }
                                .font(.caption)
                                .padding(12)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                            }

'''
content = content.replace(metric_anchor, intelligence_ui + metric_anchor, 1)

# Shared duration helper.
helper_anchor = 'private func fleetCompactAge(_ age: TimeInterval) -> String {'
if helper_anchor not in content:
    raise RuntimeError('V2.19.7 fleetCompactAge helper not found')
if 'private func fleetDuration(_ interval:' not in content:
    duration_helper = r'''private func fleetDuration(_ interval: TimeInterval) -> String {
    let totalMinutes = max(0, Int(interval / 60))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}

'''
    content = content.replace(helper_anchor, duration_helper + helper_anchor, 1)

content = content.replace('LabeledContent("RAIDO Roster", value: "2.19.6")',
                          'LabeledContent("RAIDO Roster", value: "2.19.7")', 1)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace('MARKETING_VERSION = 2.19.6;', 'MARKETING_VERSION = 2.19.7;')
PBX.write_text(pbx)

print('V2.19.7 persistent fleet tail history + phase/turnaround intelligence applied')
