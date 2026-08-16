from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "RAIDORoster"
CONTENT = SRC / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.9 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

if "import UIKit" not in content:
    content = content.replace("import SwiftUI\n", "import SwiftUI\nimport UIKit\n", 1)

# Fix the previous Airbus-only display assumption while keeping RAIDO's type
# field authoritative.
content = replace_once(
    content,
    '''        if !aircraftType.isEmpty {
            pieces.append(aircraftType.hasPrefix("A") ? aircraftType : "A\\(aircraftType)")
        }
''',
    '''        let typeLabel = aircraftTypeLabel(aircraftType)
        if !typeLabel.isEmpty { pieces.append(typeLabel) }
''',
    "aircraft type display"
)

operator_support = r'''
enum DutyOperator: String, Equatable {
    case getjet = "GETJET"
    case airhub = "AIRHUB"
    case verify = "VERIFY"

    var systemImage: String {
        switch self {
        case .getjet, .airhub: return "airplane.circle.fill"
        case .verify: return "questionmark.circle.fill"
        }
    }
}

struct OperatorResolver {
    static func resolve(registration: String) -> DutyOperator {
        let upper = registration.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = upper
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")

        if compact == "9HGTS" || compact == "GTS" { return .airhub }
        if compact.hasPrefix("LY") { return .getjet }
        return .verify
    }
}

private func aircraftTypeLabel(_ value: String) -> String {
    let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !raw.isEmpty else { return "" }
    let compact = raw.replacingOccurrences(of: " ", with: "")

    if compact.hasPrefix("A") || compact.hasPrefix("B") { return raw }
    if ["318", "319", "320", "321", "330", "340", "350", "380"].contains(compact) {
        return "A" + compact
    }
    if compact.hasPrefix("73") || compact.hasPrefix("7M") {
        return "B" + compact
    }
    return raw
}

struct OperatorBadge: View {
    let value: DutyOperator

    var body: some View {
        Label(value.rawValue, systemImage: value.systemImage)
            .font(.caption.bold())
            .foregroundStyle(value == .verify ? Color.orange : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                (value == .verify ? Color.orange : Color.secondary).opacity(0.11),
                in: Capsule()
            )
    }
}

'''
content = replace_once(
    content,
    '''struct AircraftCard: View {
''',
    operator_support + '''struct AircraftCard: View {
''',
    "operator resolver"
)

old_aircraft_card = '''struct AircraftCard: View {
    let item: RosterItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(item.aircraft) { aircraft in
                HStack(spacing: 12) {
                    Image(systemName: "airplane.circle.fill").font(.title2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(aircraft.aircraftDisplay.isEmpty ? "Aircraft" : aircraft.aircraftDisplay)
                            .font(.headline)
                        if !aircraft.aircraftPhone.isEmpty {
                            Text("A/C phone \\(aircraft.aircraftPhone)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(15)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }
}
'''
new_aircraft_card = '''struct AircraftCard: View {
    let item: RosterItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(item.aircraft) { aircraft in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "airplane.circle.fill").font(.title2)
                    VStack(alignment: .leading, spacing: 7) {
                        OperatorBadge(value: OperatorResolver.resolve(registration: aircraft.aircraftReg))

                        let details = [
                            aircraftTypeLabel(aircraft.aircraftType),
                            aircraft.aircraftReg,
                            aircraft.aircraftVersion
                        ].filter { !$0.isEmpty }

                        Text(details.isEmpty ? "Aircraft" : details.joined(separator: " • "))
                            .font(.headline)

                        if !aircraft.aircraftPhone.isEmpty {
                            Text("A/C phone \\(aircraft.aircraftPhone)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(15)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }
}
'''
content = replace_once(content, old_aircraft_card, new_aircraft_card, "operator aircraft card")

