import SwiftUI
import Foundation
import UIKit
import CoreLocation
import MapKit

private enum FleetFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case getjet = "GetJet"
    case airhub = "Airhub"
    var id: String { rawValue }
}

struct FleetView: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    @ObservedObject var store: RosterStore
    var tabActive = true
    var showsDismissButton = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var live = FleetLiveStore()
    @State private var query = ""
    @State private var filter: FleetFilter = .all
    @State private var selectedAircraft: FleetAircraftDefinition?
    @State private var showOtherFleet = false

    @State private var currentDutyRegistrations: Set<String> = []
    @State private var rosterIndex = FleetRosterIndex()
    @State private var learnedAircraft: [FleetAircraftDefinition] = []
    @State private var refreshNonce = 0
    @State private var contextTask: Task<Void, Never>?

    private func updateDuty() {
        let rows = store.todayItems + (store.nextDuty.map { [$0] } ?? [])
        currentDutyRegistrations = Set(rows.flatMap(\.aircraft).map {
            FleetTrackingPolicy.normalizedRegistration($0.aircraftReg)
        }.filter { !$0.isEmpty })
    }

    private func updateRosterContext() {
        updateDuty()
        let records = store.items.flatMap(\.flightActivities).map {
            FleetRosterEvidence(aircraftReg: $0.aircraftReg, aircraftType: $0.aircraftType,
                                route: $0.route, startUTC: $0.startUTC, endUTC: $0.endUTC)
        }
        let stations = store.items.flatMap(\.activityList).map(\.station).filter { !$0.isEmpty }
        let rows = store.todayItems + (store.nextDuty.map { [$0] } ?? [])
        let preferred = rows.flatMap(\.activityList).map(\.station).filter { !$0.isEmpty }
        contextTask?.cancel()
        contextTask = Task {
            let index = await Task.detached(priority: .userInitiated) {
                FleetRosterIndex(records, stations: stations, preferred: preferred)
            }.value
            guard !Task.isCancelled else { return }
            rosterIndex = index
            learnedAircraft = rosterLearnedAircraft
        }
    }

    private var rosterLearnedAircraft: [FleetAircraftDefinition] {
        var known = Set(FleetAircraftDefinition.all.map { FleetTrackingPolicy.normalizedRegistration($0.registration) })
        var learned: [FleetAircraftDefinition] = []
        for activity in rosterIndex.activities {
            let registration = FleetTrackingPolicy.canonicalRegistration(activity.aircraftReg)
            let key = FleetTrackingPolicy.normalizedRegistration(registration)
            guard !key.isEmpty, !known.contains(key) else { continue }
            if let stamp = activity.end ?? activity.start,
               Date().timeIntervalSince(stamp) > 30 * 86_400 { continue }
            known.insert(key)
            let rawType = activity.aircraftType.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let type: String
            if rawType.isEmpty { type = "Aircraft" }
            else if rawType.hasPrefix("A") || rawType.hasPrefix("B") { type = rawType }
            else if rawType.count == 3 && rawType.allSatisfy(\.isNumber) { type = "A" + rawType }
            else { type = rawType }
            learned.append(.init(registration: registration, type: type,
                                 operatorName: "RAIDO aircraft", operatorCode: "ROSTER", seats: ""))
        }
        return learned.sorted { $0.registration < $1.registration }
    }

    private var allAircraft: [FleetAircraftDefinition] {
        FleetAircraftDefinition.all + learnedAircraft
    }

    private var rotationAirport: String? { rosterIndex.rotationAirport }
    private var rosterRotationRegistrations: Set<String> { rosterIndex.rotationRegistrations }

    private enum FleetEvidenceBand: Int { case live = 0, recent, aging, historical, old, none }

    private func rosterActivities(for aircraft: FleetAircraftDefinition) -> [FleetRosterEvidence] {
        rosterIndex.byRegistration[FleetTrackingPolicy.normalizedRegistration(aircraft.registration)] ?? []
    }

    private func rosterAge(for aircraft: FleetAircraftDefinition, now: Date = Date()) -> TimeInterval? {
        rosterIndex.latest[FleetTrackingPolicy.normalizedRegistration(aircraft.registration)]
            .map { max(0, now.timeIntervalSince($0)) }
    }

    private func evidenceBand(_ aircraft: FleetAircraftDefinition) -> FleetEvidenceBand {
        guard let age = live.snapshot(for: aircraft.registration)?.effectivePositionAge else { return .none }
        if age <= 90 { return .live }
        if age <= 1200 { return .recent }
        if age <= 10800 { return .aging }
        if age <= 86400 { return .historical }
        return .old
    }

    private var filteredAircraft: [FleetAircraftDefinition] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allAircraft.filter { aircraft in
            let operatorMatches: Bool
            switch filter {
            case .all: operatorMatches = true
            case .getjet: operatorMatches = aircraft.operatorCode == "GETJET"
            case .airhub: operatorMatches = aircraft.operatorCode == "AIRHUB"
            }
            guard operatorMatches else { return false }
            return needle.isEmpty || [aircraft.registration, aircraft.type, aircraft.operatorName]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var refreshAircraft: [FleetAircraftDefinition] {
        allAircraft.sorted { lhs, rhs in
            let l = fleetPriority(lhs)
            let r = fleetPriority(rhs)
            if l != r { return l < r }
            return lhs.registration < rhs.registration
        }
    }

    private var assignedAircraft: [FleetAircraftDefinition] {
        filteredAircraft.filter { currentDutyRegistrations.contains(FleetTrackingPolicy.normalizedRegistration($0.registration)) }
    }

    private var rotationAircraft: [FleetAircraftDefinition] {
        guard rotationAirport != nil else { return [] }
        return filteredAircraft.filter {
            !currentDutyRegistrations.contains(FleetTrackingPolicy.normalizedRegistration($0.registration)) && isRotationRelevant($0)
        }.sorted { lhs, rhs in
            let l = fleetPriority(lhs)
            let r = fleetPriority(rhs)
            if l != r { return l < r }
            return lhs.registration < rhs.registration
        }
    }

    private var activeFleet: [FleetAircraftDefinition] {
        let used = Set((assignedAircraft + rotationAircraft).map {
            FleetTrackingPolicy.normalizedRegistration($0.registration)
        })
        return filteredAircraft.filter {
            !used.contains(FleetTrackingPolicy.normalizedRegistration($0.registration)) &&
            evidenceBand($0).rawValue <= FleetEvidenceBand.historical.rawValue
        }.sorted {
            let la = live.snapshot(for: $0.registration)?.effectivePositionAge ?? .infinity
            let ra = live.snapshot(for: $1.registration)?.effectivePositionAge ?? .infinity
            return la == ra ? $0.registration < $1.registration : la < ra
        }
    }

    private var otherFleet: [FleetAircraftDefinition] {
        let used = Set((assignedAircraft + rotationAircraft + activeFleet).map {
            FleetTrackingPolicy.normalizedRegistration($0.registration)
        })
        return filteredAircraft.filter {
            !used.contains(FleetTrackingPolicy.normalizedRegistration($0.registration))
        }.sorted { $0.registration < $1.registration }
    }

    private func isRotationRelevant(_ aircraft: FleetAircraftDefinition) -> Bool {
        guard let airport = rotationAirport else { return false }
        let key = FleetTrackingPolicy.normalizedRegistration(aircraft.registration)
        if currentDutyRegistrations.contains(key) { return true }
        if let intelligence = live.intelligence(for: aircraft.registration),
           (live.snapshot(for: aircraft.registration)?.effectivePositionAge ?? .infinity) <= 10800 {
            if intelligence.nearestAirport == airport { return true }
            if let route = intelligence.currentRoute,
               FleetTrackingPolicy.rotationRelation(route: route, airport: airport) != .unrelated { return true }
        }
        return rosterRotationRegistrations.contains(key) && (rosterAge(for: aircraft) ?? .infinity) <= 604800
    }

    private func fleetPriority(_ aircraft: FleetAircraftDefinition) -> Int {
        let key = FleetTrackingPolicy.normalizedRegistration(aircraft.registration)
        if currentDutyRegistrations.contains(key) { return 0 }
        guard let airport = rotationAirport else {
            return live.snapshot(for: aircraft.registration).map { $0.isFresh && $0.isAirborne } == true ? 20 : 30
        }
        let intelligence = live.intelligence(for: aircraft.registration)
        if live.snapshot(for: aircraft.registration).map({ $0.isFresh && $0.isAirborne }) == true,
           let route = intelligence?.currentRoute {
            switch FleetTrackingPolicy.rotationRelation(route: route, airport: airport) {
            case .inbound: return 1
            case .outbound: return 3
            case .touches: return 4
            case .unrelated: break
            }
        }
        if live.snapshot(for: aircraft.registration)?.isFresh == true,
           live.snapshot(for: aircraft.registration)?.onGround == true,
           intelligence?.nearestAirport == airport { return 2 }
        if intelligence?.nearestAirport == airport { return 4 }
        if rosterRotationRegistrations.contains(key) { return 5 }
        return live.snapshot(for: aircraft.registration).map { $0.isFresh && $0.isAirborne } == true ? 20 : 30
    }

    private func fleetRoute(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if let pair = FleetTrackingPolicy.routeAirports(raw) {
            return "\(pair.origin) → \(pair.destination)"
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value.replacingOccurrences(of: "-", with: " → ")
    }

    private func fleetAge(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private func rosterStatus(_ aircraft: FleetAircraftDefinition, now: Date = Date()) -> String? {
        let activities = rosterActivities(for: aircraft)
        guard !activities.isEmpty else { return nil }

        if let current = activities.first(where: { a in
            guard let start = a.start, let end = a.end else { return false }
            return now >= start && now < end
        }) {
            return "ROSTER FLIGHT · \(fleetRoute(current.route) ?? "Sector")"
        }

        let future = activities.compactMap { a -> (FleetRosterEvidence, Date)? in
            guard let start = a.start, start > now else { return nil }
            return (a, start)
        }.sorted { $0.1 < $1.1 }
        if let next = future.first, next.1.timeIntervalSince(now) <= 24 * 3600 {
            return "NEXT ROSTER FLIGHT · \(fleetRoute(next.0.route) ?? "Sector") · in \(fleetAge(next.1.timeIntervalSince(now)))"
        }

        let recent = activities.compactMap { a -> (FleetRosterEvidence, Date)? in
            guard let end = a.end, end <= now else { return nil }
            return (a, end)
        }.sorted { $0.1 > $1.1 }
        if let last = recent.first, now.timeIntervalSince(last.1) <= 6 * 3600 {
            return "ROSTER SECTOR ENDED · \(fleetRoute(last.0.route) ?? "Sector") · \(fleetAge(now.timeIntervalSince(last.1))) ago"
        }
        return nil
    }

    private func primaryStatus(_ aircraft: FleetAircraftDefinition, now: Date = Date()) -> String {
        let snapshot = live.snapshot(for: aircraft.registration)
        let intelligence = live.intelligence(for: aircraft.registration)
        let route = fleetRoute(intelligence?.currentRoute ?? snapshot?.route)
        if let snapshot, snapshot.effectivePositionAge <= 90, snapshot.hasKnownGroundState {
            if snapshot.onGround { return intelligence?.nearestAirport.map { "LIVE · ON GROUND · \($0)" } ?? "LIVE · ON GROUND" }
            let raw = intelligence?.phase.rawValue.uppercased() ?? "AIRBORNE"
            let phase = raw == "UNKNOWN" ? "AIRBORNE" : raw
            return route.map { "LIVE · \(phase) · \($0)" } ?? "LIVE · \(phase)"
        }
        if let snapshot, snapshot.effectivePositionAge <= 1200, snapshot.hasKnownGroundState {
            if snapshot.onGround { return "RECENTLY ON GROUND" }
            return route.map { "RECENTLY AIRBORNE · \($0)" } ?? "RECENTLY AIRBORNE"
        }
        if let roster = rosterStatus(aircraft, now: now) { return roster }
        if let snapshot, snapshot.effectivePositionAge <= 10800, snapshot.hasKnownGroundState {
            let age = fleetAge(snapshot.effectivePositionAge)
            return snapshot.onGround ? "LAST SEEN ON GROUND · \(age)" : "LAST SEEN AIRBORNE · \(age)"
        }
        if let snapshot, snapshot.effectivePositionAge <= 86400 { return "LAST OBSERVED · \(fleetAge(snapshot.effectivePositionAge)) ago" }
        if isRotationRelevant(aircraft), let airport = rotationAirport { return "RECENT ROTATION AIRCRAFT · \(airport)" }
        return "NO RECENT TRACKING"
    }

    private func sourceStatus(_ aircraft: FleetAircraftDefinition) -> String {
        guard let snapshot = live.snapshot(for: aircraft.registration) else {
            return rosterStatus(aircraft) == nil ? "No live or recent tracking evidence" : "Roster evidence · live position unavailable"
        }
        let source = snapshot.providerName ?? "public ADS-B"
        var values = [snapshot.isFresh ? "\(source) · \(fleetCompactAge(snapshot.effectivePositionAge))" : "Last ADS-B · \(fleetCompactAge(snapshot.effectivePositionAge)) · \(source)"]
        if let callsign = snapshot.callsign?.trimmingCharacters(in: .whitespacesAndNewlines), !callsign.isEmpty { values.append(callsign) }
        if snapshot.isFresh, !snapshot.onGround, let altitude = snapshot.altitudeFeet { values.append("\(Int(altitude.rounded()).formatted()) ft") }
        if snapshot.isFresh, let speed = snapshot.groundSpeedKnots, speed.isFinite, speed > 30 { values.append("\(Int(speed.rounded())) kt") }
        return values.joined(separator: " · ")
    }

    private func rotationContext(_ aircraft: FleetAircraftDefinition) -> String? {
        guard let airport = rotationAirport else { return nil }
        let intelligence = live.intelligence(for: aircraft.registration)
        let snapshot = live.snapshot(for: aircraft.registration)
        if let route = intelligence?.currentRoute,
           let label = FleetTrackingPolicy.rotationRouteLabel(route: route, airport: airport,
                isFresh: snapshot?.isFresh == true, isAirborne: snapshot?.isAirborne == true) {
            return label
        }
        if live.snapshot(for: aircraft.registration)?.isFresh == true,
           live.snapshot(for: aircraft.registration)?.onGround == true,
           intelligence?.nearestAirport == airport { return "On ground · \(airport)" }
        if intelligence?.nearestAirport == airport { return "Last seen near \(airport)" }
        if rosterRotationRegistrations.contains(FleetTrackingPolicy.normalizedRegistration(aircraft.registration)) {
            return rosterAge(for: aircraft).map { "Roster-used on \(airport) · \(fleetAge($0)) ago" } ?? "Roster-used on \(airport)"
        }
        return nil
    }

    private var rotationTitle: String? {
        guard let airport = rotationAirport else { return nil }
        let names = ["TLV": "Tel Aviv", "AUH": "Abu Dhabi", "BEG": "Belgrade",
                     "VNO": "Vilnius", "RIX": "Riga", "LCA": "Larnaca"]
        if let name = names[airport] { return "CURRENT ROTATION · \(name) · \(airport)" }
        return "CURRENT ROTATION · \(airport)"
    }

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        // Evaluate the sections once per render, not again for every count/row.
        let assignedAircraft = self.assignedAircraft
        let rotationAircraft = self.rotationAircraft
        let activeFleet = self.activeFleet
        let otherFleet = self.otherFleet
        return NavigationStack {
            List {
                HStack(alignment: .top) {
                    IcePageHeading(title: "Fleet", subtitle: "Your aircraft, rotation & live observations")
                    Button { refreshNonce += 1 } label: {
                        if live.isRefreshing { ProgressView().frame(width: 44, height: 44) }
                        else { Image(systemName: "arrow.clockwise").font(.title3).frame(width: 44, height: 44) }
                    }.buttonStyle(.plain).accessibilityLabel("Refresh fleet")
                    if showsDismissButton { Button("Done") { dismiss() }.frame(minHeight: 44) }
                }.padding(.vertical, 8).listRowSeparator(.hidden).listRowBackground(Color.clear)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Registration or aircraft type", text: $query)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .accessibilityLabel("Search Fleet")
                }.font(.subheadline).padding(11).background(MidnightTheme.elevated, in: RoundedRectangle(cornerRadius: 11))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                Section {
                    Picker("Fleet", selection: $filter) {
                        ForEach(FleetFilter.allCases) { value in Text(value.rawValue).tag(value) }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)

                if !assignedAircraft.isEmpty {
                    Section("YOUR CURRENT / NEXT AIRCRAFT") {
                        ForEach(assignedAircraft) { aircraft in
                            FleetAircraftRow(aircraft: aircraft,
                                snapshot: live.snapshot(for: aircraft.registration), isAssigned: true,
                                primaryStatus: { primaryStatus(aircraft) },
                                contextText: { rotationContext(aircraft) },
                                sourceText: { sourceStatus(aircraft) })
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedAircraft = aircraft }
                        }
                    }
                }

                if let rotationTitle, !rotationAircraft.isEmpty {
                    Section(rotationTitle) {
                        ForEach(rotationAircraft) { aircraft in
                            FleetAircraftRow(aircraft: aircraft,
                                snapshot: live.snapshot(for: aircraft.registration), isAssigned: false,
                                primaryStatus: { primaryStatus(aircraft) },
                                contextText: { rotationContext(aircraft) },
                                sourceText: { sourceStatus(aircraft) })
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedAircraft = aircraft }
                        }
                    }
                }

                if activeFleet.isEmpty && otherFleet.isEmpty && assignedAircraft.isEmpty && rotationAircraft.isEmpty {
                    ContentUnavailableView.search(text: query)
                }

                if !activeFleet.isEmpty {
                    Section("ACTIVE / RECENT FLEET") {
                        ForEach(activeFleet) { aircraft in
                            FleetAircraftRow(aircraft: aircraft,
                                snapshot: live.snapshot(for: aircraft.registration), isAssigned: false,
                                primaryStatus: { primaryStatus(aircraft) },
                                sourceText: { sourceStatus(aircraft) })
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedAircraft = aircraft }
                        }
                    }
                }

                if !otherFleet.isEmpty {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Section {
                            DisclosureGroup(isExpanded: $showOtherFleet) {
                                ForEach(otherFleet) { aircraft in
                                    FleetAircraftRow(aircraft: aircraft,
                                        snapshot: live.snapshot(for: aircraft.registration), isAssigned: false,
                                        primaryStatus: { primaryStatus(aircraft) },
                                        sourceText: { sourceStatus(aircraft) })
                                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                                .contentShape(Rectangle())
                                        .onTapGesture { selectedAircraft = aircraft }
                                }
                            } label: {
                                Label("Other fleet · \(otherFleet.count) aircraft", systemImage: "airplane.circle")
                                    .font(.subheadline.weight(.semibold))
                            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                        }
                    } else {
                        Section("OTHER MATCHES") {
                            ForEach(otherFleet) { aircraft in
                                FleetAircraftRow(aircraft: aircraft,
                                    snapshot: live.snapshot(for: aircraft.registration), isAssigned: false,
                                    primaryStatus: { primaryStatus(aircraft) },
                                    sourceText: { sourceStatus(aircraft) })
                                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                                .contentShape(Rectangle())
                                    .onTapGesture { selectedAircraft = aircraft }
                            }
                        }
                    }
                }

                if let error = live.errorText {
                    Text(error).font(.caption).foregroundStyle(.secondary).listRowBackground(Color.clear)
                }

                Section {
                    Text("Live position uses independent public ADS-B networks (ADSB.lol, adsb.fi, with outage fallback). Public ADS-B can be incomplete, delayed or unavailable. Routes and rotation relevance are inferred from public signals and your saved RAIDO roster. AOG, serviceability and standby activation are never inferred; RAIDO / Crew Control remain authoritative for operational status.")
                        .font(.caption).foregroundStyle(.secondary).listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain).midnightCanvas()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedAircraft) { aircraft in
                FleetAircraftDetailView(aircraft: aircraft, live: live,
                    isAssigned: currentDutyRegistrations.contains(FleetTrackingPolicy.normalizedRegistration(aircraft.registration)))
            }
            .onChange(of: store.lastSync, initial: true) { _, _ in updateRosterContext() }
            .onDisappear { contextTask?.cancel() }
            .task(id: "\(tabActive)-\(scenePhase)-\(refreshNonce)-" + allAircraft.map(\.registration).sorted().joined(separator: "|")) {
                guard tabActive, scenePhase == .active else { return }
                updateDuty()
                await live.refresh(definitions: refreshAircraft)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    updateDuty()
                    await live.refresh(definitions: refreshAircraft)
                }
            }
        }
    }
}

