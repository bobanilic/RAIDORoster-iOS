from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster/ContentView.swift"
s = CONTENT.read_text()

ms = s.find('private final class TodayLiveFlightLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {')
me = s.find('\nstruct TodayRouteMapCard: View {', ms)
if ms < 0 or me < 0:
    raise RuntimeError('V2 manager boundaries missing')
m = s[ms:me]

pub = '    @Published private(set) var positionIsEstimated = false\n'
if pub not in m:
    raise RuntimeError('V2 published anchor missing')
if 'flightPhaseText' not in m:
    m = m.replace(pub, pub + '''    @Published private(set) var flightPhaseText = "Parked"\n    @Published private(set) var taxiOutDurationText: String?\n    @Published private(set) var airborneDurationText: String?\n    @Published private(set) var taxiInDurationText: String?\n    @Published private(set) var takeoffTimeText: String?\n    @Published private(set) var landingTimeText: String?\n\n''', 1)

# The original V2.19.6 constant is not a reliable insertion point anymore because
# later Flight Companion reliability patches can legitimately reshape that state
# region. v2219 guarantees lastFusedTrailAt exists, so prefer the old constant
# when available and otherwise insert next to that stable state field.
state = '    private let maximumExtrapolationAge: TimeInterval = 120\n'
state_fallback = '    private var lastFusedTrailAt: Date?\n'
if 'private enum CompanionPhase' not in m:
    state_anchor = state if state in m else state_fallback if state_fallback in m else None
    if state_anchor is None:
        raise RuntimeError('V2 state anchor missing: neither extrapolation nor fused-trail state found')
    m = m.replace(state_anchor, state_anchor + '''    private enum CompanionPhase { case parked, taxiOut, takeoffRoll, airborne, descent, taxiIn, complete }\n    private var companionPhase: CompanionPhase = .parked\n    private var routeCoordinates: [CLLocationCoordinate2D] = []\n    private var taxiOutStartedAt: Date?\n    private var airborneAt: Date?\n    private var landedAt: Date?\n    private var stationarySince: Date?\n    private var groundAltitude: CLLocationDistance?\n    private var lastMeasuredProgress = 0.0\n    private var lastMeasuredProgressAt: Date?\n    private var previousMeasuredSpeed: CLLocationSpeed?\n\n''', 1)

# Background tracking is session-scoped and only starts after explicit user
# action. Patch the individual Core Location knobs rather than relying on one
# formatting-sensitive three-line block, then fail closed if any expected knob
# cannot be established.
for old, new in [
    ('manager.pausesLocationUpdatesAutomatically = false', 'manager.pausesLocationUpdatesAutomatically = true'),
    ('manager.allowsBackgroundLocationUpdates = false', 'manager.allowsBackgroundLocationUpdates = true'),
    ('manager.showsBackgroundLocationIndicator = false', 'manager.showsBackgroundLocationIndicator = true'),
]:
    if old in m:
        m = m.replace(old, new, 1)
for required in [
    'manager.pausesLocationUpdatesAutomatically = true',
    'manager.allowsBackgroundLocationUpdates = true',
    'manager.showsBackgroundLocationIndicator = true',
]:
    if required not in m:
        raise RuntimeError('V2 background-location configuration missing: ' + required)

idx = m.find('    func start() {\n')
if idx < 0:
    raise RuntimeError('V2 start anchor missing')
