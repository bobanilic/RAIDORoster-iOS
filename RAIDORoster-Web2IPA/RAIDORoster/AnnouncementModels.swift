import Foundation

enum AnnouncementAircraft: String, CaseIterable, Identifiable, Codable {
    case unspecified = ""
    case a320 = "A320"
    case a321 = "A321"
    case b738 = "B738"
    var id: String { rawValue }
    var label: String { self == .unspecified ? "Select aircraft" : (self == .b738 ? "B737-800" : rawValue) }

    static func fromRoster(_ value: String) -> Self {
        let key = value.uppercased().filter { $0.isLetter || $0.isNumber }
        switch key {
        case "320", "A320", "A320200", "A320214", "A320232": return .a320
        case "321", "A321", "A321200", "A321211": return .a321
        case "738", "B738", "737800", "B737800": return .b738
        default: return .unspecified // A generic 737 or an unknown subtype is not a verified 737-800.
        }
    }
}

enum AnnouncementAirline: String, CaseIterable, Identifiable {
    case unspecified = ""
    case getjet = "getjet"
    case airhub = "airhub"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .unspecified: return "Select airline"
        case .getjet: return "GetJet"
        case .airhub: return "Airhub"
        }
    }
}

enum AnnouncementLanguage: String, CaseIterable, Identifiable {
    case en, lt
    var id: String { rawValue }
    var label: String { self == .en ? "English" : "Lietuvių" }
}

struct AnnouncementSegment: Codable, Identifiable {
    let id: String
    let language: String
    let kind: String
    let aircraft: [String]
    let text: String
    let pdfPages: [Int]

    func applies(language: AnnouncementLanguage, aircraft selected: AnnouncementAircraft) -> Bool {
        (self.language == language.rawValue || self.language == "both") &&
        (aircraft.isEmpty || aircraft.contains(selected.rawValue))
    }
}

struct CrewAnnouncement: Codable, Identifiable {
    let id: String
    let section: String
    let title: String
    let category: String
    let aircraft: [String]
    let sourcePage: String
    let requiresAircraft: Bool
    let segments: [AnnouncementSegment]

    func applies(to selected: AnnouncementAircraft) -> Bool {
        (!requiresAircraft || selected != .unspecified) &&
        (aircraft.isEmpty || aircraft.contains(selected.rawValue))
    }

    func hasLanguage(_ language: AnnouncementLanguage) -> Bool {
        segments.contains { $0.language == language.rawValue }
    }

    func readingSegments(language: AnnouncementLanguage, aircraft: AnnouncementAircraft) -> [AnnouncementSegment] {
        guard applies(to: aircraft), hasLanguage(language) else { return [] }
        return segments.filter { $0.applies(language: language, aircraft: aircraft) }
    }

    func favoriteKey(airline: AnnouncementAirline, aircraft: AnnouncementAircraft) -> String {
        // Common scripts follow the airline; aircraft-dependent scripts keep a per-type favorite.
        "\(airline.rawValue)|\(requiresAircraft ? aircraft.rawValue : "common")|\(id)"
    }
}

struct AnnouncementCatalogue: Codable {
    let schemaVersion: Int
    let airline: String
    let title: String
    let issue: String
    let revision: String
    let revisionDate: String
    let uncontrolledExport: Bool
    let sourceSHA256: String
    let copyright: String
    let announcements: [CrewAnnouncement]

    static let categoryOrder = ["Boarding", "Fueling", "Safety demonstration", "In-flight", "Arrival",
                                "Service", "Disruptions", "Transit", "Other situations", "Emergency"]

    func available(airline selectedAirline: AnnouncementAirline, aircraft: AnnouncementAircraft,
                   query: String = "") -> [CrewAnnouncement] {
        guard selectedAirline.rawValue == airline else { return [] }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return announcements.filter { item in
            item.applies(to: aircraft) && (needle.isEmpty ||
                item.title.localizedCaseInsensitiveContains(needle) ||
                item.category.localizedCaseInsensitiveContains(needle) ||
                item.section == needle || item.segments.contains { $0.text.localizedCaseInsensitiveContains(needle) })
        }
    }

    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1, value.airline == "getjet", !value.announcements.isEmpty,
              Set(value.announcements.map(\.id)).count == value.announcements.count,
              value.announcements.allSatisfy({ item in
                  let validTypes = Set(["A320", "A321", "B738"])
                  return !item.segments.isEmpty && item.hasLanguage(.en) &&
                      Self.categoryOrder.contains(item.category) &&
                      Set(item.segments.map(\.id)).count == item.segments.count &&
                      Set(item.aircraft).isSubset(of: validTypes) &&
                      item.requiresAircraft == (!item.aircraft.isEmpty || item.segments.contains { !$0.aircraft.isEmpty }) &&
                      item.segments.allSatisfy { segment in
                          ["en", "lt", "both"].contains(segment.language) &&
                          ["text", "heading"].contains(segment.kind) &&
                          !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                          !segment.pdfPages.isEmpty && segment.pdfPages.allSatisfy { $0 > 0 } &&
                          Set(segment.aircraft).isSubset(of: validTypes)
                      }
              }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }
}

final class AnnouncementPreferences {
    private let defaults: UserDefaults
    private let favoritesKey = "RAIDORoster.Announcements.Favorites.V1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var favorites: Set<String> { Set(defaults.stringArray(forKey: favoritesKey) ?? []) }

    func toggle(_ key: String) {
        var values = favorites
        if !values.insert(key).inserted { values.remove(key) }
        defaults.set(values.sorted(), forKey: favoritesKey)
    }

    func savePosition(_ segmentID: String, for key: String) {
        defaults.set(segmentID, forKey: "RAIDORoster.Announcements.Position." + key)
    }

    func position(for key: String) -> String? {
        defaults.string(forKey: "RAIDORoster.Announcements.Position." + key)
    }
}
