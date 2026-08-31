from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"

content = CONTENT.read_text()

# -----------------------------------------------------------------------------
# V2.17.5 — live flight GPS quality / speed reliability
# -----------------------------------------------------------------------------
# iOS can provide a valid CLLocation.speed while speedAccuracy is unavailable
# (-1). Do not suppress a valid ground-speed reading in that case.
old_speed = '''    private var speedText: String {\n        guard let location = gps.location,\n              location.speed >= 0,\n              location.speedAccuracy >= 0 else {\n            switch groundSpeedUnit {\n            case "kmh": return "— km/h"\n            case "mph": return "— mph"\n            default: return "— kt"\n            }\n        }\n'''
new_speed = '''    private var speedText: String {\n        guard let location = gps.location,\n              location.speed >= 0 else {\n            switch groundSpeedUnit {\n            case "kmh": return "— km/h"\n            case "mph": return "— mph"\n            default: return "— kt"\n            }\n        }\n'''
if new_speed not in content:
    if old_speed not in content:
        raise RuntimeError("V2.17.5 speedText marker not found")
    content = content.replace(old_speed, new_speed, 1)

# Reject very coarse/stale fixes before they move the aircraft marker. Prefer
# the newest usable fix from the delivered batch, preserving the last good fix
# while GPS reception is weak in the cabin.
old_location = '''    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {\n        guard let newest = locations.last(where: {\n            $0.horizontalAccuracy >= 0 &&\n            abs($0.timestamp.timeIntervalSinceNow) < 60\n        }) else { return }\n\n        location = newest\n        errorText = nil\n\n        guard newest.horizontalAccuracy <= 1_500 else { return }\n\n        if let lastCoordinate = trail.last {\n            let last = CLLocation(latitude: lastCoordinate.latitude, longitude: lastCoordinate.longitude)\n            guard newest.distance(from: last) >= 40 else { return }\n        }\n\n        trail.append(newest.coordinate)\n        if trail.count > 900 {\n            trail.removeFirst(trail.count - 900)\n        }\n    }\n'''
new_location = '''    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {\n        let recent = locations.filter {\n            $0.horizontalAccuracy >= 0 &&\n            abs($0.timestamp.timeIntervalSinceNow) < 30\n        }\n        guard !recent.isEmpty else { return }\n\n        // A multi-hundred-metre cellular/Wi-Fi estimate is visibly wrong on a\n        // flight map. Use GPS-grade fixes for the moving marker and retain the\n        // previous good fix if reception temporarily degrades.\n        guard let newest = recent.reversed().first(where: { $0.horizontalAccuracy <= 300 }) else {\n            if location == nil {\n                let best = recent.map(\\.horizontalAccuracy).min() ?? 0\n                errorText = best > 0 ? "Waiting for precise GPS (±\\(Int(best.rounded())) m)" : "Waiting for precise GPS"\n            }\n            return\n        }\n\n        location = newest\n        errorText = nil\n\n        if let lastCoordinate = trail.last {\n            let last = CLLocation(latitude: lastCoordinate.latitude, longitude: lastCoordinate.longitude)\n            guard newest.distance(from: last) >= 25 else { return }\n        }\n\n        trail.append(newest.coordinate)\n        if trail.count > 1_200 {\n            trail.removeFirst(trail.count - 1_200)\n        }\n    }\n'''
if new_location not in content:
    if old_location not in content:
        raise RuntimeError("V2.17.5 Core Location update marker not found")
    content = content.replace(old_location, new_location, 1)

# Add an explicit accuracy readout next to the existing altitude/speed metrics.
accuracy_helper = '''\n    private var horizontalAccuracyText: String {\n        guard let location = gps.location, location.horizontalAccuracy >= 0 else { return "—" }\n        return "±\\(Int(location.horizontalAccuracy.rounded())) m"\n    }\n'''
if "private var horizontalAccuracyText" not in content:
    marker = '''    private var speedAccuracyText: String {\n'''
    idx = content.find(marker)
    if idx < 0:
        raise RuntimeError("V2.17.5 speedAccuracyText marker not found")
    content = content[:idx] + accuracy_helper + "\n" + content[idx:]

