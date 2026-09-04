from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def block_end(text: str, start: int) -> int:
    brace = text.find('{', start)
    if brace < 0:
        return -1
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return i + 1
    return -1


content = CONTENT.read_text()

# -----------------------------------------------------------------------------
# V2.19.6 — hybrid aircraft position engine.
# Core Location (including external accessory GNSS) remains preferred. When the
# cabin loses a usable GNSS fix, poll ADSB.lol for the roster-assigned aircraft
# and locally propagate the latest observation between network updates.
# -----------------------------------------------------------------------------
manager_start = content.find('private final class TodayLiveFlightLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {')
manager_end = content.find('\nstruct TodayRouteMapCard: View {', manager_start)
if manager_start < 0 or manager_end < 0:
    raise RuntimeError('V2.19.6 location manager boundaries not found')
manager = content[manager_start:manager_end]

# Published fused state + network observation state.
anchor = '    @Published private(set) var acquisitionStartedAt: Date?\n'
if anchor not in manager:
    raise RuntimeError('V2.19.6 acquisition state anchor not found')
if '@Published private(set) var fusedLocation:' not in manager:
    manager = manager.replace(anchor, anchor + '''    @Published private(set) var fusedLocation: CLLocation?\n    @Published private(set) var fusedTrail: [CLLocationCoordinate2D] = []\n    @Published private(set) var positionSourceText = "Acquiring"\n    @Published private(set) var positionIsEstimated = false\n\n    private var trackedRegistration: String?\n    private var networkLatitude: Double?\n    private var networkLongitude: Double?\n    private var networkAltitudeMeters: Double?\n    private var networkGroundSpeedMPS: Double?\n    private var networkTrackDegrees: Double?\n    private var networkObservationAt: Date?\n    private var hybridTask: Task<Void, Never>?\n    private var lastFusedTrailAt: Date?\n    private let maximumNetworkObservationAge: TimeInterval = 90\n    private let maximumExtrapolationAge: TimeInterval = 120\n\n''', 1)

# Insert hybrid helpers before start().
marker = '    func start() {\n'
idx = manager.find(marker)
if idx < 0:
    raise RuntimeError('V2.19.6 start marker not found')
