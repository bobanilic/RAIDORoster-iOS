import Foundation
import Combine

private struct ADSBLOLResponse: Decodable {
    let ac: [ADSBLOLAircraft]
    let now: Double?
}

private enum FleetProviderError: Error {
    case http(Int)
    case rateLimited(TimeInterval)
    case identityMismatch
}

private struct ADSBLOLAircraft: Decodable {
    let registration: String?
    let verticalRate: Double?
    let groundStateKnown: Bool
    let hex: String?
    let flight: String?
    let lat: Double?
    let lon: Double?
    let gs: Double?
    let track: Double?
    let seen: Double
    let seenPos: Double?
    let nacP: Int?
    let nic: Int?
    let rc: Double?
    let altitudeFeet: Double?
    let onGround: Bool

    enum CodingKeys: String, CodingKey {
        case hex, flight, lat, lon, gs, track, seen, nic, rc
        case registration = "r"
        case verticalRate = "baro_rate"
        case seenPos = "seen_pos"
        case nacP = "nac_p"
        case altBaro = "alt_baro"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        registration = try? container.decodeIfPresent(String.self, forKey: .registration)
        verticalRate = try? container.decodeIfPresent(Double.self, forKey: .verticalRate)
        hex = try? container.decodeIfPresent(String.self, forKey: .hex)
        flight = try container.decodeIfPresent(String.self, forKey: .flight)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lat = try container.decodeIfPresent(Double.self, forKey: .lat)
        lon = try container.decodeIfPresent(Double.self, forKey: .lon)
        gs = try container.decodeIfPresent(Double.self, forKey: .gs)
        track = try container.decodeIfPresent(Double.self, forKey: .track)
        seen = (try? container.decode(Double.self, forKey: .seen)) ?? 31_536_000
        seenPos = try? container.decodeIfPresent(Double.self, forKey: .seenPos)
        nacP = try? container.decodeIfPresent(Int.self, forKey: .nacP)
        nic = try? container.decodeIfPresent(Int.self, forKey: .nic)
        rc = try? container.decodeIfPresent(Double.self, forKey: .rc)

        if let numeric = try? container.decode(Double.self, forKey: .altBaro) {
            altitudeFeet = numeric.isFinite ? numeric : nil
            groundStateKnown = numeric.isFinite
            onGround = false
        } else if let value = try? container.decode(String.self, forKey: .altBaro) {
            altitudeFeet = nil
            onGround = value.lowercased() == "ground"
            groundStateKnown = onGround
        } else {
            altitudeFeet = nil
            groundStateKnown = false
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
        case iataAirportCodes = "_airport_codes_iata"
        case airportCodes = "airport_codes"
        case plausible
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callsign = (try? container.decode(String.self, forKey: .callsign)) ?? ""
        let iata = try? container.decodeIfPresent(String.self, forKey: .iataAirportCodes)
        let icao = try? container.decodeIfPresent(String.self, forKey: .airportCodes)
        airportCodes = (iata ?? nil) ?? (icao ?? nil)

        if let bool = try? container.decode(Bool.self, forKey: .plausible) {
            plausible = bool
        } else if let number = try? container.decode(Int.self, forKey: .plausible) {
            plausible = number != 0
        } else {
            plausible = nil
        }
    }
}


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

@MainActor
final class FleetLiveStore: ObservableObject {
    @Published private(set) var snapshots: [String: FleetLiveSnapshot] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var errorText: String?
    @Published private(set) var histories: [String: [FleetTrackObservation]] = [:]

    private let cacheKey = "RAIDORoster.FleetLiveCache.V1"
    private let historyCacheKey = "RAIDORoster.FleetHistory.V2"
    private let maximumHistoryPerAircraft = 720
    private var retryAfter: Date?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private let httpClient: AircraftHTTPClient
    private let session: URLSession
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }
    private var intelligenceCache: [String: FleetAircraftIntelligence] = [:]
    private var intelligenceBucket = -1
    private var cacheApplied = false
    private let cacheLoad: Task<([FleetLiveSnapshot], [String: [FleetTrackObservation]]), Never>
    private let cacheWriter = FleetCacheWriter()

