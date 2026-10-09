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
        if text[i] == '{': depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0: return i + 1
    return -1

ms = s.find('private final class TodayLiveFlightLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {')
me = s.find('\nstruct TodayRouteMapCard: View {', ms)
if ms < 0 or me < 0: raise RuntimeError('auto-arm manager bounds missing')
m = s[ms:me]

anchor = 'private final class TodayLiveFlightLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {\n'
if 'static let shared = TodayLiveFlightLocationManager()' not in m:
    m = m.replace(anchor, anchor + '    static let shared = TodayLiveFlightLocationManager()\n', 1)

old_enum = '    private enum CompanionPhase { case parked, taxiOut, takeoffRoll, airborne, descent, taxiIn, complete }'
new_enum = '    private enum CompanionPhase { case parked, armed, groundCandidate, taxiOut, takeoffRoll, airborne, descent, taxiIn, complete }'
if old_enum in m: m = m.replace(old_enum, new_enum, 1)
elif new_enum not in m: raise RuntimeError('auto-arm phase enum missing')

state = '    private var previousMeasuredSpeed: CLLocationSpeed?\n'
if state not in m: raise RuntimeError('auto-arm state anchor missing')
if 'private var automaticDepartureAt:' not in m:
    m = m.replace(state, state + '''    private var automaticDepartureAt: Date?\n    private var automaticOrigin: CLLocationCoordinate2D?\n    private var automaticKey: String?\n    private var automaticMonitoring = false\n    private var automaticRegionID: String?\n    private var groundCandidateAt: Date?\n    private var stoppedAt: Date?\n    private var highSpeedAt: Date?\n    private let autoLead: TimeInterval = 30 * 60\n    private let autoGrace: TimeInterval = 4 * 60 * 60\n    private let airportGateRadius: CLLocationDistance = 6_000\n\n''', 1)

old_power = '        case .parked, .complete: manager.desiredAccuracy = kCLLocationAccuracyHundredMeters; manager.distanceFilter = 50\n'
new_power = '        case .parked, .armed: manager.desiredAccuracy = kCLLocationAccuracyKilometer; manager.distanceFilter = 250\n        case .groundCandidate: manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters; manager.distanceFilter = 15\n        case .complete: manager.desiredAccuracy = kCLLocationAccuracyHundredMeters; manager.distanceFilter = 50\n'
if old_power in m: m = m.replace(old_power, new_power, 1)
elif 'case .groundCandidate:' not in m: raise RuntimeError('auto-arm power anchor missing')

start = m.find('    func start() {\n')
if start < 0: raise RuntimeError('auto-arm start missing')
if 'func configureAutomaticFlight(from items:' not in m:
    helpers = r'''    func configureAutomaticFlight(from items: [RosterItem], now: Date = Date()) {
        let candidates = items.flatMap { $0.flightActivities }.compactMap { activity -> (RosterActivity, Date)? in
            guard let date = parseUTCStamp(activity.startUTC), date >= now.addingTimeInterval(-autoGrace) else { return nil }
            return (activity, date)
        }.sorted { $0.1 < $1.1 }
        guard let selected = candidates.first else { return }
        let codes = routeCodes(selected.0.route)
        guard let originCode = codes.first, let origin = TodayAirportCoordinates.airports[originCode] else { return }
        let key = [selected.0.startUTC, selected.0.route, selected.0.aircraftReg].joined(separator: "|")
        if automaticKey != key {
            automaticKey = key
            automaticDepartureAt = selected.1
            automaticOrigin = origin.coordinate
            routeCoordinates = codes.compactMap { TodayAirportCoordinates.airports[$0]?.coordinate }
            configureAircraftTracking(registration: selected.0.aircraftReg)
            companionPhase = .armed
            flightPhaseText = "Armed · automatic"
            configureAutoRegion(code: originCode, coordinate: origin.coordinate)
        }
        automaticMonitoring = true
        requestAutomaticAuthorization()
        manager.startMonitoringSignificantLocationChanges()
        evaluateAuto(now: now, location: manager.location)
    }

    private func routeCodes(_ route: String) -> [String] {
        route.uppercased().replacingOccurrences(of: "→", with: " ")
            .replacingOccurrences(of: "–", with: " ").replacingOccurrences(of: "—", with: " ")
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "/", with: " ")
            .split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count == 3 }
    }

    private func requestAutomaticAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    private func configureAutoRegion(code: String, coordinate: CLLocationCoordinate2D) {
        if let id = automaticRegionID {
            for region in manager.monitoredRegions where region.identifier == id { manager.stopMonitoring(for: region) }
        }
        let radius = min(airportGateRadius, manager.maximumRegionMonitoringDistance)
        guard radius > 0 else { return }
        let id = "RAIDORoster.AutoDeparture.\(code)"
        let region = CLCircularRegion(center: coordinate, radius: radius, identifier: id)
        region.notifyOnEntry = true; region.notifyOnExit = false
        automaticRegionID = id
        manager.startMonitoring(for: region)
        manager.requestState(for: region)
    }

    private func insideAirport(_ value: CLLocation) -> Bool {
        guard let origin = automaticOrigin else { return false }
        return value.distance(from: CLLocation(latitude: origin.latitude, longitude: origin.longitude)) <= airportGateRadius
    }

    private func insideAutoWindow(_ now: Date) -> Bool {
        guard let departure = automaticDepartureAt else { return false }
        return now >= departure.addingTimeInterval(-autoLead) && now <= departure.addingTimeInterval(autoGrace)
    }

    private func evaluateAuto(now: Date, location: CLLocation?) {
        guard automaticMonitoring, insideAutoWindow(now), let location, insideAirport(location) else { return }
        guard !isTracking else { return }
        acquisitionStartedAt = now
        isTracking = true
        companionPhase = .armed
        flightPhaseText = "At departure airport · armed"
        applyPowerProfile()
        manager.startUpdatingLocation()
        restartHybridTask()
    }

'''
    m = m[:start] + helpers + m[start:]

