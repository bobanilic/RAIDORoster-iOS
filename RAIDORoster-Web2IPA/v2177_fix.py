from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"

content = CONTENT.read_text()

# -----------------------------------------------------------------------------
# V2.17.7 — make the true offline map an explicit, persistent map source and
# give the local vector canvas a conventional map-like visual treatment.
# -----------------------------------------------------------------------------
# Persist the user's map choice. "auto" keeps the current online/offline switch,
# while "offline" guarantees that MapKit tiles are never required.
old_state = '''    @StateObject private var connectivity = TodayMapConnectivityMonitor()\n    @State private var forceOfflineMap = false\n    @State private var onlineCameraPosition: MapCameraPosition = .automatic\n'''
new_state = '''    @StateObject private var connectivity = TodayMapConnectivityMonitor()\n    @AppStorage("RAIDORoster.TodayMapSource") private var todayMapSource = "auto"\n    @State private var onlineCameraPosition: MapCameraPosition = .automatic\n'''
if old_state in content:
    content = content.replace(old_state, new_state, 1)

# Replace old forceOfflineMap tests with a single explicit decision.
if 'private var useOfflineMap: Bool' not in content:
    marker = '''    private var points: [TodayAirportMapPoint] {\n'''
    idx = content.find(marker, content.find('struct TodayRouteMapCard: View {'))
    if idx < 0:
        raise RuntimeError('V2.17.7 TodayRouteMapCard points marker not found')
    helper = '''    private var useOfflineMap: Bool {\n        todayMapSource == "offline" || !connectivity.isConnected\n    }\n\n'''
    content = content[:idx] + helper + content[idx:]

content = content.replace('connectivity.isConnected && !forceOfflineMap', '!useOfflineMap')
content = content.replace('forceOfflineMap || !connectivity.isConnected', 'useOfflineMap')
content = content.replace('forceOfflineMap = false\n                                onlineCameraPosition = .automatic', 'todayMapSource = "auto"\n                                onlineCameraPosition = .automatic')
content = content.replace('forceOfflineMap = true', 'todayMapSource = "offline"')

# Map menu wording/status: make it obvious that Offline is a real local map,
# and keep the selection visible even when network state changes.
content = content.replace('Text("Apple Map (when online)")', 'Text("Apple Map / Auto")')
content = content.replace('Text("Offline aviation map")', 'Text("Offline local map")')
content = content.replace('Text(connectivity.isConnected && !forceOfflineMap ? "APPLE MAP" : "OFFLINE MAP")', 'Text(useOfflineMap ? "OFFLINE MAP" : "APPLE MAP")')
content = content.replace('Image(systemName: connectivity.isConnected && !forceOfflineMap ? "map.fill" : "airplane.circle.fill")', 'Image(systemName: useOfflineMap ? "map.circle.fill" : "map.fill")')

# Recenter branch should follow the selected source.
content = content.replace('if connectivity.isConnected && !forceOfflineMap {', 'if !useOfflineMap {')

# Improve the local map colors to look like a normal navigation map rather than
# a diagnostic aviation canvas. These replacements are deliberately narrow and
# harmless if a previous patch has already changed a value.
content = content.replace('Color.blue.opacity(colorScheme == .dark ? 0.16 : 0.10)', 'Color.blue.opacity(colorScheme == .dark ? 0.24 : 0.16)')
content = content.replace('Color.secondary.opacity(colorScheme == .dark ? 0.16 : 0.08)', 'Color.secondary.opacity(colorScheme == .dark ? 0.22 : 0.12)')

# Add a compact legend over the offline canvas so a blank MapKit tile view can
# never be mistaken for the local basemap.
if 'Text("LOCAL • NO DATA REQUIRED")' not in content:
    offline_anchor = '''                        OfflineAviationMapCanvas(\n                            points: points,\n                            trail: gps.trail,\n                            liveLocation: gps.location,\n                            isTracking: gps.isTracking,\n                            zoom: effectiveZoom,\n                            pan: effectivePan,\n                            colorScheme: colorScheme\n                        )\n'''
    offline_replacement = offline_anchor + '''                        VStack {\n                            HStack {\n                                Text("LOCAL • NO DATA REQUIRED")\n                                    .font(.system(size: 9, weight: .bold))\n                                    .foregroundStyle(.secondary)\n                                    .padding(.horizontal, 8)\n                                    .padding(.vertical, 5)\n                                    .background(Color(uiColor: .systemBackground).opacity(0.88), in: Capsule())\n                                Spacer()\n                            }\n                            Spacer()\n                        }\n                        .padding(9)\n                        .allowsHitTesting(false)\n'''
    if offline_anchor in content:
        content = content.replace(offline_anchor, offline_replacement, 1)

# -----------------------------------------------------------------------------
# V2.17.7 — Fleet status reliability.
# Public ADS-B can tell us whether an observation is airborne/on-ground and how
# old it is. It cannot prove maintenance AOG, so never fabricate AOG.
# -----------------------------------------------------------------------------
if 'var observationAge: TimeInterval' not in content:
    marker = '''    var hasPosition: Bool { latitude != nil && longitude != nil }\n\n'''
    support = '''    var observationAge: TimeInterval {\n        max(0, Date().timeIntervalSince(fetchedAt) + sourceSeenSeconds)\n    }\n\n    var isFresh: Bool { observationAge <= 120 }\n    var isRecent: Bool { observationAge <= 900 }\n    var isStale: Bool { observationAge > 900 }\n\n'''
    if marker not in content:
        raise RuntimeError('V2.17.7 FleetLiveSnapshot marker not found')
    content = content.replace(marker, marker + support, 1)

