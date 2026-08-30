from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.16 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

start_marker = "private final class TodayLiveFlightLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {"
end_marker = "private struct CrewCompanionPhase {"

start = content.find(start_marker)
end = content.find(end_marker, start)
if start < 0 or end < 0:
    raise RuntimeError("V2.16 live map/GPS section range not found")

replacement = r'''
private struct OfflineAviationMapViewport {
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    init(route: [CLLocationCoordinate2D]) {
        let latitudes = route.map(\.latitude)
        let longitudes = route.map(\.longitude)

        let minLat = latitudes.min() ?? 30
        let maxLat = latitudes.max() ?? 50
        let minLon = longitudes.min() ?? 10
        let maxLon = longitudes.max() ?? 30

        let latSpan = max(7.0, maxLat - minLat)
        let lonSpan = max(7.0, maxLon - minLon)
        let latPadding = max(2.0, latSpan * 0.30)
        let lonPadding = max(2.0, lonSpan * 0.30)

        minLatitude = max(-80, minLat - latPadding)
        maxLatitude = min(80, maxLat + latPadding)
        minLongitude = max(-180, minLon - lonPadding)
        maxLongitude = min(180, maxLon + lonPadding)
    }

    var midLatitude: Double { (minLatitude + maxLatitude) / 2 }
    var midLongitude: Double { (minLongitude + maxLongitude) / 2 }

    func point(
        for coordinate: CLLocationCoordinate2D,
        in size: CGSize,
        zoom: CGFloat,
        pan: CGSize
    ) -> CGPoint {
        let latitudeSpan = max(1, maxLatitude - minLatitude)
        let longitudeSpan = max(1, maxLongitude - minLongitude)
        let longitudeCompression = max(0.25, cos(midLatitude * .pi / 180))

        let projectedWidth = longitudeSpan * longitudeCompression
        let projectedHeight = latitudeSpan
        let baseScale = min(
            Double(size.width) / projectedWidth,
            Double(size.height) / projectedHeight
        ) * 0.88

        let x = (coordinate.longitude - midLongitude) * longitudeCompression * baseScale
        let y = (midLatitude - coordinate.latitude) * baseScale

        return CGPoint(
            x: size.width / 2 + CGFloat(x) * zoom + pan.width,
            y: size.height / 2 + CGFloat(y) * zoom + pan.height
        )
    }

    func gridStep() -> Double {
        let span = max(maxLatitude - minLatitude, maxLongitude - minLongitude)
        switch span {
        case ..<12: return 2
        case ..<28: return 5
        case ..<60: return 10
        default: return 20
        }
    }
}

private enum OfflineAviationBasemap {
    // Lightweight silhouettes only. The route, GPS calculations and all map
    // geometry remain fully local with no Apple Maps tile dependency.
    static let land: [[CLLocationCoordinate2D]] = [
        [
            .init(latitude: 43.8, longitude: -9.3), .init(latitude: 43.5, longitude: -1.8),
            .init(latitude: 42.7, longitude: 3.2), .init(latitude: 40.6, longitude: 0.7),
            .init(latitude: 38.7, longitude: 0.0), .init(latitude: 36.0, longitude: -5.6),
            .init(latitude: 36.8, longitude: -9.0), .init(latitude: 40.0, longitude: -9.5)
        ],
        [
            .init(latitude: 43.0, longitude: -1.8), .init(latitude: 48.7, longitude: -4.8),
            .init(latitude: 51.2, longitude: 1.4), .init(latitude: 53.6, longitude: 8.0),
            .init(latitude: 54.8, longitude: 14.0), .init(latitude: 54.7, longitude: 22.0),
            .init(latitude: 53.6, longitude: 28.0), .init(latitude: 50.0, longitude: 31.0),
            .init(latitude: 46.0, longitude: 30.0), .init(latitude: 44.0, longitude: 27.5),
            .init(latitude: 43.0, longitude: 23.0), .init(latitude: 45.0, longitude: 20.0),
            .init(latitude: 46.0, longitude: 15.0), .init(latitude: 45.0, longitude: 12.0),
            .init(latitude: 43.8, longitude: 7.0), .init(latitude: 43.0, longitude: 3.0)
        ],
        [
            .init(latitude: 46.5, longitude: 7.0), .init(latitude: 46.0, longitude: 13.7),
            .init(latitude: 44.0, longitude: 12.8), .init(latitude: 42.4, longitude: 14.2),
            .init(latitude: 40.0, longitude: 18.5), .init(latitude: 38.0, longitude: 16.1),
            .init(latitude: 40.2, longitude: 15.0), .init(latitude: 41.5, longitude: 12.0),
            .init(latitude: 43.2, longitude: 10.0)
        ],
        [
            .init(latitude: 46.0, longitude: 13.5), .init(latitude: 46.5, longitude: 20.0),
            .init(latitude: 44.0, longitude: 23.5), .init(latitude: 41.5, longitude: 26.0),
            .init(latitude: 39.0, longitude: 24.0), .init(latitude: 36.3, longitude: 23.0),
            .init(latitude: 37.2, longitude: 21.0), .init(latitude: 40.0, longitude: 20.0),
            .init(latitude: 42.0, longitude: 18.0)
        ],
        [
            .init(latitude: 50.0, longitude: -5.8), .init(latitude: 51.0, longitude: 1.7),
            .init(latitude: 54.8, longitude: -1.0), .init(latitude: 58.7, longitude: -3.0),
            .init(latitude: 57.8, longitude: -6.0), .init(latitude: 54.0, longitude: -5.0)
        ],
        [
            .init(latitude: 51.4, longitude: -10.5), .init(latitude: 53.5, longitude: -10.0),
            .init(latitude: 55.4, longitude: -7.0), .init(latitude: 54.0, longitude: -5.5),
            .init(latitude: 51.5, longitude: -6.0)
        ],
        [
            .init(latitude: 55.4, longitude: 8.0), .init(latitude: 57.0, longitude: 12.0),
            .init(latitude: 60.0, longitude: 18.5), .init(latitude: 65.0, longitude: 24.0),
            .init(latitude: 70.5, longitude: 28.0), .init(latitude: 71.2, longitude: 20.0),
            .init(latitude: 68.0, longitude: 12.0), .init(latitude: 62.0, longitude: 5.0),
            .init(latitude: 58.0, longitude: 6.0)
        ],
        [
            .init(latitude: 41.7, longitude: 26.0), .init(latitude: 42.0, longitude: 35.0),
            .init(latitude: 41.2, longitude: 41.5), .init(latitude: 38.5, longitude: 44.0),
            .init(latitude: 36.0, longitude: 36.0), .init(latitude: 36.0, longitude: 29.0),
            .init(latitude: 38.0, longitude: 26.0)
        ],
        [
            .init(latitude: 41.0, longitude: 39.0), .init(latitude: 43.5, longitude: 40.0),
            .init(latitude: 44.5, longitude: 47.0), .init(latitude: 41.0, longitude: 48.5),
            .init(latitude: 39.0, longitude: 44.0)
        ],
        [
            .init(latitude: 36.0, longitude: 35.5), .init(latitude: 37.5, longitude: 39.0),
            .init(latitude: 34.0, longitude: 40.0), .init(latitude: 29.5, longitude: 35.0),
            .init(latitude: 31.0, longitude: 34.0), .init(latitude: 33.5, longitude: 35.0)
        ],
        [
            .init(latitude: 37.0, longitude: -10.0), .init(latitude: 37.2, longitude: 10.0),
            .init(latitude: 33.0, longitude: 23.0), .init(latitude: 31.5, longitude: 34.0),
            .init(latitude: 25.0, longitude: 35.0), .init(latitude: 20.0, longitude: -10.0),
            .init(latitude: 28.0, longitude: -17.0)
        ],
        [
            .init(latitude: 38.3, longitude: 12.3), .init(latitude: 38.3, longitude: 15.7),
            .init(latitude: 36.7, longitude: 15.0), .init(latitude: 37.0, longitude: 12.5)
        ],
        [
            .init(latitude: 41.3, longitude: 8.0), .init(latitude: 41.2, longitude: 9.8),
            .init(latitude: 38.8, longitude: 9.6), .init(latitude: 39.0, longitude: 8.2)
        ],
        [
            .init(latitude: 43.0, longitude: 8.5), .init(latitude: 43.0, longitude: 9.6),
            .init(latitude: 41.3, longitude: 9.5), .init(latitude: 41.4, longitude: 8.7)
        ],
        [
            .init(latitude: 35.7, longitude: 23.3), .init(latitude: 35.5, longitude: 26.4),
            .init(latitude: 34.9, longitude: 26.2), .init(latitude: 35.0, longitude: 23.4)
        ],
        [
            .init(latitude: 35.7, longitude: 32.2), .init(latitude: 35.7, longitude: 34.6),
            .init(latitude: 34.6, longitude: 34.5), .init(latitude: 34.5, longitude: 32.3)
        ]
    ]
}

private final class TodayLiveFlightLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var trail: [CLLocationCoordinate2D] = []
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isTracking = false
    @Published private(set) var errorText: String?
    @Published private(set) var acquisitionStartedAt: Date?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .airborne
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
        acquisitionStartedAt = Date()
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
        acquisitionStartedAt = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        guard isTracking else { return }

        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            errorText = nil
            manager.startUpdatingLocation()
        case .denied, .restricted:
            errorText = "Location permission required"
            isTracking = false
            acquisitionStartedAt = nil
            manager.stopUpdatingLocation()
        case .notDetermined:
            break
        @unknown default:
            errorText = "Location unavailable"
            isTracking = false
            acquisitionStartedAt = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let newest = locations.last(where: {
            $0.horizontalAccuracy >= 0 &&
            abs($0.timestamp.timeIntervalSinceNow) < 60
        }) else { return }

        location = newest
        errorText = nil

        guard newest.horizontalAccuracy <= 1_500 else { return }

        if let lastCoordinate = trail.last {
            let last = CLLocation(latitude: lastCoordinate.latitude, longitude: lastCoordinate.longitude)
            guard newest.distance(from: last) >= 40 else { return }
        }

        trail.append(newest.coordinate)
        if trail.count > 900 {
            trail.removeFirst(trail.count - 900)
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
    @AppStorage("RAIDORoster.GroundSpeedUnit") private var groundSpeedUnit = "kt"

    @StateObject private var gps = TodayLiveFlightLocationManager()
    @State private var committedZoom: CGFloat = 1
    @GestureState private var gestureZoom: CGFloat = 1
    @State private var committedPan: CGSize = .zero
    @GestureState private var gesturePan: CGSize = .zero

    static func canDisplay(_ item: RosterItem) -> Bool {
        routePoints(for: item).count >= 2
    }

    private var points: [TodayAirportMapPoint] {
        Self.routePoints(for: item)
    }

    private var coordinates: [CLLocationCoordinate2D] {
        points.map(\.coordinate)
    }

    private var effectiveZoom: CGFloat {
        min(max(committedZoom * gestureZoom, 1), 7)
    }

    private var effectivePan: CGSize {
        .init(
            width: committedPan.width + gesturePan.width,
            height: committedPan.height + gesturePan.height
        )
    }

    private var gpsQuality: (label: String, color: Color) {
        guard gps.isTracking else { return ("GPS Off", .secondary) }
        guard let location = gps.location else { return ("Acquiring GPS", .orange) }

        let age = abs(location.timestamp.timeIntervalSinceNow)
        if age > 15 { return ("GPS Stale", .orange) }
        if !gps.isPrecise { return ("Reduced Accuracy", .orange) }
        if location.horizontalAccuracy <= 50 { return ("GPS Strong", .green) }
        if location.horizontalAccuracy <= 200 { return ("GPS Usable", .green) }
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
        guard let location = gps.location,
              location.speed >= 0,
              location.speedAccuracy >= 0 else {
            switch groundSpeedUnit {
            case "kmh": return "— km/h"
            case "mph": return "— mph"
            default: return "— kt"
            }
        }

        switch groundSpeedUnit {
        case "kmh":
            return "\(Int((location.speed * 3.6).rounded())) km/h"
        case "mph":
            return "\(Int((location.speed * 2.23694).rounded())) mph"
        default:
            return "\(Int((location.speed * 1.94384).rounded())) kt"
        }
    }

    private var courseText: String {
        guard let location = gps.location,
              location.course >= 0,
              location.courseAccuracy >= 0,
              location.speed > 2 else { return "—°" }
        return "\(Int(location.course.rounded()))°"
    }

    private var positionAccuracyText: String {
        guard let location = gps.location, location.horizontalAccuracy >= 0 else { return "POS —" }
        return "POS ±\(Int(location.horizontalAccuracy.rounded()))m"
    }

    private var altitudeAccuracyText: String {
        guard let location = gps.location, location.verticalAccuracy >= 0 else { return "ALT —" }
        let feet = Int((location.verticalAccuracy * 3.28084).rounded())
        return "ALT ±\(feet)ft"
    }

    private var speedAccuracyText: String {
        guard let location = gps.location, location.speedAccuracy >= 0 else { return "SPD —" }
        switch groundSpeedUnit {
        case "kmh":
            return "SPD ±\(Int((location.speedAccuracy * 3.6).rounded()))km/h"
        case "mph":
            return "SPD ±\(Int((location.speedAccuracy * 2.23694).rounded()))mph"
        default:
            return "SPD ±\(Int((location.speedAccuracy * 1.94384).rounded()))kt"
        }
    }

    private var courseAccuracyText: String {
        guard let location = gps.location, location.courseAccuracy >= 0 else { return "CRS —" }
        return "CRS ±\(Int(location.courseAccuracy.rounded()))°"
    }

    private var fixAgeText: String {
        guard let location = gps.location else { return "AGE —" }
        let age = max(0, Int(abs(location.timestamp.timeIntervalSinceNow).rounded()))
        return "AGE \(age)s"
    }

    private var progressText: String? {
        guard gps.isTracking,
              let location = gps.location,
              let estimate = Self.routeProgress(
                location: location,
                coordinates: coordinates,
                preferredSegment: preferredSegmentIndex(at: Date())
              ) else { return nil }

        let base = "\(estimate.percent)% route • \(estimate.remainingKM.formatted()) km remaining"

        guard location.speed >= 30,
              location.speedAccuracy >= 0,
              estimate.remainingKM > 0 else { return base }

        let seconds = (Double(estimate.remainingKM) * 1_000) / location.speed
        guard seconds.isFinite, seconds > 0, seconds < 24 * 60 * 60 else { return base }

        let minutes = max(1, Int((seconds / 60).rounded()))
        let eta: String
        if minutes < 60 {
            eta = "\(minutes)m"
        } else {
            let hours = minutes / 60
            let remainder = minutes % 60
            eta = remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        }
        return base + " • ~" + eta
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Flight Companion", systemImage: "airplane.circle.fill")
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)

                HStack(spacing: 5) {
                    Circle()
                        .fill(gps.isTracking ? gpsQuality.color : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(gps.isTracking ? "LIVE GPS" : "ROUTE OVERVIEW")
                        .font(.caption2.bold())
                        .foregroundStyle(gps.isTracking ? gpsQuality.color : Color.secondary)
                }
            }
            .padding(.horizontal, 2)

            GeometryReader { _ in
                ZStack {
                    OfflineAviationMapCanvas(
                        points: points,
                        trail: gps.trail,
                        liveLocation: gps.location,
                        isTracking: gps.isTracking,
                        zoom: effectiveZoom,
                        pan: effectivePan,
                        colorScheme: colorScheme
                    )

                    VStack {
                        HStack {
                            Text("OFFLINE VECTOR MAP")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Color(uiColor: .systemBackground).opacity(0.92), in: Capsule())

                            Spacer()

                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    committedZoom = 1
                                    committedPan = .zero
                                }
                            } label: {
                                Image(systemName: "scope")
                                    .font(.subheadline.bold())
                                    .frame(width: 34, height: 34)
                                    .background(Color(uiColor: .systemBackground).opacity(0.92), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Reset route map view")
                        }
                        .padding(10)

                        Spacer()

                        if !gps.isTracking {
                            Button {
                                gps.start()
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "location.fill")
                                    Text(gps.errorText ?? "Start Live GPS")
                                        .font(.subheadline.weight(.semibold))
                                }
                                .foregroundStyle(gps.errorText == nil ? Color.accentColor : Color.orange)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(Color(uiColor: .systemBackground).opacity(0.94), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 12)
                            .accessibilityLabel("Start foreground live GPS flight tracking")
                        }
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(
                    MagnificationGesture()
                        .updating($gestureZoom) { value, state, _ in
                            state = value
                        }
                        .onEnded { value in
                            committedZoom = min(max(committedZoom * value, 1), 7)
                        }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 6)
                        .updating($gesturePan) { value, state, _ in
                            state = value.translation
                        }
                        .onEnded { value in
                            committedPan = .init(
                                width: committedPan.width + value.translation.width,
                                height: committedPan.height + value.translation.height
                            )
                        }
                )
            }
            .frame(height: gps.isTracking ? 230 : 195)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.secondary.opacity(colorScheme == .dark ? 0.24 : 0.14), lineWidth: 1)
            }

            if gps.isTracking {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(spacing: 7) {
                        HStack(spacing: 0) {
                            liveMetric("Altitude", altitudeText)
                            Divider().frame(height: 28)

                            Menu {
                                Button {
                                    groundSpeedUnit = "kt"
                                } label: {
                                    HStack {
                                        Text("Knots (kt)")
                                        if groundSpeedUnit == "kt" { Image(systemName: "checkmark") }
                                    }
                                }

                                Button {
                                    groundSpeedUnit = "kmh"
                                } label: {
                                    HStack {
                                        Text("Kilometres/hour (km/h)")
                                        if groundSpeedUnit == "kmh" { Image(systemName: "checkmark") }
                                    }
                                }

                                Button {
                                    groundSpeedUnit = "mph"
                                } label: {
                                    HStack {
                                        Text("Miles/hour (mph)")
                                        if groundSpeedUnit == "mph" { Image(systemName: "checkmark") }
                                    }
                                }
                            } label: {
                                liveMetric("Ground speed", speedText)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Divider().frame(height: 28)
                            liveMetric("Track", courseText)
                        }

                        HStack(spacing: 5) {
                            Circle()
                                .fill(gpsQuality.color)
                                .frame(width: 7, height: 7)
                            Text(gpsQuality.label)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            if !gps.isPrecise {
                                Text("Precise Location recommended")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }

                        Text([
                            positionAccuracyText,
                            altitudeAccuracyText,
                            speedAccuracyText,
                            courseAccuracyText,
                            fixAgeText
                        ].joined(separator: " • "))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)

                        HStack(spacing: 8) {
                            if let progressText {
                                Text(progressText)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            } else if gps.location == nil {
                                Text(acquisitionText(at: Date()))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Position available • route projection not reliable yet")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 6)

                            Button("Stop") {
                                gps.stop()
                            }
                            .font(.caption.bold())
                        }
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: gps.isTracking)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                gps.stop()
            }
        }
        .onDisappear {
            gps.stop()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Offline route map " + points.map(\.code).joined(separator: " to "))
    }

    @ViewBuilder
    private func liveMetric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func acquisitionText(at now: Date) -> String {
        guard let started = gps.acquisitionStartedAt else { return "Acquiring GPS…" }
        let seconds = max(0, Int(now.timeIntervalSince(started).rounded()))
        if seconds < 12 { return "Acquiring GPS… \(seconds)s" }
        if seconds < 45 { return "Waiting for satellite/location fix… \(seconds)s" }
        return "Weak/no GPS fix • try placing iPhone near a window"
    }

    private func preferredSegmentIndex(at now: Date) -> Int? {
        for (index, flight) in item.flightActivities.enumerated() {
            guard index < max(0, coordinates.count - 1),
                  let start = parseUTCStamp(flight.startUTC),
                  let end = parseUTCStamp(flight.endUTC) else { continue }
            if now >= start && now < end { return index }
        }

        if let next = item.flightActivities.enumerated()
            .compactMap({ pair -> (Int, Date)? in
                guard pair.offset < max(0, coordinates.count - 1),
                      let start = parseUTCStamp(pair.element.startUTC),
                      start > now else { return nil }
                return (pair.offset, start)
            })
            .sorted(by: { $0.1 < $1.1 })
            .first {
            return next.0
        }

        return nil
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
        coordinates: [CLLocationCoordinate2D],
        preferredSegment: Int?
    ) -> (percent: Int, remainingKM: Int)? {
        guard coordinates.count >= 2,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 5_000,
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
            let fraction = max(
                0,
                min(
                    1,
                    (dAC * dAC + segment * segment - dBC * dBC) /
                    (2 * segment * segment)
                )
            )
            let routeExcess = max(0, dAC + dBC - segment)

            var headingPenalty = 0.0
            if location.course >= 0 && location.courseAccuracy >= 0 {
                let routeBearing = bearing(from: a, to: b)
                let delta = angularDifference(location.course, routeBearing)
                headingPenalty = (delta / 180.0) * 350_000
            }

            let schedulePenalty: Double
            if let preferredSegment {
                schedulePenalty = preferredSegment == index ? 0 : 750_000
            } else {
                schedulePenalty = 0
            }

            let score = routeExcess + headingPenalty + schedulePenalty

            if score < bestScore {
                bestScore = score
                bestAlong = cumulative + fraction * segment
            }

            cumulative += segment
        }

        guard bestScore < 1_400_000 else { return nil }

        let progress = max(0, min(1, bestAlong / totalDistance))
        return (
            percent: Int((progress * 100).rounded()),
            remainingKM: Int(((totalDistance - bestAlong) / 1_000).rounded())
        )
    }

    private static func geoDistance(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private static func bearing(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
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

private struct OfflineAviationMapCanvas: View {
    let points: [TodayAirportMapPoint]
    let trail: [CLLocationCoordinate2D]
    let liveLocation: CLLocation?
    let isTracking: Bool
    let zoom: CGFloat
    let pan: CGSize
    let colorScheme: ColorScheme

    private var coordinates: [CLLocationCoordinate2D] {
        points.map(\.coordinate)
    }

    private var viewport: OfflineAviationMapViewport {
        .init(route: coordinates)
    }

    var body: some View {
        Canvas { context, size in
            let sea = colorScheme == .dark
                ? Color(red: 0.055, green: 0.075, blue: 0.105)
                : Color(red: 0.90, green: 0.94, blue: 0.97)
            let land = colorScheme == .dark
                ? Color(red: 0.12, green: 0.15, blue: 0.17)
                : Color(red: 0.80, green: 0.84, blue: 0.81)
            let border = Color.secondary.opacity(colorScheme == .dark ? 0.35 : 0.28)
            let grid = Color.secondary.opacity(colorScheme == .dark ? 0.16 : 0.13)

            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(sea))

            let step = viewport.gridStep()
            let firstLat = floor(viewport.minLatitude / step) * step
            let firstLon = floor(viewport.minLongitude / step) * step

            var latitude = firstLat
            while latitude <= viewport.maxLatitude + step {
                let a = viewport.point(
                    for: .init(latitude: latitude, longitude: viewport.minLongitude),
                    in: size,
                    zoom: zoom,
                    pan: pan
                )
                let b = viewport.point(
                    for: .init(latitude: latitude, longitude: viewport.maxLongitude),
                    in: size,
                    zoom: zoom,
                    pan: pan
                )
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                context.stroke(path, with: .color(grid), lineWidth: 0.7)
                latitude += step
            }

            var longitude = firstLon
            while longitude <= viewport.maxLongitude + step {
                let a = viewport.point(
                    for: .init(latitude: viewport.minLatitude, longitude: longitude),
                    in: size,
                    zoom: zoom,
                    pan: pan
                )
                let b = viewport.point(
                    for: .init(latitude: viewport.maxLatitude, longitude: longitude),
                    in: size,
                    zoom: zoom,
                    pan: pan
                )
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                context.stroke(path, with: .color(grid), lineWidth: 0.7)
                longitude += step
            }

            for polygon in OfflineAviationBasemap.land where polygon.count >= 3 {
                var path = Path()
                path.move(to: viewport.point(for: polygon[0], in: size, zoom: zoom, pan: pan))
                for coordinate in polygon.dropFirst() {
                    path.addLine(
                        to: viewport.point(
                            for: coordinate,
                            in: size,
                            zoom: zoom,
                            pan: pan
                        )
                    )
                }
                path.closeSubpath()
                context.fill(path, with: .color(land))
                context.stroke(path, with: .color(border), lineWidth: 0.8)
            }

            if coordinates.count >= 2 {
                var route = Path()
                route.move(to: viewport.point(for: coordinates[0], in: size, zoom: zoom, pan: pan))
                for coordinate in coordinates.dropFirst() {
                    route.addLine(
                        to: viewport.point(
                            for: coordinate,
                            in: size,
                            zoom: zoom,
                            pan: pan
                        )
                    )
                }
                context.stroke(
                    route,
                    with: .color(Color.accentColor),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )
            }

            if trail.count >= 2 {
                var track = Path()
                track.move(to: viewport.point(for: trail[0], in: size, zoom: zoom, pan: pan))
                for coordinate in trail.dropFirst() {
                    track.addLine(
                        to: viewport.point(
                            for: coordinate,
                            in: size,
                            zoom: zoom,
                            pan: pan
                        )
                    )
                }
                context.stroke(
                    track,
                    with: .color(.green),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                )
            }

            for point in points {
                let position = viewport.point(for: point.coordinate, in: size, zoom: zoom, pan: pan)

                context.fill(
                    Path(ellipseIn: CGRect(x: position.x - 5, y: position.y - 5, width: 10, height: 10)),
                    with: .color(Color.accentColor)
                )
                context.stroke(
                    Path(ellipseIn: CGRect(x: position.x - 8, y: position.y - 8, width: 16, height: 16)),
                    with: .color(.white.opacity(0.9)),
                    lineWidth: 1.5
                )

                context.draw(
                    Text(point.code)
                        .font(.caption2.bold())
                        .foregroundStyle(.primary),
                    at: CGPoint(x: position.x, y: position.y + 17),
                    anchor: .center
                )
            }

            if isTracking, let location = liveLocation {
                let position = viewport.point(
                    for: location.coordinate,
                    in: size,
                    zoom: zoom,
                    pan: pan
                )

                context.fill(
                    Path(ellipseIn: CGRect(x: position.x - 10, y: position.y - 10, width: 20, height: 20)),
                    with: .color(.green.opacity(0.18))
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: position.x - 4, y: position.y - 4, width: 8, height: 8)),
                    with: .color(.green)
                )
            }
        }
        .background(Color.clear)
    }
}

'''

content = content[:start] + replacement + content[end:]

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.15")',
    'LabeledContent("RAIDO Roster", value: "2.16")',
    1,
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 33;", "CURRENT_PROJECT_VERSION = 34;")
pbx = pbx.replace("MARKETING_VERSION = 2.15;", "MARKETING_VERSION = 2.16;")
PBX.write_text(pbx)

print("V2.16 offline vector map + GPS acquisition/reliability fixes applied")
