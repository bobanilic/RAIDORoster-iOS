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
    static let icePaletteKey = "RAIDORoster.Palette.Ice"
    static let getJetPaletteKey = "RAIDORoster.Palette.GetJet"

    static func migrate(_ defaults: UserDefaults) {
        if defaults.string(forKey: themeKey) == nil { defaults.set(RaidoTheme.ice.rawValue, forKey: themeKey) }
        if defaults.string(forKey: iceKey) == nil {
            let previous = defaults.string(forKey: "RAIDORoster.Appearance") ?? "system"
            defaults.set((RaidoAppearance(rawValue: previous) ?? .system).rawValue, forKey: iceKey)
        }
        if defaults.string(forKey: getJetKey) == nil { defaults.set("system", forKey: getJetKey) }
        if defaults.string(forKey: icePaletteKey) == nil { defaults.set(RaidoPalette.iceBlue.rawValue, forKey: icePaletteKey) }
        if defaults.string(forKey: getJetPaletteKey) == nil { defaults.set(RaidoPalette.forestGreen.rawValue, forKey: getJetPaletteKey) }
    }

    static func selectedPalette(theme: RaidoTheme, ice: String, getJet: String) -> RaidoPalette {
        RaidoPalette(rawValue: theme == .ice ? ice : getJet) ?? RaidoPalette.defaultPalette(for: theme)
    }
    static func selectedTheme(_ raw: String) -> RaidoTheme { RaidoTheme(rawValue: raw) ?? .ice }
    static func appearance(theme: String, ice: String, getJet: String) -> RaidoAppearance {
        RaidoAppearance(rawValue: selectedTheme(theme) == .ice ? ice : getJet) ?? .system
    }
}

// Filled actions need a separate colour from the lighter accent used for links.
enum RaidoActionPalette {
    static func fill(theme: RaidoTheme, dark: Bool) -> UInt32 {
        switch theme {
        case .ice: return dark ? 0x265F7A : 0x1F607F
        case .getJet: return dark ? 0x365B4F : 0x00656A
        }
    }
    static let ink: UInt32 = 0xFFFFFF
}

