import Foundation

/// A tracking session may remain active while GPS, motion and network are off.
enum FlightPowerPolicy {
    static let preferenceKey = "RAIDORoster.Flight.SaveBattery"
    static let accuracyFixSeconds: TimeInterval = 45
    struct Resources: Equatable {
        let estimated: Bool
        let location: Bool
        let motion: Bool
        let network: Bool
        let backgroundLocation: Bool
        let timer: Bool
    }
    static func resolve(active: Bool, phase: String, saving: Bool, foreground: Bool,
                        accuracyFix: Bool, estimatedArrival: Bool = false) -> Resources {
        let finished = phase == "complete"
        let flight = ["airborne", "descent"].contains(phase)
        let estimated = (saving && flight) || (estimatedArrival && phase == "taxiIn")
        let pulse = accuracyFix && foreground && estimated
        let location = active && !finished && (!estimated || pulse)
        let preflight = ["parked", "armed", "groundCandidate", "taxiOut", "takeoffRoll"].contains(phase)
        return Resources(estimated: estimated, location: location,
            motion: active && !finished && (preflight || (flight && !saving)),
            network: active && !finished && !estimated,
            backgroundLocation: location && !pulse,
            timer: active && !finished && (!estimated || foreground))
    }
    static func canEstimateArrival(takeoff: Date, progress: Double?, now: Date) -> Bool {
        now.timeIntervalSince(takeoff) >= 12 * 60 && progress.map { $0.isFinite && $0 >= 1 } == true
    }
}