crew_control_support = r'''
enum CompanyContacts {
    static let crewControlDisplay = "+370 688 38250"
    static let crewControlPhone = "+37068838250"
    static let crewControlWhatsApp = "37068838250"
    static let crewControlEmail = "crewcontrol@getjet.aero"
}

enum CrewControlTemplate: String, CaseIterable, Identifiable {
    case roster = "Roster clarification"
    case pickup = "Pickup / transport"
    case hotel = "Hotel issue"
    case standby = "Standby / reserve"
    case operational = "Operational issue"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .roster: return "calendar.badge.questionmark"
        case .pickup: return "car.fill"
        case .hotel: return "bed.double.fill"
        case .standby: return "clock.badge.questionmark"
        case .operational: return "exclamationmark.triangle.fill"
        }
    }
}

struct CrewControlSheet: View {
    let item: RosterItem?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("24/7 Crew Control")
                            .font(.title3.bold())
                        Text(CompanyContacts.crewControlDisplay)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button {
                            openWhatsApp(message: nil)
                        } label: {
                            Label("WhatsApp", systemImage: "message.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            openURL("tel:\\(CompanyContacts.crewControlPhone)")
                        } label: {
                            Image(systemName: "phone.fill").frame(minWidth: 28)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Call Crew Control")

                        Button {
                            openURL("mailto:\\(CompanyContacts.crewControlEmail)")
                        } label: {
                            Image(systemName: "envelope.fill").frame(minWidth: 28)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Email Crew Control")
                    }

                    if let item {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("CURRENT / NEXT DUTY")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)

                            if let aircraft = item.aircraft.first {
                                HStack(spacing: 8) {
                                    OperatorBadge(value: OperatorResolver.resolve(registration: aircraft.aircraftReg))
                                    let details = [aircraftTypeLabel(aircraft.aircraftType), aircraft.aircraftReg]
                                        .filter { !$0.isEmpty }
                                    if !details.isEmpty {
                                        Text(details.joined(separator: " • "))
                                            .font(.subheadline.weight(.semibold))
                                    }
                                }
                            }

                            Text(item.displayTitle).font(.headline)
                            if !item.route.isEmpty {
                                Label(item.route, systemImage: "airplane").font(.subheadline)
                            }
                            let timing = [
                                item.dateText,
                                item.reportLocal.isEmpty ? "" : "CI \\(item.reportLocal)"
                            ].filter { !$0.isEmpty }
                            if !timing.isEmpty {
                                Text(timing.joined(separator: " • "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quick WhatsApp").font(.headline)

                        ForEach(CrewControlTemplate.allCases) { template in
                            Button {
                                openWhatsApp(message: message(for: template))
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: template.systemImage).frame(width: 24)
                                    Text(template.rawValue).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)

                            if template.id != CrewControlTemplate.allCases.last?.id {
                                Divider().padding(.leading, 36)
                            }
                        }
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))

                    Text("Quick messages open Crew Control in WhatsApp with duty context pre-filled. Review and send the message in WhatsApp.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Crew Control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func message(for template: CrewControlTemplate) -> String {
        let context = dutyContext
        switch template {
        case .roster:
            return "Hi Crew Control,\\n\\nRegarding \\(context):\\n\\nCould you please clarify the roster details?"
        case .pickup:
            if let pickup = item?.pickups.first, !pickup.isEmpty {
                return "Hi Crew Control,\\n\\nRegarding \\(context), my roster shows pickup: \\(pickup).\\n\\nCould you please confirm the transport?"
            }
            return "Hi Crew Control,\\n\\nRegarding \\(context):\\n\\nCould you please assist with the pickup / transport details?"
        case .hotel:
            if let hotel = item?.hotelAssignments.first {
                let name = hotel.hotelName.isEmpty ? hotel.title : hotel.hotelName
                if !name.isEmpty {
                    return "Hi Crew Control,\\n\\nRegarding \\(context), my roster shows \\(name).\\n\\nCould you please assist with the hotel arrangement?"
                }
            }
            return "Hi Crew Control,\\n\\nRegarding \\(context):\\n\\nCould you please assist with the hotel arrangement?"
        case .standby:
            return "Hi Crew Control,\\n\\nRegarding \\(context):\\n\\nCould you please clarify my standby / reserve assignment?"
        case .operational:
            return "Hi Crew Control,\\n\\nRegarding \\(context):\\n\\nI need assistance with an operational issue."
        }
    }

    private var dutyContext: String {
        guard let item else { return "my current roster" }
        var parts: [String] = []
        if !item.dateText.isEmpty { parts.append(item.dateText) }
        if !item.displayTitle.isEmpty { parts.append(item.displayTitle) }
        if !item.route.isEmpty { parts.append(item.route) }
        if !item.reportLocal.isEmpty { parts.append("CI \\(item.reportLocal)") }
        if let aircraft = item.aircraft.first {
            let op = OperatorResolver.resolve(registration: aircraft.aircraftReg)
            if op != .verify { parts.append(op.rawValue) }
            let aircraftText = [aircraftTypeLabel(aircraft.aircraftType), aircraft.aircraftReg]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !aircraftText.isEmpty { parts.append(aircraftText) }
        }
        return parts.isEmpty ? "my current roster" : parts.joined(separator: " • ")
    }

    private func openWhatsApp(message: String?) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "wa.me"
        components.path = "/" + CompanyContacts.crewControlWhatsApp
        if let message, !message.isEmpty {
            components.queryItems = [URLQueryItem(name: "text", value: message)]
        }
        if let url = components.url { UIApplication.shared.open(url) }
    }

    private func openURL(_ value: String) {
        guard let url = URL(string: value) else { return }
        UIApplication.shared.open(url)
    }
}

'''
content = replace_once(
    content,
    '''struct SettingsView: View {
''',
    crew_control_support + '''struct SettingsView: View {
''',
    "Crew Control sheet"
)

