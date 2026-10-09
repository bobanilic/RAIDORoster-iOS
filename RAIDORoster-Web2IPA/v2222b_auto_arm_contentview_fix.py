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


vs = s.find('struct ContentView: View {')
ve = s.find('\nstruct RosterHomeView: View {', vs)
if vs < 0 or ve < 0:
    raise RuntimeError('auto-arm fix: ContentView bounds missing')

v = s[vs:ve]
mods = '''        .onAppear { TodayLiveFlightLocationManager.shared.configureAutomaticFlight(from: appState.rosterStore.items) }\n        .onChange(of: appState.rosterStore.snapshot) { _, _ in\n            TodayLiveFlightLocationManager.shared.configureAutomaticFlight(from: appState.rosterStore.items)\n        }'''

v = v.replace('\n' + mods, '')
body_start = v.find('    var body: some View {')
body_end = block_end(v, body_start) if body_start >= 0 else -1
if body_start < 0 or body_end < 0:
    raise RuntimeError('auto-arm fix: ContentView body bounds missing')
body = v[body_start:body_end]
if 'TodayLiveFlightLocationManager.shared.configureAutomaticFlight' not in body:
    close = body.rfind('\n    }')
    if close < 0:
        raise RuntimeError('auto-arm fix: ContentView body close missing')
    body = body[:close] + '\n' + mods + body[close:]
    v = v[:body_start] + body + v[body_end:]
body_start = v.find('    var body: some View {')
body_end = block_end(v, body_start)
body = v[body_start:body_end]
if mods not in body:
    raise RuntimeError('auto-arm fix: modifiers are not attached to ContentView body')
if v.count('TodayLiveFlightLocationManager.shared.configureAutomaticFlight') != 2:
    raise RuntimeError('auto-arm fix: unexpected automatic-flight configuration copies')
s = s[:vs] + v + s[ve:]

ms = s.find('private final class TodayLiveFlightLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {')
me = s.find('\nstruct TodayRouteMapCard: View {', ms)
if ms < 0 or me < 0:
    raise RuntimeError('companion state: manager bounds missing')
m = s[ms:me]
anchor = '    func start() {\n'
if anchor not in m:
    raise RuntimeError('companion state: start anchor missing')

old_helper_start = m.find('    func companionStateText() -> String {')
if old_helper_start < 0:
    old_helper_start = m.find('    func companionStateText(now: Date = Date()) -> String {')
if old_helper_start >= 0:
    old_helper_end = block_end(m, old_helper_start)
    m = m[:old_helper_start] + m[old_helper_end:]

helper = r'''    private var companionPowerModeText: String {
        if !isTracking { return automaticMonitoring ? "low-power armed" : "idle" }
        switch companionPhase {
        case .parked, .armed: return "armed low-power"
        case .groundCandidate: return "ground verification"
        case .taxiOut, .taxiIn: return "taxi"
        case .takeoffRoll: return "takeoff high-accuracy"
        case .airborne: return "cruise reduced"
        case .descent: return "descent high-accuracy"
        case .complete: return "complete"
        }
    }

    func companionStateText(now: Date = Date()) -> String {
        let departure = automaticDepartureAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none"
        let origin = automaticRegionID?.split(separator: ".").last.map(String.init) ?? "none"
        return [
            "version=2.23.0-companion-state",
            "scheduledDepartureUTC=\(departure)",
            "originAirport=\(origin)",
            "automaticMonitoring=\(automaticMonitoring)",
            "activeWindow=\(insideAutoWindow(now))",
            "phase=\(flightPhaseText)",
            "tracking=\(isTracking)",
            "source=\(positionSourceText)",
            "estimated=\(positionIsEstimated)",
            "powerMode=\(companionPowerModeText)",
            "standardGPS=\(isTracking)",
            "desiredAccuracy=\(Int(manager.desiredAccuracy.rounded()))",
            "distanceFilter=\(Int(manager.distanceFilter.rounded()))"
        ].joined(separator: "\n")
    }

'''
m = m.replace(anchor, helper + anchor, 1)

# Return-flight hotfix: a fresh ADS-B observation is already tied to the roster
# aircraft registration. It can therefore confirm aircraft ground movement when
# cabin GNSS is weak, without allowing generic phone/car speed to do so.
hotfix_marker = '    private func applyFreshADSBPhase('
if hotfix_marker not in m:
    hotfix = r'''    private func applyFreshADSBPhase(_ value: CLLocation, source: String, estimated: Bool, now: Date) {
        guard source == "ADS-B live", !estimated, automaticMonitoring, insideAutoWindow(now) else { return }
        let speed = max(0, value.speed)
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
        case .parked, .airborne, .descent, .taxiIn, .complete:
            break
        }
        updateDurations(now)
    }

'''
    m = m.replace(anchor, hotfix + anchor, 1)

