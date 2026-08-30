from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.16.1 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# Network is used only to choose the visual map layer. GPS and route progress
# remain Core Location/local calculations and do not depend on connectivity.
if "import Network" not in content:
    content = replace_once(
        content,
        "import CoreLocation\n",
        "import CoreLocation\nimport Network\n",
        "Network import",
    )

connectivity = r'''
private final class TodayMapConnectivityMonitor: ObservableObject {
    @Published private(set) var isConnected = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "RAIDORoster.TodayMapConnectivity")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

private struct TodayOnlineRouteMap: View {
    let points: [TodayAirportMapPoint]
    let trail: [CLLocationCoordinate2D]
    let liveLocation: CLLocation?
    let isTracking: Bool

    @Binding var cameraPosition: MapCameraPosition

    private var coordinates: [CLLocationCoordinate2D] {
        points.map(\.coordinate)
    }

    private var planeRotation: Angle {
        guard let location = liveLocation,
              location.course >= 0,
              location.speed > 2 else { return .degrees(-20) }
        return .degrees(location.course - 90)
    }

    var body: some View {
        Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
            MapPolyline(coordinates: coordinates, contourStyle: .geodesic)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

            if trail.count >= 2 {
                MapPolyline(coordinates: trail)
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
                                .stroke(Color.white.opacity(0.95), lineWidth: 2)
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
                            .background(Color(uiColor: .systemBackground).opacity(0.92), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }

            if isTracking, let coordinate = liveLocation?.coordinate {
                Annotation("Aircraft", coordinate: coordinate, anchor: .center) {
                    Image(systemName: "airplane")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Color.green)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .rotationEffect(planeRotation)
                }
            }
        }
        .mapStyle(.standard)
    }
}

'''

if "private final class TodayMapConnectivityMonitor" not in content:
    content = replace_once(
        content,
        "private final class TodayLiveFlightLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {\n",
        connectivity + "private final class TodayLiveFlightLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {\n",
        "connectivity and online map components",
    )

content = replace_once(
    content,
    '''    @StateObject private var gps = TodayLiveFlightLocationManager()\n    @State private var committedZoom: CGFloat = 1\n''',
    '''    @StateObject private var gps = TodayLiveFlightLocationManager()\n    @StateObject private var connectivity = TodayMapConnectivityMonitor()\n    @State private var forceOfflineMap = false\n    @State private var onlineCameraPosition: MapCameraPosition = .automatic\n    @State private var committedZoom: CGFloat = 1\n''',
    "hybrid map state",
)

old_map = r'''            GeometryReader { _ in
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
'''

new_map = r'''            ZStack {
                if connectivity.isConnected && !forceOfflineMap {
                    TodayOnlineRouteMap(
                        points: points,
                        trail: gps.trail,
                        liveLocation: gps.location,
                        isTracking: gps.isTracking,
                        cameraPosition: $onlineCameraPosition
                    )
                } else {
                    GeometryReader { _ in
                        OfflineAviationMapCanvas(
                            points: points,
                            trail: gps.trail,
                            liveLocation: gps.location,
                            isTracking: gps.isTracking,
                            zoom: effectiveZoom,
                            pan: effectivePan,
                            colorScheme: colorScheme
                        )
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
                }

                VStack {
                    HStack {
                        Menu {
                            Button {
                                forceOfflineMap = false
                                onlineCameraPosition = .automatic
                            } label: {
                                HStack {
                                    Text("Apple Map (when online)")
                                    if connectivity.isConnected && !forceOfflineMap { Image(systemName: "checkmark") }
                                }
                            }

                            Button {
                                forceOfflineMap = true
                            } label: {
                                HStack {
                                    Text("Offline aviation map")
                                    if forceOfflineMap || !connectivity.isConnected { Image(systemName: "checkmark") }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: connectivity.isConnected && !forceOfflineMap ? "map.fill" : "airplane.circle.fill")
                                Text(connectivity.isConnected && !forceOfflineMap ? "APPLE MAP" : "OFFLINE MAP")
                            }
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color(uiColor: .systemBackground).opacity(0.92), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if connectivity.isConnected && !forceOfflineMap {
                                    if let coordinate = gps.location?.coordinate {
                                        onlineCameraPosition = .region(
                                            MKCoordinateRegion(
                                                center: coordinate,
                                                latitudinalMeters: 500_000,
                                                longitudinalMeters: 500_000
                                            )
                                        )
                                    } else {
                                        onlineCameraPosition = .automatic
                                    }
                                } else {
                                    committedZoom = 1
                                    committedPan = .zero
                                }
                            }
                        } label: {
                            Image(systemName: "scope")
                                .font(.subheadline.bold())
                                .frame(width: 34, height: 34)
                                .background(Color(uiColor: .systemBackground).opacity(0.92), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Recenter route map")
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
            .frame(height: gps.isTracking ? 230 : 195)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.secondary.opacity(colorScheme == .dark ? 0.24 : 0.14), lineWidth: 1)
            }
'''

content = replace_once(content, old_map, new_map, "hybrid online/offline map body")

content = content.replace(
    '.accessibilityLabel("Offline route map " + points.map(\\.code).joined(separator: " to "))',
    '.accessibilityLabel("Flight route map " + points.map(\\.code).joined(separator: " to "))',
    1,
)

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.16")',
    'LabeledContent("RAIDO Roster", value: "2.16.1")',
    1,
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 34;", "CURRENT_PROJECT_VERSION = 35;")
pbx = pbx.replace("MARKETING_VERSION = 2.16;", "MARKETING_VERSION = 2.16.1;")
PBX.write_text(pbx)

print("V2.16.1 hybrid Apple Map + guaranteed offline fallback applied")
