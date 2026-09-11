import Foundation

@main
struct FleetTrackingPolicyChecks {
    static func main() {
        let t = Date(timeIntervalSince1970: 1_788_566_400)
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
            precondition(condition(), description)
            checks += 1
        }
        expect(FleetTrackingPolicy.positionAge(referenceAt: t, messageAge: 1,
                   positionAge: 110, now: t.addingTimeInterval(20)) == 130,
               "A recent message must not rejuvenate a stale position")
        expect(FleetTrackingPolicy.positionAge(referenceAt: t, messageAge: 1,
                   positionAge: nil, now: t).isInfinite, "Missing position age is unknown")
        expect(FleetTrackingPolicy.age(referenceAt: t, seconds: -1, now: t).isInfinite,
               "Negative source age must not be fresh")
        expect(FleetTrackingPolicy.age(referenceAt: t, seconds: .nan, now: t).isInfinite,
               "NaN is not an observation")
        expect(FleetTrackingPolicy.age(referenceAt: t, seconds: 0, now: t.addingTimeInterval(-60)).isInfinite,
               "Clock rollback must not rejuvenate a position")
        expect(FleetTrackingPolicy.sourceDate(epoch: t.timeIntervalSince1970 * 1000, receivedAt: t) == t,
               "Millisecond provider epoch")
        expect(FleetTrackingPolicy.sourceDate(epoch: t.timeIntervalSince1970, receivedAt: t) == t,
               "Second provider epoch")
        expect(FleetTrackingPolicy.sourceDate(epoch: t.timeIntervalSince1970 + 90, receivedAt: t) == nil,
               "Future provider clock rejected")
        expect(FleetTrackingPolicy.sourceDate(epoch: nil, receivedAt: t) == nil,
               "Missing provider clock not replaced with current time")
        expect(FleetTrackingPolicy.retryDelay("120", now: t) == 120, "Respect numeric Retry-After")
        expect(FleetTrackingPolicy.retryDelay("NaN", now: t) == 300, "Invalid retry header uses backoff")
        expect(FleetTrackingPolicy.validCoordinate(latitude: 0, longitude: 0), "Zero is a valid coordinate")
        expect(!FleetTrackingPolicy.validCoordinate(latitude: 91, longitude: 34), "Invalid latitude")
        expect(!FleetTrackingPolicy.validCoordinate(latitude: 32, longitude: .infinity), "Nonfinite longitude")
        expect(FleetTrackingPolicy.validHex("~12345") == nil, "Non-ICAO identity rejected")
        expect(FleetTrackingPolicy.matches(registration: "ly now", hex: "503123",
                   requested: "LY-NOW", expectedHex: nil), "Registration normalization")
        expect(!FleetTrackingPolicy.matches(registration: "LY-UNO", hex: "503123",
                   requested: "LY-NOW", expectedHex: "503123"), "Conflicting registration wins over cached hex")
        expect(!FleetTrackingPolicy.matches(registration: nil, hex: "503123",
                   requested: "LY-NOW", expectedHex: nil), "Never accept first unrelated aircraft")
        expect(FleetTrackingPolicy.matches(registration: nil, hex: "503123",
                   requested: "LY-NOW", expectedHex: "503123"), "Known hex can bridge missing registration")
        expect(!FleetTrackingPolicy.matches(registration: "LY-NOW", hex: "503124",
                   requested: "LY-NOW", expectedHex: "503123"), "Hex change requires reconciliation")
        expect(FleetTrackingPolicy.verticalRate(previousAltitude: 10_000, previousAt: t,
                   altitude: 11_000, observedAt: t.addingTimeInterval(120)) == 500,
               "Vertical rate must account for elapsed time")
        expect(FleetTrackingPolicy.verticalRate(previousAltitude: 10_000, previousAt: t,
                   altitude: 11_000, observedAt: t.addingTimeInterval(1000)) == nil,
               "No climb inference across reception gap")
        expect(!FleetTrackingPolicy.canInferTransition(previousAt: t, currentAt: t.addingTimeInterval(600),
                   previousKnown: true, currentKnown: true, previousCallsign: "ISR123", currentCallsign: "ISR123"),
               "Reopening the app must not invent a landing")
        expect(!FleetTrackingPolicy.canInferTransition(previousAt: t, currentAt: t.addingTimeInterval(30),
                   previousKnown: false, currentKnown: true, previousCallsign: "ISR123", currentCallsign: "ISR123"),
               "Unknown ground state must not become takeoff evidence")
        expect(!FleetTrackingPolicy.canInferTransition(previousAt: t, currentAt: t.addingTimeInterval(30),
                   previousKnown: true, currentKnown: true, previousCallsign: "ISR123", currentCallsign: "ISR124"),
               "Different flight identities must not create an event")
        expect(FleetTrackingPolicy.canInferTransition(previousAt: t, currentAt: t.addingTimeInterval(30),
                   previousKnown: true, currentKnown: true, previousCallsign: "ISR123", currentCallsign: "ISR123"),
               "Contiguous observations can contribute event evidence")

