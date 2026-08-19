from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.14 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# Foreground-only Core Location. No Always permission, no background mode,
# no persistence of GPS tracks, and no internet flight-tracking service.
if "import CoreLocation" not in content:
    content = replace_once(
        content,
        "import MapKit\n",
        "import MapKit\nimport CoreLocation\n",
        "CoreLocation import",
    )

start = content.find("struct TodayRouteMapCard: View {")
end = content.find("struct TodayPersonalNoteDisclosure: View {", start)
if start < 0 or end < 0:
    raise RuntimeError("V2.14 TodayRouteMapCard range not found")

live_map = r'''private final class TodayLiveFlightLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var trail: [CLLocationCoordinate2D] = []
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isTracking = false
    @Published private(set) var errorText: String?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 250
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        authorizationStatus = manager.authorizationStatus
    }

    var isPrecise: Bool {
        manager.accuracyAuthorization == .fullAccuracy
    }

    func start() {
        guard CLLocationManager.locationServicesEnabled() else {
            errorText = "Location Services are off"
            isTracking = false
            return
        }

        errorText = nil
        trail = []
        location = nil
        isTracking = true

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            errorText = "Location permission required"
            isTracking = false
        @unknown default:
            errorText = "Location unavailable"
            isTracking = false
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        isTracking = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        guard isTracking else { return }

        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            errorText = "Location permission required"
            isTracking = false
            manager.stopUpdatingLocation()
        case .notDetermined:
            break
        @unknown default:
            errorText = "Location unavailable"
            isTracking = false
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let newest = locations.last,
              newest.horizontalAccuracy >= 0,
              abs(newest.timestamp.timeIntervalSinceNow) < 30 else { return }

        location = newest

        guard newest.horizontalAccuracy <= 1_500 else { return }
        if let lastCoordinate = trail.last {
            let last = CLLocation(latitude: lastCoordinate.latitude, longitude: lastCoordinate.longitude)
            guard newest.distance(from: last) >= 100 else { return }
        }

        trail.append(newest.coordinate)
        if trail.count > 600 {
            trail.removeFirst(trail.count - 600)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let coreError = error as? CLError, coreError.code == .locationUnknown {
            return
        }
        errorText = "GPS temporarily unavailable"
    }
}

struct TodayRouteMapCard: View {
    let item: RosterItem
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var gps = TodayLiveFlightLocationManager()
    @State private var cameraPosition: MapCameraPosition = .automatic

    static func canDisplay(_ item: RosterItem) -> Bool {
        routePoints(for: item).count >= 2
    }

    private var points: [TodayAirportMapPoint] {
        Self.routePoints(for: item)
    }

    private var coordinates: [CLLocationCoordinate2D] {
        points.map(\.coordinate)
    }

    private var cameraBounds: MapCameraBounds {
        // Aviation-scale limits: enough detail around an airport without
        // allowing a useless street-level view or whole-globe zoom-out.
        MapCameraBounds(minimumDistance: 20_000, maximumDistance: 8_000_000)
    }

    private var staticAirplaneCoordinate: CLLocationCoordinate2D? {
        guard coordinates.count >= 2 else { return nil }
        let a = coordinates[0]
        let b = coordinates[1]
        return CLLocationCoordinate2D(
            latitude: (a.latitude + b.latitude) / 2,
            longitude: (a.longitude + b.longitude) / 2
        )
    }

    private var livePlaneCoordinate: CLLocationCoordinate2D? {
        if gps.isTracking { return gps.location?.coordinate }
        return staticAirplaneCoordinate
    }

    private var planeRotation: Angle {
        guard gps.isTracking,
              let course = gps.location?.course,
              course >= 0 else { return .degrees(-20) }
        // SF Symbols airplane points roughly east, while Core Location course
        // is clockwise from north.
        return .degrees(course - 90)
    }

    private var gpsQuality: (label: String, color: Color) {
        guard gps.isTracking else { return ("GPS Off", .secondary) }
        guard let location = gps.location else { return ("Acquiring GPS", .orange) }
        let age = abs(location.timestamp.timeIntervalSinceNow)
        if age > 20 { return ("GPS Stale", .orange) }
        if location.horizontalAccuracy <= 100 { return (gps.isPrecise ? "GPS Good" : "GPS Reduced", .green) }
        if location.horizontalAccuracy <= 1_000 { return ("GPS Weak", .orange) }
        return ("GPS Poor", .red)
    }

    private var altitudeText: String {
        guard let location = gps.location,
              location.verticalAccuracy >= 0 else { return "— ft" }
        let feet = Int((location.altitude * 3.28084).rounded())
        return "\(feet.formatted()) ft"
    }

    private var speedText: String {
        guard let speed = gps.location?.speed, speed >= 0 else { return "— kt" }
        return "\(Int((speed * 1.94384).rounded())) kt"
    }

    private var courseText: String {
        guard let course = gps.location?.course, course >= 0 else { return "—°" }
        return "\(Int(course.rounded()))°"
    }

    private var progressText: String? {
        guard gps.isTracking,
              let location = gps.location,
              let estimate = Self.routeProgress(location: location, coordinates: coordinates) else { return nil }
        return "\(estimate.percent)% route • \(estimate.remainingKM.formatted()) km remaining"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: gps.isTracking ? 9 : 0) {
            Map(position: $cameraPosition, bounds: cameraBounds, interactionModes: [.pan, .zoom]) {
                MapPolyline(coordinates: coordinates, contourStyle: .geodesic)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                if gps.trail.count >= 2 {
                    MapPolyline(coordinates: gps.trail)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }

                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Annotation(point.code, coordinate: point.coordinate, anchor: .center) {
                        VStack(spacing: 3) {
                            ZStack {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 12, height: 12)
                                Circle()
                                    .stroke(Color.white.opacity(0.9), lineWidth: 2)
                                    .frame(width: 18, height: 18)
                            }

                            if index == 0 || index == points.count - 1 || points.count <= 3 {
                                VStack(spacing: 0) {
                                    Text(point.code)
                                        .font(.caption.bold())
                                    Text(point.name)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }

                if let livePlaneCoordinate {
                    Annotation("Aircraft", coordinate: livePlaneCoordinate, anchor: .center) {
                        Image(systemName: "airplane")
                            .font(.system(size: gps.isTracking ? 24 : 22, weight: .bold))
                            .foregroundStyle(gps.isTracking ? Color.green : Color.white)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            .rotationEffect(planeRotation)
                    }
                }
            }
            .mapStyle(.standard)
            .frame(height: gps.isTracking ? 225 : 185)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.secondary.opacity(colorScheme == .dark ? 0.20 : 0.12), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                if gps.isTracking {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(gpsQuality.color)
                            .frame(width: 7, height: 7)
                        Text("LIVE GPS")
                            .font(.caption.bold())
                        Text(gpsQuality.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(Color(uiColor: .systemBackground).opacity(0.94), in: Capsule())
                    .padding(10)
                }
            }
            .overlay(alignment: .topTrailing) {
                if gps.isTracking, let coordinate = gps.location?.coordinate {
                    Button {
                        recenter(on: coordinate)
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.subheadline.bold())
                            .frame(width: 34, height: 34)
                            .background(Color(uiColor: .systemBackground).opacity(0.94), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .accessibilityLabel("Recenter map on aircraft")
                }
            }
            .overlay {
                if !gps.isTracking {
                    Button {
                        gps.start()
                    } label: {
                        ZStack(alignment: .bottom) {
                            Color.clear
                                .contentShape(Rectangle())

                            HStack(spacing: 7) {
                                Image(systemName: "location.fill")
                                Text(gps.errorText ?? "Tap map to start Live GPS")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(gps.errorText == nil ? Color.accentColor : Color.orange)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Color(uiColor: .systemBackground).opacity(0.94), in: Capsule())
                            .padding(.bottom, 12)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Start foreground live GPS flight tracking")
                }
            }

            if gps.isTracking {
                HStack(spacing: 0) {
                    liveMetric("Altitude", altitudeText)
                    Divider().frame(height: 28)
                    liveMetric("Ground speed", speedText)
                    Divider().frame(height: 28)
                    liveMetric("Track", courseText)
                }

                HStack(spacing: 8) {
                    if let progressText {
                        Text(progressText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(gps.isPrecise ? "Waiting for a usable route fix" : "Precise Location recommended")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 6)

                    Button("Stop") {
                        gps.stop()
                    }
                    .font(.caption.bold())
                }
                .padding(.horizontal, 2)
            }
        }
        .animation(.snappy(duration: 0.2), value: gps.isTracking)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { gps.stop() }
        }
        .onDisappear {
            gps.stop()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Route map " + points.map(\.code).joined(separator: " to "))
    }

    @ViewBuilder
    private func liveMetric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func recenter(on coordinate: CLLocationCoordinate2D) {
        withAnimation(.easeInOut(duration: 0.25)) {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: coordinate,
                    latitudinalMeters: 500_000,
                    longitudinalMeters: 500_000
                )
            )
        }
    }

    private static func routePoints(for item: RosterItem) -> [TodayAirportMapPoint] {
        let normalized = item.route
            .uppercased()
            .replacingOccurrences(of: "→", with: " ")
            .replacingOccurrences(of: "–", with: " ")
            .replacingOccurrences(of: "—", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")

        let codes = normalized
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count == 3 }

        var output: [TodayAirportMapPoint] = []
        for code in codes {
            guard let point = TodayAirportCoordinates.airports[code] else { continue }
            if output.last?.code != point.code {
                output.append(point)
            }
        }
        return output
    }

    private static func routeProgress(
        location: CLLocation,
        coordinates: [CLLocationCoordinate2D]
    ) -> (percent: Int, remainingKM: Int)? {
        guard coordinates.count >= 2,
              location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) <= 30 else { return nil }

        var segmentDistances: [Double] = []
        var totalDistance = 0.0
        for index in 0..<(coordinates.count - 1) {
            let distance = geoDistance(coordinates[index], coordinates[index + 1])
            segmentDistances.append(distance)
            totalDistance += distance
        }
        guard totalDistance > 1 else { return nil }

        var bestScore = Double.greatestFiniteMagnitude
        var bestAlong = 0.0
        var cumulative = 0.0

        for index in 0..<segmentDistances.count {
            let a = coordinates[index]
            let b = coordinates[index + 1]
            let segment = segmentDistances[index]
            guard segment > 1 else { continue }

            let dAC = geoDistance(a, location.coordinate)
            let dBC = geoDistance(b, location.coordinate)
            let fraction = max(0, min(1, (dAC * dAC + segment * segment - dBC * dBC) / (2 * segment * segment)))
            let routeExcess = max(0, dAC + dBC - segment)

            var headingPenalty = 0.0
            if location.course >= 0 {
                let routeBearing = bearing(from: a, to: b)
                let delta = angularDifference(location.course, routeBearing)
                headingPenalty = (delta / 180.0) * 500_000
            }

            let score = routeExcess + headingPenalty
            if score < bestScore {
                bestScore = score
                bestAlong = cumulative + fraction * segment
            }
            cumulative += segment
        }

        // If the phone is hundreds of kilometres away from every route leg,
        // don't pretend the projection is meaningful.
        guard bestScore < 900_000 else { return nil }

        let progress = max(0, min(1, bestAlong / totalDistance))
        return (
            percent: Int((progress * 100).rounded()),
            remainingKM: Int(((totalDistance - bestAlong) / 1_000).rounded())
        )
    }

    private static func geoDistance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let deltaLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func angularDifference(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(diff, 360 - diff)
    }
}

'''

content = content[:start] + live_map + content[end:]

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.13")',
    'LabeledContent("RAIDO Roster", value: "2.14")',
    1,
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 30;", "CURRENT_PROJECT_VERSION = 31;")
pbx = pbx.replace("MARKETING_VERSION = 2.13;", "MARKETING_VERSION = 2.14;")
PBX.write_text(pbx)

print("V2.14 foreground-only Live GPS map tracking applied")
