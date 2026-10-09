private enum OfflineMapPlaces {
    static let labels: [OfflinePlaceLabel] = {
        guard let url = Bundle.main.url(forResource: "OfflinePlaceLabels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalogue = try? JSONDecoder().decode(OfflinePlaceCatalogue.self, from: data) else { return [] }
        return catalogue.labels
    }()

    static func draw(in context: inout GraphicsContext, size: CGSize,
                     viewport: OfflineAviationMapViewport, zoom: CGFloat, pan: CGSize,
                     airports: [CLLocationCoordinate2D], aircraft: CLLocationCoordinate2D?) {
        let screenRoute = airports.map { viewport.point(for: $0, in: size, zoom: zoom, pan: pan) }
        var protected = screenRoute.map { CGRect(x: $0.x - 24, y: $0.y - 14, width: 48, height: 44) }
        if let aircraft {
            let point = viewport.point(for: aircraft, in: size, zoom: zoom, pan: pan)
            protected.append(CGRect(x: point.x - 26, y: point.y - 26, width: 52, height: 52))
        }
        var resolved: [String: GraphicsContext.ResolvedText] = [:]
        var candidates: [MapLabelLayout.Candidate] = []
        for place in labels {
            let point = viewport.point(for: .init(latitude: place.latitude, longitude: place.longitude), in: size, zoom: zoom, pan: pan)
            guard point.x > 8, point.x < size.width - 8, point.y > 8, point.y < size.height - 8 else { continue }
            let title: String
            let priority: Int
            let font: Font
            switch place.kind {
            case .water: title = place.name; priority = 0; font = .system(size: 11, weight: .regular).italic()
            case .country: title = place.name.uppercased(); priority = 1; font = .system(size: 10, weight: .medium)
            case .capital: title = "⋆ " + place.name; priority = 2; font = .system(size: 10, weight: .medium)
            case .landmark: title = "△ " + place.name; priority = 3; font = .system(size: 10)
            case .city: title = "· " + place.name; priority = 4; font = .system(size: 10)
            }
            let text = context.resolve(Text(title).font(font).tracking(place.kind == .country ? 0.7 : 0)
                .foregroundStyle(MidnightTheme.mapLabelInk))
            let measure = text.measure(in: CGSize(width: 180, height: 30))
            let rect = CGRect(x: point.x - measure.width / 2, y: point.y - measure.height / 2, width: measure.width, height: measure.height)
            resolved[place.id] = text
            candidates.append(.init(id: place.id, name: place.name, priority: priority, rank: place.rank, rect: rect))
        }
        for candidate in MapLabelLayout.select(candidates, size: size, protected: protected, route: screenRoute, limit: size.height < 220 ? 5 : 11) {
            if let text = resolved[candidate.id] {
                context.draw(text, at: CGPoint(x: candidate.rect.midX, y: candidate.rect.midY), anchor: .center)
            }
        }
    }
}

extension View {
    func raidoPrimaryAction() -> some View {
        buttonStyle(.borderedProminent).tint(MidnightTheme.actionFill).foregroundStyle(MidnightTheme.actionInk)
    }
}
