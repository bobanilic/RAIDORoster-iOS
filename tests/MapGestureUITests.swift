import XCTest

@MainActor final class MapGestureUITests: XCTestCase {
    func testBroadSwipesAndMapPanning() {
        continueAfterFailure = false
        for theme in ["ice", "getJet"] {
            let app = XCUIApplication(bundleIdentifier: "com.bobanilic.raidoroster")
            app.launchArguments = ["--theme=" + theme, "--mode=dark", "--tab=today"]
            app.launch()
            let handle = app.buttons["today-map-handle"]
            XCTAssertTrue(handle.waitForExistence(timeout: 15))
            XCTAssertEqual(handle.value as? String, "Collapsed")
            XCTAssertFalse(app.otherElements["today-map-tracking-status"].exists, "Idle preflight banner must be hidden")
            let surface = app.otherElements["today-map-surface"].firstMatch
            XCTAssertTrue(surface.exists)
            let surfaceY = surface.frame.minY
            XCTAssertEqual(surface.frame.height, 324, accuracy: 2, "Keep the total compact header footprint")
            XCTAssertFalse(app.staticTexts["Tap or pull down for map"].exists)
            let page = app.scrollViews.firstMatch
            let broadStart = page.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45))
            broadStart.press(forDuration: 0.05, thenDragTo: broadStart.withOffset(CGVector(dx: 0, dy: 180)))
            XCTAssertTrue(NSPredicate(format: "value == %@", "Expanded").evaluate(with: handle) ||
                XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Expanded"), object: handle)], timeout: 5) == .completed)
            XCTAssertEqual(surface.frame.minY, surfaceY, accuracy: 2, "Downward disclosure must keep the page at the top")
            let collapseStart = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.72))
            collapseStart.press(forDuration: 0.05, thenDragTo: collapseStart.withOffset(CGVector(dx: 0, dy: -180)))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Collapsed"), object: handle)], timeout: 5), .completed)
            handle.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Expanded"), object: handle)], timeout: 5), .completed)
            let map = app.otherElements["offline-map-interaction"].firstMatch
            XCTAssertTrue(map.exists)
            let pageY = handle.frame.minY
            let beforePan = map.value as? String
            let start = map.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.65))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -60)))
            XCTAssertNotEqual(map.value as? String, beforePan, "Vertical drag must move the offline map")
            XCTAssertEqual(handle.frame.minY, pageY, accuracy: 2, "Map drag must not scroll Today")
            let afterUp = map.value as? String
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 60)))
            XCTAssertNotEqual(map.value as? String, afterUp, "Downward drag must also pan the map")
            XCTAssertEqual(handle.frame.minY, pageY, accuracy: 2)
            let beforePinch = map.value as? String
            map.pinch(withScale: 1.5, velocity: 1)
            XCTAssertNotEqual(map.value as? String, beforePinch, "Pinch must zoom the offline map")
            XCTAssertEqual(handle.frame.minY, pageY, accuracy: 2, "Pinch must not scroll Today")
            handle.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Collapsed"), object: handle)], timeout: 5), .completed)
            let collapsedY = handle.frame.minY
            let agenda = page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            agenda.press(forDuration: 0.05, thenDragTo: agenda.withOffset(CGVector(dx: 0, dy: -90)))
            XCTAssertLessThan(handle.frame.minY, collapsedY - 20, "Page scrolling must remain available outside the map")
            app.terminate()
        }
    }
}
