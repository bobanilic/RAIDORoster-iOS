from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.17.1 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# Fleet V1 uses a deliberately curated operational snapshot rather than every
# aircraft appearing on an ownership/asset-management page. This avoids showing
# aircraft that are managed/dry-leased but not currently relevant to GetJet or
# Airhub airline operations. Snapshot checked 30 AUG 2026.
old_catalog = '''    static let all: [FleetAircraftDefinition] = [
        .init(registration: "LY-NOW", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-GYM", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-FAS", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-WIL", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-MAL", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-WIZ", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-CAP", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-TAP", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-EKB", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-DAE", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-WSA", type: "A321", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "220Y"),
        .init(registration: "LY-UNO", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-DUE", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-CIN", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-TUI", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-SEI", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "9H-GTS", type: "A320", operatorName: "Airhub Airlines", operatorCode: "AIRHUB", seats: "180Y")
    ]
'''

new_catalog = '''    static let all: [FleetAircraftDefinition] = [
        .init(registration: "LY-ELM", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-FOX", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-MAL", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-NOW", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-TAP", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-TEN", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "180Y"),
        .init(registration: "LY-WSA", type: "A321", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "220Y"),
        .init(registration: "LY-CIN", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-DUE", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-KUA", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-SEI", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-TUI", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "LY-UNO", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: "189Y"),
        .init(registration: "9H-GTS", type: "A320", operatorName: "Airhub Airlines", operatorCode: "AIRHUB", seats: "180Y")
    ]
'''
content = replace_once(content, old_catalog, new_catalog, "current operational Fleet catalog")

# The ADSB.lol live endpoint remains the position source. Resolve the current
# callsign to an airport route using ADSBdb's documented public callsign API.
# This avoids depending on an undocumented /routeset response shape.
route_start = content.find("    private func fetchRoutes(\n")
route_end = content.find("    private func loadCache()", route_start)
if route_start < 0 or route_end < 0:
    raise RuntimeError("V2.17.1 patch marker not found: Fleet route resolver")

route_resolver = r'''    private func fetchRoutes(
        _ aircraft: [(registration: String, callsign: String, lat: Double, lon: Double)]
    ) async throws -> [String: String] {
        var output: [String: String] = [:]

        await withTaskGroup(of: (String, String?).self) { group in
            for item in aircraft {
                group.addTask {
                    let clean = item.callsign.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty,
                          let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                          let url = URL(string: "https://api.adsbdb.com/v0/callsign/\(encoded)") else {
                        return (item.registration, nil)
                    }

                    var request = URLRequest(url: url)
                    request.timeoutInterval = 8
                    request.setValue("RAIDORoster/2.17", forHTTPHeaderField: "User-Agent")

                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode),
                          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let payload = root["response"] as? [String: Any],
                          let route = payload["flightroute"] as? [String: Any],
                          let origin = route["origin"] as? [String: Any],
                          let destination = route["destination"] as? [String: Any] else {
                        return (item.registration, nil)
                    }

                    func code(_ airport: [String: Any]) -> String? {
                        if let iata = airport["iata_code"] as? String, !iata.isEmpty { return iata }
                        if let icao = airport["icao_code"] as? String, !icao.isEmpty { return icao }
                        return nil
                    }

                    guard let from = code(origin), let to = code(destination) else {
                        return (item.registration, nil)
                    }
                    return (item.registration, "\(from) → \(to)")
                }
            }

            for await (registration, route) in group {
                if let route { output[registration] = route }
            }
        }

        return output
    }

'''
content = content[:route_start] + route_resolver + content[route_end:]

# Public aircraft photos are fetched by registration from ADSBdb metadata.
# The UI falls back to the existing airplane glyph if no photo exists.
photo_support = r'''
private struct FleetAircraftPhotoView: View {
    let registration: String
    let type: String
    let height: CGFloat
    var cornerRadius: CGFloat = 12

    @State private var photoURL: URL?
    @State private var didLoadMetadata = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.10))

            if let photoURL {
                AsyncImage(url: photoURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().controlSize(.small)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        fallback
                    @unknown default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: registration) {
            guard !didLoadMetadata else { return }
            didLoadMetadata = true
            photoURL = await fetchPhotoURL()
        }
    }

    private var fallback: some View {
        VStack(spacing: 3) {
            Image(systemName: "airplane")
                .font(.system(size: height > 100 ? 58 : 24, weight: .light))
                .rotationEffect(.degrees(-18))
            Text(type)
                .font(.caption2.bold())
        }
        .foregroundStyle(.secondary.opacity(0.65))
    }

    private func fetchPhotoURL() async -> URL? {
        let encoded = registration.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? registration
        guard let url = URL(string: "https://api.adsbdb.com/v0/aircraft/\(encoded)") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("RAIDORoster/2.17", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["response"] as? [String: Any],
              let aircraft = payload["aircraft"] as? [String: Any] else { return nil }

        let raw = (aircraft["url_photo_thumbnail"] as? String)
            ?? (aircraft["url_photo"] as? String)
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}

'''

