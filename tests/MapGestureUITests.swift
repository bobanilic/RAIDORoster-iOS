import XCTest

@MainActor final class MapGestureUITests: XCTestCase {
    func testProductionLaunchAndTabResponsiveness() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier:"com.bobanilic.raidoroster")
        app.launchArguments = ["--startup","--theme=ice","--mode=dark"]
        for _ in 0..<2 {
            app.launch()
            let tabs = app.tabBars.firstMatch
            XCTAssertTrue(tabs.waitForExistence(timeout:15))
            tabs.buttons["Roster"].tap()
            XCTAssertTrue(tabs.buttons["Roster"].isSelected)
            tabs.buttons["More"].tap()
            let settings = app.buttons["more-settings"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout:5));settings.tap()
            let lockScreen = app.buttons["settings-lock-screen"].firstMatch
            for _ in 0..<6 where !lockScreen.isHittable { app.swipeUp() }
            XCTAssertTrue(lockScreen.exists);lockScreen.tap()
            let sample = app.buttons["Pickup reminder"]
            for _ in 0..<5 where !sample.isHittable { app.swipeUp() }
            XCTAssertTrue(sample.exists);sample.tap()
            let toast = app.descendants(matching:.any)["raido-toast"].firstMatch
            XCTAssertTrue(toast.waitForExistence(timeout:5))
            toast.tap()
            XCTAssertTrue(app.buttons["Roster updated"].exists,"Toast dismissal leaves Settings responsive")
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(app.buttons["Roster updated"].waitForExistence(timeout:5))
            app.terminate()
        }
    }
    func testPriorityCountdownStripAndDetailsInBothThemes() {
        continueAfterFailure = false
        for theme in ["ice","getJet"] {
            let app = XCUIApplication(bundleIdentifier:"com.bobanilic.raidoroster")
            app.launchArguments=["--theme="+theme,"--mode=dark","--tab=today","--priorities"]
            app.launch()
            let counter=app.buttons["today-pickup-countdown"]
            XCTAssertTrue(counter.waitForExistence(timeout:15))
            let alcohol=app.buttons["today-priority-alcohol"]
            XCTAssertTrue(alcohol.exists)
            let position=counter.frame.minY
            app.scrollViews.firstMatch.swipeUp()
            XCTAssertEqual(counter.frame.minY,position,accuracy:2,"Countdown stays above the tab bar while Today scrolls")
            counter.tap()
            XCTAssertTrue(app.navigationBars["Crew pickup"].waitForExistence(timeout:5))
            app.buttons["Done"].firstMatch.tap()
            XCTAssertTrue(counter.waitForExistence(timeout:5))
            app.terminate()
        }
    }
    func testFutureRelocationIsVisibleOnOffDay() {
        continueAfterFailure=false
        let app=XCUIApplication(bundleIdentifier:"com.bobanilic.raidoroster")
        app.launchArguments=["--theme=getJet","--mode=light","--tab=today","--priorities","--off-day"]
        app.launch()
        let move=app.buttons["today-priority-relocation"]
        XCTAssertTrue(move.waitForExistence(timeout:15))
        for _ in 0..<3 where !move.isHittable { app.scrollViews.firstMatch.swipeUp() }
        move.tap()
        XCTAssertTrue(app.navigationBars["Hotel relocation"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Relocation time not provided"].exists)
        XCTAssertTrue(app.buttons["Find hotel in Maps"].exists)
        app.terminate()
    }
    func testHistoricalRouteExpandsAndSelectsSector() {
        continueAfterFailure=false
        let app=XCUIApplication(bundleIdentifier:"com.bobanilic.raidoroster")
        app.launchArguments=["--theme=getJet","--mode=dark","--tab=roster"]
        app.launch()
        let map=app.buttons["historical-route-map"]
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout:15))
        for _ in 0..<5 where !map.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(map.exists)
        let sector=app.buttons["GJT102"]
        if sector.isHittable { sector.tap() }
        map.tap()
        XCTAssertTrue(app.navigationBars["Scheduled route"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["Recenter"].exists)
        let screenshot=XCTAttachment(screenshot:app.screenshot());screenshot.lifetime = .keepAlways;add(screenshot)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(map.waitForExistence(timeout:5))
        app.terminate()
    }
    func testPaletteSettingsPersistIndependently() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.bobanilic.raidoroster")
        app.launchArguments = ["--theme=getJet", "--mode=light", "--settings"]
        app.launch()
        let link = app.buttons["settings-color-palette"]
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        link.tap()
        let wine = app.buttons["palette-option-burgundyRose"]
        XCTAssertTrue(wine.waitForExistence(timeout: 5))
        wine.tap()
        XCTAssertEqual(wine.value as? String, "Selected")
        app.navigationBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Burgundy & Rose"].exists)
        app.buttons["Ice"].tap()
        link.tap()
        let blue = app.buttons["palette-option-iceBlue"]
        XCTAssertTrue(blue.waitForExistence(timeout: 5))
        blue.tap()
        XCTAssertEqual(blue.value as? String, "Selected")
        app.navigationBars.buttons["Settings"].tap()
        app.buttons["GetJet"].tap()
        XCTAssertTrue(app.staticTexts["Burgundy & Rose"].exists, "Switching theme preserves its palette")
        app.terminate()
        app.launch()
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Burgundy & Rose"].exists, "Palette persists after relaunch")
        app.terminate()
    }

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
            XCTAssertEqual(app.otherElements["offline-map-interaction"].firstMatch.value as? String,
                "zoom=1.000;panX=0.0;panY=0.0", "Collapse must reset after the map's final pan sample")
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
