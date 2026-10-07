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
        func luminance(_ hex: UInt32) -> Double {
            func channel(_ shift: UInt32) -> Double {
                let value = Double((hex >> shift) & 255) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        }
        for theme in RaidoTheme.allCases {
            for dark in [false, true] {
                let foreground = luminance(RaidoActionPalette.ink)
                let fill = luminance(RaidoActionPalette.fill(theme: theme, dark: dark))
                expect((max(foreground, fill) + 0.05) / (min(foreground, fill) + 0.05) >= 4.5, "Readable filled actions in every theme and mode")
            }
        }
        expect(defaults.string(forKey: RaidoAppearancePreferences.icePaletteKey) == "iceBlue", "Existing Ice colours remain default")
        expect(defaults.string(forKey: RaidoAppearancePreferences.getJetPaletteKey) == "forestGreen", "Existing GetJet colours remain default")
        defaults.set("espressoBronze", forKey: RaidoAppearancePreferences.icePaletteKey)
        defaults.set("burgundyRose", forKey: RaidoAppearancePreferences.getJetPaletteKey)
        RaidoAppearancePreferences.migrate(defaults)
        expect(defaults.string(forKey: RaidoAppearancePreferences.icePaletteKey) == "espressoBronze", "Migration retains Ice palette")
        expect(defaults.string(forKey: RaidoAppearancePreferences.getJetPaletteKey) == "burgundyRose", "Migration retains GetJet palette")
        expect(RaidoAppearancePreferences.selectedPalette(theme: .ice, ice: "invalid", getJet: "burgundyRose") == .iceBlue, "Invalid Ice palette falls back")
        expect(RaidoAppearancePreferences.selectedPalette(theme: .getJet, ice: "espressoBronze", getJet: "invalid") == .forestGreen, "Invalid GetJet palette falls back")
        for palette in RaidoPalette.allCases {
            for theme in RaidoTheme.allCases {
                let resolved = RaidoAppearancePreferences.selectedPalette(theme: theme,
                    ice: theme == .ice ? palette.rawValue : "iceBlue",
                    getJet: theme == .getJet ? palette.rawValue : "forestGreen")
                expect(resolved == palette, "Independent palette selection in both layouts")
            }
            for dark in [false, true] {
                let c = palette.colors(dark: dark)
                for (foreground, background) in [(c.ink, c.background), (c.ink, c.surface),
                    (c.accent, c.background), (c.offInk, c.background),
                    (c.selectionInk, c.highlight), (c.warningInk, c.warning),
                    (RaidoActionPalette.ink, c.actionFill)] {
                    let a = luminance(foreground), b = luminance(background)
                    expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5, "Readable " + palette.title + " colour roles")
                }
            }
        }
        print("Passed \(checks) appearance migration and selection checks")
    }
}
