from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.11.12 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# V2.11.11 misunderstood the requested note as RAIDO transfer/activity/day notes.
# Remove that Today-only disclosure completely; those RAIDO notes remain available
# in the normal Logistics / Notes sections farther down, unchanged.
start = content.find("struct TodayDutyHeroNotesDisclosure: View {")
end = content.find("struct DutyBriefingView: View {", start)
if start >= 0 and end > start:
    content = content[:start] + content[end:]

# Restore the normal hero in DutyBriefingView so only the personal-note helper
# below it is interactive on Today.
content = replace_once(
    content,
    '''        VStack(alignment: .leading, spacing: showTechnical ? 16 : 14) {
            if showTechnical {
                DutyHeroCard(item: item)
            } else {
                TodayDutyHeroNotesDisclosure(item: item)
            }
''',
    '''        VStack(alignment: .leading, spacing: showTechnical ? 16 : 14) {
            DutyHeroCard(item: item)
''',
    "restore DutyHeroCard",
)

# Reuse the exact same PersonalDutyNoteCard and therefore the exact same
# RAIDORoster.PersonalNote.<duty-id> storage used on the Roster/Duty screen.
# It stays collapsed by default so Today remains operationally clean.
personal_disclosure = r'''
struct TodayPersonalNoteDisclosure: View {
    let item: RosterItem
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                    Text("My note")
                        .fontWeight(.semibold)
                    Spacer(minLength: 8)
                    Text(isExpanded ? "Hide" : "View")
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide my note" : "Show my note")

            if isExpanded {
                PersonalDutyNoteCard(item: item)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .sensoryFeedback(.selection, trigger: isExpanded)
    }
}

'''

if "struct TodayPersonalNoteDisclosure: View" not in content:
    content = replace_once(
        content,
        "struct DutyBriefingView: View {\n",
        personal_disclosure + "struct DutyBriefingView: View {\n",
        "Today personal note disclosure component",
    )

# Place it immediately under the main flight/duty card on Today only. Duty Detail
# already has the full My note section at the bottom, so showTechnical stays unchanged.
content = replace_once(
    content,
    '''        VStack(alignment: .leading, spacing: showTechnical ? 16 : 14) {
            DutyHeroCard(item: item)

            if item.isOperationalDuty, !item.operationalActivities.isEmpty {
''',
    '''        VStack(alignment: .leading, spacing: showTechnical ? 16 : 14) {
            DutyHeroCard(item: item)

            if !showTechnical {
                TodayPersonalNoteDisclosure(item: item)
            }

            if item.isOperationalDuty, !item.operationalActivities.isEmpty {
''',
    "My note under Today hero",
)

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.11.11")',
    'LabeledContent("RAIDO Roster", value: "2.11.12")',
    1,
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 24;", "CURRENT_PROJECT_VERSION = 25;")
pbx = pbx.replace("MARKETING_VERSION = 2.11.11;", "MARKETING_VERSION = 2.11.12;")
PBX.write_text(pbx)

print("V2.11.12 Today uses shared personal My note editor")
