import Foundation

// Presentation only: this policy never starts GPS or infers a takeoff.
struct FlightTrackingStatus: Equatable {
    enum Permission { case allowed, pending, blocked }
    let title: String
    let detail: String
    let symbol: String

    static func resolve(tracking: Bool, automatic: Bool, completed: Bool,
                        servicesEnabled: Bool, permission: Permission,
                        source: String?, estimated: Bool,
                        acquisitionAge: TimeInterval?, windowOpen: Bool,
                        upcomingStart: String?) -> Self {
        if completed {
            return Self(title: "Flight complete · route saved", detail: "The tracking session has ended.", symbol: "checkmark.circle")
        }
        if !servicesEnabled {
            return Self(title: "Location Services are off", detail: "Enable Location Services in iPhone Settings to use GPS.", symbol: "location.slash")
        }
        if permission == .blocked {
            return Self(title: "Location permission required", detail: "Allow location for RAIDORoster in iPhone Settings. Automatic background tracking needs Always access.", symbol: "location.slash")
        }
        if tracking {
            if permission == .pending {
                return Self(title: "Allow location to start tracking", detail: "Respond to the iPhone location permission prompt.", symbol: "location")
            }
            if let source {
                return Self(title: source,
                            detail: estimated ? "This position is estimated, not a fresh GPS measurement." : "A current measured position is available.",
                            symbol: estimated ? "location.circle" : "location.fill")
            }
            let waiting = (acquisitionAge ?? 0) < 45
            return Self(title: waiting ? "Acquiring GPS · route saved" : "No usable GPS fix · route saved",
                        detail: "Tracking is running. Offline route estimates begin only after takeoff is detected; a saved route alone is not a live position.",
                        symbol: waiting ? "location" : "location.slash")
        }
        if automatic, let start = upcomingStart {
            return Self(title: "Route saved · auto GPS from " + start,
                        detail: "Automatic tracking can start within 30 minutes of departure after a recent location fix confirms you are at the departure airport.",
                        symbol: "clock")
        }
        if automatic, windowOpen {
            return Self(title: "Waiting for departure-airport fix",
                        detail: "Automatic tracking needs a recent fix at the departure airport. While online, expand the map and choose Start Live GPS to begin acquiring location.",
                        symbol: "location")
        }
        return Self(title: "Route saved · tracking off", detail: "Expand the map and choose Start Live GPS to start a location session.", symbol: "map")
    }
}