# Replace row status logic with age-aware semantics.
row_start = content.find('private struct FleetAircraftRow: View {')
row_end = content.find('\nprivate struct FleetAircraftDetailView: View {', row_start)
if row_start < 0 or row_end < 0:
    raise RuntimeError('V2.17.7 FleetAircraftRow boundaries not found')
row = content[row_start:row_end]
status_start = row.find('    private var status: (String, Color) {')
body_start = row.find('\n    var body: some View {', status_start)
if status_start < 0 or body_start < 0:
    raise RuntimeError('V2.17.7 Fleet row status boundary not found')
new_status = '''    private var status: (String, Color) {\n        guard let snapshot else { return ("No current signal", .secondary) }\n\n        if snapshot.isFresh {\n            if snapshot.isAirborne { return ("Airborne", .green) }\n            if snapshot.onGround { return ("On ground", .blue) }\n            return ("Live", .blue)\n        }\n\n        if snapshot.isRecent {\n            if snapshot.isAirborne { return ("Last seen airborne", .orange) }\n            if snapshot.onGround { return ("Last seen on ground", .orange) }\n            return ("Recently seen", .orange)\n        }\n\n        return ("Stale", .secondary)\n    }\n'''
row = row[:status_start] + new_status + row[body_start:]

# Never display a stale speed as if it were current. For recent observations,
# show age instead, which is more informative.
old_speed_block = '''                if let speed = snapshot?.groundSpeedKnots, snapshot?.isAirborne == true {\n                    Text("\\(Int(speed.rounded())) kt")\n                        .font(.caption2.monospacedDigit())\n                        .foregroundStyle(.secondary)\n                }\n'''
new_speed_block = '''                if let snapshot {\n                    if snapshot.isFresh, let speed = snapshot.groundSpeedKnots, snapshot.isAirborne {\n                        Text("\\(Int(speed.rounded())) kt")\n                            .font(.caption2.monospacedDigit())\n                            .foregroundStyle(.secondary)\n                    } else {\n                        Text(fleetCompactAge(snapshot.observationAge))\n                            .font(.caption2.monospacedDigit())\n                            .foregroundStyle(.secondary)\n                    }\n                }\n'''
if old_speed_block in row:
    row = row.replace(old_speed_block, new_speed_block, 1)
content = content[:row_start] + row + content[row_end:]

# Shared compact age helper.
if 'private func fleetCompactAge(' not in content:
    helper_marker = 'private struct FleetAircraftRow: View {'
    helper = '''private func fleetCompactAge(_ age: TimeInterval) -> String {\n    let seconds = max(0, Int(age))\n    if seconds < 60 { return "\\(seconds)s ago" }\n    if seconds < 3600 { return "\\(seconds / 60)m ago" }\n    if seconds < 86_400 { return "\\(seconds / 3600)h ago" }\n    return "\\(seconds / 86_400)d ago"\n}\n\n'''
    content = content.replace(helper_marker, helper + helper_marker, 1)

# Detail header should use the same semantics, not TRACKED for stale data.
detail_start = content.find('private struct FleetAircraftDetailView: View {')
detail_end = content.find('\nprivate struct FleetMetric: View {', detail_start)
if detail_start >= 0 and detail_end >= 0:
    detail = content[detail_start:detail_end]
    old_detail_status = 'Text(snapshot.isAirborne ? "AIRBORNE" : (snapshot.onGround ? "GROUND" : "TRACKED"))'
    new_detail_status = 'Text(snapshot.isFresh ? (snapshot.isAirborne ? "AIRBORNE" : (snapshot.onGround ? "ON GROUND" : "LIVE")) : (snapshot.isRecent ? (snapshot.isAirborne ? "LAST SEEN AIRBORNE" : (snapshot.onGround ? "LAST SEEN ON GROUND" : "RECENTLY SEEN")) : "STALE"))'
    detail = detail.replace(old_detail_status, new_detail_status)
    detail = detail.replace('Text("Last live observation \\(fleetAge(snapshot))")', 'Text("Observation \\(fleetCompactAge(snapshot.observationAge)) • public ADS-B")')
    content = content[:detail_start] + detail + content[detail_end:]

# Explain AOG limitation explicitly in Fleet footer.
content = content.replace(
    'Text("Fleet V1 does not claim operational delay unless a reliable schedule source is available. Always use RAIDO / Crew Control as the operational authority.")',
    'Text("Airborne / on-ground state comes from public ADS-B. AOG is a maintenance/operational status and is never inferred from a missing transponder signal. Use RAIDO / Crew Control for authoritative AOG or operational status.")',
    1,
)

content = content.replace('LabeledContent("RAIDO Roster", value: "2.17.6")', 'LabeledContent("RAIDO Roster", value: "2.17.7")', 1)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace('MARKETING_VERSION = 2.17.6;', 'MARKETING_VERSION = 2.17.7;')
PBX.write_text(pbx)

print('V2.17.7 persistent offline local map + age-aware Fleet statuses applied')