if "private struct FleetAircraftPhotoView: View" not in content:
    content = replace_once(
        content,
        "private struct FleetAircraftRow: View {\n",
        photo_support + "private struct FleetAircraftRow: View {\n",
        "Fleet aircraft photo component",
    )

old_row_photo = '''            ZStack {\n                RoundedRectangle(cornerRadius: 12)\n                    .fill(Color.secondary.opacity(0.10))\n                    .frame(width: 58, height: 58)\n                Image(systemName: aircraft.type.hasPrefix("B") ? "airplane" : "airplane")\n                    .font(.system(size: 25, weight: .semibold))\n                    .rotationEffect(.degrees(-20))\n            }\n'''
new_row_photo = '''            FleetAircraftPhotoView(\n                registration: aircraft.registration,\n                type: aircraft.type,\n                height: 58\n            )\n            .frame(width: 82)\n'''
content = replace_once(content, old_row_photo, new_row_photo, "Fleet row photo")

# Replace the large generic silhouette in detail with the registration photo.
old_detail_photo = '''                    ZStack(alignment: .bottomLeading) {\n                        RoundedRectangle(cornerRadius: 22, style: .continuous)\n                            .fill(\n                                LinearGradient(\n                                    colors: [Color.secondary.opacity(0.18), Color.secondary.opacity(0.06)],\n                                    startPoint: .topLeading,\n                                    endPoint: .bottomTrailing\n                                )\n                            )\n                            .frame(height: 170)\n\n                        Image(systemName: "airplane")\n                            .font(.system(size: 78, weight: .light))\n                            .rotationEffect(.degrees(-18))\n                            .foregroundStyle(.secondary.opacity(0.55))\n                            .frame(maxWidth: .infinity, maxHeight: .infinity)\n\n                        VStack(alignment: .leading, spacing: 4) {\n                            Text(aircraft.registration)\n                                .font(.title.bold().monospaced())\n                            Text("\\(aircraft.operatorName) • \\(aircraft.type)")\n                                .font(.subheadline)\n                                .foregroundStyle(.secondary)\n                        }\n                        .padding(16)\n                    }\n'''
new_detail_photo = '''                    ZStack(alignment: .bottomLeading) {\n                        FleetAircraftPhotoView(\n                            registration: aircraft.registration,\n                            type: aircraft.type,\n                            height: 190,\n                            cornerRadius: 22\n                        )\n\n                        LinearGradient(\n                            colors: [.clear, .black.opacity(0.72)],\n                            startPoint: .center,\n                            endPoint: .bottom\n                        )\n                        .frame(height: 190)\n                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))\n\n                        VStack(alignment: .leading, spacing: 4) {\n                            Text(aircraft.registration)\n                                .font(.title.bold().monospaced())\n                                .foregroundStyle(.white)\n                            Text("\\(aircraft.operatorName) • \\(aircraft.type)")\n                                .font(.subheadline)\n                                .foregroundStyle(.white.opacity(0.82))\n                        }\n                        .padding(16)\n                    }\n'''
content = replace_once(content, old_detail_photo, new_detail_photo, "Fleet detail photo")

# Fix the Settings-local presentation state. V2.17's first insertion targets
# Today; ensure Settings has its own showFleet property before its sheet modifier.
settings_start = content.find("struct SettingsView: View {")
if settings_start < 0:
    raise RuntimeError("V2.17.1 patch marker not found: SettingsView")
head = content[:settings_start]
tail = content[settings_start:]
if "@State private var showFleet = false" not in tail:
    state_marker = "    @State private var showCrewControl = false\n"
    if state_marker not in tail:
        raise RuntimeError("V2.17.1 patch marker not found: Settings showCrewControl state")
    tail = tail.replace(
        state_marker,
        state_marker + "    @State private var showFleet = false\n",
        1,
    )
content = head + tail

CONTENT.write_text(content)
print("V2.17 Fleet V1 current fleet, route resolver and aircraft photos hardened")
