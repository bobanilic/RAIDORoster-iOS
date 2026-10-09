from pathlib import Path
import json

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster/ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj/project.pbxproj"
INDEX = ROOT / "RAIDORoster/GlobalAirportIndex.json"

s = CONTENT.read_text()


def block_end(text: str, start: int) -> int:
    brace = text.find("{", start)
    if brace < 0:
        return -1
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i + 1
    return -1


# Validate the bundled global index before touching Swift/project files.
if not INDEX.exists():
    raise RuntimeError("Global airport index missing")
try:
    airport_index = json.loads(INDEX.read_text())
except Exception as error:
    raise RuntimeError("Global airport index is not valid JSON") from error
if len(airport_index) < 5000:
    raise RuntimeError(f"Global airport index unexpectedly small: {len(airport_index)}")
for required in ["TLV", "VAR", "BEG", "AUH", "JFK", "SYD", "NRT"]:
    if required not in airport_index:
        raise RuntimeError("Global airport index missing expected IATA code: " + required)


# Insert a single global resolver after the small hand-curated fast-path table.
marker = "struct TodayRouteMapCard: View {"
idx = s.find(marker)
if idx < 0:
    raise RuntimeError("Global airport resolver: TodayRouteMapCard missing")

resolver = r'''
private enum TodayGlobalAirportIndex {
    private struct Entry: Decodable {
        let name: String
        let latitude: Double
        let longitude: Double

        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            name = try values.decode(String.self)
            latitude = try values.decode(Double.self)
            longitude = try values.decode(Double.self)
        }
    }

    // The embedded dictionary remains a zero-I/O fast path for common routes.
    // The bundled global index is the source of truth for all other IATA codes.
    private static let records: [String: Entry] = {
        guard let url = Bundle.main.url(forResource: "GlobalAirportIndex", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return decoded
    }()

    static func point(for code: String) -> TodayAirportMapPoint? {
        let normalized = code
            .uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil else { return nil }

        if let local = TodayAirportCoordinates.airports[normalized] {
            return local
        }
        guard let record = records[normalized],
              (-90...90).contains(record.latitude),
              (-180...180).contains(record.longitude) else { return nil }
        return TodayAirportMapPoint(
            code: normalized,
            name: record.name,
            coordinate: CLLocationCoordinate2D(latitude: record.latitude, longitude: record.longitude)
        )
    }

    static func routeCodes(_ route: String) -> [String] {
        route
            .uppercased()
            .replacingOccurrences(of: "→", with: " ")
            .replacingOccurrences(of: "–", with: " ")
            .replacingOccurrences(of: "—", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count == 3 }
    }

    static func routePoints(for route: String) -> [TodayAirportMapPoint] {
        var output: [TodayAirportMapPoint] = []
        for code in routeCodes(route) {
            guard let point = point(for: code) else { continue }
            // Keep a return-to-origin route (e.g. TLV-VAR-TLV), while removing
            // only repeated adjacent tokens.
            if output.last?.code != point.code {
                output.append(point)
            }
        }
        return output
    }
}

'''
if "private enum TodayGlobalAirportIndex" not in s:
    s = s[:idx] + resolver + s[idx:]


# The map card must be shown based on a valid route, not on whether every airport
# happened to exist in the old embedded dictionary.
card_start = s.find("struct TodayRouteMapCard: View {")
if card_start < 0:
    raise RuntimeError("Global airport resolver: map card missing")
can_start = s.find("    static func canDisplay(_ item: RosterItem) -> Bool {", card_start)
if can_start < 0:
    raise RuntimeError("Global airport resolver: canDisplay missing")
can_end = block_end(s, can_start)
if can_end < 0:
    raise RuntimeError("Global airport resolver: canDisplay end missing")
new_can = '''    static func canDisplay(_ item: RosterItem) -> Bool {
        TodayGlobalAirportIndex.routeCodes(item.route).count >= 2
    }'''
s = s[:can_start] + new_can + s[can_end:]

route_start = s.find("    private static func routePoints(for item: RosterItem) -> [TodayAirportMapPoint] {", card_start)
if route_start < 0:
    raise RuntimeError("Global airport resolver: routePoints missing")
route_end = block_end(s, route_start)
if route_end < 0:
    raise RuntimeError("Global airport resolver: routePoints end missing")
new_route = '''    private static func routePoints(for item: RosterItem) -> [TodayAirportMapPoint] {
        TodayGlobalAirportIndex.routePoints(for: item.route)
    }'''
s = s[:route_start] + new_route + s[route_end:]


# Flight Companion automatic arming and route-model geometry must use the same
# global lookup. Otherwise the map could display a route while the tracking
# engine silently drops an unknown origin/destination.
s = s.replace(
    "let origin = TodayAirportCoordinates.airports[originCode]",
    "let origin = TodayGlobalAirportIndex.point(for: originCode)",
)
s = s.replace(
    "TodayAirportCoordinates.airports[originCode]",
    "TodayGlobalAirportIndex.point(for: originCode)",
)
s = s.replace(
    "codes.compactMap { TodayAirportCoordinates.airports[$0]?.coordinate }",
    "codes.compactMap { TodayGlobalAirportIndex.point(for: $0)?.coordinate }",
)

for required in [
    "TodayGlobalAirportIndex.routeCodes(item.route).count >= 2",
    "TodayGlobalAirportIndex.routePoints(for: item.route)",
    "TodayGlobalAirportIndex.point(for: originCode)",
    "codes.compactMap { TodayGlobalAirportIndex.point(for: $0)?.coordinate }",
]:
    if required not in s:
        raise RuntimeError("Global airport resolver semantic guard missing: " + required)

CONTENT.write_text(s)


# Add the global index as an app resource. Use stable project IDs that do not
# collide with existing patch-chain resources.
pbx = PBX.read_text()
build_id = "A22500000000000000000001"
file_id = "B22500000000000000000001"
name = "GlobalAirportIndex.json"

if file_id not in pbx:
    end_build = "/* End PBXBuildFile section */"
    end_ref = "/* End PBXFileReference section */"
    if pbx.count(end_build) != 1 or pbx.count(end_ref) != 1:
        raise RuntimeError("Global airport resolver: PBX section anchors invalid")
    pbx = pbx.replace(
        end_build,
        f'\t\t{build_id} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};\n{end_build}',
        1,
    )
    pbx = pbx.replace(
        end_ref,
        f'\t\t{file_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = text.json; path = {name}; sourceTree = "<group>"; }};\n{end_ref}',
        1,
    )

    group_anchor = "B00000000000000000000002 /* ContentView.swift */,"
    resource_anchor = "A00000000000000000000004 /* RosterEnhancements.js in Resources */,"
    if pbx.count(group_anchor) != 1 or pbx.count(resource_anchor) != 1:
        raise RuntimeError("Global airport resolver: PBX group/resource anchors invalid")
    pbx = pbx.replace(group_anchor, group_anchor + f"\n\t\t\t\t{file_id} /* {name} */,", 1)
    pbx = pbx.replace(resource_anchor, resource_anchor + f" {build_id} /* {name} in Resources */,", 1)

PBX.write_text(pbx)
print(f"Global IATA airport resolver applied ({len(airport_index)} airports)")