if 'func configureFlightRoute(coordinates:' not in m:
    helpers = r'''    func configureFlightRoute(coordinates: [CLLocationCoordinate2D]) {
        routeCoordinates = coordinates
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds.rounded()))
        let h = t / 3600, min = (t % 3600) / 60
        return h > 0 ? String(format: "%dh %02dm", h, min) : String(format: "%dm", min)
    }

    private func clockText(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; return f.string(from: date)
    }

    private var routeDistance: CLLocationDistance? {
        guard let a = routeCoordinates.first, let b = routeCoordinates.last else { return nil }
        return CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private func destinationDistance(_ value: CLLocation) -> CLLocationDistance? {
        guard let d = routeCoordinates.last else { return nil }
        return value.distance(from: CLLocation(latitude: d.latitude, longitude: d.longitude))
    }

    private func progress(_ value: CLLocation) -> Double? {
        guard let total = routeDistance, total > 1_000, let remaining = destinationDistance(value) else { return nil }
        return min(1, max(0, 1 - remaining / total))
    }

    private func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ f: Double) -> CLLocationCoordinate2D {
        let t = min(1, max(0, f)); let p1 = a.latitude * .pi / 180, l1 = a.longitude * .pi / 180
        let p2 = b.latitude * .pi / 180, l2 = b.longitude * .pi / 180
        let d = 2 * asin(sqrt(pow(sin((p2-p1)/2),2) + cos(p1)*cos(p2)*pow(sin((l2-l1)/2),2)))
        guard d > 0.000001 else { return a }
        let x = sin((1-t)*d)/sin(d), y = sin(t*d)/sin(d)
        let vx = x*cos(p1)*cos(l1)+y*cos(p2)*cos(l2), vy = x*cos(p1)*sin(l1)+y*cos(p2)*sin(l2), vz = x*sin(p1)+y*sin(p2)
        return .init(latitude: atan2(vz, sqrt(vx*vx+vy*vy))*180/.pi, longitude: atan2(vy, vx)*180/.pi)
    }

    private func estimatedRouteLocation(now: Date) -> CLLocation? {
        guard companionPhase == .airborne || companionPhase == .descent, let takeoff = airborneAt,
              let a = routeCoordinates.first, let b = routeCoordinates.last, let total = routeDistance, total > 1_000 else { return nil }
        let speed = 220.0, anchorDate = lastMeasuredProgressAt ?? takeoff
        let anchor = lastMeasuredProgressAt == nil ? 0 : lastMeasuredProgress
        let p = min(0.995, max(anchor, anchor + max(0, now.timeIntervalSince(anchorDate))*speed/total))
        if p >= 0.86 && companionPhase == .airborne { companionPhase = .descent; flightPhaseText = "Descent · estimated"; applyPowerProfile() }
        let c = interpolate(a, b, p)
        return CLLocation(coordinate: c, altitude: 0, horizontalAccuracy: 5_000, verticalAccuracy: -1, course: -1, speed: speed, timestamp: now)
    }

    private func applyPowerProfile() {
        switch companionPhase {
        case .parked, .complete: manager.desiredAccuracy = kCLLocationAccuracyHundredMeters; manager.distanceFilter = 50
        case .taxiOut, .taxiIn: manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters; manager.distanceFilter = 10
        case .takeoffRoll: manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation; manager.distanceFilter = kCLDistanceFilterNone
        case .airborne: manager.desiredAccuracy = kCLLocationAccuracyHundredMeters; manager.distanceFilter = 150
        case .descent: manager.desiredAccuracy = kCLLocationAccuracyBest; manager.distanceFilter = 30
        }
    }

    private func updateDurations(_ now: Date) {
        if let d = taxiOutStartedAt { taxiOutDurationText = durationText((airborneAt ?? now).timeIntervalSince(d)) }
        if let d = airborneAt { airborneDurationText = durationText((landedAt ?? now).timeIntervalSince(d)) }
        if let d = landedAt { taxiInDurationText = durationText(now.timeIntervalSince(d)) }
    }

    private func updatePhase(_ value: CLLocation, estimated: Bool, now: Date) {
        updateDurations(now); guard !estimated else { return }; let speed = max(0, value.speed)
        if groundAltitude == nil && speed < 2.5 && value.verticalAccuracy >= 0 { groundAltitude = value.altitude }
        if let p = progress(value) { lastMeasuredProgress = max(lastMeasuredProgress, p); lastMeasuredProgressAt = now }
        let gain = groundAltitude.map { value.altitude - $0 } ?? 0, remaining = destinationDistance(value) ?? .greatestFiniteMagnitude
        switch companionPhase {
        case .parked:
            if speed >= 2.5 { taxiOutStartedAt = now; companionPhase = .taxiOut; flightPhaseText = "Taxi out"; applyPowerProfile() }
        case .taxiOut:
            if speed < 1.5 { stationarySince = stationarySince ?? now; if now.timeIntervalSince(stationarySince ?? now) >= 30 { manager.desiredAccuracy = kCLLocationAccuracyHundredMeters; manager.distanceFilter = 25 } }
            else { stationarySince = nil; applyPowerProfile() }
            let accelerating = previousMeasuredSpeed.map { speed - $0 >= 4 } ?? false
            if speed >= 20 || (speed >= 15 && accelerating) { companionPhase = .takeoffRoll; flightPhaseText = "Takeoff roll"; applyPowerProfile() }
        case .takeoffRoll:
            if speed >= 55 || gain >= 80 { airborneAt = now; takeoffTimeText = clockText(now); companionPhase = .airborne; flightPhaseText = "Airborne"; stationarySince = nil; applyPowerProfile() }
            else if speed < 8 { companionPhase = .taxiOut; flightPhaseText = "Taxi out"; applyPowerProfile() }
        case .airborne:
            if remaining < 80_000 || (lastMeasuredProgress > 0.82 && speed < 180) { companionPhase = .descent; flightPhaseText = "Descent"; applyPowerProfile() }
        case .descent:
            if remaining < 12_000 && speed < 55 { landedAt = now; landingTimeText = clockText(now); companionPhase = .taxiIn; flightPhaseText = "Landed · taxi in"; stationarySince = nil; applyPowerProfile() }
        case .taxiIn:
            if speed < 1.5 { stationarySince = stationarySince ?? now; if now.timeIntervalSince(stationarySince ?? now) >= 120 { companionPhase = .complete; flightPhaseText = "On block"; applyPowerProfile() } } else { stationarySince = nil }
        case .complete: break
        }
        previousMeasuredSpeed = speed; updateDurations(now)
    }

'''
    m = m[:idx] + helpers + m[idx:]

