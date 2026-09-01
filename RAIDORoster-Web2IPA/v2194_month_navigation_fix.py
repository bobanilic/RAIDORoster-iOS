from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def block_end(text: str, start: int) -> int:
    brace = text.find('{', start)
    if brace < 0:
        return -1
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return i + 1
    return -1


content = CONTENT.read_text()
store_start = content.find('final class RosterStore: ObservableObject {')
store_end = content.find('\n@MainActor\nfinal class AppState:', store_start)
if store_start < 0 or store_end < 0:
    raise RuntimeError('V2.19.4 RosterStore boundaries not found')
store = content[store_start:store_end]

# Selected month is a navigation state, not an index into the cache. If the
# selected month is not cached yet, return nil rather than silently falling back
# to another month's snapshot (which made the header/grid disagree).
rv_start = store.find('    var rosterViewSnapshot: RosterSnapshot? {')
if rv_start < 0:
    raise RuntimeError('V2.19.4 rosterViewSnapshot not found')
rv_end = block_end(store, rv_start)
if rv_end < 0:
    raise RuntimeError('V2.19.4 rosterViewSnapshot end not found')
new_rv = r'''    var rosterViewSnapshot: RosterSnapshot? {
        if let key = selectedRosterMonthKey {
            return monthSnapshots[key]
        }
        return snapshot
    }'''
store = store[:rv_start] + new_rv + store[rv_end:]

# Previous/next availability must not depend on which months happen to be
# cached. Calendar adjacency is always valid within a broad practical range.
for name, body in [
    ('canSelectPreviousRosterMonth', '        adjacentRosterMonthKey(previous: true) != nil'),
    ('canSelectNextRosterMonth', '        adjacentRosterMonthKey(previous: false) != nil'),
]:
    start = store.find(f'    var {name}: Bool {{')
    if start >= 0:
        end = block_end(store, start)
        if end < 0:
            raise RuntimeError(f'V2.19.4 {name} end not found')
        repl = f'    var {name}: Bool {{\n{body}\n    }}'
        store = store[:start] + repl + store[end:]

# These methods are used by an older compact month navigator elsewhere in the
# UI. Make them use arithmetic month adjacency too, never sorted cache indexes.
for name, previous in [('selectPreviousRosterMonth', True), ('selectNextRosterMonth', False)]:
    start = store.find(f'    func {name}() {{')
    if start >= 0:
        end = block_end(store, start)
        if end < 0:
            raise RuntimeError(f'V2.19.4 {name} end not found')
        val = 'true' if previous else 'false'
        repl = f'''    func {name}() {{
        guard let target = adjacentRosterMonthKey(previous: {val}) else {{ return }}
        selectedRosterMonthKey = target
    }}'''
        store = store[:start] + repl + store[end:]

# A cached selection and a pending selection are deliberately the same visible
# operation. This prevents different behavior depending on archive gaps.
start = store.find('    @discardableResult\n    func selectRosterMonthIfCached(_ key: String) -> Bool {')
if start >= 0:
    method_start = store.find('    func selectRosterMonthIfCached(_ key: String) -> Bool {', start)
    end = block_end(store, method_start)
    if end < 0:
        raise RuntimeError('V2.19.4 selectRosterMonthIfCached end not found')
    prefix_start = start
    repl = r'''    @discardableResult
    func selectRosterMonthIfCached(_ key: String) -> Bool {
        selectedRosterMonthKey = key
        return monthSnapshots[key] != nil
    }'''
    store = store[:prefix_start] + repl + store[end:]

# Rebuild snapshots created by the first feed backend version. Past HTML-rich
# snapshots remain protected, but 2.19.3 feed snapshots may be replaced so a
# bad archived month cannot remain stuck forever after this navigation fix.
ingest_start = store.find('    func ingestCalendarFeed(messageBody: Any) {')
if ingest_start < 0:
    raise RuntimeError('V2.19.4 ingestCalendarFeed not found')
ingest_end = block_end(store, ingest_start)
if ingest_end < 0:
    raise RuntimeError('V2.19.4 ingestCalendarFeed end not found')
ingest = store[ingest_start:ingest_end]
ingest = ingest.replace(
'''            // Historical snapshots are immutable once successfully archived.
            if month < currentMonth, monthSnapshots[month] != nil { continue }
''',
'''            // Historical HTML snapshots are immutable. Feed snapshots from
            // earlier feed-parser versions may be rebuilt/migrated.
            if month < currentMonth,
               let existing = monthSnapshots[month],
               existing.validation?.parser.hasPrefix("raido-duty-envelope") == true {
                continue
            }
''', 1)
ingest = ingest.replace('parser: "n-oc-webcal-2.19.3",', 'parser: "n-oc-webcal-2.19.4",')
store = store[:ingest_start] + ingest + store[ingest_end:]

content = content[:store_start] + store + content[store_end:]

# Main calendar arrows: selection is always immediate and local. Refresh the
# feed only when the requested month is not already archived.
cal_start = content.find('struct RosterMonthCalendarView: View {')
cal_end = content.find('\nstruct RosterCalendarDayCell: View {', cal_start)
if cal_start < 0 or cal_end < 0:
    raise RuntimeError('V2.19.4 calendar boundaries not found')
cal = content[cal_start:cal_end]
nav_start = cal.find('    private func navigateMonth(previous: Bool) {')
if nav_start < 0:
    raise RuntimeError('V2.19.4 navigateMonth not found')
nav_end = block_end(cal, nav_start)
if nav_end < 0:
    raise RuntimeError('V2.19.4 navigateMonth end not found')
new_nav = r'''    private func navigateMonth(previous: Bool) {
        guard let target = store.adjacentRosterMonthKey(previous: previous) else { return }
        let cached = store.selectRosterMonthIfCached(target)
        if !cached {
            browser.refreshRosterCalendarFeed()
        }
    }'''
cal = cal[:nav_start] + new_nav + cal[nav_end:]
content = content[:cal_start] + cal + content[cal_end:]

# Remove any stale cache-index disable modifiers left by older UI patches.
content = content.replace('            .disabled(!store.canSelectPreviousRosterMonth)\n', '')
content = content.replace('            .disabled(!store.canSelectNextRosterMonth)\n', '')
content = content.replace('                .disabled(!store.canSelectPreviousRosterMonth)\n', '')
content = content.replace('                .disabled(!store.canSelectNextRosterMonth)\n', '')

# Version label.
content = content.replace('LabeledContent("RAIDO Roster", value: "2.19.3")',
                          'LabeledContent("RAIDO Roster", value: "2.19.4")', 1)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace('MARKETING_VERSION = 2.19.3;', 'MARKETING_VERSION = 2.19.4;')
PBX.write_text(pbx)

print('V2.19.4 cache-independent adjacent month navigation applied')
