from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.17 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# Keep operator inference strict: the Airhub aircraft is 9H-GTS, not an
# arbitrary registration ending in GTS.
content = content.replace(
    'if compact == "9HGTS" || compact == "GTS" { return .airhub }',
    'if compact == "9HGTS" { return .airhub }',
    1,
)

fleet_support = r'''
private struct FleetAircraftDefinition: Identifiable, Hashable {
    let registration: String
    let type: String
    let operatorName: String
    let operatorCode: String
    let seats: String

    var id: String { registration }

    static let all: [FleetAircraftDefinition] = [
        .init(registration: "LY-NOW", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-GYM", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-FAS", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-WIL", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-MAL", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-WIZ", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-CAP", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-TAP", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-EKB", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-DAE", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-WSA", type: "A321", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "220Y"),
        .init(registration: "LY-UNO", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-DUE", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-CIN", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-TUI", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-SEI", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "9H-GTS", type: "A320", operatorName: "Airhub Airlines", operatorCode: "AIRHUB", seats: "180Y")
    ]
}

private struct FleetLiveSnapshot: Codable, Identifiable {
    let registration: String
    let callsign: String?
    let route: String?
    let latitude: Double?
    let longitude: Double?
    let altitudeFeet: Double?
    let groundSpeedKnots: Double?
    let trackDegrees: Double?
    let onGround: Bool
    let sourceSeenSeconds: Double
    let fetchedAt: Date

    var id: String { registration }

    var hasPosition: Bool { latitude != nil && longitude != nil }

    var isAirborne: Bool {
        guard !onGround else { return false }
        if let altitudeFeet, altitudeFeet > 800 { return true }
        if let groundSpeedKnots, groundSpeedKnots > 80 { return true }
        return false
    }
}

private struct ADSBLOLResponse: Decodable {
    let ac: [ADSBLOLAircraft]
}

private struct ADSBLOLAircraft: Decodable {
    let flight: String?
    let lat: Double?
    let lon: Double?
    let gs: Double?
    let track: Double?
    let seen: Double
    let altitudeFeet: Double?
    let onGround: Bool

    enum CodingKeys: String, CodingKey {
        case flight, lat, lon, gs, track, seen
        case altBaro = "alt_baro"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        flight = try container.decodeIfPresent(String.self, forKey: .flight)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lat = try container.decodeIfPresent(Double.self, forKey: .lat)
        lon = try container.decodeIfPresent(Double.self, forKey: .lon)
        gs = try container.decodeIfPresent(Double.self, forKey: .gs)
        track = try container.decodeIfPresent(Double.self, forKey: .track)
        seen = (try? container.decode(Double.self, forKey: .seen)) ?? 0

        if let numeric = try? container.decode(Double.self, forKey: .altBaro) {
            altitudeFeet = numeric
            onGround = false
        } else if let value = try? container.decode(String.self, forKey: .altBaro) {
            altitudeFeet = nil
            onGround = value.lowercased() == "ground"
        } else {
            altitudeFeet = nil
            onGround = false
        }
    }
}

private struct ADSBLOLRouteRequest: Encodable {
    struct Plane: Encodable {
        let callsign: String
        let lat: Double
        let lng: Double
    }
    let planes: [Plane]
}

private struct ADSBLOLRouteResult: Decodable {
    let callsign: String
    let airportCodes: String?
    let plausible: Bool?

    enum CodingKeys: String, CodingKey {
        case callsign
        case airportCodes = "airport_codes"
        case plausible
    }
}

@MainActor
private final class FleetLiveStore: ObservableObject {
    @Published private(set) var snapshots: [String: FleetLiveSnapshot] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var errorText: String?
    @Published private(set) var completedCount = 0

    private let cacheKey = "RAIDORoster.FleetLiveCache.V1"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init() {
        loadCache()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        completedCount = 0
        errorText = nil
        defer { isRefreshing = false }

        var fresh: [String: FleetLiveSnapshot] = [:]
        var activeForRoutes: [(registration: String, callsign: String, lat: Double, lon: Double)] = []
        var failures = 0

        for definition in FleetAircraftDefinition.all {
            do {
                if let snapshot = try await fetchAircraft(definition.registration) {
                    fresh[definition.registration] = snapshot
                    if let callsign = snapshot.callsign,
                       let lat = snapshot.latitude,
                       let lon = snapshot.longitude,
                       !callsign.isEmpty {
                        activeForRoutes.append((definition.registration, callsign, lat, lon))
                    }
                }
            } catch {
                failures += 1
            }
            completedCount += 1
        }

        if !activeForRoutes.isEmpty,
           let routes = try? await fetchRoutes(activeForRoutes) {
            for (registration, route) in routes {
                guard let old = fresh[registration] else { continue }
                fresh[registration] = FleetLiveSnapshot(
                    registration: old.registration,
                    callsign: old.callsign,
                    route: route,
                    latitude: old.latitude,
                    longitude: old.longitude,
                    altitudeFeet: old.altitudeFeet,
                    groundSpeedKnots: old.groundSpeedKnots,
                    trackDegrees: old.trackDegrees,
                    onGround: old.onGround,
                    sourceSeenSeconds: old.sourceSeenSeconds,
                    fetchedAt: old.fetchedAt
                )
            }
        }

        // Preserve a previous observation for aircraft that are not currently
        // visible to ADS-B, but never make it look live: the UI marks its age.
        var merged = snapshots
        for (registration, snapshot) in fresh {
            merged[registration] = snapshot
        }
        snapshots = merged
        lastRefresh = Date()
        saveCache()

        if failures > 0 {
            errorText = failures == FleetAircraftDefinition.all.count
                ? "Live fleet data unavailable"
                : "Some aircraft could not be refreshed"
        }
    }

    func snapshot(for registration: String) -> FleetLiveSnapshot? {
        snapshots[registration]
    }

    private func fetchAircraft(_ registration: String) async throws -> FleetLiveSnapshot? {
        let encoded = registration.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? registration
        guard let url = URL(string: "https://api.adsb.lol/v2/reg/\(encoded)") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("RAIDORoster/2.17", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }

        let result = try decoder.decode(ADSBLOLResponse.self, from: data)
        guard let aircraft = result.ac.first else { return nil }

        return FleetLiveSnapshot(
            registration: registration,
            callsign: aircraft.flight?.isEmpty == false ? aircraft.flight : nil,
            route: nil,
            latitude: aircraft.lat,
            longitude: aircraft.lon,
            altitudeFeet: aircraft.altitudeFeet,
            groundSpeedKnots: aircraft.gs,
            trackDegrees: aircraft.track,
            onGround: aircraft.onGround,
            sourceSeenSeconds: aircraft.seen,
            fetchedAt: Date()
        )
    }

    private func fetchRoutes(
        _ aircraft: [(registration: String, callsign: String, lat: Double, lon: Double)]
    ) async throws -> [String: String] {
        guard let url = URL(string: "https://api.adsb.lol/api/0/routeset") else { return [:] }
        let body = ADSBLOLRouteRequest(planes: aircraft.map {
            .init(callsign: $0.callsign, lat: $0.lat, lng: $0.lon)
        })

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("RAIDORoster/2.17", forHTTPHeaderField: "User-Agent")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return [:] }

        let results = try decoder.decode([ADSBLOLRouteResult].self, from: data)
        var byCallsign: [String: String] = [:]
        for result in results {
            guard result.plausible != false,
                  let route = result.airportCodes,
                  !route.isEmpty,
                  route.lowercased() != "unknown" else { continue }
            byCallsign[result.callsign.trimmingCharacters(in: .whitespacesAndNewlines)] = route
        }

        var output: [String: String] = [:]
        for item in aircraft {
            if let route = byCallsign[item.callsign.trimmingCharacters(in: .whitespacesAndNewlines)] {
                output[item.registration] = route
            }
        }
        return output
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let values = try? decoder.decode([FleetLiveSnapshot].self, from: data) else { return }
        snapshots = Dictionary(uniqueKeysWithValues: values.map { ($0.registration, $0) })
        lastRefresh = values.map(\.fetchedAt).max()
    }

    private func saveCache() {
        let values = Array(snapshots.values)
        guard let data = try? encoder.encode(values) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}

private enum FleetFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case getjet = "GetJet"
    case airhub = "Airhub"
    var id: String { rawValue }
}

struct FleetView: View {
    @ObservedObject var store: RosterStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var live = FleetLiveStore()
    @State private var filter: FleetFilter = .all
    @State private var selectedAircraft: FleetAircraftDefinition?

    private var currentDutyRegistrations: Set<String> {
        let items = store.todayItems + (store.nextDuty.map { [$0] } ?? [])
        return Set(items.flatMap(\.aircraft).map {
            normalizedRegistration($0.aircraftReg)
        }.filter { !$0.isEmpty })
    }

    private var visibleAircraft: [FleetAircraftDefinition] {
        let filtered = FleetAircraftDefinition.all.filter { aircraft in
            switch filter {
            case .all: return true
            case .getjet: return aircraft.operatorCode == "GETJET"
            case .airhub: return aircraft.operatorCode == "AIRHUB"
            }
        }

        return filtered.sorted { lhs, rhs in
            let lhsMine = currentDutyRegistrations.contains(normalizedRegistration(lhs.registration))
            let rhsMine = currentDutyRegistrations.contains(normalizedRegistration(rhs.registration))
            if lhsMine != rhsMine { return lhsMine }

            let lhsAirborne = live.snapshot(for: lhs.registration)?.isAirborne == true
            let rhsAirborne = live.snapshot(for: rhs.registration)?.isAirborne == true
            if lhsAirborne != rhsAirborne { return lhsAirborne }
            return lhs.registration < rhs.registration
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Fleet", selection: $filter) {
                        ForEach(FleetFilter.allCases) { value in
                            Text(value.rawValue).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)

                if let assigned = visibleAircraft.first(where: {
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
                }

                Section("GETJET / AIRHUB FLEET") {
                    ForEach(visibleAircraft.filter {
                        !currentDutyRegistrations.contains(normalizedRegistration($0.registration))
                    }) { aircraft in
                        FleetAircraftRow(
                            aircraft: aircraft,
                            snapshot: live.snapshot(for: aircraft.registration),
                            isAssigned: false
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { selectedAircraft = aircraft }
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Live position data: ADSB.lol (ODbL). Public ADS-B can be incomplete, delayed or unavailable. Route data is inferred from callsign standing data when available.")
                        Text("Fleet V1 does not claim operational delay unless a reliable schedule source is available. Always use RAIDO / Crew Control as the operational authority.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Fleet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await live.refresh() }
                    } label: {
                        if live.isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(live.isRefreshing)
                    .accessibilityLabel("Refresh fleet")
                }
            }
            .overlay(alignment: .bottom) {
                if live.isRefreshing {
                    Text("Updating fleet \(live.completedCount)/\(FleetAircraftDefinition.all.count)")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 8)
                }
            }
            .refreshable {
                await live.refresh()
            }
            .sheet(item: $selectedAircraft) { aircraft in
                FleetAircraftDetailView(
                    aircraft: aircraft,
                    snapshot: live.snapshot(for: aircraft.registration),
                    isAssigned: currentDutyRegistrations.contains(normalizedRegistration(aircraft.registration))
                )
            }
            .task {
                await live.refresh()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(120))
                    guard !Task.isCancelled else { break }
                    await live.refresh()
                }
            }
        }
    }

    private func normalizedRegistration(_ value: String) -> String {
        value.uppercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct FleetAircraftRow: View {
    let aircraft: FleetAircraftDefinition
    let snapshot: FleetLiveSnapshot?
    let isAssigned: Bool

    private var status: (String, Color) {
        guard let snapshot else { return ("Not tracked", .secondary) }
        let age = Date().timeIntervalSince(snapshot.fetchedAt)
        if age > 300 { return ("Cached", .orange) }
        if snapshot.isAirborne { return ("Airborne", .green) }
        if snapshot.onGround { return ("Ground", .blue) }
        return ("Tracked", .blue)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.10))
                    .frame(width: 58, height: 58)
                Image(systemName: aircraft.type.hasPrefix("B") ? "airplane" : "airplane")
                    .font(.system(size: 25, weight: .semibold))
                    .rotationEffect(.degrees(-20))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(aircraft.registration)
                        .font(.headline.monospaced())
                    if isAssigned {
                        Text("YOUR DUTY")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.10), in: Capsule())
                    }
                }

                Text("\(aircraft.operatorName) • \(aircraft.type) • \(aircraft.seats)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let snapshot {
                    HStack(spacing: 6) {
                        if let callsign = snapshot.callsign { Text(callsign).font(.caption.monospaced()) }
                        if let route = snapshot.route { Text(route).font(.caption.weight(.semibold)) }
                    }
                    .lineLimit(1)
                }
            }

            Spacer(minLength: 5)

            VStack(alignment: .trailing, spacing: 5) {
                Text(status.0)
                    .font(.caption.bold())
                    .foregroundStyle(status.1)

                if let speed = snapshot?.groundSpeedKnots, snapshot?.isAirborne == true {
                    Text("\(Int(speed.rounded())) kt")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct FleetAircraftDetailView: View {
    let aircraft: FleetAircraftDefinition
    let snapshot: FleetLiveSnapshot?
    let isAssigned: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.secondary.opacity(0.18), Color.secondary.opacity(0.06)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(height: 170)

                        Image(systemName: "airplane")
                            .font(.system(size: 78, weight: .light))
                            .rotationEffect(.degrees(-18))
                            .foregroundStyle(.secondary.opacity(0.55))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(aircraft.registration)
                                .font(.title.bold().monospaced())
                            Text("\(aircraft.operatorName) • \(aircraft.type)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                    }

                    if isAssigned {
                        Label("Assigned to your current / next rostered duty", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let snapshot {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(snapshot.isAirborne ? "AIRBORNE" : (snapshot.onGround ? "GROUND" : "TRACKED"))
                                        .font(.caption.bold())
                                        .foregroundStyle(snapshot.isAirborne ? .green : .blue)
                                    Text(snapshot.callsign ?? "No callsign")
                                        .font(.title3.weight(.semibold).monospaced())
                                }
                                Spacer()
                                if let route = snapshot.route {
                                    Text(route)
                                        .font(.headline.monospaced())
                                }
                            }

                            if let lat = snapshot.latitude, let lon = snapshot.longitude {
                                Map(initialPosition: .region(MKCoordinateRegion(
                                    center: .init(latitude: lat, longitude: lon),
                                    latitudinalMeters: snapshot.isAirborne ? 700_000 : 80_000,
                                    longitudinalMeters: snapshot.isAirborne ? 700_000 : 80_000
                                )), interactionModes: [.pan, .zoom]) {
                                    Annotation(aircraft.registration, coordinate: .init(latitude: lat, longitude: lon)) {
                                        Image(systemName: "airplane")
                                            .font(.title2.bold())
                                            .foregroundStyle(.green)
                                            .rotationEffect(.degrees((snapshot.trackDegrees ?? 70) - 90))
                                    }
                                }
                                .mapStyle(.standard)
                                .frame(height: 210)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                            }

                            HStack(spacing: 0) {
                                FleetMetric(title: "Altitude", value: snapshot.altitudeFeet.map { "\(Int($0.rounded()).formatted()) ft" } ?? "—")
                                Divider().frame(height: 34)
                                FleetMetric(title: "Ground speed", value: snapshot.groundSpeedKnots.map { "\(Int($0.rounded())) kt" } ?? "—")
                                Divider().frame(height: 34)
                                FleetMetric(title: "Track", value: snapshot.trackDegrees.map { "\(Int($0.rounded()))°" } ?? "—")
                            }

                            Text("Last live observation \(fleetAge(snapshot))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                    } else {
                        ContentUnavailableView(
                            "Aircraft not currently tracked",
                            systemImage: "antenna.radiowaves.left.and.right.slash",
                            description: Text("Public ADS-B coverage may be unavailable while the aircraft is parked, out of coverage, or not broadcasting a usable position.")
                        )
                        .frame(minHeight: 180)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Aircraft", value: aircraft.type)
                        LabeledContent("Cabin", value: aircraft.seats)
                        LabeledContent("Operator", value: aircraft.operatorName)
                        LabeledContent("Registration", value: aircraft.registration)
                    }
                    .font(.subheadline)
                    .padding(14)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))

                    Text("Public tracking is situational awareness only. ADS-B does not provide an authoritative GetJet/Airhub operational delay. Confirm roster, aircraft assignment and operational changes in RAIDO or with Crew Control.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle("Aircraft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func fleetAge(_ snapshot: FleetLiveSnapshot) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(snapshot.fetchedAt) + snapshot.sourceSeenSeconds))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}

private struct FleetMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

'''