# Explicit Start remains a manual override.
if '    func start() {\n        automaticMonitoring = false\n' not in m:
    m = m.replace('    func start() {\n', '    func start() {\n        automaticMonitoring = false\n', 1)

# Re-evaluate auto arming from every accepted location update.
ls = m.find('    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {')
le = m.find('    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {', ls)
if ls < 0 or le < 0: raise RuntimeError('auto-arm location callback bounds missing')
lb = m[ls:le]
if 'evaluateAuto(now: Date(), location:' not in lb:
    if '        location = candidate\n' in lb:
        lb = lb.replace('        location = candidate\n', '        location = candidate\n        evaluateAuto(now: Date(), location: candidate)\n', 1)
    elif '        location = newest\n' in lb:
        lb = lb.replace('        location = newest\n', '        location = newest\n        evaluateAuto(now: Date(), location: newest)\n', 1)
    else: raise RuntimeError('auto-arm accepted location anchor missing')
    m = m[:ls] + lb + m[le:]

# Airport region callbacks are wake-up opportunities, not departure confirmation.
cb = m.find('    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {')
if cb < 0: raise RuntimeError('auto-arm delegate insertion anchor missing')
if 'didEnterRegion region:' not in m:
    callbacks = r'''    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard automaticMonitoring, region.identifier == automaticRegionID else { return }
        evaluateAuto(now: Date(), location: manager.location)
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard automaticMonitoring, region.identifier == automaticRegionID, state == .inside else { return }
        evaluateAuto(now: Date(), location: manager.location)
    }

'''
    m = m[:cb] + callbacks + m[cb:]

