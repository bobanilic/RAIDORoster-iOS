"""V2.26.1: bounded Fleet refresh and indexed roster presentation."""
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / 'RAIDORoster/ContentView.swift'
PBX = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
s, pbx = CONTENT.read_text(), PBX.read_text()
MARKER = '// V2.26.1 bounded Fleet refresh'
if MARKER in s:
    if 'FleetRefreshPolicy.run(' not in s or 'B22700000000000000000001' not in pbx:
        raise RuntimeError('Incomplete V2.26.1 installation')
    print('V2.26.1 Fleet responsiveness already applied')
    raise SystemExit(0)
def once(text, old, new):
    if text.count(old) != 1: raise RuntimeError('V2.26.1 anchor count: ' + repr(old[:100]))
    return text.replace(old, new, 1)
ms = s.index('@MainActor\nprivate final class FleetLiveStore:')
me = s.index('\nprivate enum FleetFilter:', ms)
m = s[ms:me]
m = once(m, '    @Published private(set) var completedCount = 0\n', '')
m = once(m, '    init() {\n        loadCache()\n    }', '''    private let session: URLSession
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }
    private var intelligenceCache: [String: FleetAircraftIntelligence] = [:]
    private var intelligenceBucket = -1
    private var cacheApplied = false
    private let cacheLoad: Task<([FleetLiveSnapshot], [String: [FleetTrackObservation]]), Never>
    private let cacheWriter = FleetCacheWriter()

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
        cacheLoad = Task.detached(priority: .utility) {
            let defaults = UserDefaults.standard
            let decoder = JSONDecoder()
            let values = defaults.data(forKey: "RAIDORoster.FleetLiveCache.V1")
                .flatMap { try? decoder.decode([FleetLiveSnapshot].self, from: $0) } ?? []
            let history = defaults.data(forKey: "RAIDORoster.FleetHistory.V2")
                .flatMap { try? decoder.decode([String: [FleetTrackObservation]].self, from: $0) } ?? [:]
            return (values, history)
        }
        Task { [weak self] in await self?.loadCache() }
    }''')
rs = m.index('        guard !isRefreshing, retryAfter')
re_ = m.index('        if !activeForRoutes.isEmpty,', rs)
m = m[:rs] + '''        await loadCache()
        // A view-owned manual restart cancels the previous pass. Wait for its
        // cooperative requests to unwind before acquiring the refresh slot.
        while isRefreshing {
            do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return }
        }
        guard !Task.isCancelled, retryAfter.map({ Date() >= $0 }) ?? true else { return }
        isRefreshing = true
        errorText = nil
        defer { isRefreshing = false }

        var fresh: [String: FleetLiveSnapshot] = [:]
        var activeForRoutes: [(registration: String, callsign: String, lat: Double, lon: Double)] = []
        var failures = 0
        var pending: [String: FleetLiveSnapshot] = [:]
        var lastPublish = Date.distantPast
        let report = await FleetRefreshPolicy.run(definitions, operation: { definition in
            do { return (definition.registration, try await self.fetchAircraft(definition.registration), false) }
            catch { return (definition.registration, nil, !Task.isCancelled) }
        }, receive: { result in
            let (registration, snapshot, failed) = result
            if failed { failures += 1 }
            if let snapshot {
                fresh[registration] = snapshot
                pending[registration] = snapshot
                if let callsign = snapshot.callsign, let lat = snapshot.latitude, let lon = snapshot.longitude,
                   !callsign.isEmpty { activeForRoutes.append((registration, callsign, lat, lon)) }
                if Date().timeIntervalSince(lastPublish) >= 1 {
                    self.publish(pending); pending.removeAll(); lastPublish = Date()
                }
            }
        })
        guard !Task.isCancelled else { return }
        publish(pending)

''' + m[re_:]
m = once(m, '        if !activeForRoutes.isEmpty,', '        if !report.timedOut, !Task.isCancelled, !activeForRoutes.isEmpty,')
m = once(m, '        recordFreshHistory(fresh)\n', '        guard !Task.isCancelled else { return }\n        recordFreshHistory(fresh)\n')
a = m.index('        // Preserve a previous observation')
b = m.index('\n    func snapshot(for', a)
m = m[:a] + '''        publish(fresh)
        lastRefresh = Date()
        let savedSnapshots = Array(snapshots.values), savedHistories = histories
        await cacheWriter.save(snapshots: savedSnapshots, histories: savedHistories)
        guard !Task.isCancelled else { return }
        if report.timedOut {
            errorText = "Refresh timed out · showing available observations. Tap refresh to retry."
        } else if failures > 0 {
            errorText = failures == definitions.count ? "Live fleet data unavailable" : "Some aircraft could not be refreshed"
        }
    }

    private func publish(_ fresh: [String: FleetLiveSnapshot]) {
        guard !fresh.isEmpty else { return }
        var merged = snapshots
        for (registration, snapshot) in fresh { merged[registration] = snapshot }
        intelligenceCache.removeAll()
        snapshots = merged
    }
''' + m[b:]
m = once(m, '        guard let snapshot = snapshots[registration] else { return nil }', '''        let bucket = Int(Date().timeIntervalSince1970 / 15)
        if bucket != intelligenceBucket { intelligenceCache.removeAll(); intelligenceBucket = bucket }
        if let cached = intelligenceCache[registration] { return cached }
        guard let snapshot = snapshots[registration] else { return nil }''')
