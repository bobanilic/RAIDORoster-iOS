from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.14.1 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# Persist one global display preference. Core Location remains in metres/second;
# conversion happens only at presentation time.
if '@AppStorage("RAIDORoster.GroundSpeedUnit") private var groundSpeedUnit = "kt"' not in content:
    content = replace_once(
        content,
        '''    @Environment(\\.scenePhase) private var scenePhase
    @StateObject private var gps = TodayLiveFlightLocationManager()
''',
        '''    @Environment(\\.scenePhase) private var scenePhase
    @AppStorage("RAIDORoster.GroundSpeedUnit") private var groundSpeedUnit = "kt"
    @StateObject private var gps = TodayLiveFlightLocationManager()
''',
        "Today map speed-unit preference",
    )

content = replace_once(
    content,
    '''    private var speedText: String {
        guard let speed = gps.location?.speed, speed >= 0 else { return "— kt" }
        return "\\(Int((speed * 1.94384).rounded())) kt"
    }
''',
    '''    private var speedText: String {
        guard let speed = gps.location?.speed, speed >= 0 else {
            switch groundSpeedUnit {
            case "kmh": return "— km/h"
            case "mph": return "— mph"
            default: return "— kt"
            }
        }

        switch groundSpeedUnit {
        case "kmh":
            return "\\(Int((speed * 3.6).rounded())) km/h"
        case "mph":
            return "\\(Int((speed * 2.23694).rounded())) mph"
        default:
            return "\\(Int((speed * 1.94384).rounded())) kt"
        }
    }
''',
    "Live GPS speed conversion",
)

content = replace_once(
    content,
    '''                HStack(spacing: 0) {
                    liveMetric("Altitude", altitudeText)
                    Divider().frame(height: 28)
                    liveMetric("Ground speed", speedText)
                    Divider().frame(height: 28)
                    liveMetric("Track", courseText)
                }
''',
    '''                HStack(spacing: 0) {
                    liveMetric("Altitude", altitudeText)
                    Divider().frame(height: 28)

                    Menu {
                        Button {
                            groundSpeedUnit = "kt"
                        } label: {
                            HStack {
                                Text("Knots (kt)")
                                if groundSpeedUnit == "kt" {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }

                        Button {
                            groundSpeedUnit = "kmh"
                        } label: {
                            HStack {
                                Text("Kilometres/hour (km/h)")
                                if groundSpeedUnit == "kmh" {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }

                        Button {
                            groundSpeedUnit = "mph"
                        } label: {
                            HStack {
                                Text("Miles/hour (mph)")
                                if groundSpeedUnit == "mph" {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    } label: {
                        liveMetric("Ground speed", speedText)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ground speed unit")

                    Divider().frame(height: 28)
                    liveMetric("Track", courseText)
                }
''',
    "Ground-speed tap menu",
)

# Add the same preference to Settings. The map menu and Settings edit the same
# AppStorage key, so either entry point updates the other immediately.
settings_tail = content.split("struct SettingsView: View {", 1)[1] if "struct SettingsView: View {" in content else ""
if '@AppStorage("RAIDORoster.GroundSpeedUnit") private var groundSpeedUnit = "kt"' not in settings_tail:
    content = replace_once(
        content,
        '''struct SettingsView: View {
    @AppStorage("RAIDORoster.Appearance") private var appAppearance = "system"
''',
        '''struct SettingsView: View {
    @AppStorage("RAIDORoster.Appearance") private var appAppearance = "system"
    @AppStorage("RAIDORoster.GroundSpeedUnit") private var groundSpeedUnit = "kt"
''',
        "Settings speed-unit preference",
    )

units_section = '''                Section("Units") {
                    Picker("Ground speed", selection: $groundSpeedUnit) {
                        Text("Knots (kt)").tag("kt")
                        Text("Kilometres/hour (km/h)").tag("kmh")
                        Text("Miles/hour (mph)").tag("mph")
                    }

                    Text("Used by Today → Live GPS. Knots remain the aviation default.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

'''
if 'Section("Units")' not in content:
    content = replace_once(
        content,
        '                Section("Appearance") {\n',
        units_section + '                Section("Appearance") {\n',
        "Settings Units section",
    )

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.14")',
    'LabeledContent("RAIDO Roster", value: "2.14.1")',
    1,
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 31;", "CURRENT_PROJECT_VERSION = 32;")
pbx = pbx.replace("MARKETING_VERSION = 2.14;", "MARKETING_VERSION = 2.14.1;")
PBX.write_text(pbx)

print("V2.14.1 ground-speed unit preference applied")