// Coordinated semantic colour roles: layout and mode stay independent.
enum RaidoPalette: String, CaseIterable, Identifiable {
    case iceBlue, forestGreen, midnightChampagne, burgundyRose, espressoBronze
    var id: String { rawValue }
    var title: String {
        switch self {
        case .iceBlue: return "Ice Blue"
        case .forestGreen: return "Forest Green"
        case .midnightChampagne: return "Midnight & Champagne"
        case .burgundyRose: return "Burgundy & Rose"
        case .espressoBronze: return "Espresso & Bronze"
        }
    }
    var subtitle: String {
        switch self {
        case .iceBlue: return "Blue, pearl and soft copper"
        case .forestGreen: return "Forest, warm ivory and copper"
        case .midnightChampagne: return "Deep navy, champagne and cream"
        case .burgundyRose: return "Burgundy, muted rose and ivory"
        case .espressoBronze: return "Espresso, bronze and linen"
        }
    }
    static func defaultPalette(for theme: RaidoTheme) -> RaidoPalette { theme == .ice ? .iceBlue : .forestGreen }
    func colors(dark: Bool) -> RaidoPaletteColors {
        switch self {
        case .iceBlue:
            return dark ?
                RaidoPaletteColors(accent: 0x7DC3E4,
                    background: 0x0D1A25,
                    surface: 0x142C3B,
                    elevated: 0x1B3B4B,
                    border: 0x294452,
                    ink: 0xE6F0F5,
                    warning: 0x392C20,
                    warningInk: 0xE9BD85,
                    highlight: 0xF0AD7B,
                    selectionInk: 0x0D1A25,
                    mapSea: 0x163747,
                    mapLand: 0x213943,
                    mapBorder: 0x385361,
                    offInk: 0x98AFBC,
                    actionFill: 0x265F7A,
                    calendarDivider: 0x223B49,
                    mapLabelInk: 0xAAC3CC) :
                RaidoPaletteColors(accent: 0x1F6C94,
                    background: 0xEEF4F7,
                    surface: 0xFFFFFF,
                    elevated: 0xE2EEF4,
                    border: 0xD8E4EB,
                    ink: 0x172E3E,
                    warning: 0xFFF0DA,
                    warningInk: 0x885519,
                    highlight: 0xB45023,
                    selectionInk: 0xFFFFFF,
                    mapSea: 0xD8EAF1,
                    mapLand: 0xF4F5EB,
                    mapBorder: 0xBDCED2,
                    offInk: 0x536D7C,
                    actionFill: 0x1F607F,
                    calendarDivider: 0xA2B7C4,
                    mapLabelInk: 0x45626C)
        case .forestGreen:
            return dark ?
                RaidoPaletteColors(accent: 0x99CFC5,
                    background: 0x182320,
                    surface: 0x25332F,
                    elevated: 0x303D36,
                    border: 0x49584F,
                    ink: 0xF1EEE6,
                    warning: 0x3B3026,
                    warningInk: 0xF39354,
                    highlight: 0xF39354,
                    selectionInk: 0x182320,
                    mapSea: 0x20352F,
                    mapLand: 0x36453A,
                    mapBorder: 0x596B5E,
                    offInk: 0xACB9B1,
                    actionFill: 0x365B4F,
                    calendarDivider: 0x3C4E43,
                    mapLabelInk: 0xAEBEB2) :
                RaidoPaletteColors(accent: 0x00656A,
                    background: 0xF7F5F0,
                    surface: 0xFFFEFA,
                    elevated: 0xEEEAE2,
                    border: 0xCFD7CF,
                    ink: 0x203B39,
                    warning: 0xF8EBDD,
                    warningInk: 0xA84C1B,
                    highlight: 0xB95020,
                    selectionInk: 0xFFFEFA,
                    mapSea: 0xE4EBE6,
                    mapLand: 0xF1F0E5,
                    mapBorder: 0xC1CEC1,
                    offInk: 0x58695F,
                    actionFill: 0x00656A,
                    calendarDivider: 0xA3B2A6,
                    mapLabelInk: 0x4B675C)
        case .midnightChampagne:
            return dark ?
                RaidoPaletteColors(accent: 0xDCC49A,
                    background: 0x141C29,
                    surface: 0x202C3B,
                    elevated: 0x2B394A,
                    border: 0x435368,
                    ink: 0xF1EEE7,
                    warning: 0x392F23,
                    warningInk: 0xEAC38E,
                    highlight: 0xDCC49A,
                    selectionInk: 0x141C29,
                    mapSea: 0x1D3044,
                    mapLand: 0x334044,
                    mapBorder: 0x526779,
                    offInk: 0xA7B5C4,
                    actionFill: 0x4C566D,
                    calendarDivider: 0x35465B,
                    mapLabelInk: 0xB2C6CF) :
                RaidoPaletteColors(accent: 0x765727,
                    background: 0xF5F2EB,
                    surface: 0xFFFDF7,
                    elevated: 0xEBE5DA,
                    border: 0xC8C4B8,
                    ink: 0x233348,
                    warning: 0xF4E7D4,
                    warningInk: 0x81501F,
                    highlight: 0x765727,
                    selectionInk: 0xFFFDF7,
                    mapSea: 0xDFE6EB,
                    mapLand: 0xEBEADD,
                    mapBorder: 0xB9C7CC,
                    offInk: 0x5D6B7B,
                    actionFill: 0x3B4F70,
                    calendarDivider: 0xA6ABAA,
                    mapLabelInk: 0x475F6B)
        case .burgundyRose:
            return dark ?
                RaidoPaletteColors(accent: 0xE3B5BC,
                    background: 0x291C24,
                    surface: 0x392832,
                    elevated: 0x493540,
                    border: 0x62454F,
                    ink: 0xF4EAEB,
                    warning: 0x403023,
                    warningInk: 0xEBC18D,
                    highlight: 0xE3B5BC,
                    selectionInk: 0x291C24,
                    mapSea: 0x302C3B,
                    mapLand: 0x44383B,
                    mapBorder: 0x68515D,
                    offInk: 0xC4A8B0,
                    actionFill: 0x774351,
                    calendarDivider: 0x51363F,
                    mapLabelInk: 0xCCB4C1) :
                RaidoPaletteColors(accent: 0x8A394E,
                    background: 0xFAF4F2,
                    surface: 0xFFFDFC,
                    elevated: 0xF1E5E6,
                    border: 0xD9C4C8,
                    ink: 0x452831,
                    warning: 0xF7E9D8,
                    warningInk: 0x8D5321,
                    highlight: 0x8A394E,
                    selectionInk: 0xFFFDFC,
                    mapSea: 0xE8E5EA,
                    mapLand: 0xF2EAE1,
                    mapBorder: 0xC9BAC3,
                    offInk: 0x805F69,
                    actionFill: 0x873A4D,
                    calendarDivider: 0xB99CA5,
                    mapLabelInk: 0x705663)
        case .espressoBronze:
            return dark ?
                RaidoPaletteColors(accent: 0xD9B48C,
                    background: 0x251E1A,
                    surface: 0x352B25,
                    elevated: 0x45372F,
                    border: 0x635044,
                    ink: 0xF2E9DF,
                    warning: 0x413025,
                    warningInk: 0xEFC38E,
                    highlight: 0xD9B48C,
                    selectionInk: 0x251E1A,
                    mapSea: 0x29332F,
                    mapLand: 0x414036,
                    mapBorder: 0x655E4B,
                    offInk: 0xC0AEA1,
                    actionFill: 0x72513A,
                    calendarDivider: 0x503D30,
                    mapLabelInk: 0xC2BBA8) :
                RaidoPaletteColors(accent: 0x865329,
                    background: 0xF8F3EC,
                    surface: 0xFFFDF8,
                    elevated: 0xEFE5D9,
                    border: 0xD3C2B1,
                    ink: 0x403127,
                    warning: 0xF6E7D5,
                    warningInk: 0x87501B,
                    highlight: 0x865329,
                    selectionInk: 0xFFFDF8,
                    mapSea: 0xE1E8E3,
                    mapLand: 0xF0E9DD,
                    mapBorder: 0xC1C6B4,
                    offInk: 0x796456,
                    actionFill: 0x80502D,
                    calendarDivider: 0xB29B83,
                    mapLabelInk: 0x666653)
        }
    }
}

struct RaidoPaletteColors {
    let accent: UInt32
    let background: UInt32
    let surface: UInt32
    let elevated: UInt32
    let border: UInt32
    let ink: UInt32
    let warning: UInt32
    let warningInk: UInt32
    let highlight: UInt32
    let selectionInk: UInt32
    let mapSea: UInt32
    let mapLand: UInt32
    let mapBorder: UInt32
    let offInk: UInt32
    let actionFill: UInt32
    let calendarDivider: UInt32
    let mapLabelInk: UInt32
}