acq = '        acquisitionStartedAt = Date()\n'
if acq not in m:
    raise RuntimeError('V2 acquisition anchor missing')
m = m.replace(acq, acq + '''        companionPhase = .parked\n        flightPhaseText = "Parked"\n        taxiOutStartedAt = nil; airborneAt = nil; landedAt = nil; stationarySince = nil; groundAltitude = nil\n        lastMeasuredProgress = 0; lastMeasuredProgressAt = nil; previousMeasuredSpeed = nil\n        taxiOutDurationText = nil; airborneDurationText = nil; taxiInDurationText = nil; takeoffTimeText = nil; landingTimeText = nil\n        applyPowerProfile()\n''', 1)

old = '''        if let location {\n            // Keep the last physical fix visible but explicitly stale rather\n            // than inventing a long dead-reckoning solution from phone sensors.\n            publishFused(location, source: "Last GNSS fix", estimated: true, now: now)\n            return\n        }\n'''
new = '''        if let estimate = estimatedRouteLocation(now: now) {\n            publishFused(estimate, source: "Estimated · route model", estimated: true, now: now)\n            return\n        }\n        if let location { publishFused(location, source: "Last GNSS fix", estimated: true, now: now); return }\n'''
if old not in m:
    # Tolerate the compact equivalent if an earlier reliability patch already
    # condensed the stale-GNSS fallback, but still require a recognizable last
    # GNSS fallback so we do not patch an unrelated function.
    compact = '        if let location { publishFused(location, source: "Last GNSS fix", estimated: true, now: now); return }\n'
    if compact not in m:
        raise RuntimeError('V2 fallback anchor missing')
    m = m.replace(compact, new, 1)
else:
    m = m.replace(old, new, 1)
anchor = '        positionIsEstimated = estimated\n\n'
if anchor not in m:
    raise RuntimeError('V2 publish anchor missing')
if 'updatePhase(value, estimated: estimated, now: now)' not in m:
    m = m.replace(anchor, anchor + '        updatePhase(value, estimated: estimated, now: now)\n\n', 1)
s = s[:ms] + m + s[me:]

cs = s.find('struct TodayRouteMapCard: View {'); ce = s.find('\nprivate struct CrewCompanionPhase', cs)
if ce < 0: ce = s.find('\nstruct TodayPersonalNoteDisclosure', cs)
if cs < 0 or ce < 0: raise RuntimeError('V2 map boundaries missing')
c = s[cs:ce]
old = '''        .onAppear {\n            gps.configureAircraftTracking(registration: trackedAircraftRegistration)\n            gps.configureTrailPersistence(sessionKey: trackingSessionKey)\n        }'''
new = '''        .onAppear {\n            gps.configureAircraftTracking(registration: trackedAircraftRegistration)\n            gps.configureFlightRoute(coordinates: points.map(\\.coordinate))\n            gps.configureTrailPersistence(sessionKey: trackingSessionKey)\n        }'''
if old in c:
    c = c.replace(old, new, 1)
elif new not in c:
    raise RuntimeError('V2 map onAppear anchor missing')
metric = 'liveMetric("Position", positionSourceDetailText)'
if metric in c and 'liveMetric("Phase", gps.flightPhaseText)' not in c: c = c.replace(metric, 'liveMetric("Phase", gps.flightPhaseText)\n                        ' + metric, 1)

# Final semantic guards catch silent no-op drift before xcodebuild.
for required in [
    'private enum CompanionPhase',
    'func configureFlightRoute(coordinates:',
    'estimatedRouteLocation(now:',
    'updatePhase(value, estimated: estimated, now: now)',
]:
    if required not in m:
        raise RuntimeError('V2 semantic guard missing: ' + required)
if 'gps.configureFlightRoute(coordinates: points.map(\\.coordinate))' not in c:
    raise RuntimeError('V2 route configuration guard missing')

s = s[:cs] + c + s[ce:]
s += '\n// Flight Companion V2 adaptive tracking and phase estimator\n'
CONTENT.write_text(s)
print('Flight Companion V2 applied')
