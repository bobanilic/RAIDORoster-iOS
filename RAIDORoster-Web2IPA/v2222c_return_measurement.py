from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster/ContentView.swift"
s = CONTENT.read_text()


def block_end(text: str, start: int) -> int:
    brace = text.find("{", start)
    if brace < 0:
        return -1
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i + 1
    return -1


# Re-evaluate automatic arming whenever the app becomes active. This is cheap:
# configureAutomaticFlight keeps the preflight path on significant-change
# monitoring until the airport/time gate is actually satisfied.
vs = s.find("struct ContentView: View {")
ve = s.find("\nstruct RosterHomeView: View {", vs)
if vs < 0 or ve < 0:
    raise RuntimeError("return measurement: ContentView bounds missing")
v = s[vs:ve]
scene_property = r"    @Environment(\.scenePhase) private var raidoScenePhase" + "\n"
if scene_property not in v:
    v = v.replace("struct ContentView: View {\n", "struct ContentView: View {\n" + scene_property, 1)

body_start = v.find("    var body: some View {")
body_end = block_end(v, body_start) if body_start >= 0 else -1
if body_start < 0 or body_end < 0:
    raise RuntimeError("return measurement: ContentView body bounds missing")
body = v[body_start:body_end]
scene_mod = '''        .onChange(of: raidoScenePhase) { _, phase in
            if phase == .active {
                TodayLiveFlightLocationManager.shared.configureAutomaticFlight(from: appState.rosterStore.items)
            }
        }'''
if scene_mod not in body:
    close = body.rfind("\n    }")
    if close < 0:
        raise RuntimeError("return measurement: ContentView body close missing")
    body = body[:close] + "\n" + scene_mod + body[close:]
    v = v[:body_start] + body + v[body_end:]
s = s[:vs] + v + s[ve:]


ms = s.find("private final class TodayLiveFlightLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {")
me = s.find("\nstruct TodayRouteMapCard: View {", ms)
if ms < 0 or me < 0:
    raise RuntimeError("return measurement: manager bounds missing")
m = s[ms:me]

# Battery hardening for the network side. The aircraft marker remains smooth
# because fused extrapolation still refreshes locally; only network fetch cadence
# changes by phase.
task_sig = "    private func restartHybridTask() {"
task_start = m.find(task_sig)
task_end = block_end(m, task_start) if task_start >= 0 else -1
if task_start < 0 or task_end < 0:
    raise RuntimeError("return measurement: hybrid task missing")
new_task = r'''    private func restartHybridTask() {
        hybridTask?.cancel()
        hybridTask = Task { [weak self] in
            guard let self else { return }
            var secondsSincePoll = 10_000
            while !Task.isCancelled {
                let pollEvery: Int
                switch self.companionPhase {
                case .parked, .armed: pollEvery = 30
                case .groundCandidate, .taxiOut, .taxiIn: pollEvery = 4
                case .takeoffRoll: pollEvery = 2
                case .airborne: pollEvery = 20
                case .descent: pollEvery = 6
                case .complete: pollEvery = 60
                }
                if secondsSincePoll >= pollEvery, let registration = self.trackedRegistration {
                    await self.fetchNetworkAircraft(registration: registration)
                    secondsSincePoll = 0
                }
                self.refreshFusedPosition()
                secondsSincePoll += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }'''
m = m[:task_start] + new_task + m[task_end:]


# Multi-sector handoff. A stale outbound sector must not block the return sector.
# Keep a current sector only while it has a recent, measured fused fix in an
# active flight phase. Otherwise discard sectors whose rostered end is >30 min
# in the past and arm the next usable sector.
cfg_sig = "    func configureAutomaticFlight(from items: [RosterItem], now: Date = Date()) {"
cfg_start = m.find(cfg_sig)
cfg_end = block_end(m, cfg_start) if cfg_start >= 0 else -1
if cfg_start < 0 or cfg_end < 0:
    raise RuntimeError("return measurement: automatic-flight function missing")