# Today already has the Calendar toolbar from V2.5, so integrate Crew Control
# into that toolbar rather than adding competing navigation chrome.
content = replace_once(
    content,
    '''struct TodayView: View {
    @ObservedObject var store: RosterStore
    let openPortal: () -> Void
    @StateObject private var calendarExporter = CalendarExporter()
''',
    '''struct TodayView: View {
    @ObservedObject var store: RosterStore
    let openPortal: () -> Void
    @StateObject private var calendarExporter = CalendarExporter()
    @State private var showCrewControl = false
''',
    "Today Crew Control state"
)

old_today_toolbar = '''            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let item = store.todayItems.first {
                        Button { calendarExporter.export(item) } label: {
                            Image(systemName: "calendar.badge.plus")
                        }
                        .disabled(calendarExporter.isWorking)
                        .accessibilityLabel("Sync today's duty to Calendar")
                    }
                }
            }
'''
new_today_toolbar = '''            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let item = store.todayItems.first {
                        Button { calendarExporter.export(item) } label: {
                            Image(systemName: "calendar.badge.plus")
                        }
                        .disabled(calendarExporter.isWorking)
                        .accessibilityLabel("Sync today's duty to Calendar")
                    }

                    Button { showCrewControl = true } label: {
                        Image(systemName: "message.fill")
                    }
                    .accessibilityLabel("Crew Control")
                }
            }
'''
content = replace_once(content, old_today_toolbar, new_today_toolbar, "Today Crew Control toolbar")

content = replace_once(
    content,
    '''            } message: {
                Text(calendarExporter.message ?? "")
            }
        }
    }

    private var emptyToday''',
    '''            } message: {
                Text(calendarExporter.message ?? "")
            }
            .sheet(isPresented: $showCrewControl) {
                CrewControlSheet(item: store.todayItems.first ?? store.nextDuty)
            }
        }
    }

    private var emptyToday''',
    "Today Crew Control sheet"
)

# Settings is the permanent reference point; Today remains the fast path.
content = replace_once(
    content,
    '''    @State private var confirmClear = false
''',
    '''    @State private var confirmClear = false
    @State private var showCrewControl = false
''',
    "Settings Crew Control state"
)

help_section = r'''
                Section("Help & Contacts") {
                    Button {
                        showCrewControl = true
                    } label: {
                        HStack {
                            Label("Crew Control", systemImage: "headphones")
                            Spacer()
                            Text("24/7")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("WhatsApp, phone and email access for urgent short-term roster and operational questions.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

'''
content = replace_once(
    content,
    '''                Section("Diagnostics") {
''',
    help_section + '''                Section("Diagnostics") {
''',
    "Help and Contacts section"
)

content = replace_once(
    content,
    '''            .confirmationDialog("Clear the saved offline roster?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Cache", role: .destructive) { store.clearCache() }
            }
''',
    '''            .confirmationDialog("Clear the saved offline roster?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Cache", role: .destructive) { store.clearCache() }
            }
            .sheet(isPresented: $showCrewControl) {
                CrewControlSheet(item: store.todayItems.first ?? store.nextDuty)
            }
''',
    "Settings Crew Control sheet"
)

content = content.replace('LabeledContent("RAIDO Roster", value: "2.8")', 'LabeledContent("RAIDO Roster", value: "2.9")', 1)

CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 8;", "CURRENT_PROJECT_VERSION = 9;")
pbx = pbx.replace("MARKETING_VERSION = 2.8;", "MARKETING_VERSION = 2.9;")
PBX.write_text(pbx)

print("V2.9 patch applied")