m = once(m, '        return FleetAircraftIntelligence(\n', '        let value = FleetAircraftIntelligence(\n')
m = once(m, '            observationCount: history.count\n        )\n', '            observationCount: history.count\n        )\n        intelligenceCache[registration] = value\n        return value\n')
m = once(m, '    private func recordFreshHistory(_ fresh: [String: FleetLiveSnapshot]) {\n', '    private func recordFreshHistory(_ fresh: [String: FleetLiveSnapshot]) {\n        var updated = histories\n')
m = once(m, '            var values = histories[registration] ?? []', '            var values = updated[registration] ?? []')
m = once(m, '            histories[registration] = values\n        }\n        saveHistory()', '            updated[registration] = values\n        }\n        intelligenceCache.removeAll()\n        histories = updated')
m = m.replace('URLSession.shared.data(for: request)', 'session.data(for: request)')
m = m.replace('request.timeoutInterval = 7', 'request.timeoutInterval = 5')
m = once(m, 'let result = try decoder.decode(ADSBLOLResponse.self, from: data)', 'let result = try await Task.detached { try JSONDecoder().decode(ADSBLOLResponse.self, from: data) }.value')
a = m.index('    private func loadCache() {')
m = m[:a] + '''    private func loadCache() async {
        let (values, history) = await cacheLoad.value
        guard !cacheApplied else { return }
        cacheApplied = true
        var restored: [String: FleetLiveSnapshot] = [:]
        for value in values {
            if restored[value.registration].map({ $0.fetchedAt > value.fetchedAt }) != true {
                restored[value.registration] = value
            }
        }
        snapshots = restored
        lastRefresh = values.map(\\.fetchedAt).max()
        histories = history.mapValues { Array($0.sorted { $0.observedAt < $1.observedAt }.suffix(maximumHistoryPerAircraft)) }
    }
}

private actor FleetCacheWriter {
    func save(snapshots: [FleetLiveSnapshot], histories: [String: [FleetTrackObservation]]) {
        let encoder = JSONEncoder(), defaults = UserDefaults.standard
        if let data = try? encoder.encode(snapshots) { defaults.set(data, forKey: "RAIDORoster.FleetLiveCache.V1") }
        if let data = try? encoder.encode(histories) { defaults.set(data, forKey: "RAIDORoster.FleetHistory.V2") }
    }
}
'''
s = s[:ms] + m + s[me:]
vs = s.index('struct FleetView: View {')
ve = s.index('\nprivate func fleetDuration', vs)
v = s[vs:ve]
v = once(v, '    @Environment(\\.dismiss) private var dismiss', '    @Environment(\\.dismiss) private var dismiss\n    @Environment(\\.scenePhase) private var scenePhase')
a = v.index('    private var currentDutyRegistrations:')
b = v.index('    private var rosterLearnedAircraft:', a)
v = v[:a] + '''    @State private var currentDutyRegistrations: Set<String> = []
    @State private var rosterIndex = FleetRosterIndex()
    @State private var learnedAircraft: [FleetAircraftDefinition] = []
    @State private var refreshNonce = 0
    @State private var contextTask: Task<Void, Never>?

    private func updateDuty() {
        let rows = store.todayItems + (store.nextDuty.map { [$0] } ?? [])
        currentDutyRegistrations = Set(rows.flatMap(\\.aircraft).map {
            FleetTrackingPolicy.normalizedRegistration($0.aircraftReg)
        }.filter { !$0.isEmpty })
    }

    private func updateRosterContext() {
        updateDuty()
        let records = store.items.flatMap(\\.flightActivities).map {
            FleetRosterEvidence(aircraftReg: $0.aircraftReg, aircraftType: $0.aircraftType,
                                route: $0.route, startUTC: $0.startUTC, endUTC: $0.endUTC)
        }
        let stations = store.items.flatMap(\\.activityList).map(\\.station).filter { !$0.isEmpty }
        let rows = store.todayItems + (store.nextDuty.map { [$0] } ?? [])
        let preferred = rows.flatMap(\\.activityList).map(\\.station).filter { !$0.isEmpty }
        contextTask?.cancel()
        contextTask = Task {
            let index = await Task.detached(priority: .userInitiated) {
                FleetRosterIndex(records, stations: stations, preferred: preferred)
            }.value
            guard !Task.isCancelled else { return }
            rosterIndex = index
            learnedAircraft = rosterLearnedAircraft
        }
    }

''' + v[b:]
v = once(v, 'for activity in store.items.flatMap(\\.flightActivities) {', 'for activity in rosterIndex.activities {')
v = once(v, 'if let stamp = parseUTCStamp(activity.endUTC) ?? parseUTCStamp(activity.startUTC),', 'if let stamp = activity.end ?? activity.start,')
v = once(v, 'FleetAircraftDefinition.all + rosterLearnedAircraft', 'FleetAircraftDefinition.all + learnedAircraft')
a = v.index('    private var rotationAirport:')
b = v.index('    private enum FleetEvidenceBand:', a)
v = v[:a] + '''    private var rotationAirport: String? { rosterIndex.rotationAirport }
    private var rosterRotationRegistrations: Set<String> { rosterIndex.rotationRegistrations }

''' + v[b:]
a = v.index('    private func rosterActivities(')
b = v.index('    private func evidenceBand(', a)
v = v[:a] + '''    private func rosterActivities(for aircraft: FleetAircraftDefinition) -> [FleetRosterEvidence] {
        rosterIndex.byRegistration[FleetTrackingPolicy.normalizedRegistration(aircraft.registration)] ?? []
    }

    private func rosterAge(for aircraft: FleetAircraftDefinition, now: Date = Date()) -> TimeInterval? {
        rosterIndex.latest[FleetTrackingPolicy.normalizedRegistration(aircraft.registration)]
            .map { max(0, now.timeIntervalSince($0)) }
    }

''' + v[b:]
a = v.index('        let key = FleetTrackingPolicy.normalizedRegistration(aircraft.registration)', v.index('    private func rosterStatus('))
b = v.index('        guard !activities.isEmpty', a)
v = v[:a] + '        let activities = rosterActivities(for: aircraft)\n' + v[b:]
v = v.replace('parseUTCStamp(a.startUTC)', 'a.start').replace('parseUTCStamp(a.endUTC)', 'a.end').replace('(RosterActivity, Date)?', '(FleetRosterEvidence, Date)?')
v = once(v, '    var body: some View {\n        NavigationStack {', '''    var body: some View {
        // Evaluate the sections once per render, not again for every count/row.
        let assignedAircraft = self.assignedAircraft
        let rotationAircraft = self.rotationAircraft
        let activeFleet = self.activeFleet
        let otherFleet = self.otherFleet
        return NavigationStack {''')