new_cfg = r'''    func configureAutomaticFlight(from items: [RosterItem], now: Date = Date()) {
        let candidates = items.flatMap { $0.flightActivities }.compactMap { activity -> (activity: RosterActivity, start: Date, end: Date?)? in
            guard let start = parseUTCStamp(activity.startUTC) else { return nil }
            return (activity, start, parseUTCStamp(activity.endUTC))
        }.sorted { $0.start < $1.start }

        var currentPhaseCanHold = false
        switch companionPhase {
        case .taxiOut, .takeoffRoll, .airborne, .descent, .taxiIn:
            currentPhaseCanHold = !positionIsEstimated
                && fusedLocation.map { abs(now.timeIntervalSince($0.timestamp)) <= 180 } == true
        default:
            break
        }

        var selected: (activity: RosterActivity, start: Date, end: Date?)?
        if currentPhaseCanHold, let currentKey = automaticKey {
            selected = candidates.first { candidate in
                [candidate.activity.startUTC, candidate.activity.route, candidate.activity.aircraftReg]
                    .joined(separator: "|") == currentKey
            }
        }

        if selected == nil {
            let staleCutoff = now.addingTimeInterval(-30 * 60)
            selected = candidates.first { candidate in
                guard candidate.start >= now.addingTimeInterval(-autoGrace) else { return false }
                if let end = candidate.end, end < staleCutoff { return false }
                return true
            }
        }

        if selected == nil {
            selected = candidates.first { $0.start >= now }
        }

        guard let selected else {
            automaticMonitoring = false
            return
        }

        let codes = routeCodes(selected.activity.route)
        guard let originCode = codes.first,
              let origin = TodayAirportCoordinates.airports[originCode] else { return }

        let key = [selected.activity.startUTC, selected.activity.route, selected.activity.aircraftReg]
            .joined(separator: "|")

        if automaticKey != key {
            persistFusedTrail(now: now, force: true)
            if isTracking {
                manager.stopUpdatingLocation()
                isTracking = false
            }
            hybridTask?.cancel()
            hybridTask = nil
            fusedLocation = nil
            groundCandidateAt = nil
            stoppedAt = nil
            highSpeedAt = nil
            taxiOutStartedAt = nil
            airborneAt = nil
            landedAt = nil
            stationarySince = nil
            groundAltitude = nil
            lastMeasuredProgress = 0
            lastMeasuredProgressAt = nil
            previousMeasuredSpeed = nil
            taxiOutDurationText = nil
            airborneDurationText = nil
            taxiInDurationText = nil
            takeoffTimeText = nil
            landingTimeText = nil

            automaticKey = key
            automaticDepartureAt = selected.start
            automaticOrigin = origin.coordinate
            routeCoordinates = codes.compactMap { TodayAirportCoordinates.airports[$0]?.coordinate }
            configureAircraftTracking(registration: selected.activity.aircraftReg)
            let canonicalReg = FleetTrackingPolicy.canonicalRegistration(selected.activity.aircraftReg)
            configureTrailPersistence(sessionKey: [selected.activity.startUTC, selected.activity.endUTC, selected.activity.route, canonicalReg].joined(separator: "|"))
            companionPhase = .armed
            flightPhaseText = "Armed · automatic"
            positionIsEstimated = false
            configureAutoRegion(code: originCode, coordinate: origin.coordinate)
            applyPowerProfile()
        } else {
            // A roster refresh can revise STD without changing route/registration.
            automaticDepartureAt = selected.start
        }

        automaticMonitoring = true
        requestAutomaticAuthorization()
        manager.startMonitoringSignificantLocationChanges()
        if let id = automaticRegionID,
           let region = manager.monitoredRegions.first(where: { $0.identifier == id }) {
            manager.requestState(for: region)
        }
        evaluateAuto(now: now, location: manager.location)
    }'''
m = m[:cfg_start] + new_cfg + m[cfg_end:]


