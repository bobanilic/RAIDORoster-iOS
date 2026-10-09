import XCTest
@testable import RAIDORoster

final class FlightPowerTests: XCTestCase {
    func testArmedAndTakeoffKeepBackgroundDetection() {
        for phase in ["parked", "armed", "groundCandidate", "taxiOut", "takeoffRoll"] {
            let resources = FlightPowerPolicy.resolve(active: true, phase: phase, saving: true, foreground: false, accuracyFix: false)
            XCTAssertTrue(resources.location, phase)
            XCTAssertTrue(resources.motion, phase)
            XCTAssertTrue(resources.backgroundLocation, phase)
            XCTAssertFalse(resources.estimated, phase)
        }
    }
    func testCruiseAndDescentHaveNoBackgroundWork() {
        for phase in ["airborne", "descent"] {
            let resources = FlightPowerPolicy.resolve(active: true, phase: phase, saving: true, foreground: false, accuracyFix: false)
            XCTAssertTrue(resources.estimated)
            XCTAssertFalse(resources.location)
            XCTAssertFalse(resources.motion)
            XCTAssertFalse(resources.network)
            XCTAssertFalse(resources.backgroundLocation)
            XCTAssertFalse(resources.timer)
            let visible = FlightPowerPolicy.resolve(active: true, phase: phase, saving: true, foreground: true, accuracyFix: false)
            XCTAssertTrue(visible.timer)
            XCTAssertFalse(visible.location)
        }
    }
    func testDemandFixIsGPSOnlyAndForegroundOnly() {
        let fix = FlightPowerPolicy.resolve(active: true, phase: "airborne", saving: true, foreground: true, accuracyFix: true)
        XCTAssertTrue(fix.location)
        XCTAssertFalse(fix.backgroundLocation)
        XCTAssertFalse(fix.motion)
        XCTAssertFalse(fix.network)
        XCTAssertEqual(FlightPowerPolicy.accuracyFixSeconds, 45)
        let locked = FlightPowerPolicy.resolve(active: true, phase: "airborne", saving: true, foreground: false, accuracyFix: true)
        XCTAssertFalse(locked.location)
        XCTAssertFalse(locked.timer)
    }
    func testContinuousModeRemainsAvailable() {
        let live = FlightPowerPolicy.resolve(active: true, phase: "airborne", saving: false, foreground: false, accuracyFix: false)
        XCTAssertTrue(live.location)
        XCTAssertTrue(live.motion)
        XCTAssertTrue(live.network)
        XCTAssertTrue(live.backgroundLocation)
        XCTAssertFalse(live.estimated)
    }
    func testIdleAndCompleteStopResources() {
        for phase in ["parked", "armed", "taxiOut", "takeoffRoll", "airborne", "descent", "taxiIn", "complete"] {
            let idle = FlightPowerPolicy.resolve(active: false, phase: phase, saving: true, foreground: true, accuracyFix: true)
            XCTAssertFalse(idle.location, phase)
            XCTAssertFalse(idle.motion, phase)
            XCTAssertFalse(idle.network, phase)
            XCTAssertFalse(idle.backgroundLocation, phase)
            XCTAssertFalse(idle.timer, phase)
        }
        let complete = FlightPowerPolicy.resolve(active: true, phase: "complete", saving: false, foreground: true, accuracyFix: true)
        XCTAssertFalse(complete.location)
        XCTAssertFalse(complete.motion)
        XCTAssertFalse(complete.network)
        XCTAssertFalse(complete.timer)
    }
    func testEstimatedArrivalRemainsOffAndNeedsPlausibleProgress() {
        let arrival = FlightPowerPolicy.resolve(active: true, phase: "taxiIn", saving: true, foreground: false, accuracyFix: false, estimatedArrival: true)
        XCTAssertFalse(arrival.location)
        XCTAssertFalse(arrival.motion)
        XCTAssertFalse(arrival.network)
        XCTAssertFalse(arrival.timer)
        let takeoff = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertFalse(FlightPowerPolicy.canEstimateArrival(takeoff: takeoff, progress: 1, now: takeoff.addingTimeInterval(60)))
        XCTAssertFalse(FlightPowerPolicy.canEstimateArrival(takeoff: takeoff, progress: 0.9, now: takeoff.addingTimeInterval(3600)))
        XCTAssertFalse(FlightPowerPolicy.canEstimateArrival(takeoff: takeoff, progress: .nan, now: takeoff.addingTimeInterval(3600)))
        XCTAssertFalse(FlightPowerPolicy.canEstimateArrival(takeoff: takeoff, progress: nil, now: takeoff.addingTimeInterval(3600)))
        XCTAssertTrue(FlightPowerPolicy.canEstimateArrival(takeoff: takeoff, progress: 1, now: takeoff.addingTimeInterval(3600)))
    }
}
