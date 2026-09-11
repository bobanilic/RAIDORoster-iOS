from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster/ContentView.swift"
s = CONTENT.read_text()


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


manager_start = s.find('private final class TodayLiveFlightLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {')
manager_end = s.find('\nstruct TodayRouteMapCard: View {', manager_start)
if manager_start < 0 or manager_end < 0:
    raise RuntimeError('Flight Companion reliability: location manager boundaries missing')
manager = s[manager_start:manager_end]

# Persist the flown/fused trail per roster sector so reopening Today never loses
# the green track. Keep this local-only; no roster or location data is uploaded.
state_anchor = '    private var lastFusedTrailAt: Date?\n'
if state_anchor not in manager:
    raise RuntimeError('Flight Companion reliability: fused trail state anchor missing')
if 'private struct PersistedTrailPoint: Codable' not in manager:
    manager = manager.replace(state_anchor, state_anchor + r'''    private struct PersistedTrailPoint: Codable {
        let latitude: Double
        let longitude: Double
    }
    private var trailPersistenceKey: String?
    private var lastTrailPersistAt: Date?
    private let trailStoragePrefix = "RAIDORoster.FlightTrail.V1."

''', 1)

configure_anchor = '    func configureAircraftTracking(registration: String?) {\n'
idx = manager.find(configure_anchor)
if idx < 0:
    raise RuntimeError('Flight Companion reliability: configure-aircraft anchor missing')
if 'func configureTrailPersistence(sessionKey:' not in manager:
    helpers = r'''    func configureTrailPersistence(sessionKey: String) {
        let safe = sessionKey.data(using: .utf8)?.base64EncodedString() ?? sessionKey
        let key = trailStoragePrefix + safe
        guard trailPersistenceKey != key else { return }
        trailPersistenceKey = key
        loadPersistedTrail()
    }

    private func loadPersistedTrail() {
        guard let key = trailPersistenceKey,
              let data = UserDefaults.standard.data(forKey: key),
              let points = try? JSONDecoder().decode([PersistedTrailPoint].self, from: data) else {
            fusedTrail = []
            return
        }
        fusedTrail = points.suffix(1_500).map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    private func persistFusedTrail(now: Date, force: Bool = false) {
        guard let key = trailPersistenceKey, !fusedTrail.isEmpty else { return }
        if !force, let last = lastTrailPersistAt, now.timeIntervalSince(last) < 30 { return }
        let points = fusedTrail.suffix(1_500).map {
            PersistedTrailPoint(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard let data = try? JSONEncoder().encode(points) else { return }
        UserDefaults.standard.set(data, forKey: key)
        lastTrailPersistAt = now
    }

'''
    manager = manager[:idx] + helpers + manager[idx:]

# Canonicalize RAIDO's compact tail forms (for example LYTEN -> LY-TEN) before
# network lookup. Locate the function structurally instead of requiring the exact
# V2.19.6 text: earlier patches are allowed to reformat or extend the block.
new_config = r'''    func configureAircraftTracking(registration: String?) {
        let canonical = FleetTrackingPolicy.canonicalRegistration(registration ?? "")
        trackedRegistration = canonical.isEmpty ? nil : canonical
        if isTracking { restartHybridTask() }
    }'''
config_start = manager.find(configure_anchor)
config_end = block_end(manager, config_start) if config_start >= 0 else -1
if config_start < 0 or config_end < 0:
    raise RuntimeError('Flight Companion reliability: registration function boundaries missing')
config_block = manager[config_start:config_end]
if 'FleetTrackingPolicy.canonicalRegistration' in config_block:
    pass
elif 'trackedRegistration' in config_block and 'restartHybridTask' in config_block:
    manager = manager[:config_start] + new_config + manager[config_end:]
else:
    raise RuntimeError('Flight Companion reliability: configureAircraftTracking semantics changed; refusing unsafe replacement')

# Replace the single-provider fallback with a conservative multi-provider
# cascade. Only one roster aircraft is queried and secondary providers are used
# only when an earlier provider gives no usable position.
fetch_start = manager.find('    private func fetchNetworkAircraft(registration: String) async {')
fetch_end = manager.find('    private func propagatedNetworkLocation(now: Date)', fetch_start)
if fetch_start < 0 or fetch_end < 0:
    raise RuntimeError('Flight Companion reliability: network fetch boundaries missing')
new_fetch = r'''    private func fetchNetworkAircraft(registration: String) async {
        let encoded = registration.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? registration
        let urls = [
            "https://api.adsb.lol/v2/reg/\(encoded)",
            "https://opendata.adsb.fi/api/v2/registration/\(encoded)",
            "https://api.adsb.one/v2/reg/\(encoded)"
        ]
        for raw in urls {
            guard !Task.isCancelled, let url = URL(string: raw) else { return }
            if await acceptNetworkAircraft(url: url) { return }
        }
    }

    private func acceptNetworkAircraft(url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("RAIDORoster/2.23", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let aircraft = (root["ac"] as? [[String: Any]])?.first,
                  let lat = aircraft["lat"] as? Double,
                  let lon = aircraft["lon"] as? Double,
                  (-90...90).contains(lat), (-180...180).contains(lon) else { return false }

            let seen = max(0, aircraft["seen"] as? Double ?? 0)
            networkLatitude = lat
            networkLongitude = lon
            networkGroundSpeedMPS = (aircraft["gs"] as? Double).map { $0 * 0.514444 }
            networkTrackDegrees = aircraft["track"] as? Double
            if let altitudeFeet = aircraft["alt_baro"] as? Double {
                networkAltitudeMeters = altitudeFeet * 0.3048
            } else {
                networkAltitudeMeters = nil
            }
            networkObservationAt = Date().addingTimeInterval(-seen)
            return true
        } catch {
            return false
        }
    }

'''
manager = manager[:fetch_start] + new_fetch + manager[fetch_end:]