# Conservative ground classifier: airport + schedule window first; bus/van motion
# starts as candidate and rolls back after stopping. Airborne still requires the
# existing high speed / altitude confirmation.
ps = m.find('    private func updatePhase(_ value: CLLocation, estimated: Bool, now: Date) {')
pe = block_end(m, ps) if ps >= 0 else -1
if ps < 0 or pe < 0: raise RuntimeError('auto-arm phase function bounds missing')
p = m[ps:pe]
old = '''        case .parked:\n            if speed >= 2.5 { taxiOutStartedAt = now; companionPhase = .taxiOut; flightPhaseText = "Taxi out"; applyPowerProfile() }\n        case .taxiOut:\n'''
new = '''        case .parked:\n            if automaticMonitoring { companionPhase = .armed; flightPhaseText = "Armed · automatic"; applyPowerProfile() }\n            else if speed >= 2.5 { taxiOutStartedAt = now; companionPhase = .taxiOut; flightPhaseText = "Taxi out"; applyPowerProfile() }\n        case .armed:\n            if insideAutoWindow(now), insideAirport(value), speed >= 2.5 {\n                groundCandidateAt = now; stoppedAt = nil; companionPhase = .groundCandidate\n                flightPhaseText = "Ground movement · checking"; applyPowerProfile()\n            }\n        case .groundCandidate:\n            if !insideAutoWindow(now) || !insideAirport(value) {\n                companionPhase = .armed; flightPhaseText = "Armed · automatic"; groundCandidateAt = nil; applyPowerProfile()\n            } else if speed < 1.5 {\n                stoppedAt = stoppedAt ?? now\n                if now.timeIntervalSince(stoppedAt ?? now) >= 75 {\n                    companionPhase = .armed; flightPhaseText = "At departure airport · armed"\n                    groundCandidateAt = nil; stoppedAt = nil; applyPowerProfile()\n                }\n            } else if now.timeIntervalSince(groundCandidateAt ?? now) >= 45 && speed <= 18 {\n                taxiOutStartedAt = groundCandidateAt ?? now; companionPhase = .taxiOut\n                flightPhaseText = "Taxi out · probable"; applyPowerProfile()\n            }\n        case .taxiOut:\n'''
if old in p: p = p.replace(old, new, 1)
elif 'case .groundCandidate:' not in p: raise RuntimeError('auto-arm ground phase anchor drifted')
# Make takeoff-roll entry harder than the old speed-only rule.
old_roll = '            if speed >= 20 || (speed >= 15 && accelerating) { companionPhase = .takeoffRoll; flightPhaseText = "Takeoff roll"; applyPowerProfile() }'
new_roll = '            if speed >= 28 || (speed >= 20 && accelerating) { highSpeedAt = highSpeedAt ?? now; if now.timeIntervalSince(highSpeedAt ?? now) >= 5 { companionPhase = .takeoffRoll; flightPhaseText = "Takeoff roll · probable"; applyPowerProfile() } } else { highSpeedAt = nil }'
if old_roll in p: p = p.replace(old_roll, new_roll, 1)
m = m[:ps] + p + m[pe:]

# Keep preflight pickup / airside-transfer points out of the measured green trail.
pfs = m.find('    private func publishFused(_ value: CLLocation, source: String, estimated: Bool, now: Date) {')
pfe = block_end(m, pfs) if pfs >= 0 else -1
if pfs < 0 or pfe < 0: raise RuntimeError('auto-arm publish function bounds missing')
pf = m[pfs:pfe]
guard = '        guard !estimated else { return } // measured trail only\n'
if guard not in pf: raise RuntimeError('auto-arm measured trail guard missing')
extra = '        if companionPhase == .parked || companionPhase == .armed || companionPhase == .groundCandidate { return } // preflight ground transport is not aircraft trail\n'
if extra not in pf: pf = pf.replace(guard, guard + extra, 1)
m = m[:pfs] + pf + m[pfe:]

s = s[:ms] + m + s[me:]

# Today observes the shared engine; leaving the tab must not kill auto detection.
cs = s.find('struct TodayRouteMapCard: View {')
ce = s.find('\nprivate struct CrewCompanionPhase', cs)
if ce < 0: ce = s.find('\nstruct TodayPersonalNoteDisclosure', cs)
if cs < 0 or ce < 0: raise RuntimeError('auto-arm map bounds missing')
c = s[cs:ce]
c = c.replace('@StateObject private var gps = TodayLiveFlightLocationManager()', '@ObservedObject private var gps = TodayLiveFlightLocationManager.shared', 1)
c = c.replace('''        .onDisappear {\n            gps.stop()\n        }\n''', '')
s = s[:cs] + c + s[ce:]

# Configure from the cached roster at app launch, independent of opening Today.
vs = s.find('struct ContentView: View {')
ve = s.find('\nstruct RosterHomeView: View {', vs)
if vs < 0 or ve < 0: raise RuntimeError('auto-arm ContentView bounds missing')
v = s[vs:ve]
if 'configureAutomaticFlight(from: appState.rosterStore.items)' not in v:
    close = v.rfind('\n    }\n')
    if close < 0: raise RuntimeError('auto-arm ContentView close missing')
    mods = '''\n        .onAppear { TodayLiveFlightLocationManager.shared.configureAutomaticFlight(from: appState.rosterStore.items) }\n        .onChange(of: appState.rosterStore.snapshot) { _, _ in\n            TodayLiveFlightLocationManager.shared.configureAutomaticFlight(from: appState.rosterStore.items)\n        }'''
    v = v[:close] + mods + v[close:]
    s = s[:vs] + v + s[ve:]

for required in ['static let shared = TodayLiveFlightLocationManager()', 'func configureAutomaticFlight(from items:', 'case .groundCandidate:', 'Takeoff roll · probable', 'preflight ground transport is not aircraft trail']:
    if required not in s: raise RuntimeError('auto-arm semantic guard missing: ' + required)

s += '\n// Flight Companion automatic roster arming with airport/time gating\n'
CONTENT.write_text(s)
print('Flight Companion automatic roster arming applied')
