import XCTest

@MainActor final class MapGestureUITests: XCTestCase {
    func testFourSectorsAcrossTwoDutyGroups() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.bobanilic.raidoroster")
        app.launchArguments = ["--startup", "--split-duty", "--theme=getJet", "--mode=dark"]
        app.launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15))
        for tab in ["Roster", "Today"] {
            tabs.buttons[tab].tap()
            if tab == "Roster" {
                let count = app.staticTexts["roster-day-sector-count"]
                XCTAssertTrue(count.waitForExistence(timeout: 5))
                XCTAssertEqual(count.label, "4 sectors")
            }
            for code in ["DI9003", "DI6656", "DI6657", "DI9004"] {
                let card = app.staticTexts["duty-sector-code-" + code].firstMatch
                for _ in 0..<12 where !card.isHittable { app.scrollViews.firstMatch.swipeUp() }
                XCTAssertTrue(card.isHittable, "Duty card missing for " + code + " in " + tab)
            }
            XCTAssertTrue(app.staticTexts["Duty 2 of 2"].exists)
        }
        app.terminate()
    }
    func testCleanInstallMobileLoginAndReturnToTabs() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.bobanilic.raidoroster")
        app.launchArguments = ["--startup", "--clean-install", "--theme=ice", "--mode=dark"]
        app.launch()
        let login = app.buttons["raido-welcome-login"]
        XCTAssertTrue(login.waitForExistence(timeout: 15)); XCTAssertTrue(login.isHittable)
        XCTAssertEqual(login.frame.midX, app.frame.midX, accuracy: 4)
        login.tap()
        let username = app.webViews.textFields.firstMatch
        let password = app.webViews.secureTextFields.firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 40), "Public mobile login form must load without credentials")
        XCTAssertTrue(password.exists)
        username.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        password.tap(); XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.webViews.buttons["Login"].exists)
        app.buttons["Reload RAIDO"].tap()
        XCTAssertTrue(username.waitForExistence(timeout: 40))
        app.buttons["Done"].firstMatch.tap()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        tabs.buttons["Roster"].tap(); XCTAssertTrue(tabs.buttons["Roster"].isSelected)
        tabs.buttons["Today"].tap(); XCTAssertTrue(login.waitForExistence(timeout: 5))
        login.tap(); XCTAssertTrue(username.waitForExistence(timeout: 40))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        app.terminate()
    }
    func testTodayReturnWithAutomaticMapAndNotificationsDisabled() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.bobanilic.raidoroster")
        app.launchArguments = ["--startup", "--today-return", "--priorities", "--theme=ice", "--mode=dark"]
        app.launch()
        // A first-run Flight Companion location prompt makes scenePhase
        // inactive. This scenario exercises cached UI without GPS permission;
        // answer the system prompt before asserting the active priority leaf.
        let systemAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if systemAlert.waitForExistence(timeout: 5) {
            XCTAssertTrue(systemAlert.staticTexts.matching(NSPredicate(format:
                "label CONTAINS[c] %@", "use your location")).firstMatch.exists,
                "Only the expected location prompt may be dismissed")
            let deny = systemAlert.buttons.matching(NSPredicate(format:
                "label IN %@", ["Don’t Allow", "Don't Allow"])).firstMatch
            XCTAssertTrue(deny.exists)
            deny.tap()
        }
        let tabs = app.tabBars.firstMatch
        let handle = app.buttons["today-map-handle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 15))
        XCTAssertEqual(handle.value as? String, "Collapsed")
        let pickup = app.buttons["today-pickup-countdown"]
        XCTAssertTrue(pickup.waitForExistence(timeout: 5), "Exercise the priority interface, not an empty Today shell")
        XCTAssertEqual(app.maps.count, 0, "A compact route must not construct Apple Maps, even with Auto selected")
        let requestedCycles = Int(ProcessInfo.processInfo.environment["RAIDO_UI_TRANSITION_CYCLES"] ?? "3") ?? 3
        let cycles = min(6, max(3, requestedCycles))
        print("RAIDO_UI_TRANSITION CONFIG cycles=\(cycles)")
        for cycle in 0..<cycles {
            tabs.buttons["Roster"].tap(); XCTAssertTrue(tabs.buttons["Roster"].isSelected)
            tabs.buttons["Today"].tap(); XCTAssertTrue(tabs.buttons["Today"].isSelected)
            XCTAssertTrue(handle.waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["Loading saved roster…"].exists)
            XCTAssertEqual(app.webViews.count, 0, "Tab selection must use the native cache without opening Live RAIDO")
            let before = handle.frame.minY
            app.scrollViews.firstMatch.swipeUp()
            XCTAssertLessThan(handle.frame.minY, before - 20, "Today must scroll after returning from Roster")
            XCTAssertEqual(app.maps.count, 0)
            print("RAIDO_UI_TRANSITION BEGIN cycle-\(cycle)-more uptime=\(ProcessInfo.processInfo.systemUptime)")
            tabs.buttons["More"].tap(); XCTAssertTrue(tabs.buttons["More"].isSelected)
            print("RAIDO_UI_TRANSITION END cycle-\(cycle)-more uptime=\(ProcessInfo.processInfo.systemUptime)")
            print("RAIDO_UI_TRANSITION BEGIN cycle-\(cycle)-today uptime=\(ProcessInfo.processInfo.systemUptime)")
            tabs.buttons["Today"].tap(); XCTAssertTrue(tabs.buttons["Today"].isSelected)
            print("RAIDO_UI_TRANSITION END cycle-\(cycle)-today uptime=\(ProcessInfo.processInfo.systemUptime)")
            app.scrollViews.firstMatch.swipeDown()
        }
        let previousLabel = pickup.label
        let previousMapY = handle.frame.minY
        let minuteTick = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            pickup.label != previousLabel
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [minuteTick], timeout: 75), .completed,
                       "The native countdown must update while the cached briefing stays interactive")
        XCTAssertEqual(handle.frame.minY, previousMapY, accuracy: 2, "A countdown tick must preserve Today scroll position")
        pickup.tap()
        XCTAssertTrue(app.navigationBars["Crew pickup"].waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        app.terminate()
        // Keep the on-disk cache from the first process; the host must not
        // recreate the fixture or download a roster before this launch.
        app.launchArguments.append("--reuse-startup-cache")
        app.launch()
        XCTAssertTrue(handle.waitForExistence(timeout: 15))
        tabs.buttons["Roster"].tap(); XCTAssertTrue(tabs.buttons["Roster"].isSelected)
        tabs.buttons["Today"].tap(); XCTAssertTrue(tabs.buttons["Today"].isSelected)
        XCTAssertTrue(pickup.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Loading saved roster…"].exists)
        XCTAssertEqual(app.webViews.count, 0)
        app.scrollViews.firstMatch.swipeUp()
        print("RAIDO_UI_TRANSITION BEGIN restored-more uptime=\(ProcessInfo.processInfo.systemUptime)")
        tabs.buttons["More"].tap(); XCTAssertTrue(tabs.buttons["More"].isSelected)
        print("RAIDO_UI_TRANSITION END restored-more uptime=\(ProcessInfo.processInfo.systemUptime)")
        app.terminate()
    }
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