        expect(FleetTrackingPolicy.validAirport(" tlv ") == "TLV", "Airport normalization")
        expect(FleetTrackingPolicy.validAirport("TELAVIV") == nil, "Only IATA-like station codes are accepted")
        expect(FleetTrackingPolicy.routeAirports("ATH → TLV")?.origin == "ATH", "Route origin parsing")
        expect(FleetTrackingPolicy.routeAirports("ATH → TLV")?.destination == "TLV", "Route destination parsing")
        expect(FleetTrackingPolicy.routeAirports("GJT123") == nil, "Flight numbers are not routes")
        expect(FleetTrackingPolicy.rotationRelation(route: "ATH-TLV", airport: "TLV") == .inbound,
               "Inbound rotation relation")
        expect(FleetTrackingPolicy.rotationRelation(route: "TLV-LCA", airport: "TLV") == .outbound,
               "Outbound rotation relation")
        expect(FleetTrackingPolicy.rotationRelation(route: "ATH-LCA", airport: "TLV") == .unrelated,
               "Unrelated route relation")
        expect(FleetTrackingPolicy.dominantRotationAirport(
                   routes: ["TLV-ATH", "ATH-TLV", "TLV-LCA", "LCA-TLV"],
                   stations: ["TLV"], preferredAirports: ["TLV"]) == "TLV",
               "Tel Aviv rotation is dominant")
        expect(FleetTrackingPolicy.dominantRotationAirport(
                   routes: ["AUH-CAI", "CAI-AUH", "AUH-CMB"],
                   stations: ["AUH"], preferredAirports: ["AUH"]) == "AUH",
               "Abu Dhabi rotation is dominant")
        expect(FleetTrackingPolicy.dominantRotationAirport(
                   routes: ["ATH-LCA"], stations: [], preferredAirports: []) == nil,
               "Weak one-off route does not invent a rotation")

        expect(FleetTrackingPolicy.dominantRotationAirport(
                   routes: ["ATH-LCA", "LCA-ATH", "ATH-LCA"], stations: [], preferredAirports: []) == nil,
               "Equal evidence must not invent a rotation by alphabetical order")
        expect(FleetTrackingPolicy.rotationRouteLabel(route: "ATH-TLV", airport: "TLV",
                   isFresh: false, isAirborne: true) == "Last reported route · ATH-TLV",
               "Stale airborne observation must not claim inbound now")
        expect(FleetTrackingPolicy.rotationRouteLabel(route: "TLV-ATH", airport: "TLV",
                   isFresh: true, isAirborne: false) == "Last reported route · TLV-ATH",
               "Ground observation must not claim outbound now")
        expect(FleetTrackingPolicy.rotationRouteLabel(route: "ATH-TLV", airport: "TLV",
                   isFresh: true, isAirborne: true) == "Likely inbound TLV · ATH-TLV",
               "Fresh public route remains explicitly inferred")
        expect(FleetTrackingPolicy.rotationRouteLabel(route: "ATH-LCA", airport: "TLV",
                   isFresh: true, isAirborne: true) == nil, "Unrelated route has no rotation label")
        print("Passed \(checks) Fleet tracking policy checks")
    }
}
