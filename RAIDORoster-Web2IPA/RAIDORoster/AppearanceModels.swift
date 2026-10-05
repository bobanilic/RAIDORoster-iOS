import Foundation

enum RaidoTheme: String, CaseIterable, Identifiable {
    case ice, getJet
    var id: String { rawValue }
    var title: String { self == .ice ? "Ice" : "GetJet" }
}

enum RaidoAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { self == .system ? "System" : self == .light ? "Light" : "Dark" }
    var forcedDark: Bool? { self == .system ? nil : self == .dark }
}

enum RaidoAppearancePreferences {
    static let themeKey = "RAIDORoster.Theme"
    static let iceKey = "RAIDORoster.Appearance.Ice"
    static let getJetKey = "RAIDORoster.Appearance.GetJet"

    static func migrate(_ defaults: UserDefaults) {
        if defaults.string(forKey: themeKey) == nil { defaults.set(RaidoTheme.ice.rawValue, forKey: themeKey) }
        if defaults.string(forKey: iceKey) == nil {
            let previous = defaults.string(forKey: "RAIDORoster.Appearance") ?? "system"
            defaults.set((RaidoAppearance(rawValue: previous) ?? .system).rawValue, forKey: iceKey)
        }
        if defaults.string(forKey: getJetKey) == nil { defaults.set("system", forKey: getJetKey) }
    }

    static func selectedTheme(_ raw: String) -> RaidoTheme { RaidoTheme(rawValue: raw) ?? .ice }
    static func appearance(theme: String, ice: String, getJet: String) -> RaidoAppearance {
        RaidoAppearance(rawValue: selectedTheme(theme) == .ice ? ice : getJet) ?? .system
    }
}
