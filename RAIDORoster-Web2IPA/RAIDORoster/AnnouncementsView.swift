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
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
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
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        NavigationStack {
            List {
                contextSection
                if let catalogue = store.catalogue {
                    if airline == .airhub {
                        Section {
                            ContentUnavailableView("Airhub book needed", systemImage: "book.closed",
                                description: Text("Airhub’s announcement scripts have not been added yet."))
                        }.listRowBackground(MidnightTheme.surface)
                    } else if airline == .unspecified {
                        Section {
                            Text("Select the operating airline to open its announcements.")
                                .foregroundStyle(.secondary)
                        }.listRowBackground(MidnightTheme.surface)
                    } else {
                        catalogueSections(catalogue)
                    }
                } else {
                    Section {
                        ContentUnavailableView("Book unavailable", systemImage: "exclamationmark.triangle",
                            description: Text("The offline announcement book could not be loaded. Reinstall the latest build."))
                    }.listRowBackground(MidnightTheme.surface)
                }
            }
            .midnightCanvas().navigationTitle("Announcements")
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
            Text(airline == .unspecified
                 ? "Choose the operating airline to open its announcement book."
                 : airline == .airhub
                 ? "Airhub · \(aircraft.label) · Book not installed"
                 : aircraft == .unspecified
                 ? "Choose an aircraft to see its safety demonstration and emergency briefings."
                 : "\(airline.label) · \(aircraft.label) · Available offline")
        }.listRowBackground(MidnightTheme.surface)
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
            }.listRowBackground(MidnightTheme.surface)
        }
        if available.isEmpty {
            Section {
                ContentUnavailableView.search(text: query)
            }.listRowBackground(MidnightTheme.surface)
        } else {
            ForEach(AnnouncementCatalogue.categoryOrder, id: \.self) { category in
                let values = available.filter { $0.category == category }
                if !values.isEmpty {
                    Section(category) {
                        ForEach(values) { announcementRow($0, catalogue: catalogue) }
                    }.listRowBackground(MidnightTheme.surface)
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
        }.listRowBackground(MidnightTheme.surface)
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
    @Environment(\.raidoPalette) private var raidoColorPalette
    @Environment(\.raidoTheme) private var raidoVisualTheme
    let announcement: CrewAnnouncement
    let catalogue: AnnouncementCatalogue
    @ObservedObject var store: AnnouncementStore
    let airline: AnnouncementAirline
    let aircraft: AnnouncementAircraft
    @State private var language: AnnouncementLanguage
    @State private var scrollID: String?
    @State private var segments: [AnnouncementSegment]
    @State private var priorIdleTimer = false
    @State private var ownsIdleTimer = false
    @State private var showSourceDetails = false
    @AppStorage("RAIDORoster.Announcements.TextSize") private var textSize = 22.0
    @Environment(\.scenePhase) private var scenePhase

    init(announcement: CrewAnnouncement, catalogue: AnnouncementCatalogue, store: AnnouncementStore,
         airline: AnnouncementAirline, aircraft: AnnouncementAircraft, preferredLanguage: AnnouncementLanguage) {
        self.announcement = announcement; self.catalogue = catalogue; self.store = store
        self.airline = airline; self.aircraft = aircraft
        let initialLanguage = announcement.hasLanguage(preferredLanguage) ? preferredLanguage : .en
        _language = State(initialValue: initialLanguage)
        _segments = State(initialValue: announcement.readingSegments(language: initialLanguage, aircraft: aircraft))
    }

    private var key: String { announcement.favoriteKey(airline: airline, aircraft: aircraft) }
    private var positionKey: String { "\(key)|\(language.rawValue)|\(catalogue.issue).\(catalogue.revision)" }


    var body: some View {
        let _ = raidoColorPalette

        let _ = raidoVisualTheme

        ScrollView {
            // Keep the eager layout from 2.20.6. Each paragraph is a direct scroll target.
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(airline.label) · \(aircraft == .unspecified ? "Common" : aircraft.label)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(announcement.title)
                        .font(.system(.title, design: .default, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if !announcement.hasLanguage(.lt) {
                        Text("English only in the supplied book")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if language == .lt && announcement.section == "2.1" {
                        Text("The source includes English exit instructions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 8)
                .id("header")

                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    VStack(alignment: .leading, spacing: 10) {
                        if segment.kind == "heading" {
                            Text(segment.text)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 12)
                        } else if isAlternative(segment) {
                            if index == 0 || !isAlternative(segments[index - 1]) {
                                Text("Choose the applicable version")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            Text(segment.text)
                                .font(.system(size: min(30, max(16, textSize))))
                                .lineSpacing(5)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 14)
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.accentColor.opacity(0.4))
                                        .frame(width: 2).allowsHitTesting(false)
                                }
                        } else {
                            Text(segment.text)
                                .font(.system(size: min(30, max(16, textSize))))
                                .lineSpacing(6)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(segment.id)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    Text("PAB \(catalogue.issue)/\(catalogue.revision) · § \(announcement.section) · \(catalogue.revisionDate)")
                    Text("Uncontrolled export · Check the current revision in Web Manuals.")
                    Text(catalogue.copyright)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .id("source")
            }
            .scrollTargetLayout()
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(MidnightTheme.background)
        .scrollPosition(id: $scrollID, anchor: .top)
        .midnightCanvas().navigationTitle("Announcement")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("Script details", systemImage: "info.circle") { showSourceDetails = true }
                    Button("Back to beginning", systemImage: "arrow.up.to.line") { scrollID = "header" }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(minWidth: 32, minHeight: 44)
                }.accessibilityLabel("Announcement options")
                Button { store.toggle(key) } label: {
                    Image(systemName: store.favorites.contains(key) ? "star.fill" : "star")
                        .frame(minWidth: 32, minHeight: 44)
                }.accessibilityLabel(store.favorites.contains(key) ? "Remove favorite" : "Add favorite")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 16) {
                Menu {
                    Picker("Language", selection: $language) {
                        ForEach(AnnouncementLanguage.allCases.filter { announcement.hasLanguage($0) }) {
                            Text($0.label).tag($0)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(language.label).font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }.foregroundStyle(.primary).frame(minHeight: 44)
                }.accessibilityLabel("Announcement language: " + language.label)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Button { textSize = max(16, min(30, textSize) - 1) } label: {
                        Text("A−").font(.system(size: 16, weight: .medium)).frame(width: 44, height: 44)
                    }.disabled(textSize <= 16).accessibilityLabel("Smaller text")
                    Text("\(Int(min(30, max(16, textSize))))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 22)
                        .accessibilityLabel("Text size \(Int(min(30, max(16, textSize)))) points")
                    Button { textSize = min(30, max(16, textSize) + 1) } label: {
                        Text("A+").font(.system(size: 20, weight: .medium)).frame(width: 44, height: 44)
                    }.disabled(textSize >= 30).accessibilityLabel("Larger text")
                }
                .buttonStyle(.plain)
                .background(MidnightTheme.elevated, in: Capsule())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(MidnightTheme.background)
            .overlay(alignment: .top) { Divider() }
        }
        .sheet(isPresented: $showSourceDetails) {
            NavigationStack {
                List {
                    Section {
                        LabeledContent("Book", value: "GetJet Public Announcements Book")
                        LabeledContent("Issue / revision", value: "\(catalogue.issue) / \(catalogue.revision)")
                        LabeledContent("Date", value: catalogue.revisionDate)
                        LabeledContent("Section", value: "\(announcement.section) · \(announcement.sourcePage)")
                    }.listRowBackground(MidnightTheme.surface)
                    Section {
                        Text("Source wording is retained. Fill bracketed fields and choose the applicable // alternatives before reading.")
                        Text("This export is marked uncontrolled. Check the current revision in Web Manuals.")
                    }.listRowBackground(MidnightTheme.surface)
                }
                .midnightCanvas().navigationTitle("Script details")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSourceDetails = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear {
            textSize = min(30, max(16, textSize))
            scrollID = store.preferences.position(for: positionKey)
            if scenePhase == .active { keepAwake() }
        }
        .onDisappear {
            if let scrollID { store.preferences.savePosition(scrollID, for: positionKey) }
            restoreIdleTimer()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { keepAwake() } else {
                if let scrollID { store.preferences.savePosition(scrollID, for: positionKey) }
                restoreIdleTimer()
            }
        }
        .task(id: positionKey + "|" + (scrollID ?? "")) {
            // Persist after scrolling settles, not on every paragraph transition.
            let key = positionKey
            guard let value = scrollID else { return }
            do { try await Task.sleep(for: .milliseconds(400)) }
            catch { return }
            guard !Task.isCancelled else { return }
            store.preferences.savePosition(value, for: key)
        }
        .onChange(of: language) { previous, _ in
            if let scrollID {
                let previousKey = "\(key)|\(previous.rawValue)|\(catalogue.issue).\(catalogue.revision)"
                store.preferences.savePosition(scrollID, for: previousKey)
            }
            segments = announcement.readingSegments(language: language, aircraft: aircraft)
            scrollID = store.preferences.position(for: positionKey) ?? "header"
        }
    }

    private func isAlternative(_ segment: AnnouncementSegment) -> Bool {
        segment.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("//")
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
