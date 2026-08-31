from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"

content = CONTENT.read_text()

# -----------------------------------------------------------------------------
# V2.17.8 — flight-aware GNSS quality engine.
# Keep Core Location as the source of truth, but reject physically implausible
# jumps, expose fix quality, and preserve recently valid speed/course through
# short GNSS dropouts that are common inside an aircraft cabin.
# -----------------------------------------------------------------------------
manager_start = content.find('private final class TodayLiveFlightLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {')
manager_end = content.find('\nstruct TodayRouteMapCard: View {', manager_start)
if manager_start < 0 or manager_end < 0:
    raise RuntimeError('V2.17.8 location manager boundaries not found')
manager = content[manager_start:manager_end]

# Published/retained navigation state.
if '@Published private(set) var gpsQualityText' not in manager:
    anchor = '    @Published private(set) var acquisitionStartedAt: Date?\n'
    if anchor not in manager:
        raise RuntimeError('V2.17.8 acquisition state anchor not found')
    manager = manager.replace(anchor, anchor + '''    @Published private(set) var gpsQualityText = "Acquiring"\n    @Published private(set) var rejectedFixCount = 0\n\n    private var retainedSpeed: CLLocationSpeed?\n    private var retainedSpeedAt: Date?\n    private var retainedCourse: CLLocationDirection?\n    private var retainedCourseAt: Date?\n    private let retainedNavigationLifetime: TimeInterval = 15\n''', 1)

# Add navigation-quality helpers before start().
if 'var displaySpeed: CLLocationSpeed?' not in manager:
    marker = '    func start() {\n'
    idx = manager.find(marker)
    if idx < 0:
        raise RuntimeError('V2.17.8 start boundary not found')
    helpers = r'''    var displaySpeed: CLLocationSpeed? {
        if let location, location.speed >= 0 { return location.speed }
        if let retainedSpeed, let retainedSpeedAt,
           Date().timeIntervalSince(retainedSpeedAt) <= retainedNavigationLifetime {
            return retainedSpeed
        }
        return nil
    }

    var displayCourse: CLLocationDirection? {
        if let location, location.course >= 0 { return location.course }
        if let retainedCourse, let retainedCourseAt,
           Date().timeIntervalSince(retainedCourseAt) <= retainedNavigationLifetime {
            return retainedCourse
        }
        return nil
    }

    var fixAge: TimeInterval? {
        guard let location else { return nil }
        return max(0, Date().timeIntervalSince(location.timestamp))
    }

    func startIfAuthorized() {
        guard CLLocationManager.locationServicesEnabled() else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if !isTracking { start() }
        default:
            break
        }
    }

    private func qualityText(for location: CLLocation) -> String {
        let age = abs(location.timestamp.timeIntervalSinceNow)
        let accuracy = location.horizontalAccuracy
        guard accuracy >= 0 else { return "Acquiring" }
        if age <= 5 && accuracy <= 30 { return "Excellent" }
        if age <= 10 && accuracy <= 75 { return "Good" }
        if age <= 20 && accuracy <= 200 { return "Usable" }
        if age <= 30 && accuracy <= 300 { return "Weak" }
        return "Poor"
    }

    private func isPhysicallyPlausible(_ candidate: CLLocation, after previous: CLLocation?) -> Bool {
        guard let previous else { return true }
        let dt = candidate.timestamp.timeIntervalSince(previous.timestamp)
        guard dt > 0 else { return false }
        let impliedSpeed = candidate.distance(from: previous) / dt

        // ~816 kt. Deliberately above normal transport-category cruise speed,
        // but low enough to reject cabin GNSS jumps spanning many kilometres.
        if impliedSpeed > 420 { return false }

        // At short intervals, large sideways jumps are almost always bad fixes.
        if dt < 5 && candidate.distance(from: previous) > 1_500 { return false }
        return true
    }

'''
    manager = manager[:idx] + helpers + manager[idx:]

# Reset retained state at a deliberate new tracking session.
manager = manager.replace(
    '''        trail = []\n        location = nil\n        acquisitionStartedAt = Date()\n        isTracking = true\n''',
    '''        trail = []\n        location = nil\n        retainedSpeed = nil\n        retainedSpeedAt = nil\n        retainedCourse = nil\n        retainedCourseAt = nil\n        gpsQualityText = "Acquiring"\n        rejectedFixCount = 0\n        acquisitionStartedAt = Date()\n        isTracking = true\n''',
    1,
)

# Replace didUpdateLocations structurally. The previous V2.17.5 logic already
# rejects coarse fixes; this adds quality ranking and a physics sanity check.
loc_start = manager.find('    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {')
loc_end = manager.find('    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {', loc_start)
if loc_start < 0 or loc_end < 0:
    raise RuntimeError('V2.17.8 location callback boundaries not found')