# Starting tracking is now always explicit. Preserve any already-loaded trail
# instead of clearing it, and persist before stopping.
manager = manager.replace(
    '        fusedTrail = []\n        fusedLocation = nil\n        lastFusedTrailAt = nil\n',
    '        if fusedTrail.isEmpty { loadPersistedTrail() }\n        fusedLocation = nil\n        lastFusedTrailAt = nil\n',
    1,
)
manager = manager.replace(
    '        manager.stopUpdatingLocation()\n        hybridTask?.cancel()\n',
    '        persistFusedTrail(now: Date(), force: true)\n        manager.stopUpdatingLocation()\n        hybridTask?.cancel()\n',
    1,
)

# Persist the green trail periodically after meaningful movement.
append_anchor = '''            fusedTrail.append(value.coordinate)\n            lastFusedTrailAt = now\n            if fusedTrail.count > 1_500 {\n                fusedTrail.removeFirst(fusedTrail.count - 1_500)\n            }\n'''
if append_anchor not in manager:
    raise RuntimeError('Flight Companion reliability: fused append anchor missing')
manager = manager.replace(append_anchor, append_anchor + '            persistFusedTrail(now: now)\n', 1)

s = s[:manager_start] + manager + s[manager_end:]

card_start = s.find('struct TodayRouteMapCard: View {')
card_end = s.find('\nprivate struct CrewCompanionPhase', card_start)
if card_end < 0:
    card_end = s.find('\nstruct TodayPersonalNoteDisclosure', card_start)
if card_start < 0 or card_end < 0:
    raise RuntimeError('Flight Companion reliability: Today map boundaries missing')
card = s[card_start:card_end]

# Stable sector key for local trail persistence. It intentionally contains only
# values already present locally in the roster and never leaves the device.
points_anchor = '    private var points: [TodayAirportMapPoint] {\n'
if points_anchor not in card:
    raise RuntimeError('Flight Companion reliability: map points anchor missing')
if 'private var trackingSessionKey:' not in card:
    helper = r'''    private var trackingSessionKey: String {
        let activity = item.flightActivities.first
        return [activity?.startUTC ?? "", activity?.endUTC ?? "", activity?.route ?? "", trackedAircraftRegistration ?? ""]
            .joined(separator: "|")
    }

'''
    card = card.replace(points_anchor, helper + points_anchor, 1)

# Do not start Location Services just because Today appeared. Configure the
# route/tail and load the saved trail; the user must press Start Live GPS.
auto = '''        .onAppear {\n            gps.configureAircraftTracking(registration: trackedAircraftRegistration)\n            gps.startIfAuthorized()\n        }\n        .onChange(of: trackedAircraftRegistration) { _, value in\n            gps.configureAircraftTracking(registration: value)\n        }'''
manual = '''        .onAppear {\n            gps.configureAircraftTracking(registration: trackedAircraftRegistration)\n            gps.configureTrailPersistence(sessionKey: trackingSessionKey)\n        }\n        .onChange(of: trackedAircraftRegistration) { _, value in\n            gps.configureAircraftTracking(registration: value)\n        }\n        .onChange(of: trackingSessionKey) { _, value in\n            gps.configureTrailPersistence(sessionKey: value)\n        }'''
if auto not in card:
    if manual not in card:
        raise RuntimeError('Flight Companion reliability: automatic-start anchor missing')
else:
    card = card.replace(auto, manual, 1)

# When tracking is active, expose an explicit Stop control in the same place as
# Start. This makes battery use entirely opt-in for each tracking session.
start_anchor = '''                    if !gps.isTracking {\n                        Button {\n                            gps.start()\n'''
stop_then_start = '''                    if gps.isTracking {\n                        Button {\n                            gps.stop()\n                        } label: {\n                            HStack(spacing: 7) {\n                                Image(systemName: "stop.circle.fill")\n                                Text("Stop Live Tracking")\n                                    .font(.subheadline.weight(.semibold))\n                            }\n                            .foregroundStyle(Color.orange)\n                            .padding(.horizontal, 12)\n                            .padding(.vertical, 9)\n                            .background(Color(uiColor: .systemBackground).opacity(0.94), in: Capsule())\n                        }\n                        .buttonStyle(.plain)\n                        .padding(.bottom, 12)\n                        .accessibilityLabel("Stop live flight tracking")\n                    } else {\n                        Button {\n                            gps.start()\n'''
if start_anchor not in card:
    if 'Stop Live Tracking' not in card:
        raise RuntimeError('Flight Companion reliability: Start Live GPS anchor missing')
else:
    card = card.replace(start_anchor, stop_then_start, 1)

s = s[:card_start] + card + s[card_end:]
s += '\n// Flight Companion manual persistent hybrid tracking\n'
CONTENT.write_text(s)
print('Flight Companion manual start, persistent trail, and multi-provider fallback applied')