    init(session: URLSession? = nil, httpClient: AircraftHTTPClient = .shared) {
        self.httpClient = httpClient
        self.session = session ?? Self.makeSession()
        cacheLoad = Task.detached(priority: .utility) {
            let defaults = UserDefaults.standard
            let decoder = JSONDecoder()
            let values = defaults.data(forKey: "RAIDORoster.FleetLiveCache.V1")
                .flatMap { try? decoder.decode([FleetLiveSnapshot].self, from: $0) } ?? []
            let history = defaults.data(forKey: "RAIDORoster.FleetHistory.V2")
                .flatMap { try? decoder.decode([String: [FleetTrackObservation]].self, from: $0) } ?? [:]
            return (values, history)
        }
        Task { [weak self] in await self?.loadCache() }
    }

    func refresh(definitions: [FleetAircraftDefinition] = FleetAircraftDefinition.all) async {
        await loadCache()
        // A view-owned manual restart cancels the previous pass. Wait for its
        // cooperative requests to unwind before acquiring the refresh slot.
        while isRefreshing {
            do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return }
        }
        guard !Task.isCancelled, retryAfter.map({ Date() >= $0 }) ?? true else { return }
        isRefreshing = true
        errorText = nil
        defer { isRefreshing = false }

        var fresh: [String: FleetLiveSnapshot] = [:]
        var activeForRoutes: [(registration: String, callsign: String, lat: Double, lon: Double)] = []
        var failures = 0
        var pending: [String: FleetLiveSnapshot] = [:]
        var lastPublish = Date.distantPast
        let report = await FleetRefreshPolicy.run(definitions, operation: { definition in
            do { return (definition.registration, try await self.fetchAircraft(definition.registration), false) }
            catch { return (definition.registration, nil, !Task.isCancelled) }
        }, receive: { result in
            let (registration, snapshot, failed) = result
            if failed { failures += 1 }
            if let snapshot {
                fresh[registration] = snapshot
                pending[registration] = snapshot
                if let callsign = snapshot.callsign, let lat = snapshot.latitude, let lon = snapshot.longitude,
                   !callsign.isEmpty { activeForRoutes.append((registration, callsign, lat, lon)) }
                if Date().timeIntervalSince(lastPublish) >= 1 {
                    self.publish(pending); pending.removeAll(); lastPublish = Date()
                }
            }
        })
        guard !Task.isCancelled else { return }
        publish(pending)

