import Foundation

@main
struct FlightSensorPolicyChecks {
    static func main() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label); checks += 1
        }
        func date(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }
        func replay(_ phase: FlightSensorPolicy.Phase, seconds: Int,
                    motion: (Double) -> Double, altitude: (Double) -> Double,
                    dropAltitude: (Double) -> Bool = { _ in false },
                    dropMotion: (Double) -> Bool = { _ in false }) -> [FlightSensorPolicy.Event] {
            var policy = FlightSensorPolicy()
            policy.setPhase(phase)
            var events: [FlightSensorPolicy.Event] = []
            for n in 0...(seconds * 5) {
                let t = Double(n) / 5
                if !dropMotion(t), let event = policy.ingestMotion(motion(t), at: date(t), receivedAt: date(t)) { events.append(event) }
                if n % 5 == 0, !dropAltitude(t), let event = policy.ingestAltitude(altitude(t), at: date(t), receivedAt: date(t)) { events.append(event) }
            }
            return events
        }
        let roll: (Double) -> Double = { $0 < 25 ? 0.20 : 0 }
        let climb: (Double) -> Double = { max(0, $0 - 30) * 2 }
        let validTakeoff = replay(.preflight, seconds: 100, motion: roll, altitude: climb)
        expect(validTakeoff.contains { if case .takeoff = $0 { return true }; return false }, "Sustained roll followed by cabin climb is detected")
        expect(replay(.preflight, seconds: 100, motion: roll, altitude: { _ in 0 }).isEmpty,
               "An acceleration burst without cabin climb is not takeoff")
        expect(replay(.preflight, seconds: 100, motion: { _ in 0 }, altitude: climb).isEmpty,
               "Elevator/cabin climb without a roll is not takeoff")
        expect(replay(.preflight, seconds: 100, motion: { $0 < 7 ? 0.20 : 0 }, altitude: climb).isEmpty,
               "A short movement is not a takeoff roll")
        expect(replay(.preflight, seconds: 100, motion: roll, altitude: climb,
                      dropAltitude: { $0 > 50 }).isEmpty, "Motion cannot advance a stale cabin-climb timer")
        expect(replay(.preflight, seconds: 100, motion: roll, altitude: climb,
                      dropMotion: { $0 >= 8 && $0 <= 23 }).isEmpty, "A roll cannot bridge a motion gap")
        expect(replay(.preflight, seconds: 100, motion: roll, altitude: climb,
                      dropAltitude: { $0 >= 40 && $0 <= 55 }).isEmpty, "Takeoff pressure evidence cannot bridge suspension")
        expect(replay(.inactive, seconds: 100, motion: roll, altitude: climb).isEmpty,
               "An idle/completed session cannot emit sensor transitions")
        let braking: (Double) -> Double = { $0 >= 180 && $0 <= 200 ? 0.20 : 0 }
        let descent: (Double) -> Double = { -min($0, 145) * 2 }
        let validLanding = replay(.airborne, seconds: 230, motion: braking, altitude: descent)
        expect(validLanding.contains { if case .landing = $0 { return true }; return false },
               "Sustained descent, flat pressure and braking detect landing")
        expect(replay(.airborne, seconds: 230, motion: braking, altitude: { _ in 0 }).isEmpty,
               "Walking/braking at cruise without cabin descent is not landing")
        expect(replay(.airborne, seconds: 230, motion: braking, altitude: { -$0 * 2 }).isEmpty,
               "A burst while cabin pressure is still descending is not landing")
        expect(replay(.airborne, seconds: 230, motion: braking, altitude: descent,
                      dropAltitude: { $0 > 160 }).isEmpty, "Stale flat pressure cannot certify braking")
        expect(replay(.airborne, seconds: 900, motion: { $0 >= 850 && $0 <= 870 ? 0.20 : 0 }, altitude: descent).isEmpty,
               "Old cabin descent expires before an unrelated later burst")
        expect(replay(.airborne, seconds: 300, motion: { $0 >= 260 && $0 <= 280 ? 0.20 : 0 },
                      altitude: { $0 < 145 ? -$0 * 2 : ($0 < 210 ? -290 + ($0 - 145) * 2 : -160) }).isEmpty,
               "A renewed cabin climb invalidates descent evidence")
        var policy = FlightSensorPolicy()
        policy.setPhase(.preflight)
        _ = policy.ingestMotion(0.2, at: date(0), receivedAt: date(10))
        expect(policy.rejectedSamples == 1, "Delayed deliveries are rejected")
        _ = policy.ingestMotion(0.2, at: date(10), receivedAt: date(10))
        _ = policy.ingestMotion(0.2, at: date(10), receivedAt: date(10))
        expect(policy.rejectedSamples == 2, "Duplicate motion samples are rejected")
        policy.reset(to: .airborne)
        expect(policy.smoothedAcceleration == 0 && policy.climbRateFtMin == nil,
               "A new sector starts without evidence from the previous session")
        expect(FlightSensorPolicy.sampleDate(uptime: 99, receivedAt: base, currentUptime: 100) == date(-1),
               "Motion uptime is converted to the sample date")
        expect(FlightSensorPolicy.sampleDate(uptime: 90, receivedAt: base, currentUptime: 100) == nil,
               "Old Core Motion timestamps are rejected")
        expect(FlightSensorPolicy.sampleDate(uptime: 101, receivedAt: base, currentUptime: 100) == nil,
               "Future sensor timestamps are rejected")
        let departure = date(-720), arrival = date(10_800)
        func canLand(progress: Double?, conflict: Bool = false, now: Date = base.addingTimeInterval(9_000)) -> Bool {
            FlightSensorSessionPolicy.canLand(takeoff: base, departure: departure, arrival: arrival,
                                              progress: progress, conflictingMeasurement: conflict, now: now)
        }
        expect(!canLand(progress: nil), "Missing route progress fails closed")
        expect(!canLand(progress: 0.69), "Early-route braking does not imply arrival")
        expect(!canLand(progress: .nan), "Nonfinite progress is rejected")
        expect(!canLand(progress: 0.9, conflict: true), "Fresh contradictory GNSS/ADS-B vetoes sensor landing")
        expect(canLand(progress: 0.9), "Valid bounded arrival is accepted")
        expect(!canLand(progress: 0.9, now: date(500)), "Minimum airborne duration enforced")
        expect(!canLand(progress: 0.9, now: date(30_000)), "Expired arrival window rejected")
        expect(FlightSensorSessionPolicy.arrivalWindow(takeoff: date(10_000), departure: base,
                   arrival: date(18_000), now: date(28_000)), "Delayed long flight survives departure-only gate")
        expect(!FlightSensorSessionPolicy.arrivalWindow(takeoff: base, departure: nil,
                   arrival: nil, now: date(19 * 3600)), "Manual sessions also have an upper bound")
        expect(FlightSensorSessionPolicy.cruiseSpeed(distance: 900_000, departure: base, arrival: date(5_400)) > 200,
               "Route model uses scheduled airborne duration")
        expect(FlightSensorSessionPolicy.cruiseSpeed(distance: 1, departure: nil, arrival: nil) == 220,
               "Unavailable roster geometry has an explicit fallback")
        print("Passed \(checks) Flight Sensor policy checks")
    }
}
