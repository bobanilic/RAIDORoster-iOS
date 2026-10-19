import SwiftUI
import CoreLocation

enum HistoricalRoutePolicy {
    static func sessionKeys(for sector: RosterActivity, defaultRegistration: String) -> [String] {
        let raw = (sector.aircraftReg.isEmpty ? defaultRegistration : sector.aircraftReg)
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let canonical = FleetTrackingPolicy.canonicalRegistration(raw)
        return Array(Set([raw,canonical])).sorted().map {
            let session = [sector.startUTC,sector.endUTC,sector.route,$0].joined(separator:"|")
            return "RAIDORoster.FlightTrail.V1." + Data(session.utf8).base64EncodedString()
        }
    }
}

struct HistoricalFlightRouteCard: View {
    let item: RosterItem
    var dayItems: [RosterItem] = []
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.raidoPalette) private var palette
    @Environment(\.raidoTheme) private var theme
    @State private var selectedID: String?
    @State private var expanded = false
    @State private var recorded: [CLLocationCoordinate2D] = []
    @State private var showRecorded = true

    private var sectors: [RosterActivity] {
        RosterDayPresentation.sectors(in: dayItems.isEmpty ? [item] : dayItems)
    }
    private var selected: [RosterActivity] { selectedID.map { id in sectors.filter { $0.id == id } } ?? sectors }

    var body: some View {
        let _ = palette
        let _ = theme
        let sectors = self.sectors
        let selected = selectedID.map { id in sectors.filter { $0.id == id } } ?? sectors
        let segments: [[CLLocationCoordinate2D]] = {
        selected.compactMap { activity in
            let codes = TodayGlobalAirportIndex.routeCodes(activity.route)
            let points = codes.compactMap { TodayGlobalAirportIndex.point(for:$0) }
            // Missing airports must never turn two unrelated known points into
            // a fabricated flight segment.
            return points.count == codes.count && points.count >= 2 ? points.map(\.coordinate) : nil
        }
        }()
        let points: [TodayAirportMapPoint] = {
        var seen = Set<String>()
        return selected.flatMap { TodayGlobalAirportIndex.routeCodes($0.route) }.compactMap { code in
            guard seen.insert(code).inserted else { return nil }
            return TodayGlobalAirportIndex.point(for:code)
        }
        }()
        if !sectors.isEmpty {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Label("Route preview",systemImage:"map").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("OFFLINE").font(.system(size:9,weight:.semibold)).foregroundStyle(.secondary)
                }
                if sectors.count > 1 {
                    ScrollView(.horizontal,showsIndicators:false) {
                        HStack(spacing:8) {
                            sectorButton("All sectors",id:nil)
                            ForEach(sectors) { sector in sectorButton(sector.code.isEmpty ? sector.route : sector.code,id:sector.id) }
                        }
                    }
                }
                if !segments.isEmpty {
                    Button { expanded = true } label: {
                        OfflineAviationMapCanvas(points:points,trail:showRecorded ? recorded : [],liveLocation:nil,isTracking:false,
                            zoom:1,pan:.zero,colorScheme:colorScheme,routeSegments:segments)
                            .frame(height:190).clipped().clipShape(RoundedRectangle(cornerRadius:17))
                            .overlay(alignment:.topTrailing) {
                                Image(systemName:"arrow.up.left.and.arrow.down.right").font(.caption.weight(.semibold))
                                    .padding(9).background(.regularMaterial,in:Circle()).padding(9)
                            }
                    }.buttonStyle(.plain).accessibilityLabel("Expand scheduled route map")
                        .accessibilityIdentifier("historical-route-map")
                } else {
                    Label("Airport coordinates unavailable for this sector",systemImage:"map").font(.caption).foregroundStyle(.secondary)
                }
                Text(selected.map(\.route).joined(separator:" · ")).font(.caption.weight(.medium)).fixedSize(horizontal:false,vertical:true)
                if selected.count > segments.count {
                    Text("Some airport coordinates are unavailable.").font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing:8) {
                    Label("Scheduled route",systemImage:"line.diagonal").font(.caption2).foregroundStyle(.secondary)
                    if recorded.count >= 2 {
                        Toggle("Saved GPS",isOn:$showRecorded).font(.caption2).toggleStyle(.button).tint(.green)
                    }
                }
                if recorded.count >= 2 { Text("Saved GPS may cover part of the flight.").font(.caption2).foregroundStyle(.secondary) }
            }.padding(15).midnightCard(radius:MidnightTheme.isGetJet ? 22 : 18)
                .task(id:selectionIdentity) { await loadRecorded() }
                .sheet(isPresented:$expanded) {
                    HistoricalExpandedRoute(points:points,segments:segments,trail:showRecorded ? recorded : [],title:selected.map(\.route).joined(separator:" · "))
                }
        }
    }
    private var selectionIdentity: String {
        item.id + "|" + selected.map { [$0.id,$0.startUTC,$0.endUTC,$0.route,$0.aircraftReg].joined(separator:"|") }.joined(separator:";")
    }
    private func sectorButton(_ title: String, id: String?) -> some View {
        Button { selectedID = id } label: {
            Text(title).font(.caption.weight(.medium)).padding(.horizontal,12).padding(.vertical,8)
                .foregroundStyle(selectedID == id ? MidnightTheme.accent : Color.secondary)
                .background(selectedID == id ? MidnightTheme.accent.opacity(0.13) : MidnightTheme.surface,in:Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selectedID == id ? [.isSelected] : [])
    }
    private struct Point: Codable, Sendable { let latitude: Double; let longitude: Double }
    private func loadRecorded() async {
        recorded = []
        guard selected.count == 1, let sector = selected.first,
              let start = parseUTCStamp(sector.startUTC), start < Date() else { return }
        let keys = HistoricalRoutePolicy.sessionKeys(for: sector, defaultRegistration: item.aircraft.first?.aircraftReg ?? "")
        // A sector tap must not decode a saved trail on the UI thread.
        let worker = Task.detached(priority: .utility) { Self.readRecorded(keys: keys) }
        let points = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled else { return }
        recorded = points.map { .init(latitude: $0.latitude, longitude: $0.longitude) }
    }
    nonisolated private static func readRecorded(keys: [String]) -> [Point] {
        for key in keys {
            guard !Task.isCancelled else { return [] }
            do {
                let file: ProtectedJSONFile<[Point]> = try DeviceCacheStorage.file(DeviceCacheStorage.trailName(key), folder: "Trails")
                guard let points = try file.load(migrateLegacy: false), points.count >= 2 else { continue }
                return Array(points.filter { $0.latitude.isFinite && $0.longitude.isFinite && (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) }.suffix(1500))
            } catch { DeviceCacheStorage.report("Read historical GPS points", error: error) }
        }
        return []
    }
}

