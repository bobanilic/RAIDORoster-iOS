import SwiftUI
import UIKit

@MainActor
final class AnnouncementStore: ObservableObject {
    @Published private(set) var catalogue: AnnouncementCatalogue?
    @Published private(set) var favorites: Set<String>
    let preferences = AnnouncementPreferences()

    init() {
        favorites = preferences.favorites
        if let url = Bundle.main.url(forResource: "GetJetAnnouncements", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            catalogue = try? AnnouncementCatalogue.decode(data)
        }
    }

    func toggle(_ key: String) {
        preferences.toggle(key)
        favorites = preferences.favorites
    }
}

struct AnnouncementsView: View {
    let item: RosterItem?
    @StateObject private var store = AnnouncementStore()
    @Environment(\.dismiss) private var dismiss
    @State private var aircraft: AnnouncementAircraft = .unspecified
    @State private var airline: AnnouncementAirline = .unspecified
    @State private var sectorID = ""
    @State private var query = ""
    @State private var initialized = false
    @AppStorage("RAIDORoster.Announcements.Language") private var languageValue = "en"

    @AppStorage("RAIDORoster.Announcements.BrowseAirline") private var browseAirline = ""
    @AppStorage("RAIDORoster.Announcements.BrowseAircraft") private var browseAircraft = ""

    private var sectors: [RosterActivity] { item?.flightActivities ?? [] }
    private var language: AnnouncementLanguage { AnnouncementLanguage(rawValue: languageValue) ?? .en }
    private var available: [CrewAnnouncement] {
        store.catalogue?.available(airline: airline, aircraft: aircraft, query: query) ?? []
    }
    private var favorites: [CrewAnnouncement] {
        available.filter { store.favorites.contains($0.favoriteKey(airline: airline, aircraft: aircraft)) }
    }