v = once(v, 'Button { Task { await live.refresh(definitions: refreshAircraft) } } label:', 'Button { refreshNonce += 1 } label:')
v = once(v, '                    .disabled(live.isRefreshing)\n                    .accessibilityLabel("Refresh fleet")', '                    .accessibilityLabel(live.isRefreshing ? "Restart fleet refresh" : "Refresh fleet")')
a = v.index('            .task(id: allAircraft.map(')
v = v[:a] + '''            .onChange(of: store.lastSync, initial: true) { _, _ in updateRosterContext() }
            .onDisappear { contextTask?.cancel() }
            .task(id: "\\(scenePhase)-\\(refreshNonce)-" + allAircraft.map(\\.registration).sorted().joined(separator: "|")) {
                guard scenePhase == .active else { return }
                updateDuty()
                await live.refresh(definitions: refreshAircraft)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    updateDuty()
                    await live.refresh(definitions: refreshAircraft)
                }
            }
        }
    }
}
'''
s = s[:vs] + v + s[ve:]
s = once(s, 'LabeledContent("RAIDO Roster", value: "2.26.0")', 'LabeledContent("RAIDO Roster", value: "2.26.1")')
s += '\n' + MARKER + '\n'
name = 'FleetRefreshPolicy.swift'
if not (ROOT / 'RAIDORoster' / name).is_file(): raise RuntimeError(name + ' missing')
build_id, file_id = 'A22700000000000000000001', 'B22700000000000000000001'
pbx = once(pbx, '/* End PBXBuildFile section */', f'\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};\n/* End PBXBuildFile section */')
pbx = once(pbx, '/* End PBXFileReference section */', f'\t\t{file_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */')
pbx = once(pbx, 'B00000000000000000000002 /* ContentView.swift */,', f'B00000000000000000000002 /* ContentView.swift */,\n\t\t\t\t{file_id} /* {name} */,')
pbx = once(pbx, 'A00000000000000000000002 /* ContentView.swift in Sources */,', f'A00000000000000000000002 /* ContentView.swift in Sources */, {build_id} /* {name} in Sources */,')
pbx = re.sub(r'MARKETING_VERSION = [^;]+;', 'MARKETING_VERSION = 2.26.1;', pbx)
pbx = re.sub(r'CURRENT_PROJECT_VERSION = [^;]+;', 'CURRENT_PROJECT_VERSION = 2261;', pbx)
PBX.write_text(pbx)
CONTENT.write_text(s)
print('V2.26.1 Fleet responsiveness applied')