private func fleetDuration(_ interval: TimeInterval) -> String {
    let totalMinutes = max(0, Int(interval / 60))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}

private func fleetCompactAge(_ age: TimeInterval) -> String {
    guard age.isFinite else { return "age unknown" }
    let seconds = max(0, Int(age))
    if seconds < 60 { return "\(seconds)s ago" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    if seconds < 86_400 { return "\(seconds / 3600)h ago" }
    return "\(seconds / 86_400)d ago"
}

private struct FleetAircraftRow: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let aircraft: FleetAircraftDefinition
    let snapshot: FleetLiveSnapshot?
    let isAssigned: Bool
    var primaryStatus: (() -> String)? = nil
    var contextText: (() -> String?)? = nil
    var sourceText: (() -> String)? = nil

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        TimelineView(.periodic(from: .now, by: 15)) { _ in
            HStack(spacing: 14) {
                Image(systemName: "airplane")
                    .font(.title2.weight(.regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(aircraft.registration) · \(aircraft.type)")
                        .font(.headline.weight(.semibold))
                    Text(primaryStatus?() ?? "STATUS UNKNOWN")
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if let context = contextText?(), !context.isEmpty {
                        Text(context)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(sourceText?() ?? "Live position unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14).midnightCard(radius: 16)
            .accessibilityElement(children: .combine)
        }
    }
}

@MainActor
private final class FleetAircraftPhotoStore: ObservableObject {
    @Published private(set) var imageURL: URL?
    @Published private(set) var photographer: String?
    @Published private(set) var sourceURL: URL?
    @Published private(set) var isLoading = false

    private let registration: String

    init(registration: String) {
        self.registration = registration
    }

    func load() async {
        guard imageURL == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let encoded = registration.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? registration
        guard let url = URL(string: "https://api.planespotters.net/pub/photos/reg/\(encoded)") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("RAIDORoster/2.23.0", forHTTPHeaderField: "User-Agent")

        guard let receipt = try? await AircraftHTTPClient.shared.data(for: request, cacheSeconds: 3_600),
              !Task.isCancelled,
              let root = try? JSONSerialization.jsonObject(with: receipt.data) as? [String: Any],
              let photos = root["photos"] as? [[String: Any]],
              let first = photos.first,
              let thumbnail = first["thumbnail"] as? [String: Any],
              let source = thumbnail["src"] as? String,
              let imageURL = URL(string: source) else { return }

        self.imageURL = imageURL
        photographer = first["photographer"] as? String
        if let link = first["link"] as? String, let url = URL(string: link),
           url.scheme == "https", ["planespotters.net", "www.planespotters.net"].contains(url.host ?? "") {
            sourceURL = url
        }
    }
}

private struct FleetAircraftDetailView: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let aircraft: FleetAircraftDefinition
    @ObservedObject var live: FleetLiveStore
    var snapshot: FleetLiveSnapshot? { live.snapshot(for: aircraft.registration) }
    var intelligence: FleetAircraftIntelligence? { live.intelligence(for: aircraft.registration) }
    let isAssigned: Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var photo: FleetAircraftPhotoStore

    init(aircraft: FleetAircraftDefinition, live: FleetLiveStore, isAssigned: Bool) {
        self.aircraft = aircraft
        self.live = live
        self.isAssigned = isAssigned
        _photo = StateObject(wrappedValue: FleetAircraftPhotoStore(registration: aircraft.registration))
    }

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        TimelineView(.periodic(from: .now, by: 15)) { _ in

        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ZStack(alignment: .bottomLeading) {
                        Group {
                            if let imageURL = photo.imageURL {
                                AsyncImage(url: imageURL) { phase in
                                    if let image = phase.image {
                                        image
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        fleetPhotoPlaceholder
                                    }
                                }
                            } else {
                                fleetPhotoPlaceholder
                            }
                        }
                        .frame(height: 190)
                        .frame(maxWidth: .infinity)
                        .clipped()

                        LinearGradient(
                            colors: [.clear, .black.opacity(0.74)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        .frame(height: 190)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(aircraft.registration)
                                .font(.title.bold().monospaced())
                                .foregroundStyle(.white)
                            Text("\(aircraft.operatorName) • \(aircraft.type)")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.85))
                            if let photographer = photo.photographer {
                                Group {
                                    if let source = photo.sourceURL {
                                        Link("© \(photographer) • Planespotters.net", destination: source)
                                    } else {
                                        Text("© \(photographer) • Planespotters.net")
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.85))
                            }
                        }
                        .padding(16)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .onTapGesture {
                        if let source = photo.sourceURL { UIApplication.shared.open(source) }
                    }
                    .accessibilityLabel("Aircraft photograph. Open original photo on Planespotters.")

                    if isAssigned {
                        Label("Assigned to your current / next rostered duty", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let snapshot {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(snapshot.isFresh ? (snapshot.isAirborne ? "AIRBORNE" : (snapshot.onGround ? "ON GROUND" : "LIVE")) : (snapshot.isRecent ? (snapshot.isAirborne ? "LAST SEEN AIRBORNE" : (snapshot.onGround ? "LAST SEEN ON GROUND" : "RECENTLY SEEN")) : "STALE"))
                                        .font(.caption.bold())
                                        .foregroundStyle(snapshot.isAirborne ? .green : .blue)
                                    Text(snapshot.callsign ?? "No callsign")
                                        .font(.title3.weight(.semibold).monospaced())
                                }
                                Spacer()
                                if let route = snapshot.route {
                                    Text(route)
                                        .font(.headline.monospaced())
                                }
                            }

                            if let lat = snapshot.latitude, let lon = snapshot.longitude {
                                Map(initialPosition: .region(MKCoordinateRegion(
                                    center: .init(latitude: lat, longitude: lon),
                                    latitudinalMeters: snapshot.isAirborne ? 700_000 : 80_000,
                                    longitudinalMeters: snapshot.isAirborne ? 700_000 : 80_000
                                )), interactionModes: [.pan, .zoom]) {
                                    Annotation(aircraft.registration, coordinate: .init(latitude: lat, longitude: lon)) {
                                        Image(systemName: "airplane")
                                            .font(.title2.bold())
                                            .foregroundStyle(.green)
                                            .rotationEffect(.degrees((snapshot.trackDegrees ?? 70) - 90))
                                    }
                                }
                                .mapStyle(.standard)
                                .frame(height: 210)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                            }

                            if let intelligence {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Label("Estimated: " + intelligence.phase.rawValue, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        if let airport = intelligence.nearestAirport {
                                            Text("NEAR \(airport)")
                                                .font(.caption.bold().monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    if let current = intelligence.currentRoute {
                                        LabeledContent("Inferred route", value: current)
                                    }
                                    if let previous = intelligence.previousRoute {
                                        LabeledContent("Earlier inferred route", value: previous)
                                    }
                                    if let turnaround = intelligence.turnaroundSeconds {
                                        LabeledContent("Since detected landing ≈", value: fleetDuration(turnaround))
                                    }
                                    if let arrival = intelligence.lastArrivalAt {
                                        LabeledContent("Landing detected ≈", value: arrival.formatted(date: .omitted, time: .shortened))
                                    }
                                    if let departure = intelligence.lastDepartureAt {
                                        LabeledContent("Takeoff detected ≈", value: departure.formatted(date: .omitted, time: .shortened))
                                    }
                                }
                                .font(.caption)
                                .padding(12)
                                .midnightCard(radius: 14)
                            }

                            HStack(spacing: 0) {
                                FleetMetric(title: "Altitude", value: snapshot.altitudeFeet.map { "\(Int($0.rounded()).formatted()) ft" } ?? "—")
                                Divider().frame(height: 34)
                                FleetMetric(title: "Ground speed", value: snapshot.groundSpeedKnots.map { "\(Int($0.rounded())) kt" } ?? "—")
                                Divider().frame(height: 34)
                                FleetMetric(title: "Track", value: snapshot.trackDegrees.map { "\(Int($0.rounded()))°" } ?? "—")
                            }

                            Text("Position \(fleetCompactAge(snapshot.effectivePositionAge)) • \(snapshot.providerName ?? "public ADS-B")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Text("Position \(snapshot.positionQualityText)")
                                if let hex = snapshot.icaoHex { Text("ICAO \(hex)") }
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .midnightCard(radius: 18)
                    } else {
                        ContentUnavailableView(
                            "Aircraft not currently tracked",
                            systemImage: "antenna.radiowaves.left.and.right.slash",
                            description: Text("Public ADS-B coverage may be unavailable while the aircraft is parked, out of coverage, or not broadcasting a usable position.")
                        )
                        .frame(minHeight: 180)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Aircraft", value: aircraft.type)
                        if !aircraft.seats.isEmpty {
                            LabeledContent("Cabin", value: aircraft.seats)
                        }
                        LabeledContent("Operator", value: aircraft.operatorName)
                        LabeledContent("Registration", value: aircraft.registration)
                    }
                    .font(.subheadline)
                    .padding(14)
                    .midnightCard(radius: 18)

                    Text("Public tracking is situational awareness only. ADS-B does not provide an authoritative GetJet/Airhub operational delay. Confirm roster, aircraft assignment and operational changes in RAIDO or with Crew Control.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .midnightCanvas().navigationTitle("Aircraft")
            .navigationBarTitleDisplayMode(.inline)
            .task { await photo.load() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }

        }
    }

    private var fleetPhotoPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.secondary.opacity(0.20), Color.secondary.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "airplane")
                .font(.system(size: 78, weight: .light))
                .rotationEffect(.degrees(-18))
                .foregroundStyle(.secondary.opacity(0.55))
        }
    }

    private func fleetAge(_ snapshot: FleetLiveSnapshot) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(snapshot.fetchedAt) + snapshot.sourceSeenSeconds))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}

private struct FleetMetric: View {
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let title: String
    let value: String

    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        VStack(spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

