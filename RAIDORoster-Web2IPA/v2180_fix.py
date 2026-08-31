from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
WEB = ROOT / "RAIDORoster" / "RosterWebView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"

content = CONTENT.read_text()

# -----------------------------------------------------------------------------
# V2.18 — the RAIDO page month is authoritative.
# Long-running auxiliary rows (for example a hotel beginning in August and
# ending in September) must never decide which month the September roster is.
# -----------------------------------------------------------------------------
store_start = content.find('final class RosterStore: ObservableObject {')
store_end = content.find('\n@MainActor\nfinal class AppState:', store_start)
if store_start < 0 or store_end < 0:
    raise RuntimeError('V2.18 RosterStore boundaries not found')
store = content[store_start:store_end]

# monthKey() was introduced by V2.17.5. Replace it structurally so validation.month
# wins whenever RAIDO supplied a valid yyyy-MM month.
mk_start = store.find('    private func monthKey(for snapshot: RosterSnapshot) -> String {')
if mk_start < 0:
    raise RuntimeError('V2.18 monthKey start not found')

def block_end(text: str, start: int) -> int:
    brace = text.find('{', start)
    if brace < 0:
        return -1
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == '{': depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return i + 1
    return -1

mk_end = block_end(store, mk_start)
if mk_end < 0:
    raise RuntimeError('V2.18 monthKey end not found')
new_month_key = r'''    private func monthKey(for snapshot: RosterSnapshot) -> String {
        if let month = snapshot.validation?.month,
           month.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil {
            return month
        }
        if let iso = snapshot.items.compactMap(\.dateISO).first(where: {
            $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        }) {
            return String(iso.prefix(7))
        }
        return "unknown"
    }'''
store = store[:mk_start] + new_month_key + store[mk_end:]

# The selected month's visible items must be limited to that RAIDO month.
# Auxiliary hotel rows from adjacent months remain stored in the snapshot for
# duty-detail use, but do not become calendar days in the wrong month.
if 'var rosterCalendarItems: [RosterItem]' not in store:
    anchor = '    var rosterViewItems: [RosterItem] { rosterViewSnapshot?.items ?? [] }\n'
    if anchor not in store:
        raise RuntimeError('V2.18 rosterViewItems anchor not found')
    helper = r'''

    var selectedRosterMonth: String? {
        selectedRosterMonthKey ?? rosterViewSnapshot.map(monthKey(for:))
    }

    var rosterCalendarItems: [RosterItem] {
        guard let month = selectedRosterMonth, month.count == 7 else { return rosterViewItems }
        return rosterViewItems.filter { $0.dateISO?.hasPrefix(month) == true }
    }
'''
    store = store.replace(anchor, anchor + helper, 1)

# Re-index old archives on load. This repairs installations where a September
# snapshot was accidentally saved under 2026-08 because its first row was HTL.
if 'private func normalizeMonthArchive()' not in store:
    marker = '    private func saveMonthSnapshots() {\n'
    idx = store.find(marker)
    if idx < 0:
        raise RuntimeError('V2.18 saveMonthSnapshots marker not found')
    helper = r'''    private func normalizeMonthArchive() {
        guard !monthSnapshots.isEmpty else { return }
        var repaired: [String: RosterSnapshot] = [:]
        for snapshot in monthSnapshots.values.sorted(by: { $0.capturedAt < $1.capturedAt }) {
            let key = monthKey(for: snapshot)
            guard key != "unknown" else { continue }
            if let existing = repaired[key], existing.capturedAt > snapshot.capturedAt { continue }
            repaired[key] = snapshot
        }
        monthSnapshots = repaired
        if let current = snapshot {
            monthSnapshots[monthKey(for: current)] = current
        }
        if let selected = selectedRosterMonthKey, monthSnapshots[selected] == nil {
            selectedRosterMonthKey = snapshot.map(monthKey(for:)) ?? monthSnapshots.keys.sorted().last
        }
    }

'''
    store = store[:idx] + helper + store[idx:]

# Ensure archive normalization happens after cache loading/migration.
load_start = store.find('    private func load() {')
load_end = block_end(store, load_start)
if load_start < 0 or load_end < 0:
    raise RuntimeError('V2.18 load boundaries not found')
load = store[load_start:load_end]
if 'normalizeMonthArchive()' not in load:
    # insert immediately before the method's final brace
    final_brace = load.rfind('}')
    load = load[:final_brace] + '        normalizeMonthArchive()\n        saveMonthSnapshots()\n' + load[final_brace:]
    store = store[:load_start] + load + store[load_end:]

