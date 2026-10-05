import Foundation

@main
struct AppearanceChecks {
    static func main() {
        let name = "RAIDO.AppearanceChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label); checks += 1
        }
        RaidoAppearancePreferences.migrate(defaults)
        expect(defaults.string(forKey: RaidoAppearancePreferences.themeKey) == "ice", "Ice remains default")
        expect(defaults.string(forKey: RaidoAppearancePreferences.iceKey) == "system", "Fresh Ice follows System")
        expect(defaults.string(forKey: RaidoAppearancePreferences.getJetKey) == "system", "Fresh GetJet follows System")
        for legacy in ["light", "dark", "system"] {
            defaults.removeObject(forKey: RaidoAppearancePreferences.iceKey)
            defaults.set(legacy, forKey: "RAIDORoster.Appearance")
            RaidoAppearancePreferences.migrate(defaults)
            expect(defaults.string(forKey: RaidoAppearancePreferences.iceKey) == legacy, "Preserve existing Ice " + legacy)
        }
        defaults.set("getJet", forKey: RaidoAppearancePreferences.themeKey)
        defaults.set("light", forKey: RaidoAppearancePreferences.iceKey)
        defaults.set("dark", forKey: RaidoAppearancePreferences.getJetKey)
        RaidoAppearancePreferences.migrate(defaults)
        expect(defaults.string(forKey: RaidoAppearancePreferences.themeKey) == "getJet", "Migration never resets theme")
        expect(defaults.string(forKey: RaidoAppearancePreferences.iceKey) == "light", "Migration never resets Ice mode")
        expect(defaults.string(forKey: RaidoAppearancePreferences.getJetKey) == "dark", "Migration never resets GetJet mode")
        for theme in RaidoTheme.allCases {
            for mode in RaidoAppearance.allCases {
                let resolved = RaidoAppearancePreferences.appearance(theme: theme.rawValue, ice: theme == .ice ? mode.rawValue : "light", getJet: theme == .getJet ? mode.rawValue : "dark")
                expect(resolved == mode, "All six theme/mode combinations")
                expect(resolved.forcedDark == (mode == .system ? nil : mode == .dark), "Correct system or forced appearance")
            }
        }
        expect(RaidoAppearancePreferences.selectedTheme("invalid") == .ice, "Invalid theme falls back safely")
        expect(RaidoAppearancePreferences.appearance(theme: "getJet", ice: "dark", getJet: "invalid") == .system, "Invalid mode follows System")
        print("Passed \(checks) appearance migration and selection checks")
    }
}
