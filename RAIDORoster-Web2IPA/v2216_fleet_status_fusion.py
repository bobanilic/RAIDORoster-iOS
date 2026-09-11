"""V2.23.0 Fleet status fusion: canonical tails + status-first operational cards."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster/ContentView.swift"
content = CONTENT.read_text()
if "// Fleet status fusion 2.23.0" in content:
    raise RuntimeError("Run Fleet status fusion on a clean checkout")

fleet_start = content.find("struct FleetView: View {")
fleet_end = content.find("private func fleetDuration", fleet_start)
if fleet_start < 0 or fleet_end < 0:
    raise RuntimeError("Fleet status fusion: FleetView boundaries missing")
fleet = content[fleet_start:fleet_end]

old = '            let registration = activity.aircraftReg.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()\n'
new = '            let registration = FleetTrackingPolicy.canonicalRegistration(activity.aircraftReg)\n'
if fleet.count(old) != 1:
    raise RuntimeError("Fleet status fusion: learned registration anchor mismatch")
fleet = fleet.replace(old, new, 1)

anchor = '    private func rotationContext(_ aircraft: FleetAircraftDefinition) -> String? {\n'
if fleet.count(anchor) != 1:
    raise RuntimeError("Fleet status fusion: rotation context anchor mismatch")

helpers = r'''    private func fleetRoute(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if let pair = FleetTrackingPolicy.routeAirports(raw) {
            return "\(pair.origin) → \(pair.destination)"
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value.replacingOccurrences(of: "-", with: " → ")
    }

    private func fleetAge(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private func rosterStatus(_ aircraft: FleetAircraftDefinition, now: Date = Date()) -> String? {
        let key = FleetTrackingPolicy.normalizedRegistration(aircraft.registration)
        let activities = store.items.flatMap(\.flightActivities).filter {
            FleetTrackingPolicy.normalizedRegistration($0.aircraftReg) == key
        }
        guard !activities.isEmpty else { return nil }

        if let current = activities.first(where: { a in
            guard let start = parseUTCStamp(a.startUTC), let end = parseUTCStamp(a.endUTC) else { return false }
            return now >= start && now < end
        }) {
            return "ROSTER FLIGHT · \(fleetRoute(current.route) ?? "Sector")"
        }

        let future = activities.compactMap { a -> (RosterActivity, Date)? in
            guard let start = parseUTCStamp(a.startUTC), start > now else { return nil }
            return (a, start)
        }.sorted { $0.1 < $1.1 }
        if let next = future.first, next.1.timeIntervalSince(now) <= 24 * 3600 {
            return "NEXT ROSTER FLIGHT · \(fleetRoute(next.0.route) ?? "Sector") · in \(fleetAge(next.1.timeIntervalSince(now)))"
        }

        let recent = activities.compactMap { a -> (RosterActivity, Date)? in
            guard let end = parseUTCStamp(a.endUTC), end <= now else { return nil }
            return (a, end)
        }.sorted { $0.1 > $1.1 }
        if let last = recent.first, now.timeIntervalSince(last.1) <= 6 * 3600 {
            return "ROSTER SECTOR ENDED · \(fleetRoute(last.0.route) ?? "Sector") · \(fleetAge(now.timeIntervalSince(last.1))) ago"
        }
        return nil
    }

    private func primaryStatus(_ aircraft: FleetAircraftDefinition, now: Date = Date()) -> String {
        let snapshot = live.snapshot(for: aircraft.registration)
        let intelligence = live.intelligence(for: aircraft.registration)
        let route = fleetRoute(intelligence?.currentRoute ?? snapshot?.route)

        if let snapshot, snapshot.isFresh, snapshot.hasKnownGroundState {
            if snapshot.onGround {
                return intelligence?.nearestAirport.map { "ON GROUND · \($0)" } ?? "ON GROUND"
            }
            let raw = intelligence?.phase.rawValue.uppercased() ?? "AIRBORNE"
            let phase = raw == "UNKNOWN" ? "AIRBORNE" : raw
            return route.map { "\(phase) · \($0)" } ?? phase
        }

        if let snapshot, snapshot.isRecent, snapshot.hasKnownGroundState {
            if snapshot.onGround {
                return intelligence?.nearestAirport.map { "LAST CONFIRMED ON GROUND · \($0)" } ?? "LAST CONFIRMED ON GROUND"
            }
            return route.map { "LAST SEEN AIRBORNE · \($0)" } ?? "LAST SEEN AIRBORNE"
        }

        if let intelligence, let arrival = intelligence.lastArrivalAt,
           now.timeIntervalSince(arrival) >= 0, now.timeIntervalSince(arrival) <= 6 * 3600,
           intelligence.lastDepartureAt.map({ arrival > $0 }) ?? true {
            let airport = intelligence.nearestAirport.map { " · \($0)" } ?? ""
            return "ARRIVED\(airport) · \(fleetAge(now.timeIntervalSince(arrival))) ago"
        }

        return rosterStatus(aircraft, now: now) ?? "STATUS UNKNOWN"
    }

    private func sourceStatus(_ aircraft: FleetAircraftDefinition) -> String {
        guard let snapshot = live.snapshot(for: aircraft.registration) else {
            return rosterStatus(aircraft) == nil ? "No live or recent tracking evidence" : "Roster evidence · live position unavailable"
        }
        let source = snapshot.providerName ?? "public ADS-B"
        var values = [snapshot.isFresh ? "\(source) · \(fleetCompactAge(snapshot.effectivePositionAge))" : "Last ADS-B · \(fleetCompactAge(snapshot.effectivePositionAge)) · \(source)"]
        if let callsign = snapshot.callsign?.trimmingCharacters(in: .whitespacesAndNewlines), !callsign.isEmpty { values.append(callsign) }
        if snapshot.isFresh, !snapshot.onGround, let altitude = snapshot.altitudeFeet { values.append("\(Int(altitude.rounded()).formatted()) ft") }
        if snapshot.isFresh, let speed = snapshot.groundSpeedKnots, speed.isFinite, speed > 30 { values.append("\(Int(speed.rounded())) kt") }
        return values.joined(separator: " · ")
    }

'''
fleet = fleet.replace(anchor, helpers + anchor, 1)

# Existing rotation context becomes secondary evidence only.
old_fallback = '''        if intelligence?.nearestAirport == airport { return "Last seen near \\(airport)" }\n        if rosterRotationRegistrations.contains(FleetTrackingPolicy.normalizedRegistration(aircraft.registration)) {\n            return "Used on your \\(airport) rotation"\n        }\n'''
new_fallback = '''        if intelligence?.nearestAirport == airport { return "Last seen near \\(airport)" }\n        if rosterRotationRegistrations.contains(FleetTrackingPolicy.normalizedRegistration(aircraft.registration)) {\n            return "Used on your \\(airport) rotation"\n        }\n'''
if fleet.count(old_fallback) != 1:
    raise RuntimeError("Fleet status fusion: rotation fallback anchor mismatch")
fleet = fleet.replace(old_fallback, new_fallback, 1)

replacements = [
('''FleetAircraftRow(aircraft: aircraft,\n                                snapshot: live.snapshot(for: aircraft.registration), isAssigned: true,\n                                contextText: { rotationContext(aircraft) })''', '''FleetAircraftRow(aircraft: aircraft,
                                snapshot: live.snapshot(for: aircraft.registration), isAssigned: true,
                                primaryStatus: { primaryStatus(aircraft) },
                                contextText: { rotationContext(aircraft) },
                                sourceText: { sourceStatus(aircraft) })'''),
('''FleetAircraftRow(aircraft: aircraft,\n                                snapshot: live.snapshot(for: aircraft.registration), isAssigned: false,\n                                contextText: { rotationContext(aircraft) })''', '''FleetAircraftRow(aircraft: aircraft,
                                snapshot: live.snapshot(for: aircraft.registration), isAssigned: false,
                                primaryStatus: { primaryStatus(aircraft) },
                                contextText: { rotationContext(aircraft) },
                                sourceText: { sourceStatus(aircraft) })'''),
('''FleetAircraftRow(aircraft: aircraft,\n                                snapshot: live.snapshot(for: aircraft.registration), isAssigned: false)''', '''FleetAircraftRow(aircraft: aircraft,
                                snapshot: live.snapshot(for: aircraft.registration), isAssigned: false,
                                primaryStatus: { primaryStatus(aircraft) },
                                sourceText: { sourceStatus(aircraft) })''')]
for before, after in replacements:
    if before not in fleet:
        raise RuntimeError("Fleet status fusion: row call anchor missing")
    fleet = fleet.replace(before, after)

content = content[:fleet_start] + fleet + content[fleet_end:]

row_start = content.find("private struct FleetAircraftRow: View {")
row_end = content.find("private struct FleetAircraftDetailView: View {", row_start)
if row_start < 0 or row_end < 0:
    raise RuntimeError("Fleet status fusion: FleetAircraftRow boundaries missing")
row = r'''private struct FleetAircraftRow: View {
    let aircraft: FleetAircraftDefinition
    let snapshot: FleetLiveSnapshot?
    let isAssigned: Bool
    var primaryStatus: (() -> String)? = nil
    var contextText: (() -> String?)? = nil
    var sourceText: (() -> String)? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            HStack(spacing: 14) {
                Image(systemName: "airplane")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(aircraft.registration) · \(aircraft.type)")
                        .font(.headline.weight(.semibold))
                    Text(primaryStatus?() ?? "STATUS UNKNOWN")
                        .font(.subheadline.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let context = contextText?(), !context.isEmpty {
                        Text(context)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(sourceText?() ?? "Live position unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5)
            .accessibilityElement(children: .combine)
        }
    }
}

'''
content = content[:row_start] + row + content[row_end:]
content += "\n// Fleet status fusion 2.23.0\n"
CONTENT.write_text(content)
print("V2.23.0 status-first Fleet fusion applied")
