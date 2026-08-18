from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.11.11 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# Today keeps the duty summary clean by default, but notes are available exactly
# where the crew member is already looking. The hero card and the slim disclosure
# row both toggle the same inline notes block. Duty Detail remains unchanged.
today_notes = r'''
struct TodayDutyHeroNotesDisclosure: View {
    let item: RosterItem
    @State private var isExpanded = false

    private var hasNotes: Bool {
        !item.transferNotes.isEmpty || !item.activityNotes.isEmpty || !item.dayNotes.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: hasNotes ? 7 : 0) {
            if hasNotes {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    DutyHeroCard(item: item)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Hide duty notes" : "Show duty notes")

                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "note.text")
                        Text("Notes & transfer")
                            .fontWeight(.semibold)
                        Spacer(minLength: 8)
                        Text(isExpanded ? "Hide" : "View")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(item.transferNotes, id: \.self) { note in
                            NoteBlock(title: "Transfer note", icon: "car.side.fill", text: note)
                        }
                        ForEach(item.activityNotes, id: \.self) { note in
                            NoteBlock(title: "Activity note", icon: "note.text", text: note)
                        }
                        ForEach(item.dayNotes, id: \.self) { note in
                            NoteBlock(title: "Day note", icon: "calendar.badge.exclamationmark", text: note)
                        }
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else {
                DutyHeroCard(item: item)
            }
        }
        .sensoryFeedback(.selection, trigger: isExpanded)
    }
}

'''

if "struct TodayDutyHeroNotesDisclosure: View" not in content:
    content = replace_once(
        content,
        "struct DutyBriefingView: View {\n",
        today_notes + "struct DutyBriefingView: View {\n",
        "Today inline notes component",
    )

content = replace_once(
    content,
    '''        VStack(alignment: .leading, spacing: showTechnical ? 16 : 14) {
            DutyHeroCard(item: item)
''',
    '''        VStack(alignment: .leading, spacing: showTechnical ? 16 : 14) {
            if showTechnical {
                DutyHeroCard(item: item)
            } else {
                TodayDutyHeroNotesDisclosure(item: item)
            }
''',
    "Today hero notes disclosure",
)

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.11.10")',
    'LabeledContent("RAIDO Roster", value: "2.11.11")',
    1,
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 23;", "CURRENT_PROJECT_VERSION = 24;")
pbx = pbx.replace("MARKETING_VERSION = 2.11.10;", "MARKETING_VERSION = 2.11.11;")
PBX.write_text(pbx)

print("V2.11.11 inline Today notes disclosure applied")
