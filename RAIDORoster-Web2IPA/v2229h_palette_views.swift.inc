// V2.29.7 coordinated colour palettes.
private struct RaidoPaletteEnvironmentKey: EnvironmentKey {
    static let defaultValue = RaidoPalette.iceBlue
}
extension EnvironmentValues {
    var raidoPalette: RaidoPalette {
        get { self[RaidoPaletteEnvironmentKey.self] }
        set { self[RaidoPaletteEnvironmentKey.self] = newValue }
    }
}

private struct RaidoPalettePicker: View {
    @Environment(\.raidoPalette) private var currentPalette
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: String
    let theme: RaidoTheme
    private var selected: RaidoPalette { RaidoPalette(rawValue: selection) ?? .defaultPalette(for: theme) }
    var body: some View {
        let _ = currentPalette
        List {
            Section {
                ForEach(RaidoPalette.allCases) { palette in
                    Button {
                        selection = palette.rawValue
                    } label: {
                        HStack(spacing: 14) {
                            preview(palette).frame(width: 80, height: 58)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(palette.title).font(.subheadline.weight(.semibold)).foregroundStyle(MidnightTheme.ink)
                                Text(palette.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 2)
                            if palette == selected {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(MidnightTheme.accent)
                            }
                        }.padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("palette-option-" + palette.rawValue)
                        .accessibilityLabel(palette.title + ". " + palette.subtitle)
                        .accessibilityValue(palette == selected ? "Selected" : "Not selected")
                        .listRowBackground(MidnightTheme.surface)
                }
            } footer: {
                Text("Saved for " + theme.title + ". Your light, dark or system setting stays the same.")
            }
        }.listStyle(.insetGrouped).midnightCanvas().navigationTitle("Color palette")
    }
    private func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    private func preview(_ palette: RaidoPalette) -> some View {
        let colors = palette.colors(dark: colorScheme == .dark)
        return HStack(spacing: 6) {
            Text("12").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color(colors.selectionInk)).frame(width: 27, height: 27)
                .background(color(colors.highlight), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(color(colors.accent)).frame(width: 22, height: 3)
                Capsule().fill(color(colors.offInk)).frame(width: 16, height: 2)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(color(colors.background), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(color(colors.border), lineWidth: 0.8))
            .accessibilityHidden(true)
    }
}
