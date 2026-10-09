import XCTest
import WebKit
@testable import RAIDORoster

@MainActor
final class RosterBridgeTests: XCTestCase {
    private var recorder: Recorder?
    private var webView: WKWebView?
    private var fixtureWindow: UIWindow?

    func payload() -> [String: Any] {
        ["schemaVersion": 1, "sourceURL": "https://gjt.noc.vmc.navblue.cloud/RaidoMobile/Dialogues/HumanResources/HumanResourceRoster.aspx",
         "validation": ["isValid": true, "parser": "raido-duty-envelope-test", "month": "2026-10", "datedRows": 5],
         "rows": (8...12).map { ["id": "d-\($0)", "dateISO": "2026-10-\(String(format: "%02d", $0))", "rawText": "Sanitized duty", "activities": []] as [String: Any] }]
    }
    func testAcceptedPayloadAndInvalidUpdateRetainsCache() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RosterStore(storageFolderURL: folder, automaticSideEffects: false)
        let good = payload()
        store.ingest(messageBody: good)
        let saved = try XCTUnwrap(store.snapshot)
        XCTAssertEqual(saved.items.count, 5)
        XCTAssertNil(store.portalFormatWarning)
        var broken = good; broken["schemaVersion"] = 999
        store.ingest(messageBody: broken)
        XCTAssertEqual(store.snapshot, saved)
        XCTAssertNotNil(store.portalFormatWarning)
        store.ingest(messageBody: good)
        XCTAssertNil(store.portalFormatWarning)
    }
    func testOriginsAndNavigation() {
        XCTAssertTrue(PortalBridgePolicy.acceptsOrigin(scheme: "https", host: PortalBridgePolicy.portalHost, port: 443, mainFrame: true))
        XCTAssertFalse(PortalBridgePolicy.acceptsOrigin(scheme: "https", host: PortalBridgePolicy.portalHost, port: 443, mainFrame: false))
        XCTAssertFalse(PortalBridgePolicy.acceptsOrigin(scheme: "http", host: PortalBridgePolicy.portalHost, port: 80, mainFrame: true))
        XCTAssertFalse(PortalBridgePolicy.acceptsOrigin(scheme: "https", host: "gjt.noc.vmc.navblue.cloud.evil.invalid", port: 443, mainFrame: true))
        let external = URL(string: "https://example.invalid/")!
        XCTAssertEqual(PortalBridgePolicy.navigation(external, userTapped: false, popup: false), .blocked)
        XCTAssertEqual(PortalBridgePolicy.navigation(external, userTapped: true, popup: false), .external)
        XCTAssertEqual(PortalBridgePolicy.navigation(URL(string: "javascript:alert(1)")!, userTapped: true, popup: false), .blocked)
        XCTAssertEqual(PortalBridgePolicy.navigation(URL(string: "mailto:crew@example.invalid")!, userTapped: true, popup: false), .external)
        XCTAssertEqual(PortalBridgePolicy.navigation(URL(string: "https://\(PortalBridgePolicy.portalHost)/")!, userTapped: true, popup: true), .external)
    }
    func testDatesCountsFieldsAndSizeAreCheckedNatively() throws {
        XCTAssertFalse(PortalBridgePolicy.day("2026-02-30"))
        XCTAssertFalse(PortalBridgePolicy.stamp("2026-10-08 25:00"))
        var value = payload()
        value["schemaVersion"] = 0
        XCTAssertThrowsError(try PortalBridgePolicy.snapshot(value))
        value = payload(); value["schemaVersion"] = true
        XCTAssertThrowsError(try PortalBridgePolicy.snapshot(value))
        value = payload(); value["sourceURL"] = "https://example.invalid/"
        XCTAssertThrowsError(try PortalBridgePolicy.snapshot(value))
        value = payload(); var rows = value["rows"] as! [[String: Any]]
        rows[0]["dateISO"] = "2026-02-30"; value["rows"] = rows
        XCTAssertThrowsError(try PortalBridgePolicy.snapshot(value))
        value = payload(); value["extra"] = String(repeating: "x", count: 128_001)
        XCTAssertThrowsError(try PortalBridgePolicy.snapshot(value))
        value = payload(); rows = value["rows"] as! [[String: Any]]
        rows[0]["activities"] = [["title": "Flight", "startUTC": "2026-10-08 25:00"]]; value["rows"] = rows
        XCTAssertThrowsError(try PortalBridgePolicy.snapshot(value))
        value = payload()
        var nested: Any = "leaf"
        for _ in 0..<14 { nested = ["child": nested] }
        value["extra"] = nested
        XCTAssertThrowsError(try PortalBridgePolicy.snapshot(value))
        // Two separate duties on one date are legitimate; row IDs remain unique.
        value = payload(); rows = value["rows"] as! [[String: Any]]
        rows[1]["dateISO"] = rows[0]["dateISO"]; value["rows"] = rows
        XCTAssertNoThrow(try PortalBridgePolicy.snapshot(value))
        rows[1]["id"] = rows[0]["id"]; value["rows"] = rows
        XCTAssertThrowsError(try PortalBridgePolicy.snapshot(value))
    }
    func testCalendarFeedRejectsMalformedDates() throws {
        var feed: [String: Any] = ["schemaVersion": 1, "source": "n-oc-webcal", "events": [["dateISO": "2026-10-08", "startUTC": "2026-10-08 10:00", "endUTC": "2026-10-08 11:00"]]]
        XCTAssertNoThrow(try PortalBridgePolicy.calendarFeed(feed))
        feed["events"] = [["dateISO": "2026-10-08", "startUTC": "", "endUTC": "2026-10-08 11:00"]]
        XCTAssertThrowsError(try PortalBridgePolicy.calendarFeed(feed))
    }
    func testActualJavaScriptExtractsSanitizedHTML() async throws {
        let body = try await extract("roster", path: "HumanResourceRoster.aspx")
        let checked = try PortalBridgePolicy.snapshot(body)
        let rows = try XCTUnwrap(checked["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 5)
        let activity = try XCTUnwrap((rows[0]["activities"] as? [[String: Any]])?.first)
        XCTAssertEqual(activity["pickup"] as? String, "8 OCT • 07:50 LT")
        XCTAssertEqual(activity["route"] as? String, "TLV → HER")
    }
    func testChangedLayoutProducesExplicitFailure() async throws {
        let body = try await extract("changed-layout", path: "HumanResourceRoster.aspx")
        XCTAssertEqual(body["error"] as? String, "portal-format-changed")
    }
    func testLoginPageDoesNotReportParserFailure() async throws {
        let expectation = expectation(description: "No roster error on login")
        expectation.isInverted = true
        try loadFixture("login", path: "Login.aspx", expectation: expectation)
        await fulfillment(of: [expectation], timeout: 2)
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil; recorder = nil
        fixtureWindow?.isHidden = true; fixtureWindow = nil
    }
    private func extract(_ name: String, path: String) async throws -> [String: Any] {
        let expectation = expectation(description: "Script bridge payload")
        try loadFixture(name, path: path, expectation: expectation)
        await fulfillment(of: [expectation], timeout: 30)
        let body = try XCTUnwrap(recorder?.body)
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil; recorder = nil
        fixtureWindow?.isHidden = true; fixtureWindow = nil
        return body
    }
    private func loadFixture(_ name: String, path: String, expectation: XCTestExpectation) throws {
        let script = try String(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "RosterEnhancements", withExtension: "js")), encoding: .utf8)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "html"))
        let html = try String(contentsOf: url, encoding: .utf8)
        let controller = WKUserContentController()
        recorder = Recorder(expectation: expectation)
        controller.add(recorder!, name: "rosterCache")
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let config = WKWebViewConfiguration(); config.userContentController = controller
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        // Keep WebKit in a visible host so CI does not throttle its extraction timer.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController(); window.rootViewController = host
        host.view.addSubview(webView!); window.isHidden = false
        fixtureWindow = window
        webView?.loadHTMLString(html, baseURL: URL(string: "https://gjt.noc.vmc.navblue.cloud/RaidoMobile/\(path)"))
    }
}

@MainActor private final class Recorder: NSObject, WKScriptMessageHandler {
    let expectation: XCTestExpectation
    var body: [String: Any]?
    init(expectation: XCTestExpectation) { self.expectation = expectation }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard body == nil else { return }
        body = message.body as? [String: Any]
        expectation.fulfill()
    }
}
