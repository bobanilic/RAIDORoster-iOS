private enum OfflineAviationBasemap {
    struct Outline: Decodable {
        let west: Double
        let south: Double
        let east: Double
        let north: Double
        let coordinates: [CLLocationCoordinate2D]
        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            west = try values.decode(Double.self); south = try values.decode(Double.self)
            east = try values.decode(Double.self); north = try values.decode(Double.self)
            let ring = try values.decode([[Double]].self)
            coordinates = ring.filter { $0.count == 2 }.map { .init(latitude: $0[1], longitude: $0[0]) }
        }
        func isVisible(viewport: OfflineAviationMapViewport, size: CGSize, zoom: CGFloat, pan: CGSize) -> Bool {
            let a = viewport.point(for: .init(latitude: south, longitude: west), in: size, zoom: zoom, pan: pan)
            let b = viewport.point(for: .init(latitude: north, longitude: east), in: size, zoom: zoom, pan: pan)
            return max(a.x, b.x) >= 0 && min(a.x, b.x) <= size.width && max(a.y, b.y) >= 0 && min(a.y, b.y) <= size.height
        }
    }
    // Natural Earth 1:50m land, public domain. Decoded once, with per-outline
    // bounds culling before projection; no downloads or tile dependency.
    static let outlines: [Outline] = {
        guard let url = Bundle.main.url(forResource: "OfflineLand", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode([Outline].self, from: data) else { return [] }
        return result
    }()
}

