from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster/ContentView.swift"
s = CONTENT.read_text()


def block_end(text: str, start: int) -> int:
    brace = text.find("{", start)
    if brace < 0:
        return -1
    depth = 0
    state = "code"
    i = brace
    while i < len(text):
        if state == "line_comment":
            if text[i] == "\n":
                state = "code"
            i += 1
            continue
        if state == "block_comment":
            if text.startswith("*/", i):
                state = "code"; i += 2
            else:
                i += 1
            continue
        if state == "string":
            if text[i] == "\\":
                i += 2
            elif text[i] == '"':
                state = "code"; i += 1
            else:
                i += 1
            continue
        if text.startswith("//", i):
            state = "line_comment"; i += 2
        elif text.startswith("/*", i):
            state = "block_comment"; i += 2
        elif text[i] == '"':
            state = "string"; i += 1
        elif text[i] == "{":
            depth += 1; i += 1
        elif text[i] == "}":
            depth -= 1; i += 1
            if depth == 0:
                return i
        else:
            i += 1
    return -1


card_start = s.find("struct TodayRouteMapCard: View {")
if card_start < 0:
    raise RuntimeError("dynamic airports: TodayRouteMapCard missing")

# Add a persistent MapKit-backed IATA resolver immediately before the card.
if "final class TodayAirportResolver" not in s:
    resolver = r'''
private struct TodayAirportCacheRecord: Codable {
    let code: String
    let name: String
    let latitude: Double
    let longitude: Double
}

@MainActor
private final class TodayAirportResolver: ObservableObject {
    static let shared = TodayAirportResolver()

    @Published private(set) var airports: [String: TodayAirportMapPoint] = [:]

    private let defaultsKey = "RAIDORoster.TodayAirportCache.V1"
    private var resolving: Set<String> = []

    private init() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([TodayAirportCacheRecord].self, from: data) else { return }
        airports = Dictionary(uniqueKeysWithValues: records.map {
            ($0.code, TodayAirportMapPoint(
                code: $0.code,
                name: $0.name,
                coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            ))
        })
    }

    func resolve(_ codes: [String]) {
        for raw in codes {
            let code = raw.uppercased()
            guard code.count == 3,
                  TodayAirportCoordinates.airports[code] == nil,
                  airports[code] == nil,
                  !resolving.contains(code) else { continue }
            resolving.insert(code)
            Task { await resolveOne(code) }
        }
    }

    private func resolveOne(_ code: String) async {
        defer { resolving.remove(code) }

        let queries = ["\(code) airport", "\(code) international airport"]
        for query in queries {
            var request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.resultTypes = .pointOfInterest
            request.pointOfInterestFilter = .including([.airport])

            guard let response = try? await MKLocalSearch(request: request).start(),
                  let item = response.mapItems.first else { continue }

            let coordinate = item.placemark.coordinate
            guard CLLocationCoordinate2DIsValid(coordinate) else { continue }

            let point = TodayAirportMapPoint(
                code: code,
                name: item.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? code,
                coordinate: coordinate
            )
            airports[code] = point
            persist()
            return
        }
    }

    private func persist() {
        let records = airports.values.map {
            TodayAirportCacheRecord(
                code: $0.code,
                name: $0.name,
                latitude: $0.coordinate.latitude,
                longitude: $0.coordinate.longitude
            )
        }.sorted { $0.code < $1.code }

        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

'''
    s = s[:card_start] + resolver + s[card_start:]
    card_start = s.find("struct TodayRouteMapCard: View {")

card_end = block_end(s, card_start)
if card_end < 0:
    raise RuntimeError("dynamic airports: TodayRouteMapCard end missing")
card = s[card_start:card_end]

# Observe cached/async airport resolution.
gps_markers = [
    "@ObservedObject private var gps = TodayLiveFlightLocationManager.shared\n",
    "@StateObject private var gps = TodayLiveFlightLocationManager()\n",
]
if "@ObservedObject private var airportResolver = TodayAirportResolver.shared" not in card:
    inserted = False
    for marker in gps_markers:
        if marker in card:
            card = card.replace(
                marker,
                marker + "    @ObservedObject private var airportResolver = TodayAirportResolver.shared\n",
                1,
            )
            inserted = True
            break
    if not inserted:
        raise RuntimeError("dynamic airports: GPS state marker missing")

# Never hide Flight Companion merely because a coordinate is not embedded yet.
old_can = '''    static func canDisplay(_ item: RosterItem) -> Bool {
        routePoints(for: item).count >= 2
    }
'''
new_can = '''    static func canDisplay(_ item: RosterItem) -> Bool {
        routeCodes(for: item).count >= 2
    }
'''
if old_can in card:
    card = card.replace(old_can, new_can, 1)
