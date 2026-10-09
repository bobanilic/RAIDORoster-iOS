import Foundation

@main struct FlightTrackingStatusChecks {
    static func main() {
        func status(tracking: Bool = false, automatic: Bool = true, completed: Bool = false,
                    enabled: Bool = true, permission: FlightTrackingStatus.Permission = .allowed,
                    source: String? = nil, estimated: Bool = false,
                    age: TimeInterval? = nil, window: Bool = false, start: String? = nil) -> FlightTrackingStatus {
            FlightTrackingStatus.resolve(tracking: tracking, automatic: automatic, completed: completed,
                servicesEnabled: enabled, permission: permission, source: source, estimated: estimated,
                acquisitionAge: age, windowOpen: window, upcomingStart: start)
        }
        precondition(status(start: "09:20").title == "Route saved · auto GPS from 09:20")
        precondition(status(window: true).title == "Waiting for departure-airport fix")
        precondition(status(automatic: false).title == "Route saved · tracking off")
        precondition(status(tracking: true, age: 44).title == "Acquiring GPS · route saved")
        precondition(status(tracking: true, age: 45).title == "No usable GPS fix · route saved")
        precondition(status(tracking: true, age: 300).title == "No usable GPS fix · route saved")
        precondition(status(tracking: true, permission: .pending).title == "Allow location to start tracking")
        precondition(status(permission: .blocked, start: "09:20").title == "Location permission required")
        precondition(status(enabled: false, start: "09:20").title == "Location Services are off")
        precondition(status(tracking: true, source: "iPhone GNSS").title == "iPhone GNSS")
        precondition(status(tracking: true, source: "ADS-B live").title == "ADS-B live")
        precondition(status(tracking: true, source: "Estimated · route model", estimated: true).detail.contains("estimated"))
        precondition(status(tracking: true, source: "Last GNSS fix", estimated: true).detail.contains("not a fresh GPS"))
        precondition(status(source: "Old source", start: "09:20").title.contains("auto GPS"))
        precondition(status(automatic: false, source: "Old source").title.contains("tracking off"))
        precondition(status(completed: true).title == "Flight complete · route saved")
        precondition(status(tracking: true).detail.contains("only after takeoff is detected"))
        print("Passed 17 GPS status checks: future duty, airport gate, permission, acquisition, loss, estimation, completion")
    }
}
