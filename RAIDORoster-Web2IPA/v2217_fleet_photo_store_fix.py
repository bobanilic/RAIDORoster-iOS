"""V2.23.0 compile fix: restore FleetAircraftPhotoStore after Fleet UI rewrites."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster/ContentView.swift"
content = CONTENT.read_text()

marker = "private struct FleetAircraftDetailView: View {\n"
if marker not in content:
    raise RuntimeError("Fleet photo-store fix: detail-view anchor missing")

# V2.17.1 introduced this loader. Later Fleet view-region rewrites preserved the
# detail view's @StateObject reference but could drop the private helper type.
# Restore the original implementation only when it is missing so the patch is
# idempotent with respect to future refactors that retain the helper correctly.
if "private final class FleetAircraftPhotoStore" not in content:
    photo_support = r'''@MainActor
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
        request.setValue("RAIDORoster/2.23.0", forHTTPHeaderField: "User-Agent")

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
    content = content.replace(marker, photo_support + marker, 1)

# Fail fast before xcodebuild if a later patch ever recreates this orphaned
# reference. This specifically guards the CodeMagic failure seen in build #33.
if content.count("private final class FleetAircraftPhotoStore") != 1:
    raise RuntimeError("Fleet photo-store fix: expected exactly one FleetAircraftPhotoStore definition")
if "@StateObject private var photo: FleetAircraftPhotoStore" not in content:
    raise RuntimeError("Fleet photo-store fix: detail view no longer has expected photo state")
if "FleetAircraftPhotoStore(registration: aircraft.registration)" not in content:
    raise RuntimeError("Fleet photo-store fix: detail view photo initializer missing")

CONTENT.write_text(content)
print("V2.23.0 Fleet aircraft photo-store compile fix applied")
