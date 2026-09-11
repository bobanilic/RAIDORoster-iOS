"""V2.23.0: multi-source public ADS-B, RAIDO-learned tails, and rotation-prioritized Fleet."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster/ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj/project.pbxproj"


def once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"Fleet V2 {label}: expected one anchor, found {count}: {old[:120]}")
    return text.replace(old, new, 1)


def replace_region(text: str, start: str, end: str, replacement: str, label: str) -> str:
    a = text.find(start)
    if a < 0:
        raise RuntimeError(f"Fleet V2 {label}: start anchor missing: {start}")
    b = text.find(end, a)
    if b < 0:
        raise RuntimeError(f"Fleet V2 {label}: end anchor missing: {end}")
    return text[:a] + replacement + text[b:]


content = CONTENT.read_text()
if "// Fleet V2 2.23.0" in content:
    raise RuntimeError("Run Fleet V2 on a clean checkout")

# -----------------------------------------------------------------------------
# Official public catalogue: current GetJet public fleet is 17 aircraft.
# Tails later seen in RAIDO are learned dynamically instead of pretending they
# are still in the public catalogue.
# -----------------------------------------------------------------------------
for obsolete in ["LY-FOX", "LY-TEN"]:
    line = f'        .init(registration: "{obsolete}", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),\n'
    if line not in content:
        raise RuntimeError(f"Fleet V2 official catalogue anchor missing for {obsolete}")
    content = content.replace(line, "", 1)

# Abu Dhabi is a recurrent ACMI rotation and must participate in nearest-airport
# / rotation context. DXB is useful as a nearby distinct UAE operation.
content = once(content,
'''        .init(code: "TLV", latitude: 32.0005, longitude: 34.8708),''',
'''        .init(code: "TLV", latitude: 32.0005, longitude: 34.8708),
        .init(code: "AUH", latitude: 24.4330, longitude: 54.6511),
        .init(code: "DXB", latitude: 25.2532, longitude: 55.3657),''',
"airport catalogue")

# Persist the source used for each observation. Optional/default keeps old cache
# decoding compatible and avoids changing older initializer call sites.
content = once(content,
'''    var verticalRateFeetPerMinute: Double? = nil
    var hasKnownGroundState: Bool''',
'''    var verticalRateFeetPerMinute: Double? = nil
    var providerName: String? = nil
    var hasKnownGroundState: Bool''',
"snapshot provider")

# A route-enriched snapshot is still the same provider observation.
content = content.replace(
'''                    verticalRateFeetPerMinute: old.verticalRateFeetPerMinute
''',
'''                    verticalRateFeetPerMinute: old.verticalRateFeetPerMinute,
                    providerName: old.providerName
''',
1,
)

# Refresh a dynamic list so RAIDO-learned/leased aircraft receive live data too.
content = once(content,
'''    func refresh() async {
        guard !isRefreshing, retryAfter.map({ Date() >= $0 }) ?? true else { return }''',
'''    func refresh(definitions: [FleetAircraftDefinition] = FleetAircraftDefinition.all) async {
        guard !isRefreshing, retryAfter.map({ Date() >= $0 }) ?? true else { return }''',
"refresh signature")
content = once(content,
'''        for definition in FleetAircraftDefinition.all {
            guard !Task.isCancelled else { return }''',
'''        for definition in definitions {
            guard !Task.isCancelled else { return }''',
"dynamic refresh loop")
content = once(content,
'''            errorText = failures == FleetAircraftDefinition.all.count
                ? "Live fleet data unavailable"''',
'''            errorText = failures == definitions.count
                ? "Live fleet data unavailable"''',
"dynamic failure count")

# -----------------------------------------------------------------------------
# Multi-provider observation layer.
# ADSB.lol remains primary. adsb.fi is the independent secondary. ADSB One is
# used only when the secondary itself fails, not merely because an aircraft is
# silent. This avoids hammering every public service for parked aircraft.
# -----------------------------------------------------------------------------
provider_support = r'''
private struct FleetProviderSpec {
    let name: String
    let baseURL: String
    let registrationPath: String
    let hexPath: String
}

private enum FleetProviderFetchResult {
    case snapshot(FleetLiveSnapshot)
    case empty
    case failed
}

'''
content = once(content,
'''@MainActor
private final class FleetLiveStore: ObservableObject {''',
provider_support + '''@MainActor
private final class FleetLiveStore: ObservableObject {''',
"provider support")

content = once(content,
'''    private var retryAfter: Date?''',
'''    private var retryAfter: Date?
    private var providerRetryAfter: [String: Date] = [:]''',
"provider cooldown state")

fetch_start = '    private func fetchAircraft(_ registration: String) async throws -> FleetLiveSnapshot? {'
fetch_end = '    private func fetchRoutes('
a = content.find(fetch_start)
b = content.find(fetch_end, a)
if a < 0 or b < 0:
    raise RuntimeError("Fleet V2 provider fetch boundaries missing")
new_fetch = r'''    private let primaryFleetProvider = FleetProviderSpec(
        name: "ADSB.lol", baseURL: "https://api.adsb.lol/v2",
        registrationPath: "reg", hexPath: "hex")
    private let secondaryFleetProvider = FleetProviderSpec(
        name: "adsb.fi", baseURL: "https://opendata.adsb.fi/api/v2",
        registrationPath: "registration", hexPath: "hex")
    private let tertiaryFleetProvider = FleetProviderSpec(
        name: "ADSB One", baseURL: "https://api.adsb.one/v2",
        registrationPath: "reg", hexPath: "icao")

    private func fetchAircraft(_ registration: String) async throws -> FleetLiveSnapshot? {
        let expectedHex = FleetTrackingPolicy.validHex(snapshots[registration]?.icaoHex)
        var lastKnown: FleetLiveSnapshot?

        func remember(_ value: FleetLiveSnapshot) {
            if lastKnown == nil || value.effectivePositionAge < lastKnown!.effectivePositionAge {
                lastKnown = value
            }
        }

        let primary = await fetchAircraft(registration, expectedHex: expectedHex, provider: primaryFleetProvider)
        try Task.checkCancellation()
        if case .snapshot(let value) = primary {
            if value.isFresh { return value }
            remember(value)
        }

        let secondary = await fetchAircraft(registration, expectedHex: expectedHex, provider: secondaryFleetProvider)
        try Task.checkCancellation()
        switch secondary {
        case .snapshot(let value):
            if value.isFresh { return value }
            remember(value)
            return lastKnown
        case .empty:
            // The secondary completed successfully. Retain any older observation
            // with its original timestamp; silence never implies AOG.
            return lastKnown
        case .failed:
            break
        }

        // Tertiary is outage resilience, not a normal third request for every
        // parked aircraft.
        let tertiary = await fetchAircraft(registration, expectedHex: expectedHex, provider: tertiaryFleetProvider)
        try Task.checkCancellation()
        switch tertiary {
        case .snapshot(let value):
            if value.isFresh { return value }
            remember(value)
            return lastKnown
        case .empty: return lastKnown
        case .failed:
            if let lastKnown { return lastKnown }
            if case .empty = primary { return nil }
            throw URLError(.cannotConnectToHost)
        }
    }

    private func fetchAircraft(_ registration: String, expectedHex: String?,
                               provider: FleetProviderSpec) async -> FleetProviderFetchResult {
        if let retry = providerRetryAfter[provider.name], Date() < retry { return .failed }

        let segment = expectedHex == nil ? provider.registrationPath : provider.hexPath
        let identity = expectedHex ?? registration
        guard let encoded = identity.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(provider.baseURL)/\(segment)/\(encoded)") else { return .failed }

        var request = URLRequest(url: url)
        request.timeoutInterval = 7
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("RAIDORoster/2.23.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            if http.statusCode == 429 {
                let delay = FleetTrackingPolicy.retryDelay(http.value(forHTTPHeaderField: "Retry-After"), now: Date())
                providerRetryAfter[provider.name] = Date().addingTimeInterval(delay)
                return .failed
            }
            guard (200..<300).contains(http.statusCode) else { return .failed }

            let result = try decoder.decode(ADSBLOLResponse.self, from: data)
            guard !result.ac.isEmpty else { return .empty }
            guard let aircraft = result.ac.first(where: {
                FleetTrackingPolicy.matches(registration: $0.registration, hex: $0.hex,
                                            requested: registration, expectedHex: expectedHex)
            }) else { return .failed }

            let receivedAt = Date()
            let referenceAt = FleetTrackingPolicy.sourceDate(epoch: result.now, receivedAt: receivedAt)
            let hasPosition = FleetTrackingPolicy.validCoordinate(latitude: aircraft.lat, longitude: aircraft.lon)
            let snapshot = FleetLiveSnapshot(
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
                verticalRateFeetPerMinute: aircraft.verticalRate,
                providerName: provider.name
            )
            return .snapshot(snapshot)
        } catch is CancellationError {
            return .failed
        } catch {
            return .failed
        }
    }

'''
content = content[:a] + new_fetch + content[b:]

# -----------------------------------------------------------------------------
# Fleet screen: merge current public catalogue with tails actually seen in
# RAIDO, infer the current rotation from roster evidence, and prioritize the
# aircraft that matter to the crew member before the full fleet.
# -----------------------------------------------------------------------------
fleet_start = 'struct FleetView: View {'
fleet_end = 'private func fleetDuration'
a = content.find(fleet_start)
b = content.find(fleet_end, a)
if a < 0 or b < 0:
    raise RuntimeError("Fleet V2 FleetView boundaries missing")

fleet_view = r'''struct FleetView: View {
    @ObservedObject var store: RosterStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var live = FleetLiveStore()
    @State private var query = ""
    @State private var filter: FleetFilter = .all
    @State private var selectedAircraft: FleetAircraftDefinition?

    private var currentDutyRegistrations: Set<String> {
        let rows = store.todayItems + (store.nextDuty.map { [$0] } ?? [])
        return Set(rows.flatMap(\.aircraft).map { normalizedRegistration($0.aircraftReg) }.filter { !$0.isEmpty })
    }

    private var rosterLearnedAircraft: [FleetAircraftDefinition] {
        var known = Set(FleetAircraftDefinition.all.map { normalizedRegistration($0.registration) })
        var learned: [FleetAircraftDefinition] = []
        for activity in store.items.flatMap(\.flightActivities) {
            let registration = activity.aircraftReg.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let key = normalizedRegistration(registration)
            guard !key.isEmpty, !known.contains(key) else { continue }
            known.insert(key)
            let rawType = activity.aircraftType.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let type: String
            if rawType.isEmpty { type = "Aircraft" }
            else if rawType.hasPrefix("A") || rawType.hasPrefix("B") { type = rawType }
            else if rawType.count == 3 && rawType.allSatisfy(\.isNumber) { type = "A" + rawType }
            else { type = rawType }
            learned.append(.init(registration: registration, type: type,
                                 operatorName: "RAIDO aircraft", operatorCode: "ROSTER", seats: ""))
        }
        return learned.sorted { $0.registration < $1.registration }
    }

    private var allAircraft: [FleetAircraftDefinition] {
        FleetAircraftDefinition.all + rosterLearnedAircraft
    }

    private var rotationAirport: String? {
        let routes = store.items.flatMap(\.flightActivities).map(\.route).filter { !$0.isEmpty }
        let stations = store.items.flatMap(\.activityList).map(\.station).filter { !$0.isEmpty }
        let preferredRows = store.todayItems + (store.nextDuty.map { [$0] } ?? [])
        let preferred = preferredRows.flatMap(\.activityList).map(\.station).filter { !$0.isEmpty }
        return FleetTrackingPolicy.dominantRotationAirport(
            routes: routes, stations: stations, preferredAirports: preferred)
    }

    private var rosterRotationRegistrations: Set<String> {
        guard let airport = rotationAirport else { return [] }
        var registrations = Set<String>()
        for row in store.items {
            for activity in row.flightActivities {
                guard FleetTrackingPolicy.rotationRelation(route: activity.route, airport: airport) != .unrelated else { continue }
                let key = normalizedRegistration(activity.aircraftReg)
                if !key.isEmpty { registrations.insert(key) }
            }
        }
        return registrations
    }

    private var filteredAircraft: [FleetAircraftDefinition] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allAircraft.filter { aircraft in
            let operatorMatches: Bool
            switch filter {
            case .all: operatorMatches = true
            case .getjet: operatorMatches = aircraft.operatorCode == "GETJET"
            case .airhub: operatorMatches = aircraft.operatorCode == "AIRHUB"
            }
            guard operatorMatches else { return false }
            return needle.isEmpty || [aircraft.registration, aircraft.type, aircraft.operatorName]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var refreshAircraft: [FleetAircraftDefinition] {
        allAircraft.sorted { lhs, rhs in
            let l = fleetPriority(lhs)
            let r = fleetPriority(rhs)
            if l != r { return l < r }
            return lhs.registration < rhs.registration
        }
    }

    private var assignedAircraft: [FleetAircraftDefinition] {
        filteredAircraft.filter { currentDutyRegistrations.contains(normalizedRegistration($0.registration)) }
    }

    private var rotationAircraft: [FleetAircraftDefinition] {
        guard rotationAirport != nil else { return [] }
        return filteredAircraft.filter {
            !currentDutyRegistrations.contains(normalizedRegistration($0.registration)) && isRotationRelevant($0)
        }.sorted { lhs, rhs in
            let l = fleetPriority(lhs)
            let r = fleetPriority(rhs)
            if l != r { return l < r }
            return lhs.registration < rhs.registration
        }
    }

    private var remainingAircraft: [FleetAircraftDefinition] {
        let used = Set((assignedAircraft + rotationAircraft).map { normalizedRegistration($0.registration) })
        return filteredAircraft.filter { !used.contains(normalizedRegistration($0.registration)) }
            .sorted { lhs, rhs in
                let leftLive = live.snapshot(for: lhs.registration).map { $0.isFresh && $0.isAirborne } == true
                let rightLive = live.snapshot(for: rhs.registration).map { $0.isFresh && $0.isAirborne } == true
                if leftLive != rightLive { return leftLive }
                let leftAge = live.snapshot(for: lhs.registration)?.effectivePositionAge ?? .infinity
                let rightAge = live.snapshot(for: rhs.registration)?.effectivePositionAge ?? .infinity
                if leftAge != rightAge { return leftAge < rightAge }
                return lhs.registration < rhs.registration
            }
    }

    private func isRotationRelevant(_ aircraft: FleetAircraftDefinition) -> Bool {
        guard let airport = rotationAirport else { return false }
        let key = normalizedRegistration(aircraft.registration)
        if rosterRotationRegistrations.contains(key) { return true }
        if let intelligence = live.intelligence(for: aircraft.registration) {
            if intelligence.nearestAirport == airport { return true }
            if let route = intelligence.currentRoute,
               FleetTrackingPolicy.rotationRelation(route: route, airport: airport) != .unrelated { return true }
            if let route = intelligence.previousRoute,
               FleetTrackingPolicy.rotationRelation(route: route, airport: airport) != .unrelated { return true }
        }
        return false
    }

    private func fleetPriority(_ aircraft: FleetAircraftDefinition) -> Int {
        let key = normalizedRegistration(aircraft.registration)
        if currentDutyRegistrations.contains(key) { return 0 }
        guard let airport = rotationAirport else {
            return live.snapshot(for: aircraft.registration).map { $0.isFresh && $0.isAirborne } == true ? 20 : 30
        }
        let intelligence = live.intelligence(for: aircraft.registration)
        if live.snapshot(for: aircraft.registration).map({ $0.isFresh && $0.isAirborne }) == true,
           let route = intelligence?.currentRoute {
            switch FleetTrackingPolicy.rotationRelation(route: route, airport: airport) {
            case .inbound: return 1
            case .outbound: return 3
            case .touches: return 4
            case .unrelated: break
            }
        }
        if live.snapshot(for: aircraft.registration)?.isFresh == true,
           live.snapshot(for: aircraft.registration)?.onGround == true,
           intelligence?.nearestAirport == airport { return 2 }
        if intelligence?.nearestAirport == airport { return 4 }
        if rosterRotationRegistrations.contains(key) { return 5 }
        return live.snapshot(for: aircraft.registration).map { $0.isFresh && $0.isAirborne } == true ? 20 : 30
    }

    private func rotationContext(_ aircraft: FleetAircraftDefinition) -> String? {
        guard let airport = rotationAirport else { return nil }
        let intelligence = live.intelligence(for: aircraft.registration)
        let snapshot = live.snapshot(for: aircraft.registration)
        if let route = intelligence?.currentRoute,
           let label = FleetTrackingPolicy.rotationRouteLabel(route: route, airport: airport,
                isFresh: snapshot?.isFresh == true, isAirborne: snapshot?.isAirborne == true) {
            return label
        }
        if live.snapshot(for: aircraft.registration)?.isFresh == true,
           live.snapshot(for: aircraft.registration)?.onGround == true,
           intelligence?.nearestAirport == airport { return "On ground · \(airport)" }
        if intelligence?.nearestAirport == airport { return "Last seen near \(airport)" }
        if rosterRotationRegistrations.contains(normalizedRegistration(aircraft.registration)) {
            return "Used on your \(airport) rotation"
        }
        return nil
    }

    private var rotationTitle: String? {
        guard let airport = rotationAirport else { return nil }
        let names = ["TLV": "Tel Aviv", "AUH": "Abu Dhabi", "BEG": "Belgrade",
                     "VNO": "Vilnius", "RIX": "Riga", "LCA": "Larnaca"]
        if let name = names[airport] { return "INFERRED ROTATION · \(name) · \(airport)" }
        return "INFERRED ROTATION · \(airport)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Fleet", selection: $filter) {
                        ForEach(FleetFilter.allCases) { value in Text(value.rawValue).tag(value) }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)

                if !assignedAircraft.isEmpty {
                    Section("YOUR CURRENT / NEXT AIRCRAFT") {
                        ForEach(assignedAircraft) { aircraft in
                            FleetAircraftRow(aircraft: aircraft,
                                snapshot: live.snapshot(for: aircraft.registration), isAssigned: true,
                                contextText: { rotationContext(aircraft) })
                                .contentShape(Rectangle())
                                .onTapGesture { selectedAircraft = aircraft }
                        }
                    }
                }

                if let rotationTitle, !rotationAircraft.isEmpty {
                    Section(rotationTitle) {
                        ForEach(rotationAircraft) { aircraft in
                            FleetAircraftRow(aircraft: aircraft,
                                snapshot: live.snapshot(for: aircraft.registration), isAssigned: false,
                                contextText: { rotationContext(aircraft) })
                                .contentShape(Rectangle())
                                .onTapGesture { selectedAircraft = aircraft }
                        }
                    }
                }

                if remainingAircraft.isEmpty && assignedAircraft.isEmpty && rotationAircraft.isEmpty {
                    ContentUnavailableView.search(text: query)
                }

                if !remainingAircraft.isEmpty {
                    Section("GETJET / AIRHUB FLEET") {
                        ForEach(remainingAircraft) { aircraft in
                            FleetAircraftRow(aircraft: aircraft,
                                snapshot: live.snapshot(for: aircraft.registration), isAssigned: false)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedAircraft = aircraft }
                        }
                    }
                }

                if let error = live.errorText {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Text("Live position uses independent public ADS-B networks (ADSB.lol, adsb.fi, with outage fallback). Public ADS-B can be incomplete, delayed or unavailable. Routes and rotation relevance are inferred from public signals and your saved RAIDO roster. AOG, serviceability and standby activation are never inferred; RAIDO / Crew Control remain authoritative for operational status.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, prompt: "Registration or aircraft type")
            .navigationTitle("Fleet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await live.refresh(definitions: refreshAircraft) } } label: {
                        if live.isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(live.isRefreshing)
                    .accessibilityLabel("Refresh fleet")
                }
            }
            .sheet(item: $selectedAircraft) { aircraft in
                FleetAircraftDetailView(aircraft: aircraft, live: live,
                    isAssigned: currentDutyRegistrations.contains(normalizedRegistration(aircraft.registration)))
            }
            .task(id: allAircraft.map(\.registration).sorted().joined(separator: "|")) {
                await live.refresh(definitions: refreshAircraft)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch { return }
                    await live.refresh(definitions: refreshAircraft)
                }
            }
        }
    }
}

'''
content = content[:a] + fleet_view + content[b:]

# Rotation rows get one extra operationally useful line without changing the
# normal all-fleet rows.
content = once(content,
'''    let isAssigned: Bool

    private var status:''',
'''    let isAssigned: Bool
    var contextText: (() -> String?)? = nil

    private var status:''',
"row context property")
content = once(content,
'''                    Text(snapshot.map { "Position " + fleetCompactAge($0.effectivePositionAge) } ?? "No recent position received")
                        .font(.caption).foregroundStyle(.secondary)''',
'''                    if let contextText = contextText?(), !contextText.isEmpty {
                        Text(contextText).font(.caption.weight(.medium)).foregroundStyle(MidnightTheme.accent)
                    }
                    Text(snapshot.map { "Position " + fleetCompactAge($0.effectivePositionAge) } ?? "No recent position received")
                        .font(.caption).foregroundStyle(.secondary)''',
"row context UI")

# Detail screen shows which public network supplied the accepted observation.
content = content.replace(
'''Text("Position \\(fleetCompactAge(snapshot.effectivePositionAge)) • public ADS-B")''',
'''Text("Position \\(fleetCompactAge(snapshot.effectivePositionAge)) • \\(snapshot.providerName ?? "public ADS-B")")''',
1,
)

# Marker/version. Later patches already produced 2.22.0; Fleet V2 is a major
# functional revision but leaves previous features intact.
content += "\n// Fleet V2 2.23.0\n"
content = content.replace("2.22.0", "2.23.0")
CONTENT.write_text(content)

pbx = PBX.read_text().replace("MARKETING_VERSION = 2.22.0;", "MARKETING_VERSION = 2.23.0;")
PBX.write_text(pbx)

print("V2.23.0 multi-source rotation-prioritized Fleet integrated")
