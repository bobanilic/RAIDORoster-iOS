from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.11.13 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# -----------------------------------------------------------------------------
# Roster change notice is secondary context. Keep it visible, but make it a
# slim review strip rather than a full card competing with the calendar.
# Dismissal moves to the Review screen.
# -----------------------------------------------------------------------------
home_start = content.find("struct RosterHomeView: View {")
home_end = content.find("struct RosterMonthCalendarView: View {", home_start)
if home_end < 0:
    home_end = content.find("struct TodayView: View {", home_start)
if home_start < 0 or home_end < 0:
    raise RuntimeError("V2.11.13 RosterHomeView range not found")

home = content[home_start:home_end]
notice_start = home.find("                    if let notice = store.changeNotice {")
notice_end = home.find("                    if !store.hasCache {", notice_start)
if notice_start < 0 or notice_end < 0:
    raise RuntimeError("V2.11.13 change notice range not found")

compact_notice = r'''                    if let notice = store.changeNotice {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 7, height: 7)

                            Text(store.latestChanges.isEmpty
                                 ? notice
                                 : "\(store.latestChanges.count) roster change\(store.latestChanges.count == 1 ? "" : "s")")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            if !store.latestChanges.isEmpty {
                                NavigationLink("Review") {
                                    RosterChangesView(changes: store.latestChanges)
                                }
                                .font(.caption.bold())
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.orange.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                    }

'''
home = home[:notice_start] + compact_notice + home[notice_end:]
content = content[:home_start] + home + content[home_end:]

# Review screen owns the explicit acknowledgement now that the home strip no
# longer carries a separate X button.
changes_start = content.find("struct RosterChangesView: View {")
changes_end = content.find("struct RosterChangeCard: View {", changes_start)
if changes_start < 0 or changes_end < 0:
    raise RuntimeError("V2.11.13 RosterChangesView range not found")
changes_view = content[changes_start:changes_end]
if "@EnvironmentObject private var store: RosterStore" not in changes_view:
    changes_view = changes_view.replace(
        "struct RosterChangesView: View {\n    let changes: [RosterDayChange]\n",
        "struct RosterChangesView: View {\n    @EnvironmentObject private var store: RosterStore\n    let changes: [RosterDayChange]\n",
        1,
    )
changes_view = changes_view.replace(
    '''        .navigationTitle("Roster changes")
        .navigationBarTitleDisplayMode(.inline)
''',
    '''        .navigationTitle("Roster changes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reviewed") {
                    store.dismissChangeNotice()
                }
                .font(.subheadline.weight(.semibold))
            }
        }
''',
    1,
)
content = content[:changes_start] + changes_view + content[changes_end:]

# -----------------------------------------------------------------------------
# Calendar agenda: when a pre-duty pickup exists, surface it before CI and give
# it the only live countdown on the planning card. No extra polling/networking;
# TimelineView derives the countdown locally from the cached timestamp.
# -----------------------------------------------------------------------------
agenda_start = content.find("struct RosterCalendarAgendaCard: View {")
agenda_end = content.find("private func calendarPrimaryLabel", agenda_start)
if agenda_start < 0 or agenda_end < 0:
    raise RuntimeError("V2.11.13 calendar agenda range not found")
agenda = content[agenda_start:agenda_end]
old_details = '''                let details = [
                    item.reportLocal.isEmpty ? "" : "CI \\(item.reportLocal)",
                    item.releaseLocal.isEmpty ? "" : "END \\(item.releaseLocal)",
                    item.sectorCount > 0 ? "\\(item.sectorCount) sectors" : ""
                ].filter { !$0.isEmpty }
                if !details.isEmpty {
                    Text(details.joined(separator: " • "))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
'''
new_details = '''                if !item.preDutyPickupDisplay.isEmpty {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let clock = compactPickupClock(item.preDutyPickupDisplay)
                        let countdown = item.preDutyPickupUTCDate.map { calendarPickupCountdown(from: context.date, to: $0) } ?? ""
                        Text(["PU \\(clock)", countdown].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                    }
                }

                let details = [
                    item.reportLocal.isEmpty ? "" : "CI \\(item.reportLocal)",
                    item.releaseLocal.isEmpty ? "" : "END \\(item.releaseLocal)",
                    item.sectorCount > 0 ? "\\(item.sectorCount) sectors" : ""
                ].filter { !$0.isEmpty }
                if !details.isEmpty {
                    Text(details.joined(separator: " • "))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
'''
if old_details not in agenda:
    raise RuntimeError("V2.11.13 calendar agenda details marker not found")
agenda = agenda.replace(old_details, new_details, 1)

countdown_helper = r'''
private func calendarPickupCountdown(from now: Date, to pickup: Date) -> String {
    let seconds = pickup.timeIntervalSince(now)
    guard seconds > 0 else { return "" }
    let minutes = max(1, Int((seconds + 59) / 60))
    if minutes < 60 { return "in \(minutes)m" }
    if minutes < 24 * 60 {
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "in \(hours)h" : "in \(hours)h \(remainder)m"
    }
    let days = minutes / (24 * 60)
    let hours = (minutes % (24 * 60)) / 60
    return hours == 0 ? "in \(days)d" : "in \(days)d \(hours)h"
}

'''
agenda = agenda + countdown_helper
content = content[:agenda_start] + agenda + content[agenda_end:]

# -----------------------------------------------------------------------------
# Today personal note: preserve the same duty-keyed UserDefaults record while
# exposing whether a note already exists without expanding the editor.
# -----------------------------------------------------------------------------
note_start = content.find("struct TodayPersonalNoteDisclosure: View {")
note_end = content.find("struct DutyBriefingView: View {", note_start)
if note_start < 0 or note_end < 0:
    raise RuntimeError("V2.11.13 TodayPersonalNoteDisclosure range not found")

note_view = r'''struct TodayPersonalNoteDisclosure: View {
    let item: RosterItem
    @State private var isExpanded = false
    @AppStorage private var storedNote: String

    init(item: RosterItem) {
        self.item = item
        self._storedNote = AppStorage(
            wrappedValue: "",
            "RAIDORoster.PersonalNote." + item.id
        )
    }

    private var hasStoredNote: Bool {
        !storedNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
                    Text(isExpanded ? "Hide" : (hasStoredNote ? "Added" : "View"))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide my note" : (hasStoredNote ? "Open existing my note" : "Add my note"))

            if isExpanded {
                PersonalDutyNoteCard(item: item)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .sensoryFeedback(.selection, trigger: isExpanded)
    }
}

'''
content = content[:note_start] + note_view + content[note_end:]

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.11.12")',
    'LabeledContent("RAIDO Roster", value: "2.11.13")',
    1,
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 25;", "CURRENT_PROJECT_VERSION = 26;")
pbx = pbx.replace("MARKETING_VERSION = 2.11.12;", "MARKETING_VERSION = 2.11.13;")
PBX.write_text(pbx)

print("V2.11.13 compact changes + pickup agenda + note state applied")