# After every ingest, the page's validation month becomes selected. V2.17.5
# already does this, but reinforce it in case an earlier patch path differed.
ingest_start = store.find('    func ingest(messageBody: Any) {')
ingest_end = store.find('\n    func dismissChangeNotice()', ingest_start)
if ingest_start < 0 or ingest_end < 0:
    raise RuntimeError('V2.18 ingest boundaries not found')
ingest = store[ingest_start:ingest_end]
if 'selectedRosterMonthKey = validation.month' not in ingest:
    marker = '        let archiveKey = monthKey(for: newSnapshot)\n'
    if marker in ingest:
        ingest = ingest.replace(marker, marker + '        selectedRosterMonthKey = validation.month.isEmpty ? archiveKey : validation.month\n', 1)
    elif 'snapshot = newSnapshot\n' in ingest:
        ingest = ingest.replace('        snapshot = newSnapshot\n', '        snapshot = newSnapshot\n        selectedRosterMonthKey = validation.month.isEmpty ? monthKey(for: newSnapshot) : validation.month\n', 1)
    else:
        raise RuntimeError('V2.18 ingest selection point not found')
    store = store[:ingest_start] + ingest + store[ingest_end:]

content = content[:store_start] + store + content[store_end:]

# -----------------------------------------------------------------------------
# Calendar uses selected RAIDO month, not first activity date.
# -----------------------------------------------------------------------------
cal_start = content.find('struct RosterMonthCalendarView: View {')
cal_end = content.find('\nstruct RosterCalendarDayCell: View {', cal_start)
if cal_start < 0 or cal_end < 0:
    raise RuntimeError('V2.18 calendar boundaries not found')
cal = content[cal_start:cal_end]

cal = cal.replace('private var items: [RosterItem] { store.rosterViewItems }',
                  'private var items: [RosterItem] { store.rosterCalendarItems }')

# Replace first-row-derived month title with the selected archive key/title.
mt_start = cal.find('    private var monthTitle: String {')
if mt_start >= 0:
    mt_end = block_end(cal, mt_start)
    if mt_end < 0:
        raise RuntimeError('V2.18 monthTitle end not found')
    cal = cal[:mt_start] + '    private var monthTitle: String { store.rosterMonthTitle }' + cal[mt_end:]

# Generate slots directly from selected yyyy-MM. This removes all dependence on
# the Aug-20 hotel row and also renders an empty selected month correctly.
slots_start = cal.find('    private var slots: [String?] {')
if slots_start < 0:
    raise RuntimeError('V2.18 slots start not found')
slots_end = block_end(cal, slots_start)
if slots_end < 0:
    raise RuntimeError('V2.18 slots end not found')
new_slots = r'''    private var slots: [String?] {
        guard let month = store.selectedRosterMonth, month.count == 7 else { return [] }
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return [] }
        var comps = DateComponents()
        comps.year = parts[0]
        comps.month = parts[1]
        comps.day = 1
        guard let monthStart = calendar.date(from: comps),
              let days = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }

        let weekday = calendar.component(.weekday, from: monthStart)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var result = Array<String?>(repeating: nil, count: leading)
        for day in days {
            result.append(String(format: "%04d-%02d-%02d", parts[0], parts[1], day))
        }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }'''
cal = cal[:slots_start] + new_slots + cal[slots_end:]

content = content[:cal_start] + cal + content[cal_end:]

# -----------------------------------------------------------------------------
# Wire Roster screen to the browser so arrows can use the actual RAIDO controls
# when an adjacent month is not already cached.
# -----------------------------------------------------------------------------
# RosterHomeView gains browser reference.
home_start = content.find('struct RosterHomeView: View {')
home_end = content.find('\nstruct RosterMonthCalendarView: View {', home_start)
if home_start < 0 or home_end < 0:
    raise RuntimeError('V2.18 RosterHomeView boundaries not found')
home = content[home_start:home_end]
if '@ObservedObject var browser: RosterBrowserModel' not in home:
    home = home.replace(
        '    @ObservedObject var store: RosterStore\n',
        '    @ObservedObject var store: RosterStore\n    @ObservedObject var browser: RosterBrowserModel\n',
        1,
    )
content = content[:home_start] + home + content[home_end:]

# Calendar view gains browser reference and passes arrow actions through a
# cache-first helper. Cached navigation is instant/offline; otherwise it clicks
# RAIDO Previous/Next in the already-authenticated WKWebView.
cal_start = content.find('struct RosterMonthCalendarView: View {')
cal_end = content.find('\nstruct RosterCalendarDayCell: View {', cal_start)
cal = content[cal_start:cal_end]
if '@ObservedObject var browser: RosterBrowserModel' not in cal:
    cal = cal.replace(
        '    @ObservedObject var store: RosterStore\n',
        '    @ObservedObject var store: RosterStore\n    @ObservedObject var browser: RosterBrowserModel\n',
        1,
    )
