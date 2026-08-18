from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
APP = ROOT / "RAIDORoster" / "RAIDORosterApp.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.11.7 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# Duty Detail should prioritize the duty itself. Roster changes are secondary
# context: collapsed by default, with exact old -> new values one tap away.
content = replace_once(
    content,
    '''                if let change = store.change(for: item.dateISO) {
                    BriefingSectionTitle("Roster change")
                    RosterChangeCard(change: change)
                }
''',
    '''                if let change = store.change(for: item.dateISO) {
                    RosterChangeDisclosure(change: change)
                }
''',
    "collapsed roster change in Duty Detail",
)

change_disclosure = r'''
struct RosterChangeDisclosure: View {
    let change: RosterDayChange
    @State private var expanded = false

    private var visibleFields: [RosterChangeField] {
        change.fields.filter { field in
            !(field.oldValue == "—" && field.newValue == "Details changed")
        }
    }

    var body: some View {
        if !visibleFields.isEmpty {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        expanded.toggle()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)

                        Text("\(visibleFields.count) roster change\(visibleFields.count == 1 ? "" : "s")")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        Spacer(minLength: 8)

                        Text(expanded ? "Hide" : "View")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)

                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    Divider().padding(.horizontal, 14)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(visibleFields.enumerated()), id: \.offset) { index, field in
                            if index > 0 { Divider() }

                            VStack(alignment: .leading, spacing: 6) {
                                Text(field.label.uppercased())
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)

                                HStack(alignment: .top, spacing: 8) {
                                    Text(field.oldValue)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .strikethrough(field.oldValue != "—")
                                        .fixedSize(horizontal: false, vertical: true)

                                    Image(systemName: "arrow.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 3)

                                    Text(field.newValue)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)

                                    Spacer(minLength: 0)
                                }
                            }
                            .padding(.vertical, 11)
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }
            .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
            .sensoryFeedback(.selection, trigger: expanded)
        }
    }
}

'''
if "struct RosterChangeDisclosure: View" not in content:
    content = replace_once(
        content,
        "struct RosterChangeCard: View {\n",
        change_disclosure + "struct RosterChangeCard: View {\n",
        "roster change disclosure component",
    )

# Appearance is a local presentation preference only; it does not affect RAIDO,
# cached data, Calendar, reminders, or parsing.
if '@AppStorage("RAIDORoster.Appearance") private var appAppearance = "system"' not in content:
    content = replace_once(
        content,
        "struct SettingsView: View {\n",
        '''struct SettingsView: View {
    @AppStorage("RAIDORoster.Appearance") private var appAppearance = "system"
''',
        "Settings appearance state",
    )

appearance_section = '''                Section("Appearance") {
                    Picker("Theme", selection: $appAppearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)

                    Text("System follows the iPhone appearance automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

'''
if 'Section("Appearance")' not in content:
    content = replace_once(
        content,
        '                Section("Version") {\n',
        appearance_section + '                Section("Version") {\n',
        "Appearance Settings section",
    )

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.11.6")',
    'LabeledContent("RAIDO Roster", value: "2.11.7")',
    1,
)
CONTENT.write_text(content)

app = APP.read_text()
app = replace_once(
    app,
    '''@main
struct RAIDORosterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
''',
    '''@main
struct RAIDORosterApp: App {
    @AppStorage("RAIDORoster.Appearance") private var appAppearance = "system"

    private var preferredScheme: ColorScheme? {
        switch appAppearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(preferredScheme)
        }
    }
}
''',
    "app-wide appearance preference",
)
APP.write_text(app)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 19;", "CURRENT_PROJECT_VERSION = 20;")
pbx = pbx.replace("MARKETING_VERSION = 2.11.6;", "MARKETING_VERSION = 2.11.7;")
PBX.write_text(pbx)

print("V2.11.7 compact changes + appearance applied")