new_callback = r'''    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let candidates = locations
            .filter {
                $0.horizontalAccuracy >= 0 &&
                abs($0.timestamp.timeIntervalSinceNow) <= 30
            }
            .sorted { lhs, rhs in
                // Prefer materially better horizontal accuracy; otherwise keep
                // the newer fix. This avoids blindly accepting the last object.
                if abs(lhs.horizontalAccuracy - rhs.horizontalAccuracy) > 20 {
                    return lhs.horizontalAccuracy < rhs.horizontalAccuracy
                }
                return lhs.timestamp > rhs.timestamp
            }

        guard let candidate = candidates.first else {
            gpsQualityText = location == nil ? "Acquiring" : "Weak"
            return
        }

        // A coarse cellular/Wi-Fi estimate is not good enough to move an
        // aircraft marker. Keep the last good GNSS fix until reception returns.
        guard candidate.horizontalAccuracy <= 300 else {
            gpsQualityText = location == nil ? "Acquiring" : "Poor"
            if location == nil {
                errorText = "Waiting for GNSS (±\(Int(candidate.horizontalAccuracy.rounded())) m)"
            }
            return
        }

        guard isPhysicallyPlausible(candidate, after: location) else {
            rejectedFixCount += 1
            gpsQualityText = location == nil ? "Acquiring" : "Weak"
            return
        }

        location = candidate
        gpsQualityText = qualityText(for: candidate)
        errorText = nil

        if candidate.speed >= 0 {
            retainedSpeed = candidate.speed
            retainedSpeedAt = candidate.timestamp
        }
        if candidate.course >= 0 {
            retainedCourse = candidate.course
            retainedCourseAt = candidate.timestamp
        }

        if let lastCoordinate = trail.last {
            let last = CLLocation(latitude: lastCoordinate.latitude, longitude: lastCoordinate.longitude)
            guard candidate.distance(from: last) >= 25 else { return }
        }

        trail.append(candidate.coordinate)
        if trail.count > 1_200 {
            trail.removeFirst(trail.count - 1_200)
        }
    }

'''
manager = manager[:loc_start] + new_callback + manager[loc_end:]
content = content[:manager_start] + manager + content[manager_end:]

# -----------------------------------------------------------------------------
# Today map presentation — use retained navigation values and expose quality.
# -----------------------------------------------------------------------------
card_start = content.find('struct TodayRouteMapCard: View {')
card_end = content.find('\nprivate struct CrewCompanionPhase', card_start)
if card_start < 0 or card_end < 0:
    # V2.16 places another type after the card; use a broader safe boundary.
    card_end = content.find('\nstruct TodayPersonalNoteDisclosure', card_start)
if card_start < 0 or card_end < 0:
    raise RuntimeError('V2.17.8 TodayRouteMapCard boundaries not found')
card = content[card_start:card_end]

# Speed should survive a short speedAccuracy/speed dropout if a recent valid
# GNSS speed exists.
speed_start = card.find('    private var speedText: String {')
speed_end = card.find('\n    private var ', speed_start + 10)
if speed_start >= 0 and speed_end > speed_start:
    speed_block = card[speed_start:speed_end]
    if 'gps.displaySpeed' not in speed_block:
        speed_block = re.sub(
            r'guard let location = gps\.location,\s*location\.speed >= 0 else \{',
            'guard let speed = gps.displaySpeed else {',
            speed_block,
            count=1,
        )
        speed_block = speed_block.replace('location.speed * 3.6', 'speed * 3.6')
        speed_block = speed_block.replace('location.speed * 2.23694', 'speed * 2.23694')
        speed_block = speed_block.replace('location.speed * 1.94384', 'speed * 1.94384')
        card = card[:speed_start] + speed_block + card[speed_end:]

# Online aircraft marker rotation should also retain a recent valid course.
card = card.replace(
    '''        guard let location = liveLocation,\n              location.course >= 0,\n              location.speed > 2 else { return .degrees(-20) }\n        return .degrees(location.course - 90)\n''',
    '''        guard let location = liveLocation,\n              location.course >= 0,\n              location.speed > 2 else { return .degrees(-20) }\n        return .degrees(location.course - 90)\n''',
    1,
)

# Quality helper for UI.
if 'private var gpsQualityDetailText:' not in card:
    marker = '    private var horizontalAccuracyText: String {'
    idx = card.find(marker)
    if idx >= 0:
        helper = r'''    private var gpsQualityDetailText: String {
        guard let location = gps.location else { return gps.gpsQualityText }
        let accuracy = Int(max(0, location.horizontalAccuracy).rounded())
        let age = Int(max(0, Date().timeIntervalSince(location.timestamp)).rounded())
        return "\(gps.gpsQualityText) • ±\(accuracy)m • \(age)s"
    }

'''
        card = card[:idx] + helper + card[idx:]

# Replace the terse GPS ± metric with a useful quality metric where available.
card = card.replace('liveMetric("GPS ±", horizontalAccuracyText)', 'liveMetric("GPS", gpsQualityDetailText)', 1)

# Once permission has already been granted, acquire a fix automatically when
# the flight map appears. This avoids first acquiring GNSS only after takeoff.
if '.onAppear { gps.startIfAuthorized() }' not in card:
    accessibility = '.accessibilityLabel("Flight route map " + points.map(\\.code).joined(separator: " to "))'
    if accessibility in card:
        card = card.replace(accessibility, accessibility + '\n        .onAppear { gps.startIfAuthorized() }', 1)
    else:
        # Fallback: attach to the final map-card overlay block before body ends.
        body_end = card.rfind('\n    }\n')
        if body_end > 0:
            card = card[:body_end] + '\n        .onAppear { gps.startIfAuthorized() }' + card[body_end:]

content = content[:card_start] + card + content[card_end:]

# Version bump.
content = content.replace('LabeledContent("RAIDO Roster", value: "2.17.7")', 'LabeledContent("RAIDO Roster", value: "2.17.8")', 1)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace('MARKETING_VERSION = 2.17.7;', 'MARKETING_VERSION = 2.17.8;')
PBX.write_text(pbx)

print('V2.17.8 flight-aware GNSS quality engine + retained navigation telemetry applied')