# Run the roster-aircraft ADS-B classifier for every fused publication. The
# existing estimator still runs first and keeps GNSS/route-model behavior intact.
pfs = m.find('    private func publishFused(_ value: CLLocation, source: String, estimated: Bool, now: Date) {')
pfe = block_end(m, pfs) if pfs >= 0 else -1
if pfs < 0 or pfe < 0:
    raise RuntimeError('return hotfix: publishFused bounds missing')
pf = m[pfs:pfe]
phase_line = '        updatePhase(value, estimated: estimated, now: now)\n'
adsb_line = '        applyFreshADSBPhase(value, source: source, estimated: estimated, now: now)\n'
if adsb_line not in pf:
    if phase_line not in pf:
        raise RuntimeError('return hotfix: updatePhase anchor missing')
    pf = pf.replace(phase_line, phase_line + adsb_line, 1)
m = m[:pfs] + pf + m[pfe:]

# Authorization changes must re-evaluate automatic monitoring. This fixes the
# observed case where reopening the app was required before the airport gate
# transitioned into active tracking.
auth_sig = '    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {'
auth_pos = m.find(auth_sig)
auth_body = '''\n        if automaticMonitoring {\n            requestAutomaticAuthorization()\n            manager.startMonitoringSignificantLocationChanges()\n            if let id = automaticRegionID, let region = manager.monitoredRegions.first(where: { $0.identifier == id }) {\n                manager.requestState(for: region)\n            }\n            evaluateAuto(now: Date(), location: manager.location)\n        }\n'''
if auth_pos >= 0:
    auth_end = block_end(m, auth_pos)
    block = m[auth_pos:auth_end]
    if 'if automaticMonitoring {' not in block:
        brace = block.find('{') + 1
        block = block[:brace] + auth_body + block[brace:]
        m = m[:auth_pos] + block + m[auth_end:]
else:
    cb = m.find('    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {')
    if cb < 0:
        raise RuntimeError('return hotfix: delegate insertion anchor missing')
    callback = '''    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {\n        if automaticMonitoring {\n            requestAutomaticAuthorization()\n            manager.startMonitoringSignificantLocationChanges()\n            if let id = automaticRegionID, let region = manager.monitoredRegions.first(where: { $0.identifier == id }) {\n                manager.requestState(for: region)\n            }\n            evaluateAuto(now: Date(), location: manager.location)\n        }\n    }\n\n'''
    m = m[:cb] + callback + m[cb:]

s = s[:ms] + m + s[me:]

# Ensure the map presentation consumes fused aircraft state even when standard
# phone GPS is not active. Fresh ADS-B must be able to move the aircraft marker.
cs = s.find('struct TodayRouteMapCard: View {')
ce = s.find('\nprivate struct CrewCompanionPhase', cs)
if ce < 0:
    ce = s.find('\nstruct TodayPersonalNoteDisclosure', cs)
if cs < 0 or ce < 0:
    raise RuntimeError('return hotfix: TodayRouteMapCard bounds missing')
c = s[cs:ce]
c = c.replace('trail: gps.trail', 'trail: gps.fusedTrail')
c = c.replace('liveLocation: gps.location', 'liveLocation: gps.fusedLocation')
c = c.replace('liveLocation: gps.isTracking ? gps.fusedLocation : nil', 'liveLocation: gps.fusedLocation')
c = c.replace('if gps.isTracking, let coordinate = gps.fusedLocation?.coordinate', 'if let coordinate = gps.fusedLocation?.coordinate')
c = c.replace('if let coordinate = gps.location?.coordinate', 'if let coordinate = gps.fusedLocation?.coordinate')
if 'liveLocation: gps.fusedLocation' not in c:
    raise RuntimeError('return hotfix: map is not wired to fused aircraft position')
s = s[:cs] + c + s[ce:]

ss = s.find('struct SettingsView: View {')
se = s.find('\nstruct DutyHeroCard: View {', ss)
if ss < 0 or se < 0:
    raise RuntimeError('companion state: SettingsView bounds missing')
settings = s[ss:se]
section = '                Section("Diagnostics") {\n'
if section not in settings:
    raise RuntimeError('companion state: Diagnostics section missing')
if 'Flight Companion state' not in settings:
    settings = settings.replace(section, section + '''                    DisclosureGroup("Flight Companion state") {\n                        Text(TodayLiveFlightLocationManager.shared.companionStateText())\n                            .font(.caption.monospaced())\n                            .textSelection(.enabled)\n                    }\n''', 1)
s = s[:ss] + settings + s[se:]

for required in [
    'scheduledDepartureUTC=', 'originAirport=', 'automaticMonitoring=', 'activeWindow=',
    'powerMode=', 'standardGPS=', 'Flight Companion state',
    'applyFreshADSBPhase(value, source: source', 'Taxi out · ADS-B',
    'liveLocation: gps.fusedLocation'
]:
    if required not in s:
        raise RuntimeError('companion return-test guard missing: ' + required)

CONTENT.write_text(s)
print('Flight Companion ContentView fix + ADS-B return-test hotfix + power diagnostics applied')