if 'func configureAircraftTracking(registration:' not in manager:
    helpers = r'''    func configureAircraftTracking(registration: String?) {
        let normalized = (registration ?? "")
            .uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        trackedRegistration = normalized.isEmpty ? nil : normalized
        if isTracking { restartHybridTask() }
    }

    private var usableGNSSLocation: CLLocation? {
        guard let location else { return nil }
        let age = max(0, Date().timeIntervalSince(location.timestamp))
        guard age <= 20, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 250 else { return nil }
        return location
    }

    private func sourceLabel(for location: CLLocation) -> String {
        if #available(iOS 15.0, *), location.sourceInformation?.isProducedByAccessory == true {
            return "External GNSS"
        }
        return "iPhone GNSS"
    }

    private func restartHybridTask() {
        hybridTask?.cancel()
        hybridTask = Task { [weak self] in
            guard let self else { return }
            var pollCounter = 0
            while !Task.isCancelled {
                if pollCounter == 0, let registration = self.trackedRegistration {
                    await self.fetchNetworkAircraft(registration: registration)
                }
                self.refreshFusedPosition()
                pollCounter = (pollCounter + 1) % 8
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func fetchNetworkAircraft(registration: String) async {
        let encoded = registration.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? registration
        guard let url = URL(string: "https://api.adsb.lol/v2/reg/\(encoded)") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("RAIDORoster/2.19.6", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let aircraft = (root["ac"] as? [[String: Any]])?.first,
                  let lat = aircraft["lat"] as? Double,
                  let lon = aircraft["lon"] as? Double else { return }

            let seen = aircraft["seen"] as? Double ?? 0
            networkLatitude = lat
            networkLongitude = lon
            networkGroundSpeedMPS = (aircraft["gs"] as? Double).map { $0 * 0.514444 }
            networkTrackDegrees = aircraft["track"] as? Double
            if let altitudeFeet = aircraft["alt_baro"] as? Double {
                networkAltitudeMeters = altitudeFeet * 0.3048
            } else {
                networkAltitudeMeters = nil
            }
            networkObservationAt = Date().addingTimeInterval(-max(0, seen))
        } catch {
            // Preserve the last known network state. Its age naturally lowers
            // confidence and eventually stops extrapolation.
        }
    }

    private func propagatedNetworkLocation(now: Date) -> (CLLocation, Bool)? {
        guard let lat = networkLatitude,
              let lon = networkLongitude,
              let observedAt = networkObservationAt else { return nil }
        let age = max(0, now.timeIntervalSince(observedAt))
        guard age <= maximumExtrapolationAge else { return nil }

        var latitude = lat
        var longitude = lon
        let canPropagate = age > 2 && age <= maximumExtrapolationAge
        if canPropagate,
           let speed = networkGroundSpeedMPS,
           speed > 1,
           let track = networkTrackDegrees {
            let distance = speed * age
            let radius = 6_371_000.0
            let bearing = track * .pi / 180
            let phi1 = lat * .pi / 180
            let lambda1 = lon * .pi / 180
            let angular = distance / radius
            let phi2 = asin(sin(phi1) * cos(angular) + cos(phi1) * sin(angular) * cos(bearing))
            let lambda2 = lambda1 + atan2(
                sin(bearing) * sin(angular) * cos(phi1),
                cos(angular) - sin(phi1) * sin(phi2)
            )
            latitude = phi2 * 180 / .pi
            longitude = lambda2 * 180 / .pi
        }

        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: networkAltitudeMeters ?? 0,
            horizontalAccuracy: age <= maximumNetworkObservationAge ? 100 : 500,
            verticalAccuracy: networkAltitudeMeters == nil ? -1 : 150,
            course: networkTrackDegrees ?? -1,
            speed: networkGroundSpeedMPS ?? -1,
            timestamp: now
        )
        return (location, canPropagate)
    }

    private func refreshFusedPosition() {
        let now = Date()
        if let gnss = usableGNSSLocation {
            publishFused(gnss, source: sourceLabel(for: gnss), estimated: false, now: now)
            return
        }
        if let (network, estimated) = propagatedNetworkLocation(now: now) {
            publishFused(network, source: estimated ? "ADS-B estimated" : "ADS-B live", estimated: estimated, now: now)
            return
        }
        if let location {
            // Keep the last physical fix visible but explicitly stale rather
            // than inventing a long dead-reckoning solution from phone sensors.
            publishFused(location, source: "Last GNSS fix", estimated: true, now: now)
            return
        }
        fusedLocation = nil
        positionSourceText = "Acquiring"
        positionIsEstimated = false
    }

    private func publishFused(_ value: CLLocation, source: String, estimated: Bool, now: Date) {
        fusedLocation = value
        positionSourceText = source
        positionIsEstimated = estimated

        let shouldAppend: Bool
        if let last = fusedTrail.last {
            let previous = CLLocation(latitude: last.latitude, longitude: last.longitude)
            shouldAppend = value.distance(from: previous) >= 100 ||
                lastFusedTrailAt.map { now.timeIntervalSince($0) >= 10 } == true
        } else {
            shouldAppend = true
        }
        if shouldAppend {
            fusedTrail.append(value.coordinate)
            lastFusedTrailAt = now
            if fusedTrail.count > 1_500 {
                fusedTrail.removeFirst(fusedTrail.count - 1_500)
            }
        }
    }

'''
    manager = manager[:idx] + helpers + manager[idx:]

# Start/stop hybrid task alongside Core Location.
manager = manager.replace(
    '        acquisitionStartedAt = Date()\n        isTracking = true\n',
    '        acquisitionStartedAt = Date()\n        fusedTrail = []\n        fusedLocation = nil\n        lastFusedTrailAt = nil\n        positionSourceText = "Acquiring"\n        positionIsEstimated = false\n        isTracking = true\n        restartHybridTask()\n',
    1,
)
manager = manager.replace(
    '        manager.stopUpdatingLocation()\n        isTracking = false\n',
    '        manager.stopUpdatingLocation()\n        hybridTask?.cancel()\n        hybridTask = nil\n        isTracking = false\n',
    1,
)

# Refresh fused source immediately after every accepted Core Location update.
loc_start = manager.find('    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {')
loc_end = manager.find('    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {', loc_start)
if loc_start < 0 or loc_end < 0:
    raise RuntimeError('V2.19.6 location callback boundaries not found')
