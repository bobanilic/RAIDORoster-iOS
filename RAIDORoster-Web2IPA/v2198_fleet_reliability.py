"""Append to the existing build pipeline; fail closed if the inspected source drifts."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / 'RAIDORoster/ContentView.swift'
PBX = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
content = CONTENT.read_text()
if '// Fleet reliability 2.19.8' in content:
    raise RuntimeError('Run the pipeline on a clean checkout; patch already applied')

def replace(old, new, count=1):
    global content
    actual = content.count(old)
    if actual != count:
        raise RuntimeError(f'Expected {count} anchors, found {actual}: {old[:100]}')
    content = content.replace(old, new)

replace('    let radiusContainmentMeters: Double?\n', '''    let radiusContainmentMeters: Double?
    var sourceReferenceAt: Date? = nil
    var groundStateKnown: Bool? = nil
    var verticalRateFeetPerMinute: Double? = nil
    var hasKnownGroundState: Bool { groundStateKnown ?? (onGround || altitudeFeet != nil) }
''')
replace('    var hasPosition: Bool { latitude != nil && longitude != nil }', '''    var hasPosition: Bool {
        FleetTrackingPolicy.validCoordinate(latitude: latitude, longitude: longitude)
    }''')
replace('        max(0, Date().timeIntervalSince(fetchedAt) + sourceSeenSeconds)', '''        FleetTrackingPolicy.age(referenceAt: sourceReferenceAt ?? fetchedAt,
                                seconds: sourceSeenSeconds, now: Date())''')
replace('        max(observationAge, seenPositionSeconds ?? sourceSeenSeconds)', '''        FleetTrackingPolicy.positionAge(referenceAt: sourceReferenceAt ?? fetchedAt,
                                        messageAge: sourceSeenSeconds,
                                        positionAge: seenPositionSeconds, now: Date())''')
replace('    var isFresh: Bool { effectivePositionAge <= 120 }', '    var isFresh: Bool { hasPosition && effectivePositionAge <= 120 }')
replace('    var isRecent: Bool { effectivePositionAge <= 900 }', '    var isRecent: Bool { hasPosition && effectivePositionAge <= 900 }')
replace('''        guard !onGround else { return false }
        if let altitudeFeet, altitudeFeet > 800 { return true }
        if let groundSpeedKnots, groundSpeedKnots > 80 { return true }
        return false''', '''        hasKnownGroundState && !onGround''')
replace('''            return rc < 1000 ? "±\\(Int(rc.rounded())) m" : "±\\(String(format: "%.1f", rc / 1000)) km"''', '''            return rc < 1000 ? "Containment \\(Int(rc.rounded())) m" : "Containment \\(String(format: "%.1f", rc / 1000)) km"''')

# Optional fields preserve decoding of the existing cache. Missing ground state
# in old history is deliberately not eligible for transition inference.
replace('    let observedAt: Date\n\n    var id: String {\n        "\\(registration)|', '''    let observedAt: Date
    var groundStateKnown: Bool? = nil

    var id: String {
        "\\(registration)|''')
replace('''private struct ADSBLOLResponse: Decodable {
    let ac: [ADSBLOLAircraft]
}''', '''private struct ADSBLOLResponse: Decodable {
    let ac: [ADSBLOLAircraft]
    let now: Double?
}

private enum FleetProviderError: Error {
    case http(Int)
    case rateLimited(TimeInterval)
    case identityMismatch
}''')
replace('''private struct ADSBLOLAircraft: Decodable {
    let hex: String?''', '''private struct ADSBLOLAircraft: Decodable {
    let registration: String?
    let verticalRate: Double?
    let groundStateKnown: Bool
    let hex: String?''')
replace('        case hex, flight, lat, lon, gs, track, seen, nic, rc', '''        case hex, flight, lat, lon, gs, track, seen, nic, rc
        case registration = "r"
        case verticalRate = "baro_rate"''')
replace('        hex = try? container.decodeIfPresent(String.self, forKey: .hex)', '''        registration = try? container.decodeIfPresent(String.self, forKey: .registration)
        verticalRate = try? container.decodeIfPresent(Double.self, forKey: .verticalRate)
        hex = try? container.decodeIfPresent(String.self, forKey: .hex)''')
replace('        seen = (try? container.decode(Double.self, forKey: .seen)) ?? 0', '        seen = (try? container.decode(Double.self, forKey: .seen)) ?? 31_536_000')
replace('''            altitudeFeet = numeric
            onGround = false''', '''            altitudeFeet = numeric.isFinite ? numeric : nil
            groundStateKnown = numeric.isFinite
            onGround = false''')
replace('''            onGround = value.lowercased() == "ground"
        } else {
            altitudeFeet = nil
            onGround = false''', '''            onGround = value.lowercased() == "ground"
            groundStateKnown = onGround
        } else {
            altitudeFeet = nil
            groundStateKnown = false
            onGround = false''')

replace('    private let maximumHistoryPerAircraft = 720', '''    private let maximumHistoryPerAircraft = 720
    private var retryAfter: Date?''')
replace('''    func refresh() async {
        guard !isRefreshing else { return }''', '''    func refresh() async {
        guard !isRefreshing, retryAfter.map({ Date() >= $0 }) ?? true else { return }''')
replace('''        for definition in FleetAircraftDefinition.all {
            do {''', '''        for definition in FleetAircraftDefinition.all {
            guard !Task.isCancelled else { return }
            do {''')
replace('''            } catch {
                failures += 1
            }
            completedCount += 1''', '''            } catch is CancellationError {
                return
            } catch FleetProviderError.rateLimited(let delay) {
                retryAfter = Date().addingTimeInterval(delay)
                failures += 1
                break
            } catch {
                failures += 1
            }
            completedCount += 1''')
replace('''                    radiusContainmentMeters: old.radiusContainmentMeters
''', '''                    radiusContainmentMeters: old.radiusContainmentMeters,
                    sourceReferenceAt: old.sourceReferenceAt,
                    groundStateKnown: old.groundStateKnown,
                    verticalRateFeetPerMinute: old.verticalRateFeetPerMinute
''')

# Inference only uses source-fresh, known observations from one flight with a
# bounded gap. Event timestamps are labelled detection estimates in the UI.
replace('''        let phase = inferredPhase(snapshot: snapshot, history: recent)''', '''        let phase = snapshot.isFresh && snapshot.hasKnownGroundState
            ? inferredPhase(snapshot: snapshot, history: recent) : .unknown''')
replace('''            for pair in zip(history, history.dropFirst()) {
                if pair.0.onGround && !pair.1.onGround {''', '''            for pair in zip(history, history.dropFirst()) {
                guard FleetTrackingPolicy.canInferTransition(
                    previousAt: pair.0.observedAt, currentAt: pair.1.observedAt,
                    previousKnown: pair.0.groundStateKnown == true,
                    currentKnown: pair.1.groundStateKnown == true,
                    previousCallsign: pair.0.callsign, currentCallsign: pair.1.callsign
                ) else { continue }
                if pair.0.onGround && !pair.1.onGround {''')
replace('''        if snapshot.onGround, let arrival = lastArrivalAt {''', '''        if snapshot.isFresh, snapshot.onGround, let arrival = lastArrivalAt,
           lastDepartureAt.map({ arrival > $0 }) ?? true {''')
start = content.index('    private func inferredPhase(snapshot: FleetLiveSnapshot, history: [FleetTrackObservation])')
end = content.index('    private func recordFreshHistory', start)
content = content[:start] + '''    private func inferredPhase(snapshot: FleetLiveSnapshot, history: [FleetTrackObservation]) -> FleetFlightPhase {
        guard snapshot.isFresh, snapshot.hasKnownGroundState else { return .unknown }
        if snapshot.onGround { return .onGround }
        let observedAt = (snapshot.sourceReferenceAt ?? snapshot.fetchedAt)
            .addingTimeInterval(-max(0, snapshot.sourceSeenSeconds))
        let previous = history.last(where: { $0.observedAt < observedAt && $0.callsign == snapshot.callsign })
        let rate = snapshot.verticalRateFeetPerMinute ?? FleetTrackingPolicy.verticalRate(
            previousAltitude: previous?.altitudeFeet, previousAt: previous?.observedAt,
            altitude: snapshot.altitudeFeet, observedAt: observedAt)
        if let rate, rate.isFinite, abs(rate) <= 10_000 {
            if rate > 500 { return .climbing }
            if rate < -500 { return .descending }
            if (snapshot.altitudeFeet ?? 0) >= 20_000 { return .cruise }
        }
        return .airborne
    }

''' + content[end:]
replace('''        for (registration, snapshot) in fresh {
            let observedAt = snapshot.fetchedAt.addingTimeInterval(-max(0, snapshot.sourceSeenSeconds))''', '''        for (registration, snapshot) in fresh {
            guard snapshot.isFresh, snapshot.hasKnownGroundState else { continue }
            let observedAt = (snapshot.sourceReferenceAt ?? snapshot.fetchedAt)
                .addingTimeInterval(-max(snapshot.sourceSeenSeconds, snapshot.seenPositionSeconds ?? 0))''')
replace('''                observedAt: observedAt
            )

            var values = histories''', '''                observedAt: observedAt,
                groundStateKnown: snapshot.hasKnownGroundState
            )

            var values = histories''')

# Keep this phase on the existing provider. Extra providers require the service
# design and entitlement review documented in docs/getjet-fleet-research.md.
start = content.index('    private func fetchAircraft(_ registration: String)')
end = content.index('    private func fetchRoutes(', start)
content = content[:start] + '''    private func fetchAircraft(_ registration: String) async throws -> FleetLiveSnapshot? {
        let expectedHex = FleetTrackingPolicy.validHex(snapshots[registration]?.icaoHex)
        let path = expectedHex.map { "hex/\\($0)" } ?? "reg/\\(registration)"
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.adsb.lol/v2/\\(encoded)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("RAIDORoster/2.19.8", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 429 {
            let delay = FleetTrackingPolicy.retryDelay(http.value(forHTTPHeaderField: "Retry-After"), now: Date())
            throw FleetProviderError.rateLimited(delay)
        }
        guard (200..<300).contains(http.statusCode) else { throw FleetProviderError.http(http.statusCode) }
        let result = try decoder.decode(ADSBLOLResponse.self, from: data)
        guard !result.ac.isEmpty else { return nil }
        guard let aircraft = result.ac.first(where: {
            FleetTrackingPolicy.matches(registration: $0.registration, hex: $0.hex,
                                        requested: registration, expectedHex: expectedHex)
        }) else { throw FleetProviderError.identityMismatch }
        let receivedAt = Date()
        let referenceAt = FleetTrackingPolicy.sourceDate(epoch: result.now, receivedAt: receivedAt)
        let hasPosition = FleetTrackingPolicy.validCoordinate(latitude: aircraft.lat, longitude: aircraft.lon)
        return FleetLiveSnapshot(
            registration: registration,
            callsign: aircraft.flight?.isEmpty == false ? aircraft.flight : nil,
            route: nil,
            latitude: hasPosition ? aircraft.lat : nil,
            longitude: hasPosition ? aircraft.lon : nil,
            altitudeFeet: aircraft.altitudeFeet,
            groundSpeedKnots: aircraft.gs,
            trackDegrees: aircraft.track,
            onGround: aircraft.onGround,
            sourceSeenSeconds: referenceAt == nil ? 31_536_000 : aircraft.seen,
            fetchedAt: receivedAt,
            icaoHex: FleetTrackingPolicy.validHex(aircraft.hex),
            seenPositionSeconds: referenceAt == nil ? nil : aircraft.seenPos,
            nacP: aircraft.nacP,
            nic: aircraft.nic,
            radiusContainmentMeters: aircraft.rc,
            sourceReferenceAt: referenceAt,
            groundStateKnown: aircraft.groundStateKnown,
            verticalRateFeetPerMinute: aircraft.verticalRate
        )
    }

''' + content[end:]
replace('''            guard result.plausible != false,''', '''            guard result.plausible == true,''')

# Current/next duties may contain two or more assigned tails: show every one.
replace('''                if let assigned = visibleAircraft.first(where: {
                    currentDutyRegistrations.contains(normalizedRegistration($0.registration))
                }) {
                    Section("YOUR CURRENT / NEXT AIRCRAFT") {
                        FleetAircraftRow(
                            aircraft: assigned,
                            snapshot: live.snapshot(for: assigned.registration),
                            isAssigned: true
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { selectedAircraft = assigned }
                    }
                }''', '''                let assignedAircraft = visibleAircraft.filter {
                    currentDutyRegistrations.contains(normalizedRegistration($0.registration))
                }
                if !assignedAircraft.isEmpty {
                    Section("YOUR CURRENT / NEXT AIRCRAFT") {
                        ForEach(assignedAircraft) { assigned in
                            FleetAircraftRow(aircraft: assigned,
                                snapshot: live.snapshot(for: assigned.registration), isAssigned: true)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedAircraft = assigned }
                        }
                    }
                }''')
replace('''                    snapshot: live.snapshot(for: aircraft.registration),
                    intelligence: live.intelligence(for: aircraft.registration),''', '''                    live: live,''')
replace('''    let snapshot: FleetLiveSnapshot?
    let intelligence: FleetAircraftIntelligence?
    let isAssigned: Bool''', '''    @ObservedObject var live: FleetLiveStore
    var snapshot: FleetLiveSnapshot? { live.snapshot(for: aircraft.registration) }
    var intelligence: FleetAircraftIntelligence? { live.intelligence(for: aircraft.registration) }
    let isAssigned: Bool''')
replace('''    init(aircraft: FleetAircraftDefinition, snapshot: FleetLiveSnapshot?, intelligence: FleetAircraftIntelligence?, isAssigned: Bool) {
        self.aircraft = aircraft
        self.snapshot = snapshot
        self.intelligence = intelligence''', '''    init(aircraft: FleetAircraftDefinition, live: FleetLiveStore, isAssigned: Bool) {
        self.aircraft = aircraft
        self.live = live''')
replace('''        let lhsAirborne = live.snapshot(for: lhs.registration)?.isAirborne == true
            let rhsAirborne = live.snapshot(for: rhs.registration)?.isAirborne == true''', '''        let lhsAirborne = live.snapshot(for: lhs.registration).map { $0.isFresh && $0.isAirborne } == true
            let rhsAirborne = live.snapshot(for: rhs.registration).map { $0.isFresh && $0.isAirborne } == true''')
replace('''    let seconds = max(0, Int(age))''', '''    guard age.isFinite else { return "age unknown" }
    let seconds = max(0, Int(age))''')
replace('Text(fleetCompactAge(snapshot.observationAge))', 'Text(fleetCompactAge(snapshot.effectivePositionAge))')
replace('''Text("Observation \\(fleetCompactAge(snapshot.observationAge)) • public ADS-B")''', '''Text("Position \\(fleetCompactAge(snapshot.effectivePositionAge)) • public ADS-B")''')
replace('Label(intelligence.phase.rawValue,', 'Label("Estimated: " + intelligence.phase.rawValue,')
replace('LabeledContent("Last landing",', 'LabeledContent("Landing detected ≈",')
replace('LabeledContent("Last takeoff",', 'LabeledContent("Takeoff detected ≈",')
replace('LabeledContent("On ground", value: fleetDuration(turnaround))', 'LabeledContent("Since detected landing ≈", value: fleetDuration(turnaround))')
replace('LabeledContent("Current sector",', 'LabeledContent("Inferred route",')
replace('LabeledContent("Previous sector",', 'LabeledContent("Earlier inferred route",')
replace('LabeledContent("RAIDO Roster", value: "2.19.7")', 'LabeledContent("RAIDO Roster", value: "2.19.8")')
replace('return ("Live", .blue)', 'return ("Position available · state unknown", .blue)')

# Today must use position age, not the timestamp of an unrelated Mode-S message.
replace('''        trackedRegistration = normalized.isEmpty ? nil : normalized
        if isTracking { restartHybridTask() }''', '''        let next = normalized.isEmpty ? nil : normalized
        if next != trackedRegistration {
            networkLatitude = nil; networkLongitude = nil
            networkAltitudeMeters = nil; networkGroundSpeedMPS = nil
            networkTrackDegrees = nil; networkObservationAt = nil
            fusedTrail = []; lastFusedTrailAt = nil
        }
        trackedRegistration = next
        if isTracking { restartHybridTask() }''')
replace('    private let maximumExtrapolationAge: TimeInterval = 120', '    private let maximumExtrapolationAge: TimeInterval = 20')
replace('''                  let aircraft = (root["ac"] as? [[String: Any]])?.first,
                  let lat = aircraft["lat"] as? Double,
                  let lon = aircraft["lon"] as? Double else { return }

            let seen = aircraft["seen"] as? Double ?? 0''', '''                  let aircraft = (root["ac"] as? [[String: Any]])?.first(where: {
                      FleetTrackingPolicy.matches(registration: $0["r"] as? String,
                          hex: $0["hex"] as? String, requested: registration, expectedHex: nil)
                  }),
                  let lat = aircraft["lat"] as? Double,
                  let lon = aircraft["lon"] as? Double,
                  FleetTrackingPolicy.validCoordinate(latitude: lat, longitude: lon),
                  let reference = FleetTrackingPolicy.sourceDate(epoch: root["now"] as? Double, receivedAt: Date()),
                  let seen = aircraft["seen_pos"] as? Double, seen.isFinite, seen >= 0,
                  trackedRegistration == registration else { return }''')
replace('''            networkObservationAt = Date().addingTimeInterval(-max(0, seen))''', '''            networkObservationAt = reference.addingTimeInterval(-seen)''')
replace('''            horizontalAccuracy: age <= maximumNetworkObservationAge ? 100 : 500,''', '''            horizontalAccuracy: -1,''')
replace('''            verticalAccuracy: networkAltitudeMeters == nil ? -1 : 150,''', '''            verticalAccuracy: -1,''')
replace('''            timestamp: now
        )
        return (location, canPropagate)''', '''            timestamp: observedAt
        )
        return (location, canPropagate && networkGroundSpeedMPS.map { $0 > 1 } == true && networkTrackDegrees != nil)''')

# Age labels must change even when no new network observation arrives.
for struct_name in ['private struct FleetAircraftRow: View {', 'private struct FleetAircraftDetailView: View {']:
    start = content.index(struct_name)
    body = content.index('    var body: some View {', start)
    brace = content.index('{', body)
    depth = 1
    end = brace + 1
    while depth:
        if content[end] == '{': depth += 1
        if content[end] == '}': depth -= 1
        end += 1
    inner = content[brace+1:end-1]
    content = content[:brace+1] + '\n        TimelineView(.periodic(from: .now, by: 15)) { _ in\n' + inner + '\n        }\n    ' + content[end-1:]

content += '\n// Fleet reliability 2.19.8\n'
CONTENT.write_text(content)
pbx = PBX.read_text()
for old, new in [
    ('/* End PBXBuildFile section */', 'A19800000000000000000001 /* FleetTrackingPolicy.swift in Sources */ = {isa = PBXBuildFile; fileRef = B19800000000000000000001 /* FleetTrackingPolicy.swift */; };\n/* End PBXBuildFile section */'),
    ('/* End PBXFileReference section */', 'B19800000000000000000001 /* FleetTrackingPolicy.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FleetTrackingPolicy.swift; sourceTree = "<group>"; };\n/* End PBXFileReference section */'),
    ('B00000000000000000000002 /* ContentView.swift */,', 'B00000000000000000000002 /* ContentView.swift */,\n B19800000000000000000001 /* FleetTrackingPolicy.swift */,'),
    ('A00000000000000000000002 /* ContentView.swift in Sources */,', 'A00000000000000000000002 /* ContentView.swift in Sources */, A19800000000000000000001 /* FleetTrackingPolicy.swift in Sources */,'),
]:
    if pbx.count(old) != 1: raise RuntimeError(f'PBX anchor mismatch: {old}')
    pbx = pbx.replace(old, new)
pbx = pbx.replace('MARKETING_VERSION = 2.19.7;', 'MARKETING_VERSION = 2.19.8;')
PBX.write_text(pbx)
print('V2.19.8 Fleet observation reliability applied')