if "struct FleetView: View" not in content:
    content = replace_once(
        content,
        "struct SettingsView: View {\n",
        fleet_support + "struct SettingsView: View {\n",
        "Fleet V1 components",
    )

# Primary Fleet access: Today toolbar, beside Calendar and Crew Control. This
# preserves the established four-tab navigation while keeping Fleet one tap away.
content = replace_once(
    content,
    '''    @State private var showCrewControl = false\n''',
    '''    @State private var showCrewControl = false\n    @State private var showFleet = false\n''',
    "Today Fleet state",
)

content = replace_once(
    content,
    '''                    Button { showCrewControl = true } label: {\n                        Image(systemName: "message.fill")\n                    }\n                    .accessibilityLabel("Crew Control")\n''',
    '''                    Button { showFleet = true } label: {\n                        Image(systemName: "airplane.circle.fill")\n                    }\n                    .accessibilityLabel("Fleet")\n\n                    Button { showCrewControl = true } label: {\n                        Image(systemName: "message.fill")\n                    }\n                    .accessibilityLabel("Crew Control")\n''',
    "Today Fleet toolbar",
)

content = replace_once(
    content,
    '''            .sheet(isPresented: $showCrewControl) {\n                CrewControlSheet(item: store.todayItems.first ?? store.nextDuty)\n            }\n''',
    '''            .sheet(isPresented: $showCrewControl) {\n                CrewControlSheet(item: store.todayItems.first ?? store.nextDuty)\n            }\n            .sheet(isPresented: $showFleet) {\n                FleetView(store: store)\n            }\n''',
    "Today Fleet sheet",
)