loc_block = manager[loc_start:loc_end]
if 'refreshFusedPosition()' not in loc_block:
    # Add after the accepted location assignment, before trail filtering may return.
    loc_block = loc_block.replace('        location = candidate\n', '        location = candidate\n        refreshFusedPosition()\n', 1)
    if '        location = newest\n' in loc_block:
        loc_block = loc_block.replace('        location = newest\n', '        location = newest\n        refreshFusedPosition()\n', 1)
    manager = manager[:loc_start] + loc_block + manager[loc_end:]

content = content[:manager_start] + manager + content[manager_end:]

# -----------------------------------------------------------------------------
# Today map: drive presentation from the fused source, not raw phone GNSS.
# -----------------------------------------------------------------------------
card_start = content.find('struct TodayRouteMapCard: View {')
card_end = content.find('\nprivate struct CrewCompanionPhase', card_start)
if card_end < 0:
    card_end = content.find('\nstruct TodayPersonalNoteDisclosure', card_start)
if card_start < 0 or card_end < 0:
    raise RuntimeError('V2.19.6 TodayRouteMapCard boundaries not found')
card = content[card_start:card_end]

# Registration is already in the parsed roster; normalize without depending on
# Fleet-private helpers so Today tracking remains self-contained.
if 'private var trackedAircraftRegistration:' not in card:
    marker = '    private var points: [TodayAirportMapPoint] {\n'
    idx = card.find(marker)
    if idx < 0:
        raise RuntimeError('V2.19.6 points marker not found')
    helper = r'''    private var trackedAircraftRegistration: String? {
        let raw = item.aircraft.first?.aircraftReg
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        return raw.isEmpty ? nil : raw
    }

'''
    card = card[:idx] + helper + card[idx:]

# All map rendering/recenter/speed/course/accuracy presentation should use the
# selected fused position and fused trail.
card = card.replace('trail: gps.trail', 'trail: gps.fusedTrail')
card = card.replace('liveLocation: gps.location', 'liveLocation: gps.fusedLocation')
card = card.replace('if let coordinate = gps.location?.coordinate', 'if let coordinate = gps.fusedLocation?.coordinate')

# Metrics: make source explicit. Existing GPS quality remains useful when GNSS
# is active but the source label is more important once ADS-B takes over.
if 'private var positionSourceDetailText:' not in card:
    marker = '    private var gpsQualityDetailText: String {'
    idx = card.find(marker)
    if idx >= 0:
        helper = r'''    private var positionSourceDetailText: String {
        if let location = gps.fusedLocation {
            let age = Int(max(0, Date().timeIntervalSince(location.timestamp)).rounded())
            return "\(gps.positionSourceText) • \(age)s"
        }
        return gps.positionSourceText
    }

'''
        card = card[:idx] + helper + card[idx:]

card = card.replace('liveMetric("GPS", gpsQualityDetailText)', 'liveMetric("Position", positionSourceDetailText)', 1)

# Configure assigned-aircraft tracking whenever the map appears or roster
# aircraft changes. Keep existing automatic GNSS start behavior.
if '.onAppear { gps.configureAircraftTracking(registration: trackedAircraftRegistration)' not in card:
    old = '.onAppear { gps.startIfAuthorized() }'
    new = '.onAppear {\n            gps.configureAircraftTracking(registration: trackedAircraftRegistration)\n            gps.startIfAuthorized()\n        }\n        .onChange(of: trackedAircraftRegistration) { _, value in\n            gps.configureAircraftTracking(registration: value)\n        }'
    if old in card:
        card = card.replace(old, new, 1)
    else:
        body_end = card.rfind('\n    }\n')
        if body_end < 0:
            raise RuntimeError('V2.19.6 Today map onAppear insertion failed')
        card = card[:body_end] + '\n        .onAppear {\n            gps.configureAircraftTracking(registration: trackedAircraftRegistration)\n            gps.startIfAuthorized()\n        }\n        .onChange(of: trackedAircraftRegistration) { _, value in\n            gps.configureAircraftTracking(registration: value)\n        }' + card[body_end:]

content = content[:card_start] + card + content[card_end:]

content = content.replace('LabeledContent("RAIDO Roster", value: "2.19.5")',
                          'LabeledContent("RAIDO Roster", value: "2.19.6")', 1)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace('MARKETING_VERSION = 2.19.5;', 'MARKETING_VERSION = 2.19.6;')
PBX.write_text(pbx)

print('V2.19.6 hybrid GNSS + ADS-B fused aircraft tracking applied')
