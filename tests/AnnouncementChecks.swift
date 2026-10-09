import Foundation

@main
struct AnnouncementChecks {
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let book = try AnnouncementCatalogue.decode(data)
        func item(_ section: String) -> CrewAnnouncement {
            book.announcements.first { $0.section == section }!
        }
        expect(book.announcements.count == 54, "Complete source catalogue")
        expect(book.issue == "6" && book.revision == "1" && book.revisionDate == "2026-02-01", "Source revision")
        expect(book.sourceSHA256.count == 64 && book.uncontrolledExport, "Source traceability")
        expect(AnnouncementAircraft.fromRoster("A320-200") == .a320, "Airbus alias")
        expect(AnnouncementAircraft.fromRoster("321") == .a321, "Roster numeric type")
        expect(AnnouncementAircraft.fromRoster("B737-800") == .b738, "Boeing exact subtype")
        expect(AnnouncementAircraft.fromRoster("737") == .unspecified, "Generic Boeing cannot select 737-800")
        expect(AnnouncementAircraft.fromRoster("A330") == .unspecified, "Unsupported aircraft not guessed")
        let operators = ["LY-TEN": "GETJET", "9H-GTS": "AIRHUB"]
        expect(AnnouncementAirline.fromRoster(registration: "LYTEN", operators: operators) == .getjet, "Compact RAIDO tail selects GetJet")
        expect(AnnouncementAirline.fromRoster(registration: " ly-ten ", operators: operators) == .getjet, "Punctuation and case normalized")
        expect(AnnouncementAirline.fromRoster(registration: "9HGTS", operators: operators) == .airhub, "Compact Airhub tail")
        expect(AnnouncementAirline.fromRoster(registration: "LY-XYZ", operators: operators) == .unspecified, "Lithuanian prefix is not an operator")
        expect(AnnouncementAirline.fromRoster(registration: "9H-XYZ", operators: operators) == .unspecified, "Maltese prefix is not an operator")
        expect(AnnouncementAirline.fromRoster(registration: "6H501", operators: operators) == .unspecified, "Marketing flight number is not an operator")
        expect(AnnouncementAirline.fromRoster(registration: "", operators: operators) == .unspecified, "Missing registration requires manual selection")
        expect(AnnouncementAirline.fromRoster(registration: "LYTEN", operators: ["LY-TEN": "ROSTER"]) == .unspecified, "Unknown leased operator is not guessed")
        expect(book.available(airline: .airhub, aircraft: .a320).isEmpty, "No GetJet scripts relabelled Airhub")
        expect(book.available(airline: .unspecified, aircraft: .a320).isEmpty, "Airline selection required")
        expect(book.available(airline: .getjet, aircraft: .unspecified).count == 49, "Common scripts without type")
        for aircraft in [AnnouncementAircraft.a320, .a321, .b738] {
            let available = book.available(airline: .getjet, aircraft: aircraft)
            expect(available.count == 52, "Only one matching demo and both emergency briefings")
            expect(available.filter { $0.category == "Safety demonstration" }.count == 1, "No other type's demo")
            for section in ["2.1", "2.2"] {
                let announcement = item(section)
                for language in AnnouncementLanguage.allCases {
                    let segments = announcement.readingSegments(language: language, aircraft: aircraft)
                    let variants = segments.filter { !$0.aircraft.isEmpty }
                    expect(variants.count == 2, "Exactly matching aircraft heading and exit paragraph")
                    expect(variants.allSatisfy { $0.aircraft.contains(aircraft.rawValue) }, "No other aircraft exits")
                    expect(segments.contains { $0.text.contains("BRACE") }, "Common brace instructions preserved")
                    expect(segments.allSatisfy { $0.language == language.rawValue || $0.language == "both" }, "Language segregation")
                }
            }
        }
        expect(item("2.1").readingSegments(language: .en, aircraft: .unspecified).isEmpty, "No ambiguous emergency exits")
        expect(item("1.3.1").readingSegments(language: .en, aircraft: .b738).isEmpty, "No wrong-aircraft reader")
        expect(!item("1.5.1").hasLanguage(.lt), "Controlled disembarkation has no fabricated translation")
        expect(item("1.5.1").readingSegments(language: .lt, aircraft: .a320).isEmpty, "Missing language stays missing")
        expect(!item("1.5.1").readingSegments(language: .en, aircraft: .a320).isEmpty, "English-only script available")
        expect(book.available(airline: .getjet, aircraft: .a320, query: "  FUELING  ").contains { $0.section == "1.1.2" }, "Search title/category ignoring case and padding")
        expect(book.available(airline: .getjet, aircraft: .a320, query: "1.1.3").contains { $0.section == "1.1.3" }, "Search source section")
        for announcement in book.announcements {
            expect(AnnouncementCatalogue.categoryOrder.contains(announcement.category), "Every item has a visible category")
            expect(Set(announcement.segments.map(\.id)).count == announcement.segments.count, "Stable unique scroll targets")
            expect(announcement.segments.allSatisfy { !$0.text.isEmpty && !$0.pdfPages.isEmpty }, "Source-backed nonempty segments")
            expect(!announcement.segments.contains { $0.text.contains("END OF DOCUMENT") || $0.text.contains("UNCONTROLLED DOCUMENT") }, "No export furniture in spoken script")
        }
        let ditchingLT = item("2.2").readingSegments(language: .lt, aircraft: .b738).map(\.text).joined(separator: " ")
        expect(ditchingLT.contains("Evakuacijos atveju visus asmeninius daiktus palikite lėktuve."), "Page boundary retains evacuation line")
        let suite = "RAIDO.AnnouncementTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AnnouncementPreferences(defaults: defaults)
        let commonKey = item("1.1.3").favoriteKey(airline: .getjet, aircraft: .a320)
        expect(commonKey == item("1.1.3").favoriteKey(airline: .getjet, aircraft: .b738), "Common favorite follows aircraft change")
        expect(commonKey != item("1.1.3").favoriteKey(airline: .airhub, aircraft: .a320), "Favorites isolated by airline")
        expect(item("2.1").favoriteKey(airline: .getjet, aircraft: .a320) != item("2.1").favoriteKey(airline: .getjet, aircraft: .a321), "Exit briefing favorites are type-specific")
        preferences.toggle(commonKey)
        let reloaded = AnnouncementPreferences(defaults: UserDefaults(suiteName: suite)!)
        expect(reloaded.favorites.contains(commonKey), "Favorite survives a new store")
        reloaded.toggle(commonKey)
        expect(!preferences.favorites.contains(commonKey), "Unfavorite persists")
        preferences.savePosition("segment-5", for: commonKey + "|en|6.1")
        expect(reloaded.position(for: commonKey + "|en|6.1") == "segment-5", "Reader position survives reopening")
        expect(reloaded.position(for: commonKey + "|lt|6.1") == nil, "Reader position isolated by language")
        expect(reloaded.position(for: commonKey + "|en|6.2") == nil, "New revision does not inherit stale segment position")
        var invalid = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        invalid["schemaVersion"] = 99
        expect((try? AnnouncementCatalogue.decode(JSONSerialization.data(withJSONObject: invalid))) == nil, "Unknown schema fails closed")
        print("Passed \(checks) announcement checks")
    }
}