old_metrics = '''                            liveMetric("Altitude", altitudeText)\n                            Divider().frame(height: 28)\n\n                            Menu {\n'''
new_metrics = '''                            liveMetric("Altitude", altitudeText)\n                            Divider().frame(height: 28)\n                            liveMetric("GPS ±", horizontalAccuracyText)\n                            Divider().frame(height: 28)\n\n                            Menu {\n'''
if new_metrics not in content:
    if old_metrics not in content:
        raise RuntimeError("V2.17.5 live metric row marker not found")
    content = content.replace(old_metrics, new_metrics, 1)

# -----------------------------------------------------------------------------
# V2.17.5 — persistent multi-month offline roster cache
# -----------------------------------------------------------------------------
old_store_state = '''final class RosterStore: ObservableObject {\n    @Published private(set) var snapshot: RosterSnapshot?\n    @Published var changeNotice: String?\n'''
new_store_state = '''final class RosterStore: ObservableObject {\n    @Published private(set) var snapshot: RosterSnapshot?\n    @Published private(set) var monthSnapshots: [String: RosterSnapshot] = [:]\n    @Published var selectedRosterMonthKey: String?\n    @Published var changeNotice: String?\n'''
if new_store_state not in content:
    if old_store_state not in content:
        raise RuntimeError("V2.17.5 RosterStore state marker not found")
    content = content.replace(old_store_state, new_store_state, 1)

old_cache_props = '''    var cachedMonth: String? { snapshot?.validation?.month }\n\n    var todayItems: [RosterItem] {\n'''
new_cache_props = '''    var cachedMonth: String? { snapshot?.validation?.month }\n\n    private func monthKey(for snapshot: RosterSnapshot) -> String {\n        if let iso = snapshot.items.compactMap(\\.dateISO).first, iso.count >= 7 {\n            return String(iso.prefix(7))\n        }\n        return snapshot.validation?.month ?? "unknown"\n    }\n\n    var rosterMonthKeys: [String] {\n        monthSnapshots.keys.sorted()\n    }\n\n    var rosterViewSnapshot: RosterSnapshot? {\n        if let key = selectedRosterMonthKey, let selected = monthSnapshots[key] { return selected }\n        return snapshot\n    }\n\n    var rosterViewItems: [RosterItem] { rosterViewSnapshot?.items ?? [] }\n\n    var rosterMonthTitle: String {\n        guard let key = selectedRosterMonthKey ?? snapshot.map(monthKey(for:)), key.count == 7 else {\n            return rosterViewSnapshot?.validation?.month.nilIfEmpty ?? "Roster"\n        }\n        let formatter = DateFormatter()\n        formatter.calendar = Calendar(identifier: .gregorian)\n        formatter.locale = Locale.current\n        formatter.dateFormat = "yyyy-MM"\n        guard let date = formatter.date(from: key) else { return key }\n        formatter.dateFormat = "LLLL yyyy"\n        return formatter.string(from: date)\n    }\n\n    var canSelectPreviousRosterMonth: Bool {\n        guard let key = selectedRosterMonthKey, let index = rosterMonthKeys.firstIndex(of: key) else { return false }\n        return index > 0\n    }\n\n    var canSelectNextRosterMonth: Bool {\n        guard let key = selectedRosterMonthKey, let index = rosterMonthKeys.firstIndex(of: key) else { return false }\n        return index + 1 < rosterMonthKeys.count\n    }\n\n    func selectPreviousRosterMonth() {\n        guard let key = selectedRosterMonthKey, let index = rosterMonthKeys.firstIndex(of: key), index > 0 else { return }\n        selectedRosterMonthKey = rosterMonthKeys[index - 1]\n    }\n\n    func selectNextRosterMonth() {\n        guard let key = selectedRosterMonthKey, let index = rosterMonthKeys.firstIndex(of: key), index + 1 < rosterMonthKeys.count else { return }\n        selectedRosterMonthKey = rosterMonthKeys[index + 1]\n    }\n\n    var rosterViewSummaryMetrics: [SummaryMetric] {\n        let selectedItems = rosterViewItems\n        let flightDays = selectedItems.filter { $0.category.uppercased() == "FLIGHT" }.count\n        let sectors = selectedItems.reduce(0) { $0 + $1.sectorCount }\n        let categories = Dictionary(grouping: selectedItems, by: { $0.category.uppercased() })\n        return [\n            SummaryMetric(label: "FLY DAYS", value: flightDays),\n            SummaryMetric(label: "SECTORS", value: sectors),\n            SummaryMetric(label: "POSITION", value: categories["POSITIONING"]?.count ?? 0),\n            SummaryMetric(label: "RES", value: categories["RESERVE"]?.count ?? 0),\n            SummaryMetric(label: "SBY", value: categories["STANDBY"]?.count ?? 0),\n            SummaryMetric(label: "OFF", value: categories["OFF"]?.count ?? 0)\n        ].filter { $0.value > 0 }\n    }\n\n    var rosterViewDuty: RosterItem? {\n        let todayKey = isoDay.string(from: Date())\n        let operational = rosterViewItems.filter(\\.isOperationalDuty)\n        return operational.first(where: { ($0.dateISO ?? "") >= todayKey }) ?? operational.first\n    }\n\n    var todayItems: [RosterItem] {\n'''
if new_cache_props not in content:
    if old_cache_props not in content:
        raise RuntimeError("V2.17.5 cached month property marker not found")
    content = content.replace(old_cache_props, new_cache_props, 1)

