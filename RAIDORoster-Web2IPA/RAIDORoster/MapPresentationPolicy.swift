import Foundation
import CoreGraphics

struct OfflinePlaceLabel: Codable {
    enum Kind: String, Codable { case water, country, capital, city, landmark }
    let id: String
    let name: String
    let kind: Kind
    let latitude: Double
    let longitude: Double
    let rank: Int
}

struct OfflinePlaceCatalogue: Codable {
    let labels: [OfflinePlaceLabel]
}

enum MapExpansionGesture {
    static func destination(expanded: Bool, horizontal: Double, vertical: Double) -> Bool? {
        guard abs(vertical) >= 140, abs(vertical) > abs(horizontal) * 1.4 else { return nil }
        if !expanded, vertical < 0 { return true }
        if expanded, vertical > 0 { return false }
        return nil
    }
}

enum MapLabelLayout {
    struct Candidate {
        let id: String
        let name: String
        let priority: Int
        let rank: Int
        let rect: CGRect
    }

    static func select(_ candidates: [Candidate], size: CGSize, protected: [CGRect], route: [CGPoint], limit: Int) -> [Candidate] {
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let sorted = candidates.sorted { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            if a.rank != b.rank { return a.rank < b.rank }
            func distance(_ rect: CGRect) -> CGFloat { pow(rect.midX - center.x, 2) + pow(rect.midY - center.y, 2) }
            let lhs = distance(a.rect), rhs = distance(b.rect)
            return lhs == rhs ? a.id < b.id : lhs < rhs
        }
        var occupied = protected
        var names = Set<String>()
        var result: [Candidate] = []
        for candidate in sorted {
            guard result.count < max(0, limit), bounds.contains(candidate.rect), !names.contains(candidate.name) else { continue }
            let clearance = candidate.rect.insetBy(dx: -5, dy: -5)
            guard !occupied.contains(where: { $0.intersects(clearance) }) else { continue }
            guard !zip(route, route.dropFirst()).contains(where: { intersects($0.0, $0.1, rect: clearance) }) else { continue }
            result.append(candidate); names.insert(candidate.name); occupied.append(clearance)
        }
        return result
    }

    // Clip a segment against a rectangle. Labels must not cover the route line.
    private static func intersects(_ a: CGPoint, _ b: CGPoint, rect: CGRect) -> Bool {
        var lower: CGFloat = 0, upper: CGFloat = 1
        for (start, delta, minimum, maximum) in [(a.x, b.x - a.x, rect.minX, rect.maxX), (a.y, b.y - a.y, rect.minY, rect.maxY)] {
            if abs(delta) < 0.000001 { if start < minimum || start > maximum { return false }; continue }
            let first = (minimum - start) / delta, last = (maximum - start) / delta
            lower = max(lower, min(first, last)); upper = min(upper, max(first, last))
            if lower > upper { return false }
        }
        return true
    }
}