    var body: some View {
        NavigationStack {
            List {
                contextSection
                if let catalogue = store.catalogue {
                    if airline == .airhub {
                        Section {
                            ContentUnavailableView("Airhub book needed", systemImage: "book.closed",
                                description: Text("Airhub’s announcement scripts have not been added yet."))
                        }
                    } else if airline == .unspecified {
                        Section {
                            Text("Select the operating airline to open its announcements.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        catalogueSections(catalogue)
                    }
                } else {
                    Section {
                        ContentUnavailableView("Book unavailable", systemImage: "exclamationmark.triangle",
                            description: Text("The offline announcement book could not be loaded. Reinstall the latest build."))
                    }
                }
            }
            .navigationTitle("Announcements")
            .searchable(text: $query, prompt: "Search announcements")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                guard !initialized else { return }
                initialized = true
                // Do not silently choose the first sector of a multi-sector duty.
                if sectors.count == 1, let sector = sectors.first {
                    selectSector(sector.id)
                } else if sectors.isEmpty {
                    airline = AnnouncementAirline(rawValue: browseAirline) ?? .unspecified
                    aircraft = AnnouncementAircraft(rawValue: browseAircraft) ?? .unspecified
                }
            }
            .onChange(of: airline) { _, value in
                if sectors.isEmpty { browseAirline = value.rawValue }
            }
            .onChange(of: aircraft) { _, value in
                if sectors.isEmpty { browseAircraft = value.rawValue }
            }
        }
    }

    private var contextSection: some View {
        Section {
            if !sectors.isEmpty {
                Picker("Flight", selection: Binding(get: { sectorID }, set: { selectSector($0) })) {
                    Text("Choose flight / browse manually").tag("")
                    ForEach(sectors) { sector in
                        Text([sector.code, sector.route, sector.aircraftReg].filter { !$0.isEmpty }.joined(separator: " · "))
                            .tag(sector.id)
                    }
                }
            }
            Picker("Airline", selection: $airline) {
                ForEach(AnnouncementAirline.allCases) { Text($0.label).tag($0) }
            }
            Picker("Aircraft", selection: $aircraft) {
                ForEach(AnnouncementAircraft.allCases) { Text($0.label).tag($0) }
            }
            Picker("Language", selection: $languageValue) {
                ForEach(AnnouncementLanguage.allCases) { Text($0.label).tag($0.rawValue) }
            }
        } footer: {
            Text(aircraft == .unspecified
                 ? "Choose an aircraft to see its safety demonstration and emergency briefings."
                 : "\(airline.label) · \(aircraft.label) · Available offline")
        }
    }

    @ViewBuilder
    private func catalogueSections(_ catalogue: AnnouncementCatalogue) -> some View {
        if query.isEmpty {
            Section("Favorites") {
                if favorites.isEmpty {
                    Label("Tap a star to keep an announcement here", systemImage: "star")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(favorites) { announcementRow($0, catalogue: catalogue) }
                }
            }
        }
        if available.isEmpty {
            Section {
                ContentUnavailableView.search(text: query)
            }
        } else {
            ForEach(AnnouncementCatalogue.categoryOrder, id: \.self) { category in
                let values = available.filter { $0.category == category }
                if !values.isEmpty {
                    Section(category) {
                        ForEach(values) { announcementRow($0, catalogue: catalogue) }
                    }
                }
            }
        }
        Section {
            Label("Saved for offline reading", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
            Text("GetJet PAB · Issue \(catalogue.issue), revision \(catalogue.revision) · \(catalogue.revisionDate)")
                .font(.caption).foregroundStyle(.secondary)
            Text("Export marked uncontrolled. Check the current revision in Web Manuals.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func announcementRow(_ announcement: CrewAnnouncement, catalogue: AnnouncementCatalogue) -> some View {
        let key = announcement.favoriteKey(airline: airline, aircraft: aircraft)
        let isFavorite = store.favorites.contains(key)
        return HStack(spacing: 8) {
            NavigationLink {
                AnnouncementReader(announcement: announcement, catalogue: catalogue, store: store,
                                   airline: airline, aircraft: aircraft, preferredLanguage: language)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(announcement.title).font(.body)
                    Text(announcement.hasLanguage(language) ? "§ \(announcement.section)" : "English only in source")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                store.toggle(key)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isFavorite ? "Remove \(announcement.title) from favorites" : "Favorite \(announcement.title)")
        }
    }

    private func selectSector(_ id: String) {
        sectorID = id
        guard let sector = sectors.first(where: { $0.id == id }) else {
            aircraft = .unspecified; airline = .unspecified
            return
        }
        aircraft = AnnouncementAircraft.fromRoster(sector.aircraftType)
        airline = announcementAirline(registration: sector.aircraftReg)
    }
}

private struct AnnouncementReader: View {
    let announcement: CrewAnnouncement
    let catalogue: AnnouncementCatalogue
    @ObservedObject var store: AnnouncementStore
    let airline: AnnouncementAirline
    let aircraft: AnnouncementAircraft
    @State private var language: AnnouncementLanguage
    @State private var scrollID: String?
    @State private var priorIdleTimer = false
    @State private var ownsIdleTimer = false
    @AppStorage("RAIDORoster.Announcements.TextSize") private var textSize = 22.0
    @Environment(\.scenePhase) private var scenePhase

    init(announcement: CrewAnnouncement, catalogue: AnnouncementCatalogue, store: AnnouncementStore,
         airline: AnnouncementAirline, aircraft: AnnouncementAircraft, preferredLanguage: AnnouncementLanguage) {
        self.announcement = announcement; self.catalogue = catalogue; self.store = store
        self.airline = airline; self.aircraft = aircraft
        _language = State(initialValue: announcement.hasLanguage(preferredLanguage) ? preferredLanguage : .en)
    }

    private var key: String { announcement.favoriteKey(airline: airline, aircraft: aircraft) }
    private var positionKey: String { "\(key)|\(language.rawValue)|\(catalogue.issue).\(catalogue.revision)" }
    private var segments: [AnnouncementSegment] {
        announcement.readingSegments(language: language, aircraft: aircraft)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(announcement.title).font(.title2.bold())
                    Text("\(airline.label) · \(aircraft == .unspecified ? "Common announcement" : aircraft.label)")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    if !announcement.hasLanguage(.lt) {
                        Text("This announcement is English-only in the supplied book.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if language == .lt && announcement.section == "2.1" {
                        Text("The source’s Lithuanian version includes English exit instructions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Source wording retained. Fill the bracketed fields and choose the applicable alternatives before reading.")
                        .font(.caption).foregroundStyle(.secondary)
                }.id("header")
                ForEach(segments) { segment in
                    if segment.kind == "heading" {
                        Text(segment.text).font(.headline).foregroundStyle(.secondary).id(segment.id)
                    } else {
                        Text(segment.text)
                            .font(.system(size: min(34, max(18, textSize))))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(segment.id)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Divider()
                    Text("\(catalogue.copyright) · PAB \(catalogue.issue)/\(catalogue.revision) · § \(announcement.section), source page \(announcement.sourcePage)")
                    Text("Uncontrolled export · \(catalogue.revisionDate)")
                }.font(.caption).foregroundStyle(.secondary).id("source")
            }
            .scrollTargetLayout()
            .padding(20)
        }
        .scrollPosition(id: $scrollID, anchor: .top)
        .navigationTitle("Read announcement")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Language", selection: $language) {
                        ForEach(AnnouncementLanguage.allCases.filter { announcement.hasLanguage($0) }) {
                            Text($0.label).tag($0)
                        }
                    }
                    Button("Larger text", systemImage: "textformat.size.larger") { textSize = min(34, textSize + 2) }
                    Button("Smaller text", systemImage: "textformat.size.smaller") { textSize = max(18, textSize - 2) }
                    Button("Back to beginning", systemImage: "arrow.up.to.line") { scrollID = "header" }
                } label: {
                    Image(systemName: "textformat.size")
                }.accessibilityLabel("Reading options")
                Button { store.toggle(key) } label: {
                    Image(systemName: store.favorites.contains(key) ? "star.fill" : "star")
                }.accessibilityLabel(store.favorites.contains(key) ? "Remove favorite" : "Add favorite")
            }
        }
        .onAppear {
            scrollID = store.preferences.position(for: positionKey)
            if scenePhase == .active { keepAwake() }
        }
        .onDisappear { restoreIdleTimer() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { keepAwake() } else { restoreIdleTimer() }
        }
        .onChange(of: scrollID) { _, value in
            if let value { store.preferences.savePosition(value, for: positionKey) }
        }
        .onChange(of: language) { _, _ in
            scrollID = store.preferences.position(for: positionKey) ?? "header"
        }
    }

    private func keepAwake() {
        guard !ownsIdleTimer else { return }
        priorIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        ownsIdleTimer = true
    }

    private func restoreIdleTimer() {
        guard ownsIdleTimer else { return }
        UIApplication.shared.isIdleTimerDisabled = priorIdleTimer
        ownsIdleTimer = false
    }
}
