from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"

content = CONTENT.read_text()
start_marker = "struct RosterDetailView: View {"
end_marker = "struct PersonalDutyNoteCard: View {"

if start_marker not in content or end_marker not in content:
    raise RuntimeError("V2.11 prepatch detail markers not found")

prefix, tail = content.split(start_marker, 1)
_, suffix = tail.split(end_marker, 1)

# Normalize RosterDetailView only. Preserve PersonalDutyNoteCard and everything
# after it; V2.5 Calendar state/chrome is restored by v211_post.py.
normalized_detail = '''
    let item: RosterItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DutyBriefingView(item: item, showTechnical: true)
                BriefingSectionTitle("My note")
                PersonalDutyNoteCard(item: item)
            }
            .padding()
        }
        .navigationTitle("Duty")
        .navigationBarTitleDisplayMode(.inline)
    }
}

'''

CONTENT.write_text(prefix + start_marker + normalized_detail + end_marker + suffix)
print("V2.11 detail compatibility prepatch applied")
