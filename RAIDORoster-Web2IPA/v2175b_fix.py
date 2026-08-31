from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"

content = CONTENT.read_text()

# -----------------------------------------------------------------------------
# V2.17.5b — live GPS: usable speed + stricter position quality
# -----------------------------------------------------------------------------
# A valid CLLocation.speed must not be hidden just because speedAccuracy is -1.
content = re.sub(
    r'(private var speedText: String \{\s*guard let location = gps\.location,\s*location\.speed >= 0),\s*location\.speedAccuracy >= 0(\s*else \{)',
    r'\1\2',
    content,
    count=1,
)

# Replace the location update callback by function boundaries rather than a
# whitespace-sensitive full-text marker.
loc_start = content.find('    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {')
loc_end = content.find('    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {', loc_start)
if loc_start < 0 or loc_end < 0:
    raise RuntimeError('V2.17.5b Core Location callback boundaries not found')

new_location_callback = r'''    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let recent = locations.filter {
            $0.horizontalAccuracy >= 0 &&
            abs($0.timestamp.timeIntervalSinceNow) < 30
        }
        guard !recent.isEmpty else { return }

        // Avoid visibly wrong Wi-Fi/cell fixes on the aircraft map. Preserve
        // the last good point until a GPS-grade update is available again.
        guard let newest = recent.reversed().first(where: { $0.horizontalAccuracy <= 300 }) else {
            if location == nil {
                let best = recent.map(\.horizontalAccuracy).min() ?? 0
                errorText = best > 0
                    ? "Waiting for precise GPS (±\(Int(best.rounded())) m)"
                    : "Waiting for precise GPS"
            }
            return
        }

        location = newest
        errorText = nil

        if let lastCoordinate = trail.last {
            let last = CLLocation(latitude: lastCoordinate.latitude, longitude: lastCoordinate.longitude)
            guard newest.distance(from: last) >= 25 else { return }
        }

        trail.append(newest.coordinate)
        if trail.count > 1_200 {
            trail.removeFirst(trail.count - 1_200)
        }
    }

'''
content = content[:loc_start] + new_location_callback + content[loc_end:]

if 'private var horizontalAccuracyText: String' not in content:
    marker = '    private var speedAccuracyText: String {'
    idx = content.find(marker)
    if idx < 0:
        raise RuntimeError('V2.17.5b speed accuracy helper boundary not found')
    helper = r'''    private var horizontalAccuracyText: String {
        guard let location = gps.location, location.horizontalAccuracy >= 0 else { return "—" }
        return "±\(Int(location.horizontalAccuracy.rounded())) m"
    }

'''
    content = content[:idx] + helper + content[idx:]

if 'liveMetric("GPS ±", horizontalAccuracyText)' not in content:
    metric_anchor = '                            liveMetric("Altitude", altitudeText)\n                            Divider().frame(height: 28)\n'
    if metric_anchor not in content:
        raise RuntimeError('V2.17.5b live metric anchor not found')
    content = content.replace(
        metric_anchor,
        metric_anchor + '                            liveMetric("GPS ±", horizontalAccuracyText)\n                            Divider().frame(height: 28)\n',
        1,
    )

# -----------------------------------------------------------------------------
# V2.17.5b — persistent per-month offline roster archive
# -----------------------------------------------------------------------------
store_start = content.find('final class RosterStore: ObservableObject {')
store_end = content.find('\n@MainActor\nfinal class AppState:', store_start)
if store_start < 0 or store_end < 0:
    raise RuntimeError('V2.17.5b RosterStore boundaries not found')
store = content[store_start:store_end]

if '@Published private(set) var monthSnapshots:' not in store:
    store = store.replace(
        '    @Published private(set) var snapshot: RosterSnapshot?\n',
        '    @Published private(set) var snapshot: RosterSnapshot?\n'
        '    @Published private(set) var monthSnapshots: [String: RosterSnapshot] = [:]\n'
        '    @Published var selectedRosterMonthKey: String?\n',
        1,
    )

