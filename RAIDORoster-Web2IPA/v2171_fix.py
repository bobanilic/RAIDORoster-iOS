from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.17.1 fix marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# adsb.lol currently returns plausible as 0/1 and exposes an IATA route in
# _airport_codes_iata. Decode both integer/bool forms so one route row cannot
# make the whole batch fail.
content = replace_once(
    content,
    r'''private struct ADSBLOLRouteResult: Decodable {
    let callsign: String
    let airportCodes: String?
    let plausible: Bool?

    enum CodingKeys: String, CodingKey {
        case callsign
        case airportCodes = "airport_codes"
        case plausible
    }
}
''',
    r'''private struct ADSBLOLRouteResult: Decodable {
    let callsign: String
    let airportCodes: String?
    let plausible: Bool?

    enum CodingKeys: String, CodingKey {
        case callsign
        case iataAirportCodes = "_airport_codes_iata"
        case airportCodes = "airport_codes"
        case plausible
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callsign = (try? container.decode(String.self, forKey: .callsign)) ?? ""
        let iata = try? container.decodeIfPresent(String.self, forKey: .iataAirportCodes)
        let icao = try? container.decodeIfPresent(String.self, forKey: .airportCodes)
        airportCodes = (iata ?? nil) ?? (icao ?? nil)

        if let bool = try? container.decode(Bool.self, forKey: .plausible) {
            plausible = bool
        } else if let number = try? container.decode(Int.self, forKey: .plausible) {
            plausible = number != 0
        } else {
            plausible = nil
        }
    }
}
''',
    "robust route result decoder",
)

photo_support = r'''
@MainActor
private final class FleetAircraftPhotoStore: ObservableObject {
    @Published private(set) var imageURL: URL?
    @Published private(set) var photographer: String?
    @Published private(set) var sourceURL: URL?
    @Published private(set) var isLoading = false

    private let registration: String

    init(registration: String) {
        self.registration = registration
    }

    func load() async {
        guard imageURL == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let encoded = registration.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? registration
        guard let url = URL(string: "https://api.planespotters.net/pub/photos/reg/\(encoded)") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("RAIDORoster/2.17", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let photos = root["photos"] as? [[String: Any]],
              let first = photos.first,
              let thumbnail = first["thumbnail"] as? [String: Any],
              let source = thumbnail["src"] as? String,
              let imageURL = URL(string: source) else { return }

        self.imageURL = imageURL
        photographer = first["photographer"] as? String
        if let link = first["link"] as? String {
            sourceURL = URL(string: link)
        }
    }
}

'''

if "private final class FleetAircraftPhotoStore" not in content:
    content = replace_once(
        content,
        "private struct FleetAircraftDetailView: View {\n",
        photo_support + "private struct FleetAircraftDetailView: View {\n",
        "aircraft photo loader",
    )

content = replace_once(
    content,
    r'''private struct FleetAircraftDetailView: View {
    let aircraft: FleetAircraftDefinition
    let snapshot: FleetLiveSnapshot?
    let isAssigned: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
''',
    r'''private struct FleetAircraftDetailView: View {
    let aircraft: FleetAircraftDefinition
    let snapshot: FleetLiveSnapshot?
    let isAssigned: Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var photo: FleetAircraftPhotoStore

    init(aircraft: FleetAircraftDefinition, snapshot: FleetLiveSnapshot?, isAssigned: Bool) {
        self.aircraft = aircraft
        self.snapshot = snapshot
        self.isAssigned = isAssigned
        _photo = StateObject(wrappedValue: FleetAircraftPhotoStore(registration: aircraft.registration))
    }

    var body: some View {
''',
    "photo state on detail",
)

content = replace_once(
    content,
    r'''                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.secondary.opacity(0.18), Color.secondary.opacity(0.06)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(height: 170)

                        Image(systemName: "airplane")
                            .font(.system(size: 78, weight: .light))
                            .rotationEffect(.degrees(-18))
                            .foregroundStyle(.secondary.opacity(0.55))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(aircraft.registration)
                                .font(.title.bold().monospaced())
                            Text("\(aircraft.operatorName) • \(aircraft.type)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                    }
''',
    r'''                    ZStack(alignment: .bottomLeading) {
                        Group {
                            if let imageURL = photo.imageURL {
                                AsyncImage(url: imageURL) { phase in
                                    if let image = phase.image {
                                        image
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        fleetPhotoPlaceholder
                                    }
                                }
                            } else {
                                fleetPhotoPlaceholder
                            }
                        }
                        .frame(height: 190)
                        .frame(maxWidth: .infinity)
                        .clipped()

                        LinearGradient(
                            colors: [.clear, .black.opacity(0.74)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        .frame(height: 190)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(aircraft.registration)
                                .font(.title.bold().monospaced())
                                .foregroundStyle(.white)
                            Text("\(aircraft.operatorName) • \(aircraft.type)")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.85))
                            if let photographer = photo.photographer {
                                Text("Photo: \(photographer) • Planespotters.net")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.72))
                            }
                        }
                        .padding(16)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
''',
    "actual aircraft photo hero",
)

# Add a fallback visual and start photo loading when the detail opens.
content = replace_once(
    content,
    r'''            .navigationTitle("Aircraft")
            .navigationBarTitleDisplayMode(.inline)
''',
    r'''            .navigationTitle("Aircraft")
            .navigationBarTitleDisplayMode(.inline)
            .task { await photo.load() }
''',
    "photo load task",
)

content = replace_once(
    content,
    r'''    private func fleetAge(_ snapshot: FleetLiveSnapshot) -> String {
''',
    r'''    private var fleetPhotoPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.secondary.opacity(0.20), Color.secondary.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "airplane")
                .font(.system(size: 78, weight: .light))
                .rotationEffect(.degrees(-18))
                .foregroundStyle(.secondary.opacity(0.55))
        }
    }

    private func fleetAge(_ snapshot: FleetLiveSnapshot) -> String {
''',
    "photo placeholder",
)

CONTENT.write_text(content)
print("V2.17 Fleet route decoding + aircraft photo fix applied")