old_ingest_end = '''        snapshot = newSnapshot\n        save(newSnapshot)\n    }\n'''
new_ingest_end = '''        snapshot = newSnapshot\n        let key = monthKey(for: newSnapshot)\n        monthSnapshots[key] = newSnapshot\n        selectedRosterMonthKey = key\n        save(newSnapshot)\n        saveMonthSnapshots()\n    }\n'''
if new_ingest_end not in content:
    if old_ingest_end not in content:
        raise RuntimeError("V2.17.5 ingest cache marker not found")
    content = content.replace(old_ingest_end, new_ingest_end, 1)

old_clear = '''    func clearCache() {\n        snapshot = nil\n        changeNotice = nil\n        try? FileManager.default.removeItem(at: cacheURL)\n    }\n'''
new_clear = '''    func clearCache() {\n        snapshot = nil\n        monthSnapshots = [:]\n        selectedRosterMonthKey = nil\n        changeNotice = nil\n        try? FileManager.default.removeItem(at: cacheURL)\n        try? FileManager.default.removeItem(at: monthCacheURL)\n    }\n'''
if new_clear not in content:
    if old_clear not in content:
        raise RuntimeError("V2.17.5 clear cache marker not found")
    content = content.replace(old_clear, new_clear, 1)

old_persistence = '''    private func save(_ snapshot: RosterSnapshot) {\n        let encoder = JSONEncoder()\n        encoder.dateEncodingStrategy = .iso8601\n        if let data = try? encoder.encode(snapshot) {\n            try? data.write(to: cacheURL, options: .atomic)\n        }\n    }\n\n    private func load() {\n        guard let data = try? Data(contentsOf: cacheURL) else { return }\n        let decoder = JSONDecoder()\n        decoder.dateDecodingStrategy = .iso8601\n        snapshot = try? decoder.decode(RosterSnapshot.self, from: data)\n    }\n'''
new_persistence = '''    private var monthCacheURL: URL {\n        cacheURL.deletingLastPathComponent().appendingPathComponent("roster-months.json")\n    }\n\n    private func save(_ snapshot: RosterSnapshot) {\n        let encoder = JSONEncoder()\n        encoder.dateEncodingStrategy = .iso8601\n        if let data = try? encoder.encode(snapshot) {\n            try? data.write(to: cacheURL, options: .atomic)\n        }\n    }\n\n    private func saveMonthSnapshots() {\n        let encoder = JSONEncoder()\n        encoder.dateEncodingStrategy = .iso8601\n        if let data = try? encoder.encode(monthSnapshots) {\n            try? data.write(to: monthCacheURL, options: .atomic)\n        }\n    }\n\n    private func load() {\n        let decoder = JSONDecoder()\n        decoder.dateDecodingStrategy = .iso8601\n\n        if let data = try? Data(contentsOf: monthCacheURL),\n           let months = try? decoder.decode([String: RosterSnapshot].self, from: data) {\n            monthSnapshots = months\n        }\n\n        if let data = try? Data(contentsOf: cacheURL),\n           let latest = try? decoder.decode(RosterSnapshot.self, from: data) {\n            snapshot = latest\n            let key = monthKey(for: latest)\n            monthSnapshots[key] = latest\n            selectedRosterMonthKey = key\n            saveMonthSnapshots()\n        } else if let key = monthSnapshots.keys.sorted().last {\n            snapshot = monthSnapshots[key]\n            selectedRosterMonthKey = key\n        }\n    }\n'''
if new_persistence not in content:
    if old_persistence not in content:
        raise RuntimeError("V2.17.5 persistence marker not found")
    content = content.replace(old_persistence, new_persistence, 1)