        if !report.timedOut, !Task.isCancelled, !activeForRoutes.isEmpty,
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
                    fetchedAt: old.fetchedAt,
                    icaoHex: old.icaoHex,
                    seenPositionSeconds: old.seenPositionSeconds,
                    nacP: old.nacP,
                    nic: old.nic,
                    radiusContainmentMeters: old.radiusContainmentMeters,
                    sourceReferenceAt: old.sourceReferenceAt,
                    groundStateKnown: old.groundStateKnown,
                    verticalRateFeetPerMinute: old.verticalRateFeetPerMinute,
                    providerName: old.providerName
                )
            }
        }

        guard !Task.isCancelled else { return }
        recordFreshHistory(fresh)

        publish(fresh)
        lastRefresh = Date()
        let savedSnapshots = Array(snapshots.values), savedHistories = histories
        await cacheWriter.save(snapshots: savedSnapshots, histories: savedHistories)
        guard !Task.isCancelled else { return }
        if report.timedOut {
            errorText = "Refresh timed out · showing available observations. Tap refresh to retry."
        } else if failures > 0 {
            errorText = failures == definitions.count ? "Live fleet data unavailable" : "Some aircraft could not be refreshed"
        }
    }

    private func publish(_ fresh: [String: FleetLiveSnapshot]) {
        guard !fresh.isEmpty else { return }
        var merged = snapshots
        for (registration, snapshot) in fresh { merged[registration] = snapshot }
        intelligenceCache.removeAll()
        snapshots = merged
    }

    func snapshot(for registration: String) -> FleetLiveSnapshot? {
        snapshots[registration]
    }

    func history(for registration: String) -> [FleetTrackObservation] {
        histories[registration] ?? []
    }

    func intelligence(for registration: String) -> FleetAircraftIntelligence? {
        let bucket = Int(Date().timeIntervalSince1970 / 15)
        if bucket != intelligenceBucket { intelligenceCache.removeAll(); intelligenceBucket = bucket }
        if let cached = intelligenceCache[registration] { return cached }
        guard let snapshot = snapshots[registration] else { return nil }
        let history = histories[registration] ?? []
        let recent = Array(history.suffix(20))

        let phase = snapshot.isFresh && snapshot.hasKnownGroundState
            ? inferredPhase(snapshot: snapshot, history: recent) : .unknown
        let currentRoute = snapshot.route?.nilIfEmpty
        let previousRoute = history.reversed().compactMap(\.route).first(where: {
            guard let currentRoute else { return true }
            return $0 != currentRoute
        })

        var lastDepartureAt: Date?
        var lastArrivalAt: Date?
        if history.count >= 2 {
            for pair in zip(history, history.dropFirst()) {
                guard FleetTrackingPolicy.canInferTransition(
                    previousAt: pair.0.observedAt, currentAt: pair.1.observedAt,
                    previousKnown: pair.0.groundStateKnown == true,
                    currentKnown: pair.1.groundStateKnown == true,
                    previousCallsign: pair.0.callsign, currentCallsign: pair.1.callsign
                ) else { continue }
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
        if snapshot.isFresh, snapshot.onGround, let arrival = lastArrivalAt,
           lastDepartureAt.map({ arrival > $0 }) ?? true {
            turnaround = max(0, Date().timeIntervalSince(arrival))
        } else {
            turnaround = nil
        }

        let value = FleetAircraftIntelligence(
            phase: phase,
            currentRoute: currentRoute,
            previousRoute: previousRoute,
            nearestAirport: nearestAirport,
            lastDepartureAt: lastDepartureAt,
            lastArrivalAt: lastArrivalAt,
            turnaroundSeconds: turnaround,
            observationCount: history.count
        )
        intelligenceCache[registration] = value
        return value
    }

    private func inferredPhase(snapshot: FleetLiveSnapshot, history: [FleetTrackObservation]) -> FleetFlightPhase {
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

    private func recordFreshHistory(_ fresh: [String: FleetLiveSnapshot]) {
        var updated = histories
        for (registration, snapshot) in fresh {
            guard snapshot.isFresh, snapshot.hasKnownGroundState else { continue }
            let observedAt = (snapshot.sourceReferenceAt ?? snapshot.fetchedAt)
                .addingTimeInterval(-max(snapshot.sourceSeenSeconds, snapshot.seenPositionSeconds ?? 0))
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
                observedAt: observedAt,
                groundStateKnown: snapshot.hasKnownGroundState
            )

            var values = updated[registration] ?? []
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
            updated[registration] = values
        }
        intelligenceCache.removeAll()
        histories = updated
    }

    private let primaryFleetProvider = FleetProviderSpec(
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
        let segment = expectedHex == nil ? provider.registrationPath : provider.hexPath
        let identity = expectedHex ?? registration
        guard let encoded = identity.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(provider.baseURL)/\(segment)/\(encoded)") else { return .failed }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("RAIDORoster/2.23.0", forHTTPHeaderField: "User-Agent")

        do {
            let receipt = try await httpClient.data(for: request, session: session)
            let data = receipt.data

            let result = try await Task.detached { try JSONDecoder().decode(ADSBLOLResponse.self, from: data) }.value
            guard !result.ac.isEmpty else { return .empty }
            guard let aircraft = result.ac.first(where: {
                FleetTrackingPolicy.matches(registration: $0.registration, hex: $0.hex,
                                            requested: registration, expectedHex: expectedHex)
            }) else { return .failed }

            let receivedAt = receipt.receivedAt
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

        let receipt = try await httpClient.data(for: request, session: session, cacheSeconds: 60)
        let data = receipt.data

        let results = try decoder.decode([ADSBLOLRouteResult].self, from: data)
        var byCallsign: [String: String] = [:]
        for result in results {
            guard result.plausible == true,
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

    private func loadCache() async {
        let (values, history) = await cacheLoad.value
        guard !cacheApplied else { return }
        cacheApplied = true
        var restored: [String: FleetLiveSnapshot] = [:]
        for value in values {
            if restored[value.registration].map({ $0.fetchedAt > value.fetchedAt }) != true {
                restored[value.registration] = value
            }
        }
        snapshots = restored
        lastRefresh = values.map(\.fetchedAt).max()
        histories = history.mapValues { Array($0.sorted { $0.observedAt < $1.observedAt }.suffix(maximumHistoryPerAircraft)) }
    }
}

private actor FleetCacheWriter {
    func save(snapshots: [FleetLiveSnapshot], histories: [String: [FleetTrackObservation]]) {
        let encoder = JSONEncoder(), defaults = UserDefaults.standard
        if let data = try? encoder.encode(snapshots) { defaults.set(data, forKey: "RAIDORoster.FleetLiveCache.V1") }
        if let data = try? encoder.encode(histories) { defaults.set(data, forKey: "RAIDORoster.FleetHistory.V2") }
    }
}

