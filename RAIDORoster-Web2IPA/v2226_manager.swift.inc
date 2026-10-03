    // MARK: V2.26 sensor driver and recoverable session
    var sensorPhase: FlightSensorPolicy.Phase {
        guard isTracking else { return .inactive }
        switch companionPhase {
        case .parked, .armed, .groundCandidate, .taxiOut, .takeoffRoll: return .preflight
        case .airborne, .descent: return .airborne
        case .taxiIn, .complete: return .inactive
        }
    }

    private var sensorSessionKey: String { automaticKey ?? trailPersistenceKey ?? "manual" }

    func stopForBackgroundIfIdle() {
        persistSession(now: Date(), force: true)
        if companionPhase == .complete { stop(); return }
        if automaticMonitoring, isTracking { return }
        switch companionPhase {
        case .taxiOut, .takeoffRoll, .airborne, .descent, .taxiIn: return
        default: stop()
        }
    }

    private func modelCruiseSpeed(total: CLLocationDistance) -> CLLocationSpeed {
        FlightSensorSessionPolicy.cruiseSpeed(distance: total, departure: automaticDepartureAt, arrival: scheduledArrivalAt)
    }

    private func sensorProgress(now: Date) -> Double? {
        guard let takeoff = airborneAt, let total = routeDistance, total > 1_000 else { return nil }
        let anchorDate = lastMeasuredProgressAt ?? takeoff
        let anchor = lastMeasuredProgressAt == nil ? 0 : lastMeasuredProgress
        return min(1, max(anchor, anchor + max(0, now.timeIntervalSince(anchorDate)) * modelCruiseSpeed(total: total) / total))
    }

    private func freshMeasuredLocations(now: Date) -> [CLLocation] {
        var values: [CLLocation] = []
        if let value = location, (0...20).contains(now.timeIntervalSince(value.timestamp)),
           value.horizontalAccuracy >= 0, value.horizontalAccuracy <= 250 { values.append(value) }
        if let (value, estimated) = propagatedNetworkLocation(now: now), !estimated { values.append(value) }
        return values
    }

    @discardableResult
    func sensorTakeoffDetected(burstEnd: Date, now: Date) -> Bool {
        guard isTracking, airborneAt == nil, sensorPhase == .preflight,
              (0...360).contains(now.timeIntervalSince(burstEnd)),
              !automaticMonitoring || (insideAutoWindow(now) && insideAutoWindow(burstEnd)),
              !freshMeasuredLocations(now: now).contains(where: { insideAirport($0) && $0.speed >= 0 && $0.speed < 20 }) else { return false }
        taxiOutStartedAt = taxiOutStartedAt ?? groundCandidateAt
        airborneAt = burstEnd; takeoffTimeText = clockText(burstEnd)
        companionPhase = .airborne; flightPhaseText = "Airborne · sensors"
        stationarySince = nil; landedUsingSensors = false
        applyPowerProfile()
        persistSession(now: now, force: true)
        refreshFusedPosition()
        return true
    }

    @discardableResult
    func sensorLandingDetected(at touchdown: Date, now: Date) -> Bool {
        guard isTracking, sensorPhase == .airborne, landedAt == nil,
              (0...180).contains(now.timeIntervalSince(touchdown)),
              let takeoff = airborneAt, touchdown > takeoff else { return false }
        let conflict = freshMeasuredLocations(now: now).contains {
            $0.speed >= 55 || (destinationDistance($0).map { $0 > 20_000 } ?? true)
        }
        guard FlightSensorSessionPolicy.canLand(takeoff: airborneAt, departure: automaticDepartureAt,
                  arrival: scheduledArrivalAt, progress: sensorProgress(now: now), conflictingMeasurement: conflict, now: now) else { return false }
        landedAt = touchdown; landingTimeText = clockText(touchdown)
        companionPhase = .taxiIn; flightPhaseText = "Landed · taxi in · sensors"
        landedUsingSensors = true; stationarySince = nil
        FlightCompanionV3Observer.shared.stopObservation()
        applyPowerProfile()
        persistSession(now: now, force: true)
        refreshFusedPosition()
        return true
    }

    private struct PersistedSession: Codable {
        let key: String?
        let registration: String?
        let phase: CompanionPhase
        let tracking: Bool
        let automatic: Bool
        let departure: Date?
        let arrival: Date?
        let origin: PersistedTrailPoint?
        let route: [PersistedTrailPoint]
        let trailKey: String?
        let taxiOut: Date?
        let takeoff: Date?
        let landing: Date?
        let sensorLanding: Bool
        let progress: Double
        let progressAt: Date?
        let savedAt: Date
    }
    private let sessionStorageKey = "RAIDORoster.FlightSession.V226"
    private let completedStorageKey = "RAIDORoster.CompletedSectors.V226"
    private var completedSectors: [String: Date] = [:]
    private var lastSessionPersistAt: Date?
    private var lastPersistedPhase: CompanionPhase?
    private var resumeAfterRestore = false

    private func persistSession(now: Date, force: Bool = false) {
        guard force || lastPersistedPhase != companionPhase || lastSessionPersistAt.map({ now.timeIntervalSince($0) >= 15 }) ?? true else { return }
        let state = PersistedSession(key: automaticKey, registration: trackedRegistration,
            phase: companionPhase, tracking: isTracking, automatic: automaticMonitoring,
            departure: automaticDepartureAt, arrival: scheduledArrivalAt,
            origin: automaticOrigin.map { .init(latitude: $0.latitude, longitude: $0.longitude) },
            route: routeCoordinates.map { .init(latitude: $0.latitude, longitude: $0.longitude) },
            trailKey: trailPersistenceKey, taxiOut: taxiOutStartedAt, takeoff: airborneAt,
            landing: landedAt, sensorLanding: landedUsingSensors, progress: lastMeasuredProgress,
            progressAt: lastMeasuredProgressAt, savedAt: now)
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: sessionStorageKey) }
        lastSessionPersistAt = now; lastPersistedPhase = companionPhase
    }

    private func restoreSession(now: Date) {
        if let data = UserDefaults.standard.data(forKey: completedStorageKey),
           let values = try? JSONDecoder().decode([String: Date].self, from: data) {
            completedSectors = values.filter { (0...7 * 24 * 60 * 60).contains(now.timeIntervalSince($0.value)) }
        }
        guard let data = UserDefaults.standard.data(forKey: sessionStorageKey),
              let state = try? JSONDecoder().decode(PersistedSession.self, from: data),
              (0...18 * 60 * 60).contains(now.timeIntervalSince(state.savedAt)),
              state.key.map({ completedSectors[$0] == nil }) ?? true,
              state.tracking, state.phase != .complete,
              state.route.count >= 2, state.route.allSatisfy({ (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) }) else { return }
        if let takeoff = state.takeoff {
            guard FlightSensorSessionPolicy.arrivalWindow(takeoff: takeoff, departure: state.departure, arrival: state.arrival, now: now) else { return }
        } else if state.automatic {
            guard let departure = state.departure, now >= departure.addingTimeInterval(-autoLead), now <= departure.addingTimeInterval(autoGrace) else { return }
        } else { return } // Idle manual sessions are not relaunched.
        automaticKey = state.key; automaticMonitoring = state.automatic
        automaticDepartureAt = state.departure; scheduledArrivalAt = state.arrival
        automaticOrigin = state.origin.map { .init(latitude: $0.latitude, longitude: $0.longitude) }
        routeCoordinates = state.route.map { .init(latitude: $0.latitude, longitude: $0.longitude) }
        trackedRegistration = state.registration; trailPersistenceKey = state.trailKey
        companionPhase = state.phase; taxiOutStartedAt = state.taxiOut
        airborneAt = state.takeoff; landedAt = state.landing; landedUsingSensors = state.sensorLanding
        lastMeasuredProgress = state.progress; lastMeasuredProgressAt = state.progressAt
        takeoffTimeText = state.takeoff.map(clockText); landingTimeText = state.landing.map(clockText)
        flightPhaseText = "Restored session · \(state.phase.rawValue)"
        loadPersistedTrail()
        resumeAfterRestore = true
        // Restore phase/times, but never restore partial sensor evidence across a process gap.
    }

    private func resumeRestoredSession(now: Date) {
        guard resumeAfterRestore, manager.authorizationStatus == .authorizedAlways ||
              (manager.authorizationStatus == .authorizedWhenInUse && UIApplication.shared.applicationState == .active) else { return }
        resumeAfterRestore = false
        acquisitionStartedAt = now; isTracking = true
        applyPowerProfile(); manager.startUpdatingLocation(); restartHybridTask()
        if sensorPhase != .inactive { FlightCompanionV3Observer.shared.startObservation(sessionKey: sensorSessionKey) }
    }

    private func maintainSession(now: Date) {
        if landedUsingSensors, companionPhase == .taxiIn, let landing = landedAt,
           now.timeIntervalSince(landing) >= 25 * 60 {
            companionPhase = .complete; flightPhaseText = "Session complete · estimated"
            applyPowerProfile()
        }
        if companionPhase == .complete {
            if let key = automaticKey, completedSectors[key] == nil {
                completedSectors[key] = now
                completedSectors = completedSectors.filter { (0...7 * 24 * 60 * 60).contains(now.timeIntervalSince($0.value)) }
                if let data = try? JSONEncoder().encode(completedSectors) { UserDefaults.standard.set(data, forKey: completedStorageKey) }
            }
            if isTracking { stop() }
            return
        }
        let expired: Bool
        if let takeoff = airborneAt {
            expired = !FlightSensorSessionPolicy.arrivalWindow(takeoff: takeoff, departure: automaticDepartureAt, arrival: scheduledArrivalAt, now: now)
        } else { expired = automaticMonitoring && !insideAutoWindow(now) }
        if expired, isTracking {
            flightPhaseText = "Session expired · reopen to resume"
            stop()
            return
        }
        persistSession(now: now)
    }
