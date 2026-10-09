"""V2.29.1: select the aircraft operator and report the real GPS session state."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / 'RAIDORoster/ContentView.swift'
PBX = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
MARKER = '// V2.29.1 flight context and GPS status'
s = CONTENT.read_text()
if MARKER in s:
    if 'FlightTrackingStatus.swift in Sources' not in PBX.read_text():
        raise RuntimeError('Incomplete V2.29.1 installation')
    print('V2.29.1 flight context already applied')
    raise SystemExit(0)

def once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f'V2.29.1 anchor found {text.count(old)} times: {old[:100]}')
    return text.replace(old, new, 1)

# LY-TEN was removed by Fleet V2 when absent from the public website. It is now
# confirmed by GetJet's own fleet announcement, not inferred from an LY prefix:
# https://www.linkedin.com/posts/getjetairlines_getjetairlines-fleetmodernization-aviation-activity-7473724149845221376-nkCa
s = once(s, '        .init(registration: "LY-TAP", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),',
    '        .init(registration: "LY-TAP", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),\n'
    '        .init(registration: "LY-TEN", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),')
a = s.index('func announcementAirline(registration: String) -> AnnouncementAirline {')
b = s.index('\n}', a) + 2
s = s[:a] + '''func announcementAirline(registration: String) -> AnnouncementAirline {
    AnnouncementAirline.fromRoster(registration: registration,
        operators: Dictionary(uniqueKeysWithValues: FleetAircraftDefinition.all.map { ($0.registration, $0.operatorCode) }))
}''' + s[b:]

status = '''    // V2.29.1 flight context and GPS status
    private func refreshLocationServicesAvailability() {
        servicesCheckGeneration += 1
        let generation = servicesCheckGeneration
        Task { @MainActor [weak self] in
            let enabled = await Task.detached(priority: .utility) { CLLocationManager.locationServicesEnabled() }.value
            guard let self, self.servicesCheckGeneration == generation else { return }
            self.servicesAvailable = enabled
        }
    }

    func mapStatus(now: Date = Date()) -> FlightTrackingStatus {
        let permission: FlightTrackingStatus.Permission
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: permission = .allowed
        case .notDetermined: permission = .pending
        default: permission = .blocked
        }
        let opens = automaticDepartureAt?.addingTimeInterval(-autoLead)
        return FlightTrackingStatus.resolve(
            tracking: isTracking, automatic: automaticMonitoring, completed: companionPhase == .complete,
            servicesEnabled: servicesAvailable, permission: permission,
            source: fusedLocation == nil ? nil : positionSourceText, estimated: positionIsEstimated,
            acquisitionAge: acquisitionStartedAt.map { max(0, now.timeIntervalSince($0)) },
            windowOpen: insideAutoWindow(now), upcomingStart: opens.flatMap { now < $0 ? clockText($0) : nil })
    }

'''
s = once(s, '    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined',
    '    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined\n'
    '    @Published private var servicesAvailable = true\n    private var servicesCheckGeneration = 0')
s = once(s, '        authorizationStatus = manager.authorizationStatus\n        restoreSession(now: Date())',
    '        authorizationStatus = manager.authorizationStatus\n        refreshLocationServicesAvailability()\n        restoreSession(now: Date())')
s = once(s, '    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {\n',
    '    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {\n        refreshLocationServicesAvailability()\n')
s = once(s, '    private var companionPowerModeText: String {', status + '    private var companionPowerModeText: String {')
s = once(s, '''                    HStack(spacing: 6) {
                        Image(systemName: gps.fusedLocation == nil ? "location.slash" : "location")
                        Text(gps.fusedLocation == nil ? "GPS unavailable · route saved" : gps.positionSourceText)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }.font(.caption2).foregroundStyle(.secondary).padding(9)
                        .background(MidnightTheme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 9))
                        .padding(.horizontal, 18).padding(.bottom, 8)''', '''                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        let status = gps.mapStatus(now: context.date)
                        HStack(spacing: 6) {
                            Image(systemName: status.symbol)
                            Text(status.title).lineLimit(2)
                            Spacer(minLength: 0)
                        }.font(.caption2).foregroundStyle(.secondary).padding(9)
                            .background(MidnightTheme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 9))
                            .padding(.horizontal, 18).padding(.bottom, 8)
                            .accessibilityElement(children: .combine)
                            .accessibilityHint(status.detail)
                    }''')
s = once(s, 'Text(gps.positionSourceText + " · " + speedText).font(.caption).foregroundStyle(.secondary)',
    'Text(gps.mapStatus().title + " · " + speedText).font(.caption).foregroundStyle(.secondary)')
s = once(s, 'Text(gpsQualityDetailText).font(.caption).foregroundStyle(.secondary)\n                        if let error',
    'Text(gps.mapStatus().detail).font(.caption).foregroundStyle(.secondary)\n'
    '                        if gps.isTracking { Text(gpsQualityDetailText).font(.caption).foregroundStyle(.secondary) }\n                        if let error')
s = once(s, 'value: "2.29.0"', 'value: "2.29.1"')

pbx = PBX.read_text()
name, build, file = 'FlightTrackingStatus.swift', 'A22910000000000000000001', 'B22910000000000000000001'
if not (ROOT / 'RAIDORoster' / name).exists(): raise RuntimeError(name + ' missing')
pbx = once(pbx, '/* End PBXBuildFile section */', f'\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file} /* {name} */; }};\n/* End PBXBuildFile section */')
pbx = once(pbx, '/* End PBXFileReference section */', f'\t\t{file} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */')
pbx = once(pbx, 'B00000000000000000000002 /* ContentView.swift */,', f'B00000000000000000000002 /* ContentView.swift */,\n\t\t\t\t{file} /* {name} */,')
pbx = once(pbx, 'A00000000000000000000002 /* ContentView.swift in Sources */,', f'A00000000000000000000002 /* ContentView.swift in Sources */, {build} /* {name} in Sources */,')
pbx = re.sub(r'MARKETING_VERSION = [^;]+;', 'MARKETING_VERSION = 2.29.1;', pbx)
pbx = re.sub(r'CURRENT_PROJECT_VERSION = [^;]+;', 'CURRENT_PROJECT_VERSION = 2291;', pbx)
CONTENT.write_text(s)
PBX.write_text(pbx)
print('V2.29.1 announcement operator and GPS status applied')