if 'var rosterMonthKeys: [String]' not in store:
    marker = '    var cachedMonth: String? { snapshot?.validation?.month }\n'
    if marker not in store:
        raise RuntimeError('V2.17.5b cachedMonth anchor not found')
    support = r'''

    private func monthKey(for snapshot: RosterSnapshot) -> String {
        if let iso = snapshot.items.compactMap(\.dateISO).first, iso.count >= 7 {
            return String(iso.prefix(7))
        }
        return snapshot.validation?.month ?? "unknown"
    }

    var rosterMonthKeys: [String] { monthSnapshots.keys.sorted() }

    var rosterViewSnapshot: RosterSnapshot? {
        if let key = selectedRosterMonthKey, let selected = monthSnapshots[key] { return selected }
        return snapshot
    }

    var rosterViewItems: [RosterItem] { rosterViewSnapshot?.items ?? [] }

    var rosterMonthTitle: String {
        guard let key = selectedRosterMonthKey ?? snapshot.map(monthKey(for:)), key.count == 7 else {
            return rosterViewSnapshot?.validation?.month.nilIfEmpty ?? "Roster"
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale.current
        formatter.dateFormat = "yyyy-MM"
        guard let date = formatter.date(from: key) else { return key }
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: date)
    }

    var canSelectPreviousRosterMonth: Bool {
        guard let key = selectedRosterMonthKey, let index = rosterMonthKeys.firstIndex(of: key) else { return false }
        return index > 0
    }

    var canSelectNextRosterMonth: Bool {
        guard let key = selectedRosterMonthKey, let index = rosterMonthKeys.firstIndex(of: key) else { return false }
        return index + 1 < rosterMonthKeys.count
    }

    func selectPreviousRosterMonth() {
        guard let key = selectedRosterMonthKey,
              let index = rosterMonthKeys.firstIndex(of: key), index > 0 else { return }
        selectedRosterMonthKey = rosterMonthKeys[index - 1]
    }

    func selectNextRosterMonth() {
        guard let key = selectedRosterMonthKey,
              let index = rosterMonthKeys.firstIndex(of: key), index + 1 < rosterMonthKeys.count else { return }
        selectedRosterMonthKey = rosterMonthKeys[index + 1]
    }

    var rosterViewSummaryMetrics: [SummaryMetric] {
        let selectedItems = rosterViewItems
        let flightDays = selectedItems.filter { $0.category.uppercased() == "FLIGHT" }.count
        let sectors = selectedItems.reduce(0) { $0 + $1.sectorCount }
        let categories = Dictionary(grouping: selectedItems, by: { $0.category.uppercased() })
        return [
            SummaryMetric(label: "FLY DAYS", value: flightDays),
            SummaryMetric(label: "SECTORS", value: sectors),
            SummaryMetric(label: "POSITION", value: categories["POSITIONING"]?.count ?? 0),
            SummaryMetric(label: "RES", value: categories["RESERVE"]?.count ?? 0),
            SummaryMetric(label: "SBY", value: categories["STANDBY"]?.count ?? 0),
            SummaryMetric(label: "OFF", value: categories["OFF"]?.count ?? 0)
        ].filter { $0.value > 0 }
    }

    var rosterViewDuty: RosterItem? {
        let todayKey = isoDay.string(from: Date())
        let operational = rosterViewItems.filter(\.isOperationalDuty)
        return operational.first(where: { ($0.dateISO ?? "") >= todayKey }) ?? operational.first
    }
'''
    store = store.replace(marker, marker + support, 1)

# Inject archive update inside ingest() after the existing save(newSnapshot), or
# after snapshot assignment if another patch has reordered persistence.
ingest_start = store.find('    func ingest(messageBody: Any) {')
ingest_end = store.find('\n    func dismissChangeNotice()', ingest_start)
if ingest_start < 0 or ingest_end < 0:
    raise RuntimeError('V2.17.5b ingest boundaries not found')
ingest = store[ingest_start:ingest_end]
archive_code = '''        let archiveKey = monthKey(for: newSnapshot)\n        monthSnapshots[archiveKey] = newSnapshot\n        selectedRosterMonthKey = archiveKey\n        saveMonthSnapshots()\n'''
if 'monthSnapshots[archiveKey] = newSnapshot' not in ingest:
    save_pos = ingest.rfind('        save(newSnapshot)\n')
    if save_pos >= 0:
        insert_at = save_pos + len('        save(newSnapshot)\n')
    else:
        snapshot_pos = ingest.rfind('        snapshot = newSnapshot\n')
        if snapshot_pos < 0:
            raise RuntimeError('V2.17.5b ingest persistence point not found')
        insert_at = snapshot_pos + len('        snapshot = newSnapshot\n')
    ingest = ingest[:insert_at] + archive_code + ingest[insert_at:]
    store = store[:ingest_start] + ingest + store[ingest_end:]

# clearCache: clear both legacy cache and month archive.
clear_start = store.find('    func clearCache() {')
clear_end = store.find('\n    private func parseActivity', clear_start)
if clear_start < 0 or clear_end < 0:
    raise RuntimeError('V2.17.5b clearCache boundaries not found')
clear_body = store[clear_start:clear_end]
if 'monthSnapshots = [:]' not in clear_body:
    clear_body = clear_body.replace(
        '        snapshot = nil\n',
        '        snapshot = nil\n        monthSnapshots = [:]\n        selectedRosterMonthKey = nil\n',
        1,
    )
    clear_body = clear_body.replace(
        '        try? FileManager.default.removeItem(at: cacheURL)\n',
        '        try? FileManager.default.removeItem(at: cacheURL)\n        try? FileManager.default.removeItem(at: monthCacheURL)\n',
        1,
    )
    store = store[:clear_start] + clear_body + store[clear_end:]

