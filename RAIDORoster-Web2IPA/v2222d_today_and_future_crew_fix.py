from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"

s = CONTENT.read_text()

def block_end(text: str, start: int) -> int:
    brace = text.find("{", start)
    if brace < 0:
        return -1
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i + 1
    return -1

# ---------------------------------------------------------------------------
# Today must be independent of whichever month the user last viewed.
# The legacy snapshot can point at October after browsing October, while the
# September rich snapshot is still safely archived in monthSnapshots. Resolve
# Today from the archive entry for the device-local current yyyy-MM first.
# ---------------------------------------------------------------------------
store_start = s.find("final class RosterStore: ObservableObject {")
store_end = s.find("\n@MainActor\nfinal class AppState:", store_start)
if store_start < 0 or store_end < 0:
    raise RuntimeError("V2.23.1 current-day fix: RosterStore bounds missing")
store = s[store_start:store_end]

today_start = store.find("    var todayItems: [RosterItem] {")
today_end = block_end(store, today_start) if today_start >= 0 else -1
if today_start < 0 or today_end < 0:
    raise RuntimeError("V2.23.1 current-day fix: todayItems missing")

new_today = r'''    var todayItems: [RosterItem] {
        let key = isoDay.string(from: Date())
        let month = String(key.prefix(7))

        // Today is a global app concept, not a property of the month currently
        // selected in the Roster tab. Prefer the archived current-month
        // snapshot, then the legacy current snapshot, then any archive row that
        // actually contains today's date.
        let preferred: [RosterItem]
        if let currentMonth = monthSnapshots[month] {
            preferred = currentMonth.items
        } else if snapshot?.items.contains(where: { $0.dateISO == key }) == true {
            preferred = snapshot?.items ?? []
        } else {
            preferred = monthSnapshots.values
                .sorted { $0.capturedAt > $1.capturedAt }
                .first(where: { $0.items.contains(where: { $0.dateISO == key }) })?
                .items ?? []
        }
        return preferred.filter { $0.dateISO == key }
    }'''
store = store[:today_start] + new_today + store[today_end:]

# Make nextDuty resilient for the same reason. Prefer all archived rich/current
# rows instead of whichever month happened to be the last HTML snapshot.
next_start = store.find("    var nextDuty: RosterItem? {")
next_end = block_end(store, next_start) if next_start >= 0 else -1
if next_start >= 0 and next_end >= 0:
    new_next = r'''    var nextDuty: RosterItem? {
        let today = calendar.startOfDay(for: Date())
        var byID: [String: RosterItem] = [:]
        for snap in monthSnapshots.values {
            for item in snap.items { byID[item.id] = item }
        }
        for item in snapshot?.items ?? [] { byID[item.id] = item }

        return byID.values.compactMap { item -> (RosterItem, Date)? in
            guard item.isOperationalDuty,
                  let key = item.dateISO,
                  let date = isoDay.date(from: key) else { return nil }
            return (item, date)
        }
        .filter { $0.1 >= today }
        .sorted {
            if $0.1 == $1.1 { return $0.0.index < $1.0.index }
            return $0.1 < $1.1
        }
        .first?.0
    }'''
    store = store[:next_start] + new_next + store[next_end:]

s = s[:store_start] + store + s[store_end:]

# ---------------------------------------------------------------------------
# Future-month crew:
# WebCal is intentionally lightweight and contains no crew array. Keep its fast
# instant month display, but also drive the authenticated RAIDO month control on
# every native month-arrow navigation so the rich HTML parser can replace the
# feed-only snapshot with aircraft/crew/pickup/detail data.
# ---------------------------------------------------------------------------
cal_start = s.find("struct RosterMonthCalendarView: View {")
cal_end = s.find("\nstruct RosterCalendarDayCell: View {", cal_start)
if cal_start < 0 or cal_end < 0:
    raise RuntimeError("V2.23.1 current-day fix: calendar bounds missing")
cal = s[cal_start:cal_end]
nav_start = cal.find("    private func navigateMonth(previous: Bool) {")
nav_end = block_end(cal, nav_start) if nav_start >= 0 else -1
if nav_start < 0 or nav_end < 0:
    raise RuntimeError("V2.23.1 current-day fix: navigateMonth missing")

new_nav = r'''    private func navigateMonth(previous: Bool) {
        guard let target = store.adjacentRosterMonthKey(previous: previous) else { return }

        // Instant native navigation uses the archive/feed when available.
        _ = store.selectRosterMonthIfCached(target)

        // In parallel, move the authenticated RAIDO roster page as well.
        // Its HTML snapshot is the authoritative rich source for crew,
        // aircraft, pickup and detailed duty data that WebCal cannot provide.
        browser.switchRosterMonth(previous ? "previous" : "next")

        // WebCal remains a fallback for fast/offline month coverage.
        browser.refreshRosterCalendarFeed()
    }'''
cal = cal[:nav_start] + new_nav + cal[nav_end:]
s = s[:cal_start] + cal + s[cal_end:]

for required in [
    "let month = String(key.prefix(7))",
    "monthSnapshots[month]",
    "browser.switchRosterMonth(previous ? \"previous\" : \"next\")",
    "browser.refreshRosterCalendarFeed()",
]:
    if required not in s:
        raise RuntimeError("V2.23.1 semantic guard missing: " + required)

s += "\n// V2.23.1 Today current-month archive isolation + rich future-month refresh\n"
CONTENT.write_text(s)
print("V2.23.1 Today/current-month and future-month rich roster fixes applied")
