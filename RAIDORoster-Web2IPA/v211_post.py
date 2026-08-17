from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"

content = CONTENT.read_text()
start_marker = "struct RosterDetailView: View {"
end_marker = "struct RosterChangesView: View {"

if start_marker not in content or end_marker not in content:
    raise RuntimeError("V2.11 postpatch detail markers not found")

prefix, tail = content.split(start_marker, 1)
detail, suffix = tail.split(end_marker, 1)

if "@StateObject private var calendarExporter = CalendarExporter()" not in detail:
    detail = detail.replace(
        "    @EnvironmentObject private var store: RosterStore\n",
        "    @EnvironmentObject private var store: RosterStore\n    @StateObject private var calendarExporter = CalendarExporter()\n",
        1
    )

calendar_block = '''        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { calendarExporter.export(item) } label: {
                    Image(systemName: "calendar.badge.plus")
                }
                .disabled(calendarExporter.isWorking)
                .accessibilityLabel("Export duty to Calendar")
            }
        }
        .alert("Calendar", isPresented: Binding(
            get: { calendarExporter.message != nil },
            set: { if !$0 { calendarExporter.message = nil } }
        )) {
            Button("OK", role: .cancel) { calendarExporter.message = nil }
        } message: {
            Text(calendarExporter.message ?? "")
        }
'''

if calendar_block not in detail:
    anchor = '''        .navigationTitle("Duty")
        .navigationBarTitleDisplayMode(.inline)
'''
    if anchor not in detail:
        raise RuntimeError("V2.11 postpatch navigation marker not found")
    detail = detail.replace(anchor, anchor + calendar_block, 1)

CONTENT.write_text(prefix + start_marker + detail + end_marker + suffix)
print("V2.11 Calendar controls restored")