# Persistence: add month archive URL/save and make load migrate the old cache.
if 'private var monthCacheURL: URL' not in store:
    save_start = store.find('    private func save(_ snapshot: RosterSnapshot) {')
    load_start = store.find('    private func load() {', save_start)
    if save_start < 0 or load_start < 0:
        raise RuntimeError('V2.17.5b persistence boundaries not found')
    month_helpers = r'''    private var monthCacheURL: URL {
        cacheURL.deletingLastPathComponent().appendingPathComponent("roster-months.json")
    }

    private func saveMonthSnapshots() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(monthSnapshots) {
            try? data.write(to: monthCacheURL, options: .atomic)
        }
    }

'''
    store = store[:save_start] + month_helpers + store[save_start:]

# Replace load() through class end with archive-aware migration while keeping
# any methods before it intact. load() is the final method in RosterStore.
load_start = store.find('    private func load() {')
if load_start < 0:
    raise RuntimeError('V2.17.5b load boundary not found')
# Find matching method end by brace counting.
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

load_end = block_end(store, load_start)
if load_end < 0:
    raise RuntimeError('V2.17.5b load method end not found')
new_load = r'''    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: monthCacheURL),
           let months = try? decoder.decode([String: RosterSnapshot].self, from: data) {
            monthSnapshots = months
        }

        if let data = try? Data(contentsOf: cacheURL),
           let latest = try? decoder.decode(RosterSnapshot.self, from: data) {
            snapshot = latest
            let key = monthKey(for: latest)
            monthSnapshots[key] = latest
            selectedRosterMonthKey = key
            saveMonthSnapshots()
        } else if let key = monthSnapshots.keys.sorted().last {
            snapshot = monthSnapshots[key]
            selectedRosterMonthKey = key
        }
    }'''
store = store[:load_start] + new_load + store[load_end:]
content = content[:store_start] + store + content[store_end:]

# -----------------------------------------------------------------------------
# First tab — previous/next cached month navigation
# -----------------------------------------------------------------------------
home_start = content.find('struct RosterHomeView: View {')
home_end = content.find('\nstruct TodayView: View {', home_start)
if home_start < 0 or home_end < 0:
    raise RuntimeError('V2.17.5b RosterHomeView boundaries not found')
home = content[home_start:home_end]

if 'rosterMonthNavigator' not in home.split('private var statusHeader')[0]:
    home = home.replace(
        '                    statusHeader\n',
        '                    statusHeader\n\n                    if store.hasCache {\n                        rosterMonthNavigator\n                    }\n',
        1,
    )

home = home.replace('if let duty = store.nextDuty {', 'if let duty = store.rosterViewDuty {', 1)
home = home.replace('if !store.summaryMetrics.isEmpty {', 'if !store.rosterViewSummaryMetrics.isEmpty {', 1)
home = home.replace('ForEach(Array(store.upcomingItems.prefix(31))) { item in', 'ForEach(store.rosterViewItems) { item in', 1)
home = home.replace('ForEach(store.summaryMetrics) { metric in', 'ForEach(store.rosterViewSummaryMetrics) { metric in', 1)

if 'private var rosterMonthNavigator: some View' not in home:
    marker = '    private var statusHeader: some View {'
    idx = home.find(marker)
    if idx < 0:
        raise RuntimeError('V2.17.5b statusHeader insertion boundary not found')
    navigator = r'''    private var rosterMonthNavigator: some View {
        HStack(spacing: 12) {
            Button { store.selectPreviousRosterMonth() } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.bordered)
            .disabled(!store.canSelectPreviousRosterMonth)
            .accessibilityLabel("Previous cached roster month")

            VStack(spacing: 2) {
                Text(store.rosterMonthTitle)
                    .font(.headline)
                Text("Offline roster")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Button { store.selectNextRosterMonth() } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.bordered)
            .disabled(!store.canSelectNextRosterMonth)
            .accessibilityLabel("Next cached roster month")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }

'''
    home = home[:idx] + navigator + home[idx:]

content = content[:home_start] + home + content[home_end:]

# Version presentation / project metadata. Keep replacements tolerant if an
# earlier patch already changed one occurrence.
content = content.replace('LabeledContent("RAIDO Roster", value: "2.17")', 'LabeledContent("RAIDO Roster", value: "2.17.5")')
content = content.replace('LabeledContent("RAIDO Roster", value: "2.17.4")', 'LabeledContent("RAIDO Roster", value: "2.17.5")')
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = re.sub(r'CURRENT_PROJECT_VERSION = \d+;', 'CURRENT_PROJECT_VERSION = 40;', pbx)
pbx = re.sub(r'MARKETING_VERSION = [0-9.]+;', 'MARKETING_VERSION = 2.17.5;', pbx)
PBX.write_text(pbx)

print('V2.17.5b robust GPS + multi-month offline roster patch applied')