elif new_can not in card:
    raise RuntimeError("dynamic airports: canDisplay anchor missing")

# Replace static points with embedded + persistent dynamic resolution.
old_points = '''    private var points: [TodayAirportMapPoint] {
        Self.routePoints(for: item)
    }
'''
new_points = '''    private var routeCodes: [String] {
        Self.routeCodes(for: item)
    }

    private var points: [TodayAirportMapPoint] {
        var output: [TodayAirportMapPoint] = []
        for code in routeCodes {
            guard let point = TodayAirportCoordinates.airports[code] ?? airportResolver.airports[code] else { continue }
            if output.last?.code != point.code {
                output.append(point)
            }
        }
        return output
    }

    private var unresolvedAirportCodes: [String] {
        routeCodes.filter { TodayAirportCoordinates.airports[$0] == nil && airportResolver.airports[$0] == nil }
    }
'''
if old_points in card:
    card = card.replace(old_points, new_points, 1)
elif "private var unresolvedAirportCodes:" not in card:
    raise RuntimeError("dynamic airports: points anchor missing")

# Refactor route parser so display gating works from IATA codes, independent of
# whether coordinates are already known.
rp_start = card.find("    private static func routePoints(for item: RosterItem) -> [TodayAirportMapPoint] {")
if rp_start < 0:
    raise RuntimeError("dynamic airports: routePoints parser missing")
rp_end = block_end(card, rp_start)
if rp_end < 0:
    raise RuntimeError("dynamic airports: routePoints parser end missing")
route_helpers = r'''    private static func routeCodes(for item: RosterItem) -> [String] {
        let normalized = item.route
            .uppercased()
            .replacingOccurrences(of: "→", with: " ")
            .replacingOccurrences(of: "–", with: " ")
            .replacingOccurrences(of: "—", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")

        return normalized
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count == 3 }
    }

    private static func routePoints(for item: RosterItem) -> [TodayAirportMapPoint] {
        var output: [TodayAirportMapPoint] = []
        for code in routeCodes(for: item) {
            guard let point = TodayAirportCoordinates.airports[code] else { continue }
            if output.last?.code != point.code {
                output.append(point)
            }
        }
        return output
    }'''
card = card[:rp_start] + route_helpers + card[rp_end:]

# Trigger resolution independently of the existing GPS/onAppear chain.
task_modifier = '''        .task(id: routeCodes.joined(separator: "|")) {
            airportResolver.resolve(routeCodes)
        }
'''
if "airportResolver.resolve(routeCodes)" not in card:
    accessibility = '.accessibilityLabel("Flight route map " + points.map(\\.code).joined(separator: " to "))'
    pos = card.find(accessibility)
    if pos >= 0:
        insert = pos + len(accessibility)
        card = card[:insert] + "\n" + task_modifier.rstrip("\n") + card[insert:]
    else:
        # Fallback to the final body closing brace.
        body_start = card.find("    var body: some View {")
        body_end = block_end(card, body_start)
        if body_start < 0 or body_end < 0:
            raise RuntimeError("dynamic airports: body bounds missing")
        body = card[body_start:body_end]
        close = body.rfind("\n    }")
        if close < 0:
            raise RuntimeError("dynamic airports: body modifier insertion failed")
        body = body[:close] + "\n" + task_modifier + body[close:]
        card = card[:body_start] + body + card[body_end:]

# Show a useful status instead of a disappearing card while a new airport is
# being resolved for the first time.
if "Resolving airport data" not in card:
    map_label = 'Label("Flight Companion", systemImage: "airplane.circle.fill")'
    label_pos = card.find(map_label)
    if label_pos < 0:
        raise RuntimeError("dynamic airports: Flight Companion header missing")
    # Add a compact line directly below the header HStack when coordinates are pending.
    header_close = card.find("            .padding(.horizontal, 2)", label_pos)
    if header_close >= 0:
        header_close += len("            .padding(.horizontal, 2)")
        pending = r'''

            if !unresolvedAirportCodes.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Resolving airport data · " + unresolvedAirportCodes.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
'''
        card = card[:header_close] + pending + card[header_close:]

s = s[:card_start] + card + s[card_end:]

for required in [
    "final class TodayAirportResolver",
    "routeCodes(for: item).count >= 2",
    "airportResolver.resolve(routeCodes)",
    "RAIDORoster.TodayAirportCache.V1",
    "Resolving airport data",
]:
    if required not in s:
        raise RuntimeError("dynamic airports semantic guard missing: " + required)

CONTENT.write_text(s)
print("Automatic IATA airport resolution + persistent coordinate cache applied")