cal = cal.replace('Button { store.selectPreviousRosterMonth() } label: {',
                  'Button { navigateMonth(previous: true) } label: {', 1)
cal = cal.replace('Button { store.selectNextRosterMonth() } label: {',
                  'Button { navigateMonth(previous: false) } label: {', 1)
# Do not disable arrows merely because a month is not cached: online RAIDO can
# fetch it. Opacity remains full; the browser method surfaces failures cleanly.
cal = cal.replace('.disabled(!store.canSelectPreviousRosterMonth)\n                .opacity(store.canSelectPreviousRosterMonth ? 1 : 0.28)\n', '')
cal = cal.replace('.disabled(!store.canSelectNextRosterMonth)\n                .opacity(store.canSelectNextRosterMonth ? 1 : 0.28)\n', '')

if 'private func navigateMonth(previous: Bool)' not in cal:
    insert = cal.rfind('\n}')
    helper = r'''

    private func navigateMonth(previous: Bool) {
        if previous, store.canSelectPreviousRosterMonth {
            store.selectPreviousRosterMonth()
            return
        }
        if !previous, store.canSelectNextRosterMonth {
            store.selectNextRosterMonth()
            return
        }
        browser.switchRosterMonth(previous ? "previous" : "next")
    }
'''
    cal = cal[:insert] + helper + cal[insert:]
content = content[:cal_start] + cal + content[cal_end:]

# Pass browser from ContentView -> RosterHomeView and RosterHomeView -> calendar.
content = content.replace(
    'RosterHomeView(store: appState.rosterStore) { selectedTab = .portal }',
    'RosterHomeView(store: appState.rosterStore, browser: appState.browser) { selectedTab = .portal }',
    1,
)
content = content.replace(
    'RosterMonthCalendarView(store: store, changedDates: store.changedDates)',
    'RosterMonthCalendarView(store: store, browser: browser, changedDates: store.changedDates)',
    1,
)

# Surface month navigation status under the calendar controls only when useful.
# Keep this compact and transient through the browser model.
if 'browser.monthNavigationStatus' not in content[home_start:home_end if home_end > 0 else len(content)]:
    # No extra permanent UI is required; status is shown in the RAIDO/browser
    # model and the page update itself changes the selected month.
    pass

content = content.replace('LabeledContent("RAIDO Roster", value: "2.17.9")',
                          'LabeledContent("RAIDO Roster", value: "2.18")', 1)
CONTENT.write_text(content)

# -----------------------------------------------------------------------------
# Browser: invoke the real RAIDO Previous/Next controls discovered by diagnostics.
# -----------------------------------------------------------------------------
web = WEB.read_text()
if '@Published var monthNavigationStatus:' not in web:
    web = web.replace(
        '    @Published var diagnosticStatus: String?\n',
        '    @Published var diagnosticStatus: String?\n    @Published var monthNavigationStatus: String?\n',
        1,
    )

if 'func switchRosterMonth(_ direction: String)' not in web:
    marker = '    func copyDiagnostics() {\n'
    idx = web.find(marker)
    if idx < 0:
        raise RuntimeError('V2.18 browser diagnostics marker not found')
    method = r'''    func switchRosterMonth(_ direction: String) {
        guard let webView else {
            monthNavigationStatus = "Open RAIDO once to enable online month loading."
            return
        }
        let want = direction.lowercased() == "previous" ? "previous" : "next"
        let script = """
        (() => {
          const want = '\(want)';
          const controls = Array.from(document.querySelectorAll('button.switch-month-button, button, a'));
          const button = controls.find(el => {
            const text = (el.innerText || el.textContent || '').trim().toLowerCase();
            return text === want && !el.disabled && el.getAttribute('aria-disabled') !== 'true';
          });
          if (!button) return false;
          button.click();
          setTimeout(() => {
            try { window.RAIDOPlus?.extractNow?.(); } catch (_) {}
          }, 900);
          return true;
        })();
        """
        webView.evaluateJavaScript(script) { result, error in
            DispatchQueue.main.async {
                if result as? Bool == true {
                    self.monthNavigationStatus = "Loading \(want) roster month…"
                } else if let error {
                    self.monthNavigationStatus = "Could not switch month: \(error.localizedDescription)"
                } else {
                    self.monthNavigationStatus = "RAIDO \(want) month is unavailable."
                }
            }
        }
    }

'''
    web = web[:idx] + method + web[idx:]
WEB.write_text(web)

pbx = PBX.read_text()
pbx = pbx.replace('MARKETING_VERSION = 2.17.9;', 'MARKETING_VERSION = 2.18;')
PBX.write_text(pbx)

print('V2.18 authoritative RAIDO month + archive repair + live Previous/Next navigation applied')
