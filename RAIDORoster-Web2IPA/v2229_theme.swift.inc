// V2.29: two native themes, with independent appearance preferences.
private struct RaidoThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = RaidoTheme.ice
}

extension EnvironmentValues {
    var raidoTheme: RaidoTheme {
        get { self[RaidoThemeEnvironmentKey.self] }
        set { self[RaidoThemeEnvironmentKey.self] = newValue }
    }
}

enum MidnightTheme {
    // Build new dynamic colors after theme changes rather than relying on
    // UIKit's cached resolution of a previously-created color in the same mode.
    static var isGetJet: Bool {
        RaidoAppearancePreferences.selectedTheme(UserDefaults.standard.string(forKey: RaidoAppearancePreferences.themeKey) ?? "ice") == .getJet
    }
    static func adaptive(_ dark: UInt32, _ light: UInt32) -> UIColor {
        UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
    private static func palette(_ iceDark: UInt32, _ iceLight: UInt32, _ jetDark: UInt32, _ jetLight: UInt32) -> UIColor {
        isGetJet ? adaptive(jetDark, jetLight) : adaptive(iceDark, iceLight)
    }
    static var accent: Color { Color(uiColor: palette(0x7DC3E4, 0x1F6C94, 0x99CFC5, 0x00656A)) }
    static var backgroundUI: UIColor { palette(0x0D1A25, 0xEEF4F7, 0x182320, 0xF7F5F0) }
    static var surfaceUI: UIColor { palette(0x142C3B, 0xFFFFFF, 0x25332F, 0xFFFEFA) }
    static var elevatedUI: UIColor { palette(0x1B3B4B, 0xE2EEF4, 0x303D36, 0xEEEAE2) }
    static var background: Color { Color(uiColor: backgroundUI) }
    static var surface: Color { Color(uiColor: surfaceUI) }
    static var elevated: Color { Color(uiColor: elevatedUI) }
    static var border: Color { Color(uiColor: palette(0x294452, 0xD8E4EB, 0x49584F, 0xCFD7CF)) }
    static var ink: Color { Color(uiColor: palette(0xE6F0F5, 0x172E3E, 0xF1EEE6, 0x203B39)) }
    static var warning: Color { Color(uiColor: palette(0x392C20, 0xFFF0DA, 0x3B3026, 0xF8EBDD)) }
    static var warningInk: Color { Color(uiColor: palette(0xE9BD85, 0x885519, 0xF39354, 0xA84C1B)) }
    static var highlight: Color { isGetJet ? Color(uiColor: adaptive(0xF39354, 0xCA5B22)) : accent }
    static var selectionInk: Color { isGetJet ? Color(uiColor: adaptive(0x182320, 0xFFFEFA)) : .white }
    static var mapSea: Color { Color(uiColor: palette(0x163747, 0xD8EAF1, 0x20352F, 0xE4EBE6)) }
    static var mapLand: Color { Color(uiColor: palette(0x213943, 0xF4F5EB, 0x36453A, 0xF1F0E5)) }
    static var mapBorder: Color { Color(uiColor: palette(0x385361, 0xBDCED2, 0x596B5E, 0xC1CEC1)) }
    static var offInk: Color { Color(uiColor: palette(0x98AFBC, 0x718A9B, 0xACB9B1, 0x697871)) }
    static var standbyInk: Color { isGetJet ? warningInk : Color(uiColor: adaptive(0xDBB477, 0xAD783A)) }

    @MainActor static func navigationAppearance() -> UINavigationBarAppearance {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = backgroundUI
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor(ink)]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor(ink)]
        return nav
    }
    @MainActor static func tabAppearance() -> UITabBarAppearance {
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = backgroundUI
        tab.shadowColor = UIColor(border)
        return tab
    }
    @MainActor static func configure() {
        let nav = navigationAppearance(), tab = tabAppearance()
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UISegmentedControl.appearance().selectedSegmentTintColor = isGetJet ? surfaceUI : UIColor(accent)
        UISegmentedControl.appearance().backgroundColor = elevatedUI
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: isGetJet ? UIColor(accent) : UIColor.white], for: .selected)
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: UIColor(ink)], for: .normal)
    }
}