# Extend the fresh roster-aircraft ADS-B phase path through arrival. The normal
# updatePhase() still runs first; this block mainly gives explicit ADS-B state
# labels and makes taxi/takeoff/landing usable when cabin GNSS is poor.
adsb_sig = "    private func applyFreshADSBPhase(_ value: CLLocation, source: String, estimated: Bool, now: Date) {"
adsb_start = m.find(adsb_sig)
adsb_end = block_end(m, adsb_start) if adsb_start >= 0 else -1
if adsb_start < 0 or adsb_end < 0:
    raise RuntimeError("return measurement: ADS-B phase helper missing")

new_adsb = r'''    private func applyFreshADSBPhase(_ value: CLLocation, source: String, estimated: Bool, now: Date) {
        guard source == "ADS-B live", !estimated, automaticMonitoring, insideAutoWindow(now) else { return }
        let speed = max(0, value.speed)
        let remaining = destinationDistance(value) ?? .greatestFiniteMagnitude

        switch companionPhase {
        case .armed:
            guard insideAirport(value), speed >= 2.5 else { return }
            groundCandidateAt = groundCandidateAt ?? now
            stoppedAt = nil
            companionPhase = .groundCandidate
            flightPhaseText = "Ground movement · ADS-B"
            applyPowerProfile()

        case .groundCandidate:
            guard insideAirport(value) else { return }
            if speed >= 55 {
                taxiOutStartedAt = taxiOutStartedAt ?? groundCandidateAt ?? now
                airborneAt = now
                takeoffTimeText = clockText(now)
                companionPhase = .airborne
                flightPhaseText = "Airborne · ADS-B"
                stationarySince = nil
                applyPowerProfile()
            } else if speed >= 2.5, now.timeIntervalSince(groundCandidateAt ?? now) >= 8 {
                taxiOutStartedAt = groundCandidateAt ?? now
                companionPhase = .taxiOut
                flightPhaseText = "Taxi out · ADS-B"
                stoppedAt = nil
                applyPowerProfile()
            }

        case .taxiOut:
            if speed >= 55 {
                airborneAt = now
                takeoffTimeText = clockText(now)
                companionPhase = .airborne
                flightPhaseText = "Airborne · ADS-B"
                stationarySince = nil
                applyPowerProfile()
            } else if speed >= 28 {
                highSpeedAt = highSpeedAt ?? now
                companionPhase = .takeoffRoll
                flightPhaseText = "Takeoff roll · ADS-B"
                applyPowerProfile()
            }

        case .takeoffRoll:
            if speed >= 45 {
                airborneAt = now
                takeoffTimeText = clockText(now)
                companionPhase = .airborne
                flightPhaseText = "Airborne · ADS-B"
                stationarySince = nil
                applyPowerProfile()
            }

        case .airborne:
            if remaining < 80_000 || (lastMeasuredProgress > 0.82 && speed < 180) {
                companionPhase = .descent
                flightPhaseText = "Descent · ADS-B"
                applyPowerProfile()
            }

        case .descent:
            if remaining < 12_000 && speed < 55 {
                landedAt = landedAt ?? now
                landingTimeText = landingTimeText ?? clockText(now)
                companionPhase = .taxiIn
                flightPhaseText = "Landed · taxi in · ADS-B"
                stationarySince = nil
                applyPowerProfile()
            }

        case .taxiIn:
            if speed < 1.5 {
                stationarySince = stationarySince ?? now
                if now.timeIntervalSince(stationarySince ?? now) >= 120 {
                    companionPhase = .complete
                    flightPhaseText = "On block · ADS-B"
                    applyPowerProfile()
                }
            } else {
                stationarySince = nil
            }

        case .parked, .complete:
            break
        }
        updateDurations(now)
    }'''
m = m[:adsb_start] + new_adsb + m[adsb_end:]


# Replace diagnostics with a return-test snapshot. It deliberately reports only
# booleans/ages/power configuration -- never coordinates, roster IDs,
# subscription URLs, credentials, or employee data.
diag_sig = "    func companionStateText(now: Date = Date()) -> String {"
diag_start = m.find(diag_sig)
diag_end = block_end(m, diag_start) if diag_start >= 0 else -1
if diag_start < 0 or diag_end < 0:
    raise RuntimeError("return measurement: companion diagnostics missing")

