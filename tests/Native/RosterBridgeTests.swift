import XCTest
import WebKit
import Combine
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
        XCTAssertEqual(PortalBridgePolicy.navigation(URL(string: "https://\(PortalBridgePolicy.portalHost)/")!, userTapped: true, popup: true), .portal)
    }
    func testMobileEntryAndRecoveryStates() async throws {
        let defaults = UserDefaults.standard
        let key = "RAIDORoster.LastPortalURL", previous = defaults.object(forKey: "RAIDORoster.LastPortalURL")
        defer { if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) } }
        defaults.removeObject(forKey: key)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = RosterBrowserModel(store: RosterStore(storageFolderURL: folder, automaticSideEffects: false))
        XCTAssertEqual(model.preferredStartURL.absoluteString, "https://gjt.noc.vmc.navblue.cloud/raidomobile/")
        defaults.set("https://gjt.noc.vmc.navblue.cloud/", forKey: key)
        XCTAssertEqual(model.preferredStartURL, RosterBrowserModel.startURL, "Discard the legacy chooser preference")
        defaults.set("https://example.invalid/HumanResourceRoster.aspx", forKey: key)
        XCTAssertEqual(model.preferredStartURL, RosterBrowserModel.startURL)
        let timedOut = expectation(description: "Navigation watchdog reports its failure")
        let timeoutObservation = model.$loadError.compactMap { $0 }.first().sink { _ in timedOut.fulfill() }
        defer { timeoutObservation.cancel() }
        model.navigationStarted(timeout: .milliseconds(20))
        XCTAssertTrue(model.isLoading)
        // Observe the actual watchdog publication. A fixed sleep can resume
        // before the watchdog task on a busy simulator's main actor.
        await fulfillment(of: [timedOut], timeout: 5)
        XCTAssertFalse(model.isLoading); XCTAssertNotNil(model.loadError)
        let cancelledTimeout = expectation(description: "Finished navigation must not report a timeout")
        cancelledTimeout.isInverted = true
        // Clear the previous error before observing any new failure.
        model.navigationStarted(timeout: .milliseconds(20)); model.navigationFinished()
        let cancellationObservation = model.$loadError.compactMap { $0 }.sink { _ in cancelledTimeout.fulfill() }
        defer { cancellationObservation.cancel() }
        await fulfillment(of: [cancelledTimeout], timeout: 0.2)
        XCTAssertNil(model.loadError, "Finished navigation cancels its timeout")
        let coordinator = RosterWebView.Coordinator(model: model)
        coordinator.webViewWebContentProcessDidTerminate(WKWebView())
        XCTAssertNotNil(model.loadError)
        model.navigationStarted(); model.navigationFinished()
        XCTAssertNil(model.loadError, "Retry clears the terminated-page failure")
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
    func testActualNativeReferenceKeepsFlightProjectionAndAddsOtherActivities() async throws {
        let ready = expectation(description: "Native timing fixture ready")
        try loadFixture("roster", path: "HumanResourceRoster.aspx", expectation: ready)
        defer {
            webView?.configuration.userContentController.removeAllScriptMessageHandlers()
            webView = nil; recorder = nil; fixtureWindow?.isHidden = true; fixtureWindow = nil
        }
        await fulfillment(of: [ready], timeout: 60)
        let view = try XCTUnwrap(webView), probe = NativeRAIDOExperiment()
        // Navigation discovery and the complete history snapshot are unrelated
        // to this check. The actual dedicated parser must work without either.
        _ = try await view.evaluateJavaScript("""
            for (const key of ['inspect','discover','navigate']) {
              window.RAIDOPlus.history[key] = () => { throw Error('Unrelated history API called'); };
            }
            window.RAIDOPlus.extractNow = () => { throw Error('Extraction posting called'); };
            true; // Return a bridgeable primitive, not the assigned JS function.
            """)
        let first = await probe.timingReference(in: view, month: "2026-10")
        guard case .ready(let reference) = first else { XCTFail("Actual timing reference unavailable: \(first)"); return }
        XCTAssertEqual(reference.activities.count, 5)
        XCTAssertEqual(reference.activities.first?.startUTC, "2026-10-08 06:50")
        XCTAssertEqual(reference.activities.first?.route, "TLV → HER")
        XCTAssertEqual(reference.version, 3)
        XCTAssertEqual(reference.otherActivities?.count, 0)
        XCTAssertEqual(reference.activities.first?.checkInLT, "2026-10-08 08:50")
        XCTAssertEqual(reference.activities.first?.checkInUTC, "2026-10-08 05:50")
        XCTAssertEqual(reference.activities.first?.checkOutUTC, "")
        let days = try (8...12).map { day -> NativeRAIDOWire.Entry in
            let date = String(format: "2026-10-%02d", day)
            let activity = NativeRAIDOWire.Activity(id: Int64(day), activity: "6H501", departure: "TLV", arrival: "HER",
                std: "0650", sta: "0840", checkIn: "0850", checkOut: nil,
                validFrom: try .init(date + "T06:50:00.0000000"), validTo: try .init(date + "T08:40:00.0000000"), details: nil)
            return .init(calendarDay: date, day: .init(details: .init(activities: [activity]), notes: []))
        }
        let wire = NativeRAIDOWire.Decoded(responseDate: try .init("2026-10-01T00:00:00"), days: days)
        let evidence = NativeRAIDOTiming.compare(wire, reference: reference)
        XCTAssertEqual(evidence.paired, 5); XCTAssertEqual(evidence.utcOnly, 10)
        let fields = NativeRAIDOFlightValidation.assess(NativeRAIDOTiming.pair(wire, reference: reference))
        XCTAssertEqual(fields.std.utcOnly, 5); XCTAssertEqual(fields.checkIn.localOnly, 5)
        XCTAssertTrue(NativeRAIDOTiming.message(wire, before: first, after: first, jsonMatched: true).contains("UTC minutes"))
        view.isHidden = true
        let hidden = await probe.timingReference(in: view, month: "2026-10")
        XCTAssertEqual(hidden, first, "The diagnostic screen keeps the live web view off-screen")
        _ = try await view.evaluateJavaScript("""
            document.body.insertAdjacentHTML('beforeend', `
              <table class="activity-table"><tr><td>Activity 6H999, Departure AAA - Airport Arrival BBB - Airport
              Start 30SEP26 23:00 (LT) / 30SEP26 20:00 (UTC) End 01OCT26 01:00 (LT) / 30SEP26 22:00 (UTC)</td></tr></table>
              <table class="activity-table"><tr><td>Activity HTL,Hotel Example Station TLV - Airport
              Start 29SEP26 00:00 (LT) / 28SEP26 21:00 (UTC) End 20OCT26 23:59 (LT) / 20OCT26 20:59 (UTC)</td></tr></table>
              <table class="activity-table"><tr><td>Activity OFF,Day off
              Start 15OCT26 00:00 (LT) End 15OCT26 23:59 (LT)</td></tr></table>`);
            """)
        let withUnrelated = await probe.timingReference(in: view, month: "2026-10")
        guard case .ready(let expanded) = withUnrelated else { XCTFail("Expanded reference unavailable"); return }
        XCTAssertEqual(expanded.activities, reference.activities, "The original flight projection retains its scope")
        XCTAssertEqual(expanded.otherActivities?.count, 3)
        XCTAssertEqual(Set(expanded.otherActivities?.map(\.category) ?? []), ["HOTEL", "FLIGHT", "OFF"])
        XCTAssertNotEqual(withUnrelated, first, "Other visible activities now participate in stability validation")
        let wrongMonth = await probe.timingReference(in: view, month: "2026-09")
        XCTAssertEqual(wrongMonth, .unavailable(.mismatch))
    }

    func testActualNativeReferenceAcceptsNonFlightOnlyPage() async throws {
        let ready = expectation(description: "Non-flight reference fixture ready")
        try loadFixture("roster", path: "HumanResourceRoster.aspx", expectation: ready)
        defer {
            webView?.configuration.userContentController.removeAllScriptMessageHandlers()
            webView = nil; recorder = nil; fixtureWindow?.isHidden = true; fixtureWindow = nil
        }
        await fulfillment(of: [ready], timeout: 60)
        let view = try XCTUnwrap(webView), probe = NativeRAIDOExperiment()
        _ = try await view.evaluateJavaScript("""
            document.body.innerHTML = `<h1>October 2026</h1><table class="activity-table"><tr><td>
            Activity STB,STB Morning Station VNO - Airport
            Start 09OCT26 09:00 (LT) / 09OCT26 06:00 (UTC)
            End 09OCT26 17:00 (LT) / 09OCT26 14:00 (UTC)</td></tr></table>`;
            true;
            """)
        let result = await probe.timingReference(in: view, month: "2026-10")
        guard case .ready(let reference) = result else { XCTFail("Non-flight reference unavailable: \(result)"); return }
        XCTAssertTrue(reference.activities.isEmpty)
        XCTAssertEqual(reference.otherActivities?.count, 1)
        XCTAssertEqual(reference.otherActivities?.first?.category, "STANDBY")
        XCTAssertEqual(reference.otherActivities?.first?.startUTC, "2026-10-09 06:00")
    }

    func testNativeTimingReadinessRetriesOnlyBusyAndRemainsBounded() async throws {
        let ready = expectation(description: "Timing readiness fixture ready")
        try loadFixture("roster", path: "HumanResourceRoster.aspx", expectation: ready)
        defer {
            webView?.configuration.userContentController.removeAllScriptMessageHandlers()
            webView = nil; recorder = nil; fixtureWindow?.isHidden = true; fixtureWindow = nil
        }
        await fulfillment(of: [ready], timeout: 60)
        let view = try XCTUnwrap(webView), probe = NativeRAIDOExperiment()
        _ = try await view.evaluateJavaScript("""
            window.timingReads = 0;
            const timingInspector = window.RAIDOPlus.history.timingReference;
            window.RAIDOPlus.history.timingReference = month => {
              window.timingReads++;
              if (window.clearTimingBusyAt === window.timingReads) document.body.removeAttribute('aria-busy');
              return timingInspector(month);
            };
            document.body.setAttribute('aria-busy','true');
            """)
        let busy = await probe.timingReference(in: view, month: "2026-10")
        XCTAssertEqual(busy, .unavailable(.loading))
        let busyReads = try await view.evaluateJavaScript("window.timingReads")
        XCTAssertEqual(busyReads as? Int, 3)
        _ = try await view.evaluateJavaScript("window.timingReads=0; window.clearTimingBusyAt=2;")
        let recovered = await probe.timingReference(in: view, month: "2026-10")
        guard case .ready = recovered else { XCTFail("Rendering readiness should recover: \(recovered)"); return }
        let recoveredReads = try await view.evaluateJavaScript("window.timingReads")
        XCTAssertEqual(recoveredReads as? Int, 2)
        _ = try await view.evaluateJavaScript("window.timingReads=0;")
        let wrong = await probe.timingReference(in: view, month: "2026-09")
        XCTAssertEqual(wrong, .unavailable(.mismatch))
        let mismatchReads = try await view.evaluateJavaScript("window.timingReads")
        XCTAssertEqual(mismatchReads as? Int, 1, "Only explicit loading receives another DOM read")
        let cancelled = Task { await probe.timingReference(in: view, month: "2026-10") }
        cancelled.cancel()
        _ = await cancelled.value
        let cancelledReads = try await view.evaluateJavaScript("window.timingReads")
        XCTAssertEqual(cancelledReads as? Int, 1, "Cancellation must prevent another DOM read")
    }

    func testChangedLayoutProducesExplicitFailure() async throws {
        let body = try await extract("changed-layout", path: "HumanResourceRoster.aspx")
        XCTAssertEqual(body["error"] as? String, "portal-format-changed")
    }
    func testFetchedMonthUsesSameExtractorWithoutChangingLivePage() async throws {
        let ready = expectation(description: "Live fixture ready")
        try loadFixture("roster", path: "HumanResourceRoster.aspx", expectation: ready)
        defer {
            webView?.configuration.userContentController.removeAllScriptMessageHandlers()
            webView = nil; recorder = nil; fixtureWindow?.isHidden = true; fixtureWindow = nil
        }
        await fulfillment(of: [ready], timeout: 60)
        let view = try XCTUnwrap(webView)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "roster", withExtension: "html"))
        let original = try String(contentsOf: fixture, encoding: .utf8)
        // Adjacent blocks have no whitespace; detached textContent used to join
        // the year to BLH and reject valid archived months. Split table cells too.
        for (name, token, key) in [("September", "SEP26", "2026-09"),
                                   ("July", "JUL26", "2026-07"),
                                   ("June", "JUN26", "2026-06")] {
            let html = original.replacingOccurrences(of: "October", with: name)
                .replacingOccurrences(of: "OCT26", with: token)
                .replacingOccurrences(of: " Start ", with: "</td><td>Start ")
                + "<script>window.fetchedScriptExecuted=true;</script>"
            let value = try await view.callAsyncJavaScript("return window.RAIDOPlus.extractHTML(html, url, month)",
                arguments: ["html": html, "url": "https://gjt.noc.vmc.navblue.cloud/RaidoMobile/HumanResourceRoster.aspx", "month": key],
                in: nil, contentWorld: .page)
            let checked = try PortalBridgePolicy.snapshot(try XCTUnwrap(value as? [String: Any]))
            XCTAssertEqual((checked["validation"] as? [String: Any])?["month"] as? String, key)
            XCTAssertEqual(checked["monthlyBLH"] as? String, "40:00")
            let rows = try XCTUnwrap(checked["rows"] as? [[String: Any]])
            XCTAssertEqual(rows.count, 5)
            XCTAssertEqual(rows.first?["dateISO"] as? String, "\(key)-08")
            let activity = try XCTUnwrap((rows.first?["activities"] as? [[String: Any]])?.first)
            XCTAssertEqual(activity["route"] as? String, "TLV → HER")
            XCTAssertEqual(activity["startUTC"] as? String, "\(key)-08 06:50")
        }
        let live = try await view.callAsyncJavaScript("return {month:document.querySelector('h1').textContent, executed:!!window.fetchedScriptExecuted}", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(live?["month"] as? String, "October 2026")
        XCTAssertEqual(live?["executed"] as? Bool, false)
        do {
            _ = try await view.callAsyncJavaScript("return window.RAIDOPlus.extractHTML(html, url, month)",
                arguments: ["html": original, "url": "https://gjt.noc.vmc.navblue.cloud/RaidoMobile/HumanResourceRoster.aspx", "month": "2026-08"], in: nil, contentWorld: .page)
            XCTFail("A different returned month must be rejected")
        } catch { /* expected: requested month was not returned */ }
    }
    func testActualRelocationHTMLReachesUpcomingPriorities() async throws {
        let ready = expectation(description:"Roster fixture ready")
        try loadFixture("roster",path:"HumanResourceRoster.aspx",expectation:ready)
        defer {
            webView?.configuration.userContentController.removeAllScriptMessageHandlers()
            webView = nil; recorder = nil; fixtureWindow?.isHidden = true; fixtureWindow = nil
        }
        await fulfillment(of:[ready],timeout:60)
        let view = try XCTUnwrap(webView)
        let url = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"roster",withExtension:"html"))
        var html = try String(contentsOf:url,encoding:.utf8)
        let tableStart = try XCTUnwrap(html.range(of:"<table"))
        let tableEnd = try XCTUnwrap(html.range(of:"</table>",range:tableStart.lowerBound..<html.endIndex))
        // Real portal wording matters: HOTEL used to match before RLCN, and
        // grouping then dropped relocation metadata on days with standby.
        let first = """
        <table class="activity-table"><tr><td>
        Activity STA32,STB Afternoon320 ADHOC Station VNO - EYVI - VILNIUS
        CheckIn 23OCT26 11:00 (LT) / 23OCT26 08:00 (UTC)
        Start 23OCT26 11:00 (LT) / 23OCT26 08:00 (UTC)
        End 23OCT26 21:00 (LT) / 23OCT26 18:00 (UTC)
        CheckOut 23OCT26 21:00 (LT) / 23OCT26 18:00 (UTC)
        </td></tr><tr><td>
        Activity RLCN,Hotel relocation Station VNO - EYVI - VILNIUS
        Start 23OCT26 12:00 (LT) / 23OCT26 09:00 (UTC)
        End 23OCT26 13:00 (LT) / 23OCT26 10:00 (UTC)
        Activity Note Please use Bolt for the relocation
        </td></tr></table>
        """
        html.replaceSubrange(tableStart.lowerBound..<tableEnd.upperBound,with:first)
        let payload = try await view.callAsyncJavaScript("return window.RAIDOPlus.extractHTML(html,url,month)",
            arguments:["html":html,"url":"https://gjt.noc.vmc.navblue.cloud/RaidoMobile/HumanResourceRoster.aspx","month":"2026-10"],in:nil,contentWorld:.page)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let store = RosterStore(storageFolderURL:folder,automaticSideEffects:false)
        XCTAssertTrue(store.ingest(messageBody:try XCTUnwrap(payload),archiveOnly:true,expectedMonth:"2026-10"))
        let now = ISO8601DateFormatter().date(from:"2026-10-19T08:00:00Z")!
        let move = try XCTUnwrap(store.priorityEvents(at:now).first { $0.kind == .relocation })
        XCTAssertEqual(move.title,"Hotel relocation")
        XCTAssertEqual(TodayPriorityPolicy.status(move,now:now),"In 4 days")
        XCTAssertEqual(move.clock,"12:00"); XCTAssertEqual(move.endClock,"13:00")
        XCTAssertTrue(move.notes.contains("Please use Bolt"))
        XCTAssertFalse(move.missing.contains("Transport details not provided"))
        let day = try XCTUnwrap(store.priorityRosterItems.first { $0.dateISO == "2026-10-23" })
        XCTAssertEqual(day.operationalActivities.map(\.category),["STANDBY"])
        XCTAssertEqual(day.relocationActivities.count,1)
    }
    func testLoginPageDoesNotReportParserFailure() async throws {
        let expectation = expectation(description: "No roster error on login")
        expectation.isInverted = true
        let ready = self.expectation(description: "Login document loaded")
        try loadFixture("login", path: "Login.aspx", expectation: expectation)
        recorder?.navigationFinished = ready
        await fulfillment(of: [ready], timeout: 60)
        await fulfillment(of: [expectation], timeout: 0.3)
        let view = try XCTUnwrap(webView)
        let auth = try await view.evaluateJavaScript("window.RAIDOPlus.history.inspect().kind")
        XCTAssertEqual(auth as? String, "auth", "History worker still detects sign-in pages")
        let interactive = try await view.evaluateJavaScript("""
            (() => {
              const field = document.querySelector('input[type=text]');
              field.focus();
              return document.activeElement === field && !field.disabled && !document.querySelector('button').disabled;
            })()
            """)
        XCTAssertEqual(interactive as? Bool, true)
        let observers = try await view.evaluateJavaScript("window.testRosterObservers || 0")
        XCTAssertEqual(observers as? Int, 0, "No roster mutation observation on login")
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil; recorder = nil
        fixtureWindow?.isHidden = true; fixtureWindow = nil
    }
    private func extract(_ name: String, path: String) async throws -> [String: Any] {
        let expectation = expectation(description: "Script bridge payload")
        try loadFixture(name, path: path, expectation: expectation)
        await fulfillment(of: [expectation], timeout: 60)
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
        webView?.navigationDelegate = recorder
        // Keep WebKit in a visible host so CI does not throttle its extraction timer.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController(); window.rootViewController = host
        host.view.addSubview(webView!); window.isHidden = false
        fixtureWindow = window
        webView?.loadHTMLString(html, baseURL: URL(string: "https://gjt.noc.vmc.navblue.cloud/RaidoMobile/\(path)"))
    }
}

@MainActor private final class Recorder: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let expectation: XCTestExpectation
    var body: [String: Any]?
    var navigationFinished: XCTestExpectation?
    init(expectation: XCTestExpectation) { self.expectation = expectation }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationFinished?.fulfill(); navigationFinished = nil
        // Trigger after document-end injection; do not depend on the startup timer.
        webView.evaluateJavaScript("window.RAIDOPlus?.extractNow()", completionHandler: nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard body == nil else { return }
        body = message.body as? [String: Any]
        expectation.fulfill()
    }
}
