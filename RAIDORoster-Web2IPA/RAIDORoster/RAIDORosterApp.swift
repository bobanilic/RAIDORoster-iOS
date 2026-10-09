import SwiftUI

@main
struct RAIDORosterApp: App {
    @AppStorage("RAIDORoster.Theme") private var themeRaw = "ice"
    @AppStorage("RAIDORoster.Appearance.Ice") private var iceAppearance = "system"
    @AppStorage("RAIDORoster.Appearance.GetJet") private var getJetAppearance = "system"

    @AppStorage("RAIDORoster.Palette.Ice") private var icePalette = "iceBlue"
    @AppStorage("RAIDORoster.Palette.GetJet") private var getJetPalette = "forestGreen"
    private var colorPalette: RaidoPalette {
        RaidoAppearancePreferences.selectedPalette(theme: theme, ice: icePalette, getJet: getJetPalette)
    }
    private var theme: RaidoTheme { RaidoAppearancePreferences.selectedTheme(themeRaw) }
    private var appearance: RaidoAppearance {
        RaidoAppearancePreferences.appearance(theme: themeRaw, ice: iceAppearance, getJet: getJetAppearance)
    }
    private var preferredScheme: ColorScheme? {
        appearance.forcedDark.map { $0 ? .dark : .light }
    }
    init() {
        RaidoAppearancePreferences.migrate(.standard)
        MidnightTheme.configure()
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.raidoTheme, theme)
                .environment(\.raidoPalette, colorPalette)
                .preferredColorScheme(preferredScheme)
                .background(RaidoChromeRefresh(theme: theme, appearance: appearance, palette: colorPalette).allowsHitTesting(false))
        }
    }
}