private struct HistoricalExpandedRoute: View {
    let points: [TodayAirportMapPoint]
    let segments: [[CLLocationCoordinate2D]]
    let trail: [CLLocationCoordinate2D]
    let title: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var zoom: CGFloat = 1
    @State private var pan = CGSize.zero
    @GestureState private var drag = CGSize.zero
    @GestureState private var magnification: CGFloat = 1
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                OfflineAviationMapCanvas(points:points,trail:trail,liveLocation:nil,isTracking:false,
                    zoom:min(8,max(1,zoom*magnification)),pan:CGSize(width:pan.width+drag.width,height:pan.height+drag.height),
                    colorScheme:colorScheme,routeSegments:segments)
                    .clipped().contentShape(Rectangle())
                    .gesture(DragGesture().updating($drag) { value,state,_ in state=value.translation }.onEnded { value in
                        pan.width += value.translation.width; pan.height += value.translation.height
                    })
                    .simultaneousGesture(MagnificationGesture().updating($magnification) { value,state,_ in state=value }
                        .onEnded { value in zoom=min(8,max(1,zoom*value)) })
                    .accessibilityLabel("Offline scheduled route map. Drag to pan and pinch to zoom.")
                HStack {
                    Text(title).font(.caption).lineLimit(2)
                    Spacer()
                    Button("Recenter",systemImage:"scope") { zoom=1;pan = .zero }
                }.padding(16).background(.regularMaterial)
            }.midnightCanvas().navigationTitle("Scheduled route").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDetents([.large]).interactiveDismissDisabled()
    }
}
