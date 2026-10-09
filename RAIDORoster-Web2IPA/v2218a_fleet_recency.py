from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster/ContentView.swift"
s = CONTENT.read_text()

anchor = "    private var filteredAircraft: [FleetAircraftDefinition] {"
helpers = r'''    private enum FleetEvidenceBand: Int { case live = 0, recent, aging, historical, old, none }

    private func rosterActivities(for aircraft: FleetAircraftDefinition) -> [RosterActivity] {
        let key = FleetTrackingPolicy.normalizedRegistration(aircraft.registration)
        return store.items.flatMap(\.flightActivities).filter {
            FleetTrackingPolicy.normalizedRegistration($0.aircraftReg) == key
        }
    }

    private func rosterAge(for aircraft: FleetAircraftDefinition, now: Date = Date()) -> TimeInterval? {
        let dates = rosterActivities(for: aircraft).compactMap {
            parseUTCStamp($0.endUTC) ?? parseUTCStamp($0.startUTC)
        }
        guard let last = dates.max() else { return nil }
        return max(0, now.timeIntervalSince(last))
    }

    private func evidenceBand(_ aircraft: FleetAircraftDefinition) -> FleetEvidenceBand {
        guard let age = live.snapshot(for: aircraft.registration)?.effectivePositionAge else { return .none }
        if age <= 90 { return .live }
        if age <= 1200 { return .recent }
        if age <= 10800 { return .aging }
        if age <= 86400 { return .historical }
        return .old
    }

'''
if anchor not in s: raise RuntimeError("v2218a anchor missing")
s = s.replace(anchor, helpers + anchor, 1)

start = s.find("    private func isRotationRelevant(_ aircraft: FleetAircraftDefinition) -> Bool {")
end = s.find("    private func fleetPriority(_ aircraft: FleetAircraftDefinition) -> Int {", start)
if start < 0 or end < 0: raise RuntimeError("v2218a rotation boundaries missing")
s = s[:start] + r'''    private func isRotationRelevant(_ aircraft: FleetAircraftDefinition) -> Bool {
        guard let airport = rotationAirport else { return false }
        let key = FleetTrackingPolicy.normalizedRegistration(aircraft.registration)
        if currentDutyRegistrations.contains(key) { return true }
        if let intelligence = live.intelligence(for: aircraft.registration),
           (live.snapshot(for: aircraft.registration)?.effectivePositionAge ?? .infinity) <= 10800 {
            if intelligence.nearestAirport == airport { return true }
            if let route = intelligence.currentRoute,
               FleetTrackingPolicy.rotationRelation(route: route, airport: airport) != .unrelated { return true }
        }
        return rosterRotationRegistrations.contains(key) && (rosterAge(for: aircraft) ?? .infinity) <= 604800
    }

''' + s[end:]

start = s.find("    private func primaryStatus(_ aircraft: FleetAircraftDefinition, now: Date = Date()) -> String {")
end = s.find("    private func sourceStatus(_ aircraft: FleetAircraftDefinition) -> String {", start)
if start < 0 or end < 0: raise RuntimeError("v2218a status boundaries missing")
s = s[:start] + r'''    private func primaryStatus(_ aircraft: FleetAircraftDefinition, now: Date = Date()) -> String {
        let snapshot = live.snapshot(for: aircraft.registration)
        let intelligence = live.intelligence(for: aircraft.registration)
        let route = fleetRoute(intelligence?.currentRoute ?? snapshot?.route)
        if let snapshot, snapshot.effectivePositionAge <= 90, snapshot.hasKnownGroundState {
            if snapshot.onGround { return intelligence?.nearestAirport.map { "LIVE · ON GROUND · \($0)" } ?? "LIVE · ON GROUND" }
            let raw = intelligence?.phase.rawValue.uppercased() ?? "AIRBORNE"
            let phase = raw == "UNKNOWN" ? "AIRBORNE" : raw
            return route.map { "LIVE · \(phase) · \($0)" } ?? "LIVE · \(phase)"
        }
        if let snapshot, snapshot.effectivePositionAge <= 1200, snapshot.hasKnownGroundState {
            if snapshot.onGround { return "RECENTLY ON GROUND" }
            return route.map { "RECENTLY AIRBORNE · \($0)" } ?? "RECENTLY AIRBORNE"
        }
        if let roster = rosterStatus(aircraft, now: now) { return roster }
        if let snapshot, snapshot.effectivePositionAge <= 10800, snapshot.hasKnownGroundState {
            let age = fleetAge(snapshot.effectivePositionAge)
            return snapshot.onGround ? "LAST SEEN ON GROUND · \(age)" : "LAST SEEN AIRBORNE · \(age)"
        }
        if let snapshot, snapshot.effectivePositionAge <= 86400 { return "LAST OBSERVED · \(fleetAge(snapshot.effectivePositionAge)) ago" }
        if isRotationRelevant(aircraft), let airport = rotationAirport { return "RECENT ROTATION AIRCRAFT · \(airport)" }
        return "NO RECENT TRACKING"
    }

''' + s[end:]

s = s.replace('return "Used on your \\(airport) rotation"', 'return rosterAge(for: aircraft).map { "Roster-used on \\(airport) · \\(fleetAge($0)) ago" } ?? "Roster-used on \\(airport)"')
s = s.replace('return "INFERRED ROTATION · \\(name) · \\(airport)"', 'return "CURRENT ROTATION · \\(name) · \\(airport)"')
s = s.replace('return "INFERRED ROTATION · \\(airport)"', 'return "CURRENT ROTATION · \\(airport)"')
s += "\n// Fleet recency 2.23.1\n"
CONTENT.write_text(s)
print("Fleet recency refinement applied")