# -----------------------------------------------------------------------------
# First tab: month selector + selected-month roster content
# -----------------------------------------------------------------------------
old_after_status = '''                    statusHeader\n\n                    if let notice = store.changeNotice {\n'''
new_after_status = '''                    statusHeader\n\n                    if store.hasCache {\n                        rosterMonthNavigator\n                    }\n\n                    if let notice = store.changeNotice {\n'''
if new_after_status not in content:
    if old_after_status not in content:
        raise RuntimeError("V2.17.5 roster navigator insertion marker not found")
    content = content.replace(old_after_status, new_after_status, 1)

content = content.replace('if let duty = store.nextDuty {', 'if let duty = store.rosterViewDuty {', 1)
content = content.replace('if !store.summaryMetrics.isEmpty {', 'if !store.rosterViewSummaryMetrics.isEmpty {', 1)
content = content.replace('ForEach(Array(store.upcomingItems.prefix(31))) { item in', 'ForEach(store.rosterViewItems) { item in', 1)

old_summary_foreach = '''            ForEach(store.summaryMetrics) { metric in\n'''
new_summary_foreach = '''            ForEach(store.rosterViewSummaryMetrics) { metric in\n'''
if new_summary_foreach not in content:
    if old_summary_foreach not in content:
        raise RuntimeError("V2.17.5 summary grid marker not found")
    content = content.replace(old_summary_foreach, new_summary_foreach, 1)

navigator = '''\n    private var rosterMonthNavigator: some View {\n        HStack(spacing: 12) {\n            Button { store.selectPreviousRosterMonth() } label: {\n                Image(systemName: "chevron.left")\n                    .font(.headline)\n                    .frame(width: 40, height: 40)\n            }\n            .buttonStyle(.bordered)\n            .disabled(!store.canSelectPreviousRosterMonth)\n            .accessibilityLabel("Previous cached roster month")\n\n            VStack(spacing: 2) {\n                Text(store.rosterMonthTitle)\n                    .font(.headline)\n                Text("Offline roster")\n                    .font(.caption)\n                    .foregroundStyle(.secondary)\n            }\n            .frame(maxWidth: .infinity)\n\n            Button { store.selectNextRosterMonth() } label: {\n                Image(systemName: "chevron.right")\n                    .font(.headline)\n                    .frame(width: 40, height: 40)\n            }\n            .buttonStyle(.bordered)\n            .disabled(!store.canSelectNextRosterMonth)\n            .accessibilityLabel("Next cached roster month")\n        }\n        .padding(10)\n        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))\n    }\n'''
if "private var rosterMonthNavigator" not in content:
    marker = '''    private var statusHeader: some View {\n'''
    idx = content.find(marker, content.find("struct RosterHomeView: View"))
    if idx < 0:
        raise RuntimeError("V2.17.5 statusHeader marker not found")
    content = content[:idx] + navigator + "\n" + content[idx:]

CONTENT.write_text(content)

# Keep project metadata aligned with this field-test build.
pbx = PBX.read_text()
pbx = pbx.replace("MARKETING_VERSION = 2.17;", "MARKETING_VERSION = 2.17.5;")
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 36;", "CURRENT_PROJECT_VERSION = 37;")
PBX.write_text(pbx)

print("V2.17.5 GPS telemetry + persistent offline month navigation applied")
