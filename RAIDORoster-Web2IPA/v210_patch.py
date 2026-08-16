from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "RAIDORoster"
CONTENT = SRC / "ContentView.swift"
JS = SRC / "RosterEnhancements.js"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.10 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# -----------------------------------------------------------------------------
# Preserve the crew telephone already present in RAIDO's Crew On Board block.
# The field is optional so V2.9 caches remain decodable after upgrade.
# -----------------------------------------------------------------------------
content = replace_once(
    content,
    '''struct CrewMember: Codable, Equatable, Identifiable {
    let role: String
    let code: String
    let name: String
    let country: String?
''',
    '''struct CrewMember: Codable, Equatable, Identifiable {
    let role: String
    let code: String
    let name: String
    let country: String?
    let phone: String?
''',
    "CrewMember phone"
)

content = replace_once(
    content,
    '''            return CrewMember(
                role: role,
                code: code,
                name: name,
                country: member["country"] as? String
            )
''',
    '''            return CrewMember(
                role: role,
                code: code,
                name: name,
                country: member["country"] as? String,
                phone: member["phone"] as? String
            )
''',
    "native crew phone parser"
)

# -----------------------------------------------------------------------------
# Expandable crew rows. Contact data remains hidden until deliberately opened.
# No separate contacts tab/screen and no contact data is sent to Calendar.
# -----------------------------------------------------------------------------
old_crew_card = '''struct CrewCard: View {
    let item: RosterItem

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(item.crewMembers.enumerated()), id: \.offset) { index, member in
                HStack(spacing: 12) {
                    Text(member.role)
                        .font(.caption.bold())
                        .frame(width: 38)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.name).font(.subheadline.weight(.medium))
                        if !member.code.isEmpty {
                            Text(member.code).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let country = member.country, !country.isEmpty {
                        Text(country)
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.10), in: Capsule())
                            .accessibilityLabel("Phone country \(country)")
                    }
                }
                .padding(.vertical, 9)
                if index < item.crewMembers.count - 1 { Divider().padding(.leading, 50) }
            }
        }
        .padding(.horizontal, 15)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }
}
'''

new_crew_card = '''struct CrewCard: View {
    let item: RosterItem
    @State private var expandedCrewID: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(item.crewMembers.enumerated()), id: \.offset) { index, member in
                VStack(spacing: 0) {
                    Button {
                        guard hasPhone(member) else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            expandedCrewID = expandedCrewID == member.id ? nil : member.id
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(member.role)
                                .font(.caption.bold())
                                .frame(width: 38)
                                .padding(.vertical, 5)
                                .background(Color.secondary.opacity(0.12), in: Capsule())

                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                if !member.code.isEmpty {
                                    Text(member.code)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            if let country = member.country, !country.isEmpty {
                                Text(country)
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.10), in: Capsule())
                                    .accessibilityLabel("Phone country \(country)")
                            }

                            if hasPhone(member) {
                                Image(systemName: expandedCrewID == member.id ? "chevron.up" : "chevron.down")
                                    .font(.caption.bold())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 14)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(hasPhone(member) ? "Shows crew contact options" : "")

                    if expandedCrewID == member.id,
                       let phone = member.phone?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !phone.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Divider()

                            HStack(spacing: 10) {
                                Image(systemName: "phone.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Phone")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(phone)
                                        .font(.subheadline.monospacedDigit().weight(.medium))
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                            }

                            HStack(spacing: 8) {
                                Button {
                                    openCrewWhatsApp(phone)
                                } label: {
                                    Label("WhatsApp", systemImage: "message.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)

                                Button {
                                    callCrew(phone)
                                } label: {
                                    Label("Call", systemImage: "phone.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    UIPasteboard.general.string = phone
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .frame(minWidth: 28)
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Copy crew phone number")
                            }
                        }
                        .padding(.leading, 50)
                        .padding(.bottom, 11)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                if index < item.crewMembers.count - 1 {
                    Divider().padding(.leading, 50)
                }
            }
        }
        .padding(.horizontal, 15)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }

    private func hasPhone(_ member: CrewMember) -> Bool {
        !(member.phone?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func phoneDigits(_ phone: String) -> String {
        phone.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
    }

    private func openCrewWhatsApp(_ phone: String) {
        let digits = phoneDigits(phone)
        guard digits.count >= 8,
              let url = URL(string: "https://wa.me/\(digits)") else { return }
        UIApplication.shared.open(url)
    }

    private func callCrew(_ phone: String) {
        let digits = phoneDigits(phone)
        guard digits.count >= 6,
              let url = URL(string: "tel:+\(digits)") else { return }
        UIApplication.shared.open(url)
    }
}
'''

content = replace_once(content, old_crew_card, new_crew_card, "expandable CrewCard")

content = content.replace('LabeledContent("RAIDO Roster", value: "2.9")', 'LabeledContent("RAIDO Roster", value: "2.10")', 1)
CONTENT.write_text(content)

# -----------------------------------------------------------------------------
# Parser output: V2.7 already reads the phone to derive the compact country
# badge. V2.10 simply keeps that same RAIDO value in the private native cache.
# Diagnostics remain unchanged and continue to expose only crewCount.
# -----------------------------------------------------------------------------
js = JS.read_text()
js = replace_once(
    js,
    '''      return { role: item.role, code: item.code, name, country: phoneCountry(phone) };
''',
    '''      return {
        role: item.role,
        code: item.code,
        name,
        country: phoneCountry(phone),
        phone: compact(phone)
      };
''',
    "crew phone output"
)
JS.write_text(js)

# Version only. UIKit is already imported by V2.9 and no entitlement is needed.
pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 9;", "CURRENT_PROJECT_VERSION = 10;")
pbx = pbx.replace("MARKETING_VERSION = 2.9;", "MARKETING_VERSION = 2.10;")
PBX.write_text(pbx)

print("V2.10 patch applied")
