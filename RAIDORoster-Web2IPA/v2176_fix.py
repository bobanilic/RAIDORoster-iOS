from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"

content = CONTENT.read_text()

# V2.11 intentionally treated older RAIDO months as crew-history-only. Fleet
# V2.17.5 now has a real per-month roster archive, so allow those valid months
# through the normal snapshot/archive path instead of returning early.
old_history_gate = '''        let currentMonth = currentMonthKey()\n        if validation.month < currentMonth,\n           snapshot?.validation?.month == currentMonth {\n            return\n        }\n\n'''
if old_history_gate in content:
    content = content.replace(old_history_gate, '', 1)

# The visible Calendar is RosterMonthCalendarView. V2.17.5 added month state to
# the store but its first pass only changed the old list branch. Wire the actual
# calendar to the selected cached month and put navigation directly beside the
# month title, where it is obvious on iPhone.
old_call = 'RosterMonthCalendarView(items: store.items, changedDates: store.changedDates)'
new_call = 'RosterMonthCalendarView(store: store, changedDates: store.changedDates)'
if old_call in content:
    content = content.replace(old_call, new_call, 1)
elif new_call not in content:
    raise RuntimeError('V2.17.6 visible calendar call not found')

old_struct = '''struct RosterMonthCalendarView: View {\n    let items: [RosterItem]\n    let changedDates: Set<String>\n'''
new_struct = '''struct RosterMonthCalendarView: View {\n    @ObservedObject var store: RosterStore\n    let changedDates: Set<String>\n\n    private var items: [RosterItem] { store.rosterViewItems }\n'''
if old_struct in content:
    content = content.replace(old_struct, new_struct, 1)
elif new_struct not in content:
    raise RuntimeError('V2.17.6 calendar struct marker not found')

old_header = '''            HStack {\n                Text(monthTitle)\n                    .font(.title3.bold())\n                Spacer()\n                if !changedDates.isEmpty {\n                    Label("Changed", systemImage: "circle.fill")\n                        .font(.caption2.weight(.semibold))\n                        .foregroundStyle(.orange)\n                }\n            }\n'''
new_header = '''            HStack(spacing: 8) {\n                Button { store.selectPreviousRosterMonth() } label: {\n                    Image(systemName: "chevron.left")\n                        .font(.subheadline.bold())\n                        .frame(width: 30, height: 30)\n                }\n                .buttonStyle(.plain)\n                .disabled(!store.canSelectPreviousRosterMonth)\n                .opacity(store.canSelectPreviousRosterMonth ? 1 : 0.28)\n                .accessibilityLabel("Previous cached roster month")\n\n                Text(monthTitle)\n                    .font(.title3.bold())\n\n                Button { store.selectNextRosterMonth() } label: {\n                    Image(systemName: "chevron.right")\n                        .font(.subheadline.bold())\n                        .frame(width: 30, height: 30)\n                }\n                .buttonStyle(.plain)\n                .disabled(!store.canSelectNextRosterMonth)\n                .opacity(store.canSelectNextRosterMonth ? 1 : 0.28)\n                .accessibilityLabel("Next cached roster month")\n\n                Spacer()\n                if !changedDates.isEmpty {\n                    Label("Changed", systemImage: "circle.fill")\n                        .font(.caption2.weight(.semibold))\n                        .foregroundStyle(.orange)\n                }\n            }\n'''
if new_header not in content:
    if old_header not in content:
        raise RuntimeError('V2.17.6 calendar month header not found')
    content = content.replace(old_header, new_header, 1)

# The separate V2.17.5 navigator above the content is redundant now that the
# arrows live in the calendar header. Remove it from the visible home stack.
old_extra = '''                    if store.hasCache {\n                        rosterMonthNavigator\n                    }\n\n'''
content = content.replace(old_extra, '', 1)

content = content.replace('LabeledContent("RAIDO Roster", value: "2.17.5")', 'LabeledContent("RAIDO Roster", value: "2.17.6")', 1)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace('MARKETING_VERSION = 2.17.5;', 'MARKETING_VERSION = 2.17.6;')
PBX.write_text(pbx)

print('V2.17.6 visible Calendar month arrows + historical month archive applied')
