"""V2.23.0 Fleet status fusion: canonical RAIDO tails + useful roster-backed status."""
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

old_registration = '''            let registration = activity.aircraftReg.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()\n'''
new_registration = '''            let registration = FleetTrackingPolicy.canonicalRegistration(activity.aircraftReg)\n'''
if fleet.count(old_registration) != 1:
    raise RuntimeError("Fleet status fusion: learned registration anchor mismatch")
fleet = fleet.replace(old_registration, new_registration, 1)

rotation_anchor = '''    private func rotationContext(_ aircraft: FleetAircraftDefinition) -> String? {\n'''
if fleet.count(rotation_anchor) != 1:
    raise RuntimeError("Fleet status fusion: rotation context anchor mismatch")

roster_helper = r'''    private func rosterStatus(_ aircraft: FleetAircraftDefinition, now: Date = Date()) -> String? {
        let key = FleetTrackingPolicy.normalizedRegistration(aircraft.registration)
        guard !key.isEmpty else { return nil }

        let activities = store.items.flatMap(\.flightActivities).filter {
            FleetTrackingPolicy.normalizedRegistration($0.aircraftReg) == key
        }
        guard !activities.isEmpty else { return nil }

        func routeText(_ activity: RosterActivity) -> String {
            let route = activity.route.trimmingCharacters(in: .whitespacesAndNewlines)
            return route.isEmpty ? "Roster sector" : route.replacingOccurrences(of: "-", with: " → ")
        }

        if let current = activities.first(where: { activity in
            guard let start = parseUTCStamp(activity.startUTC),
                  let end = parseUTCStamp(activity.endUTC) else { return false }
            return now >= start && now < end
        }) {
            return "Roster now · \(routeText(current))"
        }

        let future = activities.compactMap { activity -> (RosterActivity, Date)? in
            guard let start = parseUTCStamp(activity.startUTC), start > now else { return nil }
            return (activity, start)
        }.sorted { $0.1 < $1.1 }
        if let next = future.first, next.1.timeIntervalSince(now) <= 24 * 3600 {
            let minutes = max(1, Int(next.1.timeIntervalSince(now) / 60))
            let countdown = minutes >= 60
                ? "\(minutes / 60)h \(minutes % 60)m"
                : "\(minutes)m"
            return "Next roster · \(routeText(next.0)) · in \(countdown)"
        }

        let recent = activities.compactMap { activity -> (RosterActivity, Date)? in
            guard let end = parseUTCStamp(activity.endUTC), end <= now else { return nil }
            return (activity, end)
        }.sorted { $0.1 > $1.1 }
        if let last = recent.first, now.timeIntervalSince(last.1) <= 6 * 3600 {
            let minutes = max(0, Int(now.timeIntervalSince(last.1) / 60))
            let age = minutes >= 60
                ? "\(minutes / 60)h \(minutes % 60)m"
                : "\(minutes)m"
            return "Roster sector ended \(age) ago · \(routeText(last.0))"
        }

        return nil
    }

'''
fleet = fleet.replace(rotation_anchor, roster_helper + rotation_anchor, 1)

old_fallback = '''        if intelligence?.nearestAirport == airport { return "Last seen near \\(airport)" }\n        if rosterRotationRegistrations.contains(FleetTrackingPolicy.normalizedRegistration(aircraft.registration)) {\n            return "Used on your \\(airport) rotation"\n        }\n'''
new_fallback = '''        if intelligence?.nearestAirport == airport { return "Last seen near \\(airport)" }\n        if let roster = rosterStatus(aircraft) { return roster }\n        if rosterRotationRegistrations.contains(FleetTrackingPolicy.normalizedRegistration(aircraft.registration)) {\n            return "Used on your \\(airport) rotation"\n        }\n'''
if fleet.count(old_fallback) != 1:
    raise RuntimeError("Fleet status fusion: rotation fallback anchor mismatch")
fleet = fleet.replace(old_fallback, new_fallback, 1)

content = content[:fleet_start] + fleet + content[fleet_end:]

# 'No current signal' described the data source, not the aircraft state. Make
# that explicit so a silent receiver is never mistaken for a grounded aircraft.
row_start = content.find("private struct FleetAircraftRow: View {")
row_end = content.find("private struct FleetAircraftDetailView: View {", row_start)
if row_start < 0 or row_end < 0:
    raise RuntimeError("Fleet status fusion: FleetAircraftRow boundaries missing")
row = content[row_start:row_end]
if row.count('"No current signal"') != 1:
    raise RuntimeError("Fleet status fusion: no-signal label anchor mismatch")
row = row.replace('"No current signal"', '"No live ADS-B"', 1)
if row.count('"No recent position received"') != 1:
    raise RuntimeError("Fleet status fusion: no-position label anchor mismatch")
row = row.replace('"No recent position received"', '"Live position unavailable"', 1)
content = content[:row_start] + row + content[row_end:]

content += "\n// Fleet status fusion 2.23.0\n"
CONTENT.write_text(content)
print("V2.23.0 Fleet status fusion applied")