new_diag = r'''    func companionStateText(now: Date = Date()) -> String {
        let departure = automaticDepartureAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none"
        let origin = automaticRegionID?.split(separator: ".").last.map(String.init) ?? "none"
        let fusedAge = fusedLocation.map { max(0, Int(now.timeIntervalSince($0.timestamp).rounded())) } ?? -1
        let insideGate = manager.location.map { insideAirport($0) } ?? false
        let regionActive = automaticRegionID.map { id in
            manager.monitoredRegions.contains(where: { $0.identifier == id })
        } ?? false
        let adsbPollSeconds: Int
        switch companionPhase {
        case .parked, .armed: adsbPollSeconds = 30
        case .groundCandidate, .taxiOut, .taxiIn: adsbPollSeconds = 4
        case .takeoffRoll: adsbPollSeconds = 2
        case .airborne: adsbPollSeconds = 20
        case .descent: adsbPollSeconds = 6
        case .complete: adsbPollSeconds = 60
        }
        return [
            "version=2.23.0-return-measurement",
            "scheduledDepartureUTC=\(departure)",
            "originAirport=\(origin)",
            "automaticMonitoring=\(automaticMonitoring)",
            "activeWindow=\(insideAutoWindow(now))",
            "insideOriginGate=\(insideGate)",
            "regionMonitoring=\(regionActive)",
            "locationAuthorization=\(String(describing: manager.authorizationStatus))",
            "phase=\(flightPhaseText)",
            "tracking=\(isTracking)",
            "source=\(positionSourceText)",
            "estimated=\(positionIsEstimated)",
            "fusedAgeSeconds=\(fusedAge)",
            "trailPoints=\(fusedTrail.count)",
            "powerMode=\(companionPowerModeText)",
            "standardGPS=\(isTracking)",
            "adsbPollIntervalSeconds=\(adsbPollSeconds)",
            "desiredAccuracy=\(Int(manager.desiredAccuracy.rounded()))",
            "distanceFilter=\(Int(manager.distanceFilter.rounded()))"
        ].joined(separator: "\n")
    }'''
m = m[:diag_start] + new_diag + m[diag_end:]

s = s[:ms] + m + s[me:]


# The map must use fused aircraft state independently from the phone-GPS session.
# v2222b already rewires the known render paths; guard that invariant here so a
# future upstream patch cannot silently regress the return test.
cs = s.find("struct TodayRouteMapCard: View {")
ce = s.find("\nprivate struct CrewCompanionPhase", cs)
if ce < 0:
    ce = s.find("\nstruct TodayPersonalNoteDisclosure", cs)
if cs < 0 or ce < 0:
    raise RuntimeError("return measurement: map bounds missing")
c = s[cs:ce]
c = c.replace("liveLocation: gps.isTracking ? gps.fusedLocation : nil", "liveLocation: gps.fusedLocation")
c = c.replace("if gps.isTracking, let coordinate = gps.fusedLocation?.coordinate", "if let coordinate = gps.fusedLocation?.coordinate")
if "liveLocation: gps.fusedLocation" not in c:
    raise RuntimeError("return measurement: fused map position is not wired")
s = s[:cs] + c + s[ce:]


for required in [
    "2.23.0-return-measurement",
    "insideOriginGate=",
    "regionMonitoring=",
    "locationAuthorization=",
    "fusedAgeSeconds=",
    "trailPoints=",
    "adsbPollIntervalSeconds=",
    "raidoScenePhase",
    "staleCutoff",
    "Taxi out · ADS-B",
    "Landed · taxi in · ADS-B",
    "liveLocation: gps.fusedLocation",
]:
    if required not in s:
        raise RuntimeError("return measurement semantic guard missing: " + required)

s += "\n// Flight Companion return-flight handoff, ADS-B rendering, lifecycle recovery, and diagnostics\n"
CONTENT.write_text(s)
print("Flight Companion return-flight measurement hardening applied")
