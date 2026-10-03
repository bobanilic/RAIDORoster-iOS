"""V2.26: timestamped offline phase evidence, session recovery and lifecycle fixes.

Apply after v2225 on clean generated sources. Partial or unknown older v2226
implementations fail closed rather than pretending the fixed driver is installed.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / 'RAIDORoster/ContentView.swift'
PBX = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
s = CONTENT.read_text()
pbx = PBX.read_text()
MARKER = '// V2.26 validated sensor/session driver'
if MARKER in s:
    for required in ['FlightSensorSessionPolicy.canLand(', 'appendBatch(', 'restoreSession(now:', 'completedSectors[key] = now']:
        if required not in s:
            raise RuntimeError('Incomplete V2.26 installation: ' + required)
    if 'B22600000000000000000001' not in pbx:
        raise RuntimeError('V2.26 policy missing from Xcode project')
    print('V2.26 validated sensor driver already applied')
    raise SystemExit(0)
if 'func sensorTakeoffDetected(' in s:
    raise RuntimeError('Older V2.26 driver present; rebuild from clean branch sources')


def once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'V2.26 {label}: anchor found {count} times, expected 1')
    return text.replace(old, new, 1)

ms = s.index('private final class TodayLiveFlightLocationManager:')
me = s.index('\n\nenum FlightV3EvidenceSource:', ms)
m = s[ms:me]
m = once(m, 'private final class TodayLiveFlightLocationManager:', '@MainActor\nprivate final class TodayLiveFlightLocationManager:', 'main actor')
m = once(m, 'private enum CompanionPhase {', 'private enum CompanionPhase: String, Codable {', 'phase persistence')
m = once(m, '    private var highSpeedAt: Date?\n', '    private var highSpeedAt: Date?\n    private var scheduledArrivalAt: Date?\n    private var landedUsingSensors = false\n', 'arrival properties')
m = once(m, '        authorizationStatus = manager.authorizationStatus\n    }',
         '        authorizationStatus = manager.authorizationStatus\n        restoreSession(now: Date())\n        Task { @MainActor [weak self] in self?.resumeRestoredSession(now: Date()) }\n    }', 'restore init')
m = once(m, '        let now = Date()\n        if let gnss = usableGNSSLocation {',
         '        let now = Date()\n        maintainSession(now: now)\n        if let gnss = usableGNSSLocation {', 'session maintenance')
m = once(m, '        applyFreshADSBPhase(value, source: source, estimated: estimated, now: now)\n',
         '        applyFreshADSBPhase(value, source: source, estimated: estimated, now: now)\n        maintainSession(now: now)\n', 'persist measured transitions')
m = once(m, '    func configureAircraftTracking(registration: String?) {\n',
         '    func configureAircraftTracking(registration: String?) {\n        guard !automaticMonitoring || !isTracking else { return }\n', 'active registration')
m = once(m, '    func configureTrailPersistence(sessionKey: String) {\n',
         '    func configureTrailPersistence(sessionKey: String) {\n        guard !automaticMonitoring || airborneAt == nil else { return }\n', 'active trail identity')
m = once(m, '    func configureFlightRoute(coordinates: [CLLocationCoordinate2D]) {\n        routeCoordinates = coordinates\n    }',
         '''    func configureFlightRoute(coordinates: [CLLocationCoordinate2D]) {
        // A visible duty card may contain several sectors; keep the active sector geometry.
        guard !automaticMonitoring, airborneAt == nil else { return }
        routeCoordinates = coordinates
    }''', 'active route geometry')
m = once(m, '    private func estimatedRouteLocation(now: Date) -> CLLocation? {\n',
         '''    private func estimatedRouteLocation(now: Date) -> CLLocation? {
        if landedUsingSensors, landedAt != nil, companionPhase == .taxiIn || companionPhase == .complete,
           let destination = routeCoordinates.last {
            return CLLocation(coordinate: destination, altitude: 0, horizontalAccuracy: 3_000,
                              verticalAccuracy: -1, course: -1, speed: 0, timestamp: now)
        }
''', 'arrival estimate')
m = once(m, '        let speed = 220.0, anchorDate = lastMeasuredProgressAt ?? takeoff\n',
         '        let speed = modelCruiseSpeed(total: total), anchorDate = lastMeasuredProgressAt ?? takeoff\n', 'roster speed')
m = once(m, '        case .parked, .armed: manager.desiredAccuracy = kCLLocationAccuracyKilometer; manager.distanceFilter = 250\n',
         '        case .parked, .armed: manager.desiredAccuracy = kCLLocationAccuracyHundredMeters; manager.distanceFilter = 50\n', 'armed accuracy')
m = once(m, '        case .descent: manager.desiredAccuracy = kCLLocationAccuracyBest; manager.distanceFilter = 30\n        }\n    }',
         '        case .descent: manager.desiredAccuracy = kCLLocationAccuracyBest; manager.distanceFilter = 30\n        }\n        manager.pausesLocationUpdatesAutomatically = companionPhase == .complete\n    }', 'auto pause')
m = once(m, '    func configureAutomaticFlight(from items: [RosterItem], now: Date = Date()) {\n',
         '    func configureAutomaticFlight(from items: [RosterItem], now: Date = Date()) {\n        resumeRestoredSession(now: now)\n', 'resume from roster')
m = once(m, '''            currentPhaseCanHold = !positionIsEstimated
                && fusedLocation.map { abs(now.timeIntervalSince($0.timestamp)) <= 180 } == true''',
         '''            currentPhaseCanHold = airborneAt.map {
                FlightSensorSessionPolicy.arrivalWindow(takeoff: $0, departure: automaticDepartureAt, arrival: scheduledArrivalAt, now: now)
            } ?? (automaticMonitoring && insideAutoWindow(now))''', 'hold offline flight')
m = once(m, '''        }.sorted { $0.start < $1.start }

        var currentPhaseCanHold''',
         '''        }.filter { candidate in
            let key = [candidate.activity.startUTC, candidate.activity.route, candidate.activity.aircraftReg].joined(separator: "|")
            return completedSectors[key] == nil
        }.sorted { $0.start < $1.start }

        var currentPhaseCanHold''', 'skip completed sectors')
m = once(m, '''            }
        }

        if selected == nil {
            let staleCutoff''',
         '''            }
            if selected == nil {
                // Retain a running session even when a refresh omits it or revises STD.
                selected = candidates.first { candidate in
                    candidate.activity.route == activeRouteText
                        && FleetTrackingPolicy.canonicalRegistration(candidate.activity.aircraftReg) == (trackedRegistration ?? "")
                        && automaticDepartureAt.map { abs(candidate.start.timeIntervalSince($0)) <= 2 * 60 * 60 } == true
                }
            }
            if selected == nil { persistSession(now: now, force: true); return }
        }

        if selected == nil {
            let staleCutoff''', 'retain omitted/revised sector')
m = once(m, '''        guard let selected else {
            automaticMonitoring = false
            return
        }''',
         '''        guard let selected else {
            if companionPhase == .complete { stop() }
            automaticMonitoring = false
            persistSession(now: now, force: true)
            return
        }''', 'no candidate')
m = once(m, '''        let key = [selected.activity.startUTC, selected.activity.route, selected.activity.aircraftReg]
            .joined(separator: "|")''',
         '''        let selectedKey = [selected.activity.startUTC, selected.activity.route, selected.activity.aircraftReg].joined(separator: "|")
        let key = currentPhaseCanHold ? (automaticKey ?? selectedKey) : selectedKey''', 'stable running identity')
m = once(m, '            persistFusedTrail(now: now, force: true)\n            if isTracking {',
         '            persistFusedTrail(now: now, force: true)\n            FlightCompanionV3Observer.shared.stopObservation()\n            if isTracking {', 'sector sensor reset')
m = once(m, '            automaticDepartureAt = selected.start\n            automaticOrigin',
         '            automaticDepartureAt = selected.start\n            scheduledArrivalAt = selected.end\n            activeRouteText = selected.activity.route\n            landedUsingSensors = false\n            location = nil; trail = []\n            networkObservationAt = nil; networkLatitude = nil; networkLongitude = nil\n            automaticOrigin', 'new sector')
m = once(m, '            automaticDepartureAt = selected.start\n        }\n\n        automaticMonitoring = true',
         '            automaticDepartureAt = selected.start\n            scheduledArrivalAt = selected.end\n        }\n\n        automaticMonitoring = true', 'revised schedule')
m = once(m, '        evaluateAuto(now: now, location: manager.location)\n    }',
         '        evaluateAuto(now: now, location: manager.location)\n        persistSession(now: now, force: true)\n    }', 'persist roster')
m = once(m, '''        guard automaticMonitoring, insideAutoWindow(now), let location, insideAirport(location) else { return }
        guard !isTracking else { return }''',
         '''        guard automaticMonitoring, companionPhase != .complete,
              automaticKey.map({ completedSectors[$0] == nil }) ?? true,
              insideAutoWindow(now), let location, insideAirport(location),
              (0...120).contains(now.timeIntervalSince(location.timestamp)),
              location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 1_000 else { return }
        guard !isTracking else { return }''', 'automatic gate')
m = once(m, '        restartHybridTask()\n    }\n\n    private var companionPowerModeText:',
         '        restartHybridTask()\n        FlightCompanionV3Observer.shared.startObservation(sessionKey: sensorSessionKey)\n        persistSession(now: now, force: true)\n    }\n\n    private var companionPowerModeText:', 'auto observer')
m = once(m, '            "version=2.23.0-return-measurement",',
         '            "version=2.26.0-sensor-driver",\n            "pausesUpdates=\\(manager.pausesLocationUpdatesAutomatically)",', 'manager version')
m = once(m, '        automaticMonitoring = false\n        guard CLLocationManager.locationServicesEnabled()',
         '        FlightCompanionV3Observer.shared.stopObservation()\n        resumeAfterRestore = false\n        automaticMonitoring = false\n        landedUsingSensors = false\n        guard CLLocationManager.locationServicesEnabled()', 'manual reset')
m = once(m, '''        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:''',
         '''        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
            FlightCompanionV3Observer.shared.startObservation(sessionKey: sensorSessionKey)
        case .denied, .restricted:''', 'manual observer')
m = once(m, '''    func stop() {
        persistFusedTrail''',
         (ROOT / 'v2226_manager.swift.inc').read_text() + '''
    func stop() {
        resumeAfterRestore = false
        FlightCompanionV3Observer.shared.stopObservation()
        persistFusedTrail''', 'manager hooks')
m = once(m, '        acquisitionStartedAt = nil\n    }\n\n    func locationManagerDidChangeAuthorization',
         '        acquisitionStartedAt = nil\n        persistSession(now: Date(), force: true)\n    }\n\n    func locationManagerDidChangeAuthorization', 'persist stopped session')
m = once(m, '            manager.startUpdatingLocation()\n        case .denied, .restricted:\n            errorText = "Location permission required"\n            isTracking = false\n            acquisitionStartedAt',
         '            manager.startUpdatingLocation()\n            FlightCompanionV3Observer.shared.startObservation(sessionKey: sensorSessionKey)\n        case .denied, .restricted:\n            stop()\n            errorText = "Location permission required"\n            isTracking = false\n            acquisitionStartedAt', 'authorization lifecycle')
# The restored route identity is local-only and survives omitted roster items.
m = once(m, '    private var scheduledArrivalAt: Date?\n', '    private var scheduledArrivalAt: Date?\n    private var activeRouteText = ""\n', 'route identity')
m = once(m, '        let registration: String?\n        let phase:', '        let registration: String?\n        let routeText: String\n        let phase:', 'snapshot route')
m = once(m, 'PersistedSession(key: automaticKey, registration: trackedRegistration,\n', 'PersistedSession(key: automaticKey, registration: trackedRegistration, routeText: activeRouteText,\n', 'capture route')
m = once(m, '        trackedRegistration = state.registration; trailPersistenceKey = state.trailKey\n', '        trackedRegistration = state.registration; trailPersistenceKey = state.trailKey\n        activeRouteText = state.routeText\n', 'restore route')
s = s[:ms] + m + s[me:]

os = s.index('@MainActor\nfinal class FlightCompanionV3Observer:')
oe = s.index('\n\nprivate enum TodayGlobalAirportIndex', os)
s = s[:os] + (ROOT / 'v2226_observer.swift.inc').read_text().rstrip() + s[oe:]
s = once(s, '            FlightCompanionV3Observer.shared.startObservation() }', '        }', 'session scoped startup')
s = once(s, '                gps.stop()\n            }\n        }\n', '                gps.stopForBackgroundIfIdle()\n            }\n        }\n', 'screen lock')
# Batched writes preserve every low acceleration sample without a file open at 5 Hz.
log_start = s.index('    func append(_ evidence: FlightV3Evidence) {')
log_end = s.index('\n    func all() -> [FlightV3Evidence]', log_start)
s = s[:log_start] + '''    func append(_ evidence: FlightV3Evidence) { appendBatch([evidence]) }

    func appendBatch(_ values: [FlightV3Evidence]) {
        var data = Data()
        for value in values {
            guard let encoded = try? encoder.encode(value) else { continue }
            data.append(encoded); data.append(0x0A)
        }
        guard !data.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: data) } catch { }
    }
''' + s[log_end:]
s = once(s, 'LabeledContent("RAIDO Roster", value: "2.23.0")', 'LabeledContent("RAIDO Roster", value: "2.26.0")', 'visible version')
s += '\n' + MARKER + '\n'

# Add the Foundation-only, directly tested policy to the generated iOS target.
name = 'FlightSensorPolicy.swift'
if not (ROOT / 'RAIDORoster' / name).is_file():
    raise RuntimeError('FlightSensorPolicy.swift missing')
build_id, file_id = 'A22600000000000000000001', 'B22600000000000000000001'
pbx = once(pbx, '/* End PBXBuildFile section */',
    f'\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};\n/* End PBXBuildFile section */', 'PBX build')
pbx = once(pbx, '/* End PBXFileReference section */',
    f'\t\t{file_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */', 'PBX reference')
pbx = once(pbx, 'B00000000000000000000002 /* ContentView.swift */,',
    f'B00000000000000000000002 /* ContentView.swift */,\n\t\t\t\t{file_id} /* {name} */,', 'PBX group')
pbx = once(pbx, 'A00000000000000000000002 /* ContentView.swift in Sources */,',
    f'A00000000000000000000002 /* ContentView.swift in Sources */, {build_id} /* {name} in Sources */,', 'PBX sources')
pbx = re.sub(r'MARKETING_VERSION = [^;]+;', 'MARKETING_VERSION = 2.26.0;', pbx)
pbx = re.sub(r'CURRENT_PROJECT_VERSION = [^;]+;', 'CURRENT_PROJECT_VERSION = 2260;', pbx)
# Everything is validated in memory before mutating either generated file.
PBX.write_text(pbx)
CONTENT.write_text(s)
print('V2.26 validated sensor/session driver applied')
