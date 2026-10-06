import XCTest

@MainActor final class MapGestureUITests: XCTestCase {
    func testSwipeExpansionAndHandleCollapse() {
        continueAfterFailure = false
        for theme in ["ice", "getJet"] {
            let app = XCUIApplication(bundleIdentifier: "com.bobanilic.raidoroster")
            app.launchArguments = ["--theme=" + theme, "--mode=dark", "--tab=today"]
            app.launch()
            let handle = app.buttons["today-map-handle"]
            XCTAssertTrue(handle.waitForExistence(timeout: 15))
            XCTAssertEqual(handle.value as? String, "Collapsed")
            let surface = app.otherElements["today-map-surface"].firstMatch
            XCTAssertTrue(surface.exists)
            surface.swipeDown(velocity: .slow)
            XCTAssertTrue(NSPredicate(format: "value == %@", "Expanded").evaluate(with: handle) ||
                XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Expanded"), object: handle)], timeout: 5) == .completed)
            handle.swipeUp(velocity: .slow)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Collapsed"), object: handle)], timeout: 5), .completed)
            handle.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Expanded"), object: handle)], timeout: 5), .completed)
            handle.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Collapsed"), object: handle)], timeout: 5), .completed)
            app.terminate()
        }
    }
}
