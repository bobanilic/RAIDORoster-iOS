from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.13 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# MapKit is used only for the Today route overview. No user-location tracking,
# location permission, background map work, or map content is added to Roster.
if "import MapKit" not in content:
    content = replace_once(
        content,
        "import SwiftUI\n",
        "import SwiftUI\nimport MapKit\n",
        "MapKit import",
    )

route_map = r'''
private struct TodayAirportMapPoint: Identifiable {
    let code: String
    let name: String
    let coordinate: CLLocationCoordinate2D

    var id: String { code }
}

private enum TodayAirportCoordinates {
    // Compact embedded set for current/common GetJet/AirHub European and
    // Mediterranean operations. This keeps known routes instant and offline.
    // Unknown airports simply omit the map rather than affecting roster data.
    static let airports: [String: TodayAirportMapPoint] = [
        "TLV": .init(code: "TLV", name: "Tel Aviv", coordinate: .init(latitude: 32.0005, longitude: 34.8708)),
        "BUD": .init(code: "BUD", name: "Budapest", coordinate: .init(latitude: 47.4399, longitude: 19.2610)),
        "BEG": .init(code: "BEG", name: "Belgrade", coordinate: .init(latitude: 44.8184, longitude: 20.3091)),
        "BUS": .init(code: "BUS", name: "Batumi", coordinate: .init(latitude: 41.6103, longitude: 41.5997)),
        "SKG": .init(code: "SKG", name: "Thessaloniki", coordinate: .init(latitude: 40.5197, longitude: 22.9709)),
        "CFU": .init(code: "CFU", name: "Corfu", coordinate: .init(latitude: 39.6019, longitude: 19.9117)),
        "PFO": .init(code: "PFO", name: "Paphos", coordinate: .init(latitude: 34.7180, longitude: 32.4857)),
        "LCA": .init(code: "LCA", name: "Larnaca", coordinate: .init(latitude: 34.8751, longitude: 33.6249)),
        "ATH": .init(code: "ATH", name: "Athens", coordinate: .init(latitude: 37.9364, longitude: 23.9445)),
        "RHO": .init(code: "RHO", name: "Rhodes", coordinate: .init(latitude: 36.4054, longitude: 28.0862)),
        "HER": .init(code: "HER", name: "Heraklion", coordinate: .init(latitude: 35.3397, longitude: 25.1803)),
        "CHQ": .init(code: "CHQ", name: "Chania", coordinate: .init(latitude: 35.5317, longitude: 24.1497)),
        "KGS": .init(code: "KGS", name: "Kos", coordinate: .init(latitude: 36.7933, longitude: 27.0917)),
        "VIE": .init(code: "VIE", name: "Vienna", coordinate: .init(latitude: 48.1103, longitude: 16.5697)),
        "PRG": .init(code: "PRG", name: "Prague", coordinate: .init(latitude: 50.1008, longitude: 14.2600)),
        "WAW": .init(code: "WAW", name: "Warsaw", coordinate: .init(latitude: 52.1657, longitude: 20.9671)),
        "KRK": .init(code: "KRK", name: "Krakow", coordinate: .init(latitude: 50.0777, longitude: 19.7848)),
        "SOF": .init(code: "SOF", name: "Sofia", coordinate: .init(latitude: 42.6952, longitude: 23.4062)),
        "OTP": .init(code: "OTP", name: "Bucharest", coordinate: .init(latitude: 44.5711, longitude: 26.0850)),
        "TIA": .init(code: "TIA", name: "Tirana", coordinate: .init(latitude: 41.4147, longitude: 19.7206)),
        "DBV": .init(code: "DBV", name: "Dubrovnik", coordinate: .init(latitude: 42.5614, longitude: 18.2682)),
        "SPU": .init(code: "SPU", name: "Split", coordinate: .init(latitude: 43.5389, longitude: 16.2980)),
        "ZAG": .init(code: "ZAG", name: "Zagreb", coordinate: .init(latitude: 45.7429, longitude: 16.0688)),
        "FCO": .init(code: "FCO", name: "Rome", coordinate: .init(latitude: 41.8003, longitude: 12.2389)),
        "MXP": .init(code: "MXP", name: "Milan", coordinate: .init(latitude: 45.6306, longitude: 8.7281)),
        "FRA": .init(code: "FRA", name: "Frankfurt", coordinate: .init(latitude: 50.0379, longitude: 8.5622)),
        "MUC": .init(code: "MUC", name: "Munich", coordinate: .init(latitude: 48.3538, longitude: 11.7861)),
        "BER": .init(code: "BER", name: "Berlin", coordinate: .init(latitude: 52.3667, longitude: 13.5033)),
        "AMS": .init(code: "AMS", name: "Amsterdam", coordinate: .init(latitude: 52.3105, longitude: 4.7683)),
        "CDG": .init(code: "CDG", name: "Paris", coordinate: .init(latitude: 49.0097, longitude: 2.5479)),
        "BCN": .init(code: "BCN", name: "Barcelona", coordinate: .init(latitude: 41.2974, longitude: 2.0833)),
        "MAD": .init(code: "MAD", name: "Madrid", coordinate: .init(latitude: 40.4983, longitude: -3.5676)),
        "LHR": .init(code: "LHR", name: "London", coordinate: .init(latitude: 51.4700, longitude: -0.4543)),
        "CPH": .init(code: "CPH", name: "Copenhagen", coordinate: .init(latitude: 55.6180, longitude: 12.6508)),
        "ARN": .init(code: "ARN", name: "Stockholm", coordinate: .init(latitude: 59.6519, longitude: 17.9186)),
        "OSL": .init(code: "OSL", name: "Oslo", coordinate: .init(latitude: 60.1939, longitude: 11.1004)),
        "HEL": .init(code: "HEL", name: "Helsinki", coordinate: .init(latitude: 60.3172, longitude: 24.9633)),
        "RIX": .init(code: "RIX", name: "Riga", coordinate: .init(latitude: 56.9236, longitude: 23.9711)),
        "VNO": .init(code: "VNO", name: "Vilnius", coordinate: .init(latitude: 54.6341, longitude: 25.2858)),
        "TLL": .init(code: "TLL", name: "Tallinn", coordinate: .init(latitude: 59.4133, longitude: 24.8328)),
        "TBS": .init(code: "TBS", name: "Tbilisi", coordinate: .init(latitude: 41.6692, longitude: 44.9547)),
        "KUT": .init(code: "KUT", name: "Kutaisi", coordinate: .init(latitude: 42.1767, longitude: 42.4826))
    ]
}

struct TodayRouteMapCard: View {
    let item: RosterItem
    @Environment(\.colorScheme) private var colorScheme

    static func canDisplay(_ item: RosterItem) -> Bool {
        routePoints(for: item).count >= 2
    }

    private var points: [TodayAirportMapPoint] {
        Self.routePoints(for: item)
    }

    private var coordinates: [CLLocationCoordinate2D] {
        points.map(\.coordinate)
    }

    private var airplaneCoordinate: CLLocationCoordinate2D? {
        guard coordinates.count >= 2 else { return nil }
        let a = coordinates[0]
        let b = coordinates[1]
        return CLLocationCoordinate2D(
            latitude: (a.latitude + b.latitude) / 2,
            longitude: (a.longitude + b.longitude) / 2
        )
    }

    var body: some View {
        Map(initialPosition: .automatic, interactionModes: []) {
            MapPolyline(coordinates: coordinates, contourStyle: .geodesic)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                Annotation(point.code, coordinate: point.coordinate, anchor: .center) {
                    VStack(spacing: 3) {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 12, height: 12)
                            Circle()
                                .stroke(Color.white.opacity(0.9), lineWidth: 2)
                                .frame(width: 18, height: 18)
                        }

                        if index == 0 || index == points.count - 1 || points.count <= 3 {
                            VStack(spacing: 0) {
                                Text(point.code)
                                    .font(.caption.bold())
                                    .foregroundStyle(.primary)
                                Text(point.name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }

            if let airplaneCoordinate {
                Annotation("", coordinate: airplaneCoordinate, anchor: .center) {
                    Image(systemName: "airplane")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 2)
                        .rotationEffect(.degrees(-20))
                }
            }
        }
        .mapStyle(.standard)
        .frame(height: 185)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(colorScheme == .dark ? 0.20 : 0.12), lineWidth: 1)
        }
        .accessibilityLabel("Route map " + points.map(\.code).joined(separator: " to "))
    }

    private static func routePoints(for item: RosterItem) -> [TodayAirportMapPoint] {
        let normalized = item.route
            .uppercased()
            .replacingOccurrences(of: "→", with: " ")
            .replacingOccurrences(of: "–", with: " ")
            .replacingOccurrences(of: "—", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")

        let codes = normalized
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count == 3 }

        var output: [TodayAirportMapPoint] = []
        for code in codes {
            guard let point = TodayAirportCoordinates.airports[code] else { continue }
            // Preserve a return-to-origin route (TLV-BUD-TLV), but avoid duplicate
            // adjacent tokens if RAIDO repeats a station in display text.
            if output.last?.code != point.code {
                output.append(point)
            }
        }
        return output
    }
}

'''