// Refresh existing UIKit chrome too; do not rebuild ContentView or its models.
struct RaidoChromeRefresh: UIViewRepresentable {
    let theme: RaidoTheme
    let appearance: RaidoAppearance
    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }
    func updateUIView(_ view: UIView, context: Context) {
        MidnightTheme.configure()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            updateChrome(window)
        }
    }
    private func updateChrome(_ view: UIView) {
        if let nav = view as? UINavigationBar {
            let value = MidnightTheme.navigationAppearance()
            nav.standardAppearance = value; nav.scrollEdgeAppearance = value; nav.compactAppearance = value
            nav.tintColor = UIColor(MidnightTheme.accent)
        } else if let tab = view as? UITabBar {
            let value = MidnightTheme.tabAppearance()
            tab.standardAppearance = value; tab.scrollEdgeAppearance = value
            tab.tintColor = UIColor(MidnightTheme.accent)
        } else if let segment = view as? UISegmentedControl {
            segment.selectedSegmentTintColor = theme == .getJet ? MidnightTheme.surfaceUI : UIColor(MidnightTheme.accent)
            segment.backgroundColor = MidnightTheme.elevatedUI
            segment.setTitleTextAttributes([.foregroundColor: theme == .getJet ? UIColor(MidnightTheme.accent) : UIColor.white], for: .selected)
            segment.setTitleTextAttributes([.foregroundColor: UIColor(MidnightTheme.ink)], for: .normal)
        }
        for child in view.subviews { updateChrome(child) }
    }
}

private struct RaidoCanvas: ViewModifier {
    @Environment(\.raidoTheme) private var theme
    func body(content: Content) -> some View {
        let _ = theme
        return content.scrollContentBackground(.hidden)
            .background(MidnightTheme.background.ignoresSafeArea())
            .toolbarBackground(MidnightTheme.background, for: .navigationBar, .tabBar)
            .toolbarBackground(.visible, for: .navigationBar, .tabBar)
            .tint(MidnightTheme.accent)
    }
}

// Open gutters: short round-ended separators, no enclosing cell boxes.
private struct GetJetCalendarDividers: View {
    let rows: Int
    var body: some View {
        Canvas { context, size in
            guard rows > 0 else { return }
            let width = size.width / 7, height = size.height / CGFloat(rows)
            var path = Path()
            for row in 0..<rows {
                for col in 0..<7 {
                    if col < 6 {
                        let x = CGFloat(col + 1) * width
                        path.move(to: CGPoint(x: x, y: CGFloat(row) * height + 12))
                        path.addLine(to: CGPoint(x: x, y: CGFloat(row + 1) * height - 12))
                    }
                    if row < rows - 1 {
                        let y = CGFloat(row + 1) * height
                        path.move(to: CGPoint(x: CGFloat(col) * width + 7, y: y))
                        path.addLine(to: CGPoint(x: CGFloat(col + 1) * width - 7, y: y))
                    }
                }
            }
            context.stroke(path, with: .color(MidnightTheme.border), style: StrokeStyle(lineWidth: 0.65, lineCap: .round))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct GetJetSectorCard: View {
    let sector: RosterActivity
    let crewAction: () -> Void
    private var codes: [String] { TodayGlobalAirportIndex.routeCodes(sector.route) }
    var body: some View {
        VStack(spacing: 17) {
            HStack {
                Text(sector.code).font(.caption.weight(.semibold)).tracking(0.5).foregroundStyle(MidnightTheme.accent)
                Spacer(minLength: 5)
                Text([sector.aircraftReg, sector.aircraftType].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(alignment: .center) {
                airport(codes.first ?? "—", alignment: .leading)
                Spacer(minLength: 6)
                VStack(spacing: 5) {
                    Image(systemName: "airplane").font(.system(size: 20, weight: .regular)).foregroundStyle(MidnightTheme.accent)
                    if let start = parseUTCStamp(sector.startUTC), let end = parseUTCStamp(sector.endUTC), end > start {
                        Text(durationText(end.timeIntervalSince(start))).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                airport(codes.last ?? "—", alignment: .trailing)
            }
            HStack(alignment: .firstTextBaseline) {
                time(sector.localStartTime, label: "DEP")
                Spacer(minLength: 4)
                Text("Local times").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                time(sector.localEndTime, label: "ARR")
            }
            Rectangle().fill(MidnightTheme.border.opacity(0.45)).frame(height: 0.5)
            HStack {
                Text("Flight sector").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if !sector.crew.isEmpty {
                    Button(action: crewAction) { Label("Crew", systemImage: "person.2").font(.caption) }
                        .buttonStyle(.plain).frame(minHeight: 32)
                        .accessibilityLabel("View crew for " + sector.code)
                }
            }
        }.padding(19).midnightCard(radius: 24)
    }
    private func airport(_ code: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(code).font(.system(size: 30, weight: .semibold)).tracking(-0.8)
            Text(IceAirportClock.city(for: code)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
    }
    private func time(_ value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value.isEmpty ? "—" : value).font(.system(size: 18, weight: .medium)).monospacedDigit()
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}
