from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster/ContentView.swift"
s = CONTENT.read_text()

if '    @State private var showOtherFleet = false\n' not in s:
    s = s.replace('    @State private var selectedAircraft: FleetAircraftDefinition?\n',
                  '    @State private var selectedAircraft: FleetAircraftDefinition?\n    @State private var showOtherFleet = false\n', 1)

old = '''            guard !key.isEmpty, !known.contains(key) else { continue }\n            known.insert(key)\n            let rawType = activity.aircraftType'''
new = '''            guard !key.isEmpty, !known.contains(key) else { continue }\n            if let stamp = parseUTCStamp(activity.endUTC) ?? parseUTCStamp(activity.startUTC),\n               Date().timeIntervalSince(stamp) > 30 * 86_400 { continue }\n            known.insert(key)\n            let rawType = activity.aircraftType'''
if old not in s: raise RuntimeError("v2218b learned-tail anchor missing")
s = s.replace(old, new, 1)

start = s.find('    private var remainingAircraft: [FleetAircraftDefinition] {')
end = s.find('    private func isRotationRelevant(_ aircraft: FleetAircraftDefinition) -> Bool {', start)
if start < 0 or end < 0: raise RuntimeError("v2218b remainder boundaries missing")
s = s[:start] + r'''    private var activeFleet: [FleetAircraftDefinition] {
        let used = Set((assignedAircraft + rotationAircraft).map {
            FleetTrackingPolicy.normalizedRegistration($0.registration)
        })
        return filteredAircraft.filter {
            !used.contains(FleetTrackingPolicy.normalizedRegistration($0.registration)) &&
            evidenceBand($0).rawValue <= FleetEvidenceBand.historical.rawValue
        }.sorted {
            let la = live.snapshot(for: $0.registration)?.effectivePositionAge ?? .infinity
            let ra = live.snapshot(for: $1.registration)?.effectivePositionAge ?? .infinity
            return la == ra ? $0.registration < $1.registration : la < ra
        }
    }

    private var otherFleet: [FleetAircraftDefinition] {
        let used = Set((assignedAircraft + rotationAircraft + activeFleet).map {
            FleetTrackingPolicy.normalizedRegistration($0.registration)
        })
        return filteredAircraft.filter {
            !used.contains(FleetTrackingPolicy.normalizedRegistration($0.registration))
        }.sorted { $0.registration < $1.registration }
    }

''' + s[end:]

start = s.find('                if remainingAircraft.isEmpty && assignedAircraft.isEmpty && rotationAircraft.isEmpty {')
end = s.find('                if let error = live.errorText {', start)
if start < 0 or end < 0: raise RuntimeError("v2218b list boundaries missing")
s = s[:start] + r'''                if activeFleet.isEmpty && otherFleet.isEmpty && assignedAircraft.isEmpty && rotationAircraft.isEmpty {
                    ContentUnavailableView.search(text: query)
                }

                if !activeFleet.isEmpty {
                    Section("ACTIVE / RECENT FLEET") {
                        ForEach(activeFleet) { aircraft in
                            FleetAircraftRow(aircraft: aircraft,
                                snapshot: live.snapshot(for: aircraft.registration), isAssigned: false,
                                primaryStatus: { primaryStatus(aircraft) },
                                sourceText: { sourceStatus(aircraft) })
                                .contentShape(Rectangle())
                                .onTapGesture { selectedAircraft = aircraft }
                        }
                    }
                }

                if !otherFleet.isEmpty {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Section {
                            DisclosureGroup(isExpanded: $showOtherFleet) {
                                ForEach(otherFleet) { aircraft in
                                    FleetAircraftRow(aircraft: aircraft,
                                        snapshot: live.snapshot(for: aircraft.registration), isAssigned: false,
                                        primaryStatus: { primaryStatus(aircraft) },
                                        sourceText: { sourceStatus(aircraft) })
                                        .contentShape(Rectangle())
                                        .onTapGesture { selectedAircraft = aircraft }
                                }
                            } label: {
                                Label("Other fleet · \(otherFleet.count) aircraft", systemImage: "airplane.circle")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    } else {
                        Section("OTHER MATCHES") {
                            ForEach(otherFleet) { aircraft in
                                FleetAircraftRow(aircraft: aircraft,
                                    snapshot: live.snapshot(for: aircraft.registration), isAssigned: false,
                                    primaryStatus: { primaryStatus(aircraft) },
                                    sourceText: { sourceStatus(aircraft) })
                                    .contentShape(Rectangle())
                                    .onTapGesture { selectedAircraft = aircraft }
                            }
                        }
                    }
                }

''' + s[end:]

for needle in ['ACTIVE / RECENT FLEET', 'Other fleet · \\(otherFleet.count) aircraft', 'showOtherFleet']:
    if needle not in s: raise RuntimeError(f"v2218b hierarchy missing {needle}")

s += "\n// Fleet hierarchy 2.23.1\n"
CONTENT.write_text(s)
print("Fleet hierarchy refinement applied")