# Secondary Fleet access from Settings.
settings_start = content.find("struct SettingsView: View {")
settings_text = content[settings_start:] if settings_start >= 0 else ""
if "@State private var showFleet = false" not in settings_text:
    content = replace_once(
        content,
        '''    @State private var showCrewControl = false\n''',
        '''    @State private var showCrewControl = false\n    @State private var showFleet = false\n''',
        "Settings Fleet state",
    )

fleet_settings = '''                Section("Fleet") {\n                    Button {\n                        showFleet = true\n                    } label: {\n                        HStack {\n                            Label("GetJet / Airhub Fleet", systemImage: "airplane.circle.fill")\n                            Spacer()\n                            Text("Live")\n                                .foregroundStyle(.secondary)\n                        }\n                    }\n                    .buttonStyle(.plain)\n\n                    Text("Public live ADS-B tracking with cached last-known status. Operational authority remains RAIDO / Crew Control.")\n                        .font(.footnote)\n                        .foregroundStyle(.secondary)\n                }\n\n'''
if 'Section("Fleet")' not in content:
    content = replace_once(
        content,
        '                Section("Units") {\n',
        fleet_settings + '                Section("Units") {\n',
        "Settings Fleet section",
    )

# The Crew Control settings sheet is the final modifier added by V2.9; append
# Fleet there as well. Only touch the Settings occurrence by operating on tail.
settings_start = content.find("struct SettingsView: View {")
if settings_start >= 0:
    head = content[:settings_start]
    tail = content[settings_start:]
    marker = '''            .sheet(isPresented: $showCrewControl) {\n                CrewControlSheet(item: store.todayItems.first ?? store.nextDuty)\n            }\n'''
    replacement = '''            .sheet(isPresented: $showCrewControl) {\n                CrewControlSheet(item: store.todayItems.first ?? store.nextDuty)\n            }\n            .sheet(isPresented: $showFleet) {\n                FleetView(store: store)\n            }\n'''
    if replacement not in tail:
        if marker not in tail:
            raise RuntimeError("V2.17 patch marker not found: Settings Fleet sheet")
        tail = tail.replace(marker, replacement, 1)
    content = head + tail

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.16.1")',
    'LabeledContent("RAIDO Roster", value: "2.17")',
    1,
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 35;", "CURRENT_PROJECT_VERSION = 36;")
pbx = pbx.replace("MARKETING_VERSION = 2.16.1;", "MARKETING_VERSION = 2.17;")
PBX.write_text(pbx)

print("V2.17 Fleet V1 public live ADS-B tracking applied")
