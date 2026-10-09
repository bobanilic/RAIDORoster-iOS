import XCTest
@testable import RAIDORoster

final class FlightRequestSlotTests: XCTestCase {
    func testFinishingCancelledRequestCannotLoseReplacement() async throws {
        let old = Task<String, Error> { try await Task.sleep(nanoseconds: 30_000_000_000); return "old" }
        let current = Task<String, Error> { try await Task.sleep(nanoseconds: 30_000_000_000); return "new" }
        defer { old.cancel(); current.cancel() }
        var slot = FlightRequestSlot<String>()
        let oldID = slot.replace(with: old)
        let newID = slot.replace(with: current)
        do { _ = try await old.value; XCTFail("Old request must be cancelled") } catch is CancellationError { }
        slot.finish(oldID)
        XCTAssertTrue(slot.isActive, "Old cleanup must leave the current request cancellable")
        slot.cancel()
        XCTAssertFalse(slot.isActive)
        do { _ = try await current.value; XCTFail("Replacement must still be cancellable") } catch is CancellationError { }
        slot.finish(newID)
        XCTAssertFalse(slot.isActive)
    }
    func testFinishedRequestReleasesHandleWithoutCancellingResult() async throws {
        let task = Task<String, Error> { "completed" }
        var slot = FlightRequestSlot<String>()
        let id = slot.replace(with: task)
        let value = try await task.value
        slot.finish(id)
        XCTAssertEqual(value, "completed")
        XCTAssertFalse(slot.isActive)
        XCTAssertFalse(task.isCancelled)
    }
}