if "struct TodayRouteMapCard: View" not in content:
    content = replace_once(
        content,
        "struct TodayPersonalNoteDisclosure: View {\n",
        route_map + "struct TodayPersonalNoteDisclosure: View {\n",
        "Today route map component",
    )

# Today only: show the route map immediately under the main duty card. Duty
# Detail uses showTechnical=true, so it remains map-free and unchanged.
content = replace_once(
    content,
    '''        VStack(alignment: .leading, spacing: showTechnical ? 16 : 14) {
            DutyHeroCard(item: item)

            if !showTechnical {
                TodayPersonalNoteDisclosure(item: item)
            }
''',
    '''        VStack(alignment: .leading, spacing: showTechnical ? 16 : 14) {
            DutyHeroCard(item: item)

            if !showTechnical, TodayRouteMapCard.canDisplay(item) {
                TodayRouteMapCard(item: item)
            }

            if !showTechnical {
                TodayPersonalNoteDisclosure(item: item)
            }
''',
    "Today-only route map placement",
)

# Version/build jump keeps CFBundleVersion monotonic even though V2.12 visual
# patches are intentionally no longer part of the build chain.
content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.11.13")',
    'LabeledContent("RAIDO Roster", value: "2.13")',
    1,
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 26;", "CURRENT_PROJECT_VERSION = 30;")
pbx = pbx.replace("MARKETING_VERSION = 2.11.13;", "MARKETING_VERSION = 2.13;")
PBX.write_text(pbx)

print("V2.13 classic UI + Today-only MapKit route map applied")
