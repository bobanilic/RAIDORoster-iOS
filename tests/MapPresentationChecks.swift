import Foundation
import CoreGraphics

@main struct MapPresentationChecks {
    static func main() throws {
        let catalogue = try JSONDecoder().decode(OfflinePlaceCatalogue.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        precondition(catalogue.labels.count > 1000)
        precondition(Set(catalogue.labels.map(\.id)).count == catalogue.labels.count)
        precondition(catalogue.labels.allSatisfy { (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) && !$0.name.isEmpty })
        for name in ["Mediterranean Sea", "Cyprus", "Nicosia", "Greece", "Athens", "Mount Etna", "Mount Vesuvius"] {
            precondition(catalogue.labels.contains { $0.name == name }, "Missing route geography: \(name)")
        }
        precondition(MapExpansionGesture.destination(expanded: false, horizontal: 0, vertical: 50, onHandle: false) == true)
        precondition(MapExpansionGesture.destination(expanded: false, horizontal: 0, vertical: 35, onHandle: true) == true)
        precondition(MapExpansionGesture.destination(expanded: true, horizontal: 0, vertical: -35, onHandle: true) == false)
        precondition(MapExpansionGesture.destination(expanded: true, horizontal: 0, vertical: -100, onHandle: false) == nil, "Map pans must not collapse")
        precondition(MapExpansionGesture.destination(expanded: false, horizontal: 80, vertical: 50, onHandle: false) == nil)
        precondition(MapExpansionGesture.destination(expanded: false, horizontal: 0, vertical: 12, onHandle: true) == nil)
        func label(_ id: String, _ name: String, _ x: CGFloat, _ y: CGFloat, priority: Int = 1) -> MapLabelLayout.Candidate {
            .init(id: id, name: name, priority: priority, rank: 1, rect: CGRect(x: x, y: y, width: 60, height: 14))
        }
        let selected = MapLabelLayout.select([
            label("sea", "Sea", 20, 20, priority: 0), label("duplicate", "Sea", 210, 20),
            label("overlap", "Country", 25, 20), label("route", "Route obstacle", 120, 144),
            label("airport", "Airport obstacle", 60, 200), label("city", "City", 210, 90),
            label("edge", "Offscreen", -10, 50)], size: CGSize(width: 320, height: 300),
            protected: [CGRect(x: 50, y: 190, width: 90, height: 40)],
            route: [CGPoint(x: 0, y: 150), CGPoint(x: 320, y: 150)], limit: 5)
        precondition(selected.map(\.id) == ["sea", "city"], "Labels must avoid each other, the route, airports and map edges")
        precondition(MapLabelLayout.select([label("x", "x", 20, 20)], size: CGSize(width: 320, height: 300), protected: [], route: [], limit: 0).isEmpty)
        print("Passed offline geography, gesture intent, label collisions and protected route checks")
    }
}
