import Foundation
import CoreLocation

struct FleetAircraftDefinition: Identifiable, Hashable {
    let registration: String
    let type: String
    let operatorName: String
    let operatorCode: String
    let seats: String

    var id: String { registration }

    static let all: [FleetAircraftDefinition] = [
        .init(registration: "LY-CAP", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-DAE", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-EKB", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-FAS", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-GYM", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-MAL", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-NOW", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-TAP", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-TEN", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-WIL", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-WIZ", type: "A320", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-WSA", type: "A321", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-CIN", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-DUE", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-SEI", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-TUI", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "LY-UNO", type: "B738", operatorName: "GetJet Airlines", operatorCode: "GETJET", seats: ""),
        .init(registration: "9H-GTS", type: "A320", operatorName: "Airhub Airlines", operatorCode: "AIRHUB", seats: "")
    ]
}

struct FleetLiveSnapshot: Codable, Identifiable {
    let registration: String
    let callsign: String?
    let route: String?
    let latitude: Double?
    let longitude: Double?
    let altitudeFeet: Double?
    let groundSpeedKnots: Double?
    let trackDegrees: Double?
    let onGround: Bool
    let sourceSeenSeconds: Double
    let fetchedAt: Date
    let icaoHex: String?
    let seenPositionSeconds: Double?
    let nacP: Int?
    let nic: Int?
    let radiusContainmentMeters: Double?
    var sourceReferenceAt: Date? = nil
    var groundStateKnown: Bool? = nil
    var verticalRateFeetPerMinute: Double? = nil
    var providerName: String? = nil
    var hasKnownGroundState: Bool { groundStateKnown ?? (onGround || altitudeFeet != nil) }

    var id: String { registration }

    var hasPosition: Bool {
        FleetTrackingPolicy.validCoordinate(latitude: latitude, longitude: longitude)
    }

    var observationAge: TimeInterval {
        FleetTrackingPolicy.age(referenceAt: sourceReferenceAt ?? fetchedAt,
                                seconds: sourceSeenSeconds, now: Date())
    }

    var effectivePositionAge: TimeInterval {
        FleetTrackingPolicy.positionAge(referenceAt: sourceReferenceAt ?? fetchedAt,
                                        messageAge: sourceSeenSeconds,
                                        positionAge: seenPositionSeconds, now: Date())
    }

    var positionQualityText: String {
        if let rc = radiusContainmentMeters, rc > 0 {
            return rc < 1000 ? "Containment \(Int(rc.rounded())) m" : "Containment \(String(format: "%.1f", rc / 1000)) km"
        }
        if let nacP {
            switch nacP {
            case 11: return "< 3 m"
            case 10: return "< 10 m"
            case 9: return "< 30 m"
            case 8: return "< 92 m"
            case 7: return "< 185 m"
            case 6: return "< 556 m"
            case 5: return "< 0.93 km"
            default: break
            }
        }
        return "Unknown accuracy"
    }

    var isFresh: Bool { hasPosition && effectivePositionAge <= 120 }
    var isRecent: Bool { hasPosition && effectivePositionAge <= 900 }
    var isStale: Bool { effectivePositionAge > 900 }

    var isAirborne: Bool {
        hasKnownGroundState && !onGround
    }
}


struct FleetTrackObservation: Codable, Identifiable {
    let registration: String
    let callsign: String?
    let route: String?
    let latitude: Double?
    let longitude: Double?
    let altitudeFeet: Double?
    let groundSpeedKnots: Double?
    let trackDegrees: Double?
    let onGround: Bool
    let observedAt: Date
    var groundStateKnown: Bool? = nil

    var id: String {
        "\(registration)|\(Int(observedAt.timeIntervalSince1970))"
    }
}

enum FleetFlightPhase: String {
    case unknown = "Unknown"
    case onGround = "On ground"
    case departing = "Departing"
    case climbing = "Climbing"
    case cruise = "Cruise"
    case descending = "Descending"
    case arriving = "Arriving"
    case airborne = "Airborne"
}

struct FleetAirportReference {
    let code: String
    let latitude: Double
    let longitude: Double

    static let common: [FleetAirportReference] = [
        .init(code: "TLV", latitude: 32.0005, longitude: 34.8708),
        .init(code: "AUH", latitude: 24.4330, longitude: 54.6511),
        .init(code: "DXB", latitude: 25.2532, longitude: 55.3657),
        .init(code: "LCA", latitude: 34.8751, longitude: 33.6249),
        .init(code: "FCO", latitude: 41.8003, longitude: 12.2389),
        .init(code: "ATH", latitude: 37.9364, longitude: 23.9445),
        .init(code: "BEG", latitude: 44.8184, longitude: 20.3091),
        .init(code: "VNO", latitude: 54.6341, longitude: 25.2858),
        .init(code: "RIX", latitude: 56.9236, longitude: 23.9711),
        .init(code: "KUN", latitude: 54.9639, longitude: 24.0848),
        .init(code: "WAW", latitude: 52.1657, longitude: 20.9671),
        .init(code: "VIE", latitude: 48.1103, longitude: 16.5697),
        .init(code: "BER", latitude: 52.3667, longitude: 13.5033),
        .init(code: "CDG", latitude: 49.0097, longitude: 2.5479),
        .init(code: "AMS", latitude: 52.3105, longitude: 4.7683),
        .init(code: "LHR", latitude: 51.4700, longitude: -0.4543)
    ]
}

struct FleetAircraftIntelligence {
    let phase: FleetFlightPhase
    let currentRoute: String?
    let previousRoute: String?
    let nearestAirport: String?
    let lastDepartureAt: Date?
    let lastArrivalAt: Date?
    let turnaroundSeconds: TimeInterval?
    let observationCount: Int
}

func fleetDistanceMeters(
    latitude1: Double,
    longitude1: Double,
    latitude2: Double,
    longitude2: Double
) -> Double {
    let a = CLLocation(latitude: latitude1, longitude: longitude1)
    let b = CLLocation(latitude: latitude2, longitude: longitude2)
    return a.distance(from: b)
}


func announcementAirline(registration: String) -> AnnouncementAirline {
    AnnouncementAirline.fromRoster(registration: registration,
        operators: Dictionary(uniqueKeysWithValues: FleetAircraftDefinition.all.map { ($0.registration, $0.operatorCode) }))
}
