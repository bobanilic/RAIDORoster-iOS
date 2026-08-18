from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.11.6 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# Future roster changes: store meaningful old/new previews for each note family
# instead of the old generic "Previous details -> Updated details" placeholder.
content = replace_once(
    content,
    '''            if before?.transferNotes != after?.transferNotes || before?.activityNotes != after?.activityNotes || before?.dayNotes != after?.dayNotes {
                fields.append(.init(label: "Notes / transfer", oldValue: "Previous details", newValue: "Updated details"))
            }
''',
    '''            addChange(
                &fields,
                label: "Transfer note",
                old: changeNoteSummary(before?.transferNotes ?? []),
                new: changeNoteSummary(after?.transferNotes ?? [])
            )
            addChange(
                &fields,
                label: "Activity note",
                old: changeNoteSummary(before?.activityNotes ?? []),
                new: changeNoteSummary(after?.activityNotes ?? [])
            )
            addChange(
                &fields,
                label: "Day note",
                old: changeNoteSummary(before?.dayNotes ?? []),
                new: changeNoteSummary(after?.dayNotes ?? [])
            )
''',
    "exact note changes",
)

note_helper = r'''
    private func changeNoteSummary(_ notes: [String]) -> String {
        let value = uniqueStrings(notes)
            .map { $0.replacingOccurrences(of: "\n", with: " • ") }
            .joined(separator: " | ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if value.count <= 220 { return value }
        return String(value.prefix(217)) + "…"
    }

'''
if "private func changeNoteSummary(" not in content:
    content = replace_once(
        content,
        "    private func notifyRosterChanges(_ changes: [RosterDayChange]) {\n",
        note_helper + "    private func notifyRosterChanges(_ changes: [RosterDayChange]) {\n",
        "note preview helper",
    )

# Existing V2.11.x change archives cannot recover note text that was never
# persisted. Migrate those legacy placeholders to an honest one-sided status
# instead of presenting fake old/new values.
content = replace_once(
    content,
    '''        guard let bundle = try? decoder.decode(RosterChangeBundle.self, from: data), !bundle.changes.isEmpty else { return }
        latestChanges = bundle.changes
        changedDates = Set(bundle.changes.map(\.dateISO))
        let count = bundle.changes.count
        changeNotice = "Roster changed • \(count) day\(count == 1 ? "" : "s")"
''',
    '''        guard let bundle = try? decoder.decode(RosterChangeBundle.self, from: data), !bundle.changes.isEmpty else { return }
        let migrated = bundle.changes.map { change in
            RosterDayChange(
                dateISO: change.dateISO,
                dateText: change.dateText,
                fields: change.fields.map { field in
                    if field.oldValue == "Previous details" && field.newValue == "Updated details" {
                        return RosterChangeField(label: field.label, oldValue: "—", newValue: "Details changed")
                    }
                    return field
                }
            )
        }
        latestChanges = migrated
        changedDates = Set(migrated.map(\.dateISO))
        let count = migrated.count
        changeNotice = "Roster changed • \(count) day\(count == 1 ? "" : "s")"
        if migrated != bundle.changes { saveChangeState() }
''',
    "legacy change migration",
)

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.11.5")',
    'LabeledContent("RAIDO Roster", value: "2.11.6")',
    1,
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 18;", "CURRENT_PROJECT_VERSION = 19;")
pbx = pbx.replace("MARKETING_VERSION = 2.11.5;", "MARKETING_VERSION = 2.11.6;")
PBX.write_text(pbx)

print("V2.11.6 exact roster note diffs applied")
