import XCTest
import Foundation
import WebKit
import UIKit
import Combine
@testable import RAIDORoster

@MainActor
final class NativeRAIDOTests: XCTestCase {
    private let endpoint = URL(string: "https://gjt.noc.vmc.navblue.cloud/synthetic/GetRoster")!
    private let request = Data(#"{"month":10,"year":2026,"hrId":42}"#.utf8)
    private let payload = Data(#"{"days":[{"date":"2026-10-08","activities":[]}]}"#.utf8)

    private func contract() throws -> NativeRAIDOContract {
        try NativeRAIDOContract.capture(url: endpoint, request: request, response: payload)
    }

    private func cookie(domain: String = "gjt.noc.vmc.navblue.cloud", path: String = "/", expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: "SyntheticSession", .value: "fixture-only", .domain: domain, .path: path, .secure: "TRUE"]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    private func configuration() -> URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral
        value.protocolClasses = [NativeRAIDOTestProtocol.self]
        return value
    }

    override func tearDown() {
        NativeRAIDOTestProtocol.setHandler(nil)
        super.tearDown()
    }

    func testCapturedContractRetainsExactBodyAndMonth() throws {
        let value = try contract()
        XCTAssertEqual(value.body, request); XCTAssertEqual(value.month, "2026-10")
    }

    func testRequestBoundaryRejectsOtherOperationsAndAmbiguousURLs() {
        for url in ["http://gjt.noc.vmc.navblue.cloud/GetRoster", "https://example.invalid/GetRoster",
                    "https://gjt.noc.vmc.navblue.cloud.evil.invalid/GetRoster", "https://gjt.noc.vmc.navblue.cloud/ConfirmRevision",
                    "https://gjt.noc.vmc.navblue.cloud/GetRoster?next=anything", "https://gjt.noc.vmc.navblue.cloud/GetRoster#fragment",
                    "https://user@gjt.noc.vmc.navblue.cloud/GetRoster", "https://gjt.noc.vmc.navblue.cloud/%47etRoster"] {
            XCTAssertFalse(NativeRAIDOContract.permits(URL(string: url)!), url)
        }
    }

    func testRequestBodyRejectsUnknownFieldsBooleansAndInvalidIdentity() {
        for body in [#"{"month":true,"year":2026,"hrId":42}"#, #"{"month":13,"year":2026,"hrId":42}"#,
                     #"{"month":10,"year":2026,"hrId":false}"#, #"{"month":10,"year":2026,"hrId":0}"#,
                     #"{"month":10.5,"year":2026,"hrId":42}"#, #"{"month":10,"year":2026,"hrId":42,"confirm":true}"#,
                     #"{"month":10,"year":2026,"hrId":"not-an-id"}"#, "[]"] {
            XCTAssertThrowsError(try NativeRAIDOContract.capture(url: endpoint, request: Data(body.utf8), response: payload), body)
        }
    }

    func testJSONComparisonIgnoresObjectOrderButDetectsChangedFields() throws {
        let a = try NativeRAIDOContract.digest(Data(#"{"route":"AAA-BBB","start":"10:00"}"#.utf8))
        let b = try NativeRAIDOContract.digest(Data(#"{ "start": "10:00", "route": "AAA-BBB" }"#.utf8))
        let c = try NativeRAIDOContract.digest(Data(#"{"route":"AAA-BBB","start":"10:05"}"#.utf8))
        XCTAssertEqual(a, b); XCTAssertNotEqual(a, c)
    }

    func testResponseRejectsHTMLScalarDepthAndSize() {
        for value in [Data("<html>sign in</html>".utf8), Data("true".utf8),
                      Data((String(repeating: "[", count: 25) + "0" + String(repeating: "]", count: 25)).utf8),
                      Data(repeating: 32, count: NativeRAIDOContract.maximumResponseBytes + 1)] {
            XCTAssertThrowsError(try NativeRAIDOContract.digest(value))
        }
    }

    func testCookiesRespectDomainPathExpiryAndChangedSession() throws {
        let now = Date(), good = cookie(path: "/synthetic")
        let scoped = NativeRAIDOContract.scopedCookies([good, cookie(domain: "example.invalid"), cookie(path: "/syn"),
            cookie(path: "/synthetic/other"), cookie(expires: now.addingTimeInterval(-60))], for: endpoint, now: now)
        XCTAssertEqual(scoped.count, 1); XCTAssertEqual(scoped.first?.path, "/synthetic")
        XCTAssertEqual(NativeRAIDOContract.cookieDigest(scoped), NativeRAIDOContract.cookieDigest([good]))
        XCTAssertNotEqual(NativeRAIDOContract.cookieDigest(scoped), NativeRAIDOContract.cookieDigest([]))
    }

    func testNativeRequestUsesCapturedBodyAndScopedCookie() async throws {
        let expectedURL = endpoint, expectedBody = request, response = payload
        NativeRAIDOTestProtocol.setHandler { request, client, protocolInstance in
            XCTAssertEqual(request.url, expectedURL); XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Requested-With"), "XMLHttpRequest")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "SyntheticSession=fixture-only")
            // URLProtocol may receive a body stream instead of httpBody.
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var value = Data(), buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    value.append(contentsOf: buffer.prefix(count))
                }
                body = value
            }
            XCTAssertEqual(body, expectedBody)
            client.urlProtocol(protocolInstance, didReceive: HTTPURLResponse(url: expectedURL, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(protocolInstance, didLoad: response); client.urlProtocolDidFinishLoading(protocolInstance)
        }
        let data = try await NativeRAIDOHTTPClient().fetch(contract(), cookies: [cookie()], configuration: configuration())
        XCTAssertEqual(try NativeRAIDOContract.digest(data), try contract().expectedDigest)
    }

    func testNativeResponseRejectsAuthHTMLAndOversizedHeaders() async throws {
        for (status, headers, expected) in [
            (401, ["Content-Type":"application/json"], NativeRAIDOContract.Failure.signInRequired),
            (200, ["Content-Type":"text/html"], .unsupportedResponse),
            (200, ["Content-Type":"application/json", "Content-Length":"9999999"], .responseTooLarge),
            (429, ["Content-Type":"application/json"], .http(429))] {
            let url = endpoint
            NativeRAIDOTestProtocol.setHandler { _, client, instance in
                client.urlProtocol(instance, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                    headerFields: headers)!, cacheStoragePolicy: .notAllowed)
                client.urlProtocolDidFinishLoading(instance)
            }
            do { _ = try await NativeRAIDOHTTPClient().fetch(contract(), cookies: [cookie()], configuration: configuration()); XCTFail("Expected rejection") }
            catch { XCTAssertEqual(error as? NativeRAIDOContract.Failure, expected) }
        }
    }

    func testMissingSessionDoesNotSendRequest() async throws {
        NativeRAIDOTestProtocol.setHandler { _, _, _ in XCTFail("No network request without portal cookies") }
        do { _ = try await NativeRAIDOHTTPClient().fetch(contract(), cookies: [], configuration: configuration()); XCTFail("Expected sign-in boundary") }
        catch { XCTAssertEqual(error as? NativeRAIDOContract.Failure, .signInRequired) }
    }

    func testRedirectCompletionRefusesForwarding() {
        let transport = NativeRAIDOHTTPClient(), session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: endpoint)
        transport.urlSession(session, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(url: endpoint, statusCode: 302, httpVersion: nil, headerFields: nil)!,
            newRequest: URLRequest(url: URL(string: "https://example.invalid/")!)) { request in XCTAssertNil(request) }
    }

    func testCancellationCompletesHeldRequest() async throws {
        let started = expectation(description: "Synthetic request started")
        NativeRAIDOTestProtocol.setHandler { _, _, _ in started.fulfill() }
        let contract = try contract(), cookies = [cookie()], configuration = configuration()
        let task = Task { try await NativeRAIDOHTTPClient().fetch(contract, cookies: cookies, configuration: configuration) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testRecorderIsOptInAndStopClearsState() {
        let probe = NativeRAIDOExperiment()
        XCTAssertFalse(probe.armed); XCTAssertNil(probe.capturedMonth)
        probe.receive(["token":"untrusted", "url":endpoint.absoluteString])
        XCTAssertFalse(probe.isWorking)
        probe.arm(in: WKWebView()); XCTAssertTrue(probe.armed)
        probe.stop(); XCTAssertFalse(probe.armed); XCTAssertNil(probe.capturedMonth); XCTAssertFalse(probe.isWorking)
    }

    func testSchemaNeverExportsValuesOrDynamicIdentityKeys() throws {
        let object: [String: Any] = ["hrId": 987654321, "name": "Fixture Private Person", "token": "fixture-secret-token",
            "crew": ["PrivatePersonFixture": ["email": "fixture.private@example.invalid"],
                     "987654321": ["phone": "+999123456789"]],
            "notes": "https://example.invalid/secret?session=private", "date": "2026-10-24", "published": true]
        let text = try NativeRAIDOResponseSchema.make(from: JSONSerialization.data(withJSONObject: object))
        for secret in ["987654321", "Fixture Private Person", "fixture-secret-token", "PrivatePersonFixture",
                       "fixture.private@example.invalid", "+999123456789", "https://example.invalid", "2026-10-24"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        XCTAssertTrue(text.contains("<field-1>")); XCTAssertTrue(text.contains("unrecognizedKeysMasked"))
        XCTAssertTrue(text.contains("hrId")); XCTAssertTrue(text.contains("boolean")); XCTAssertTrue(text.contains("number"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(document["valuesIncluded"] as? Bool, false)
        XCTAssertNil(document["request"]); XCTAssertNil(document["url"])
    }

    func testSchemaMergesAllArrayElementsAndScalarKinds() throws {
        let text = try NativeRAIDOResponseSchema.make(from: Data(#"{"activities":[{"code":"STB"},{"code":null,"duration":30},false]}"#.utf8))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let schema = try XCTUnwrap(document["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        let items = try XCTUnwrap(properties["activities"]?["items"] as? [String: Any])
        XCTAssertEqual(items["types"] as? [String], ["boolean", "object"])
        let fields = try XCTUnwrap(items["properties"] as? [String: [String: Any]])
        XCTAssertEqual(fields["code"]?["types"] as? [String], ["null", "string"])
        XCTAssertEqual(fields["duration"]?["types"] as? [String], ["number"])
        XCTAssertFalse(text.contains("STB"))
    }

    func testSchemaDescribesEncodedJSONEnvelopeWithoutItsValues() throws {
        let inner = #"{"days":[{"date":"2026-10-24","notes":"fixture-confidential-note"}]}"#
        let data = try JSONSerialization.data(withJSONObject: ["d": inner])
        let text = try NativeRAIDOResponseSchema.make(from: data)
        XCTAssertTrue(text.contains("encodedJSON")); XCTAssertTrue(text.contains("days"))
        XCTAssertTrue(text.contains("stringFormats")); XCTAssertTrue(text.contains("date"))
        XCTAssertFalse(text.contains("2026-10-24")); XCTAssertFalse(text.contains("fixture-confidential-note"))
    }

    func testSchemaIsDeterministicAcrossObjectOrderAndHidesUnknownNames() throws {
        let a = try NativeRAIDOResponseSchema.make(from: Data(#"{"days":[],"unreviewedSecretKey":{"code":"A"},"name":"Person One"}"#.utf8))
        let b = try NativeRAIDOResponseSchema.make(from: Data(#"{"name":"Person Two","unreviewedSecretKey":{"code":"B"},"days":[]}"#.utf8))
        XCTAssertEqual(a, b); XCTAssertFalse(a.contains("unreviewedSecretKey"))
    }

    func testSchemaBoundsInputDepthAndTraversal() throws {
        for value in [Data("<html>sign in</html>".utf8), Data("true".utf8),
                      Data((String(repeating: "[", count: 22) + "0" + String(repeating: "]", count: 22)).utf8),
                      Data(("[" + String(repeating: "0,", count: 100_000) + "0]").utf8),
                      Data(repeating: 32, count: NativeRAIDOContract.maximumResponseBytes + 1)] {
            XCTAssertThrowsError(try NativeRAIDOResponseSchema.make(from: value))
        }
        let empty = try NativeRAIDOResponseSchema.make(from: Data("[]".utf8))
        XCTAssertTrue(empty.contains("array")); XCTAssertLessThan(empty.utf8.count, 64 * 1024)
    }

    func testSchemaMarksEncodedEnvelopeLimitRatherThanSilentlyDroppingIt() throws {
        let data = try JSONSerialization.data(withJSONObject: (0..<20).map { _ in ["d": "{\"days\":[]}"] })
        let text = try NativeRAIDOResponseSchema.make(from: data)
        XCTAssertTrue(text.contains("truncated")); XCTAssertTrue(text.contains("encodedJSON"))
    }

    func testUnknownSiblingFieldsKeepTheirTypesSeparateAcrossArrayRecords() throws {
        let data = Data(#"[{"privateAlpha":"secret-one","privateBeta":{"Id":42}},{"privateBeta":{"Id":43}}]"#.utf8)
        let text = try NativeRAIDOResponseSchema.make(from: data)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let schema = try XCTUnwrap(document["schema"] as? [String: Any])
        let items = try XCTUnwrap(schema["items"] as? [String: Any])
        let fields = try XCTUnwrap(items["properties"] as? [String: [String: Any]])
        XCTAssertEqual(fields["<field-1>"]?["types"] as? [String], ["string"])
        XCTAssertEqual(fields["<field-2>"]?["types"] as? [String], ["object"])
        for secret in ["privateAlpha", "privateBeta", "secret-one"] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertEqual(document["format"] as? String, "raido-response-schema-v2")
    }

    func testSchemaGroupsDynamicDayKeysWithoutExportingDatesOrNumbers() throws {
        for (keys, kind) in [(["2026-10-01", "2026-10-02"], "date"), (["16", "17"], "numeric"),
                             (["C1061883-3DB2-4CC6-9EE0-42666DF0B111", "B68F2E00-53DB-4DC9-8A46-418E44812222"], "uuid")] {
            let value: [String: Any] = ["Days": [keys[0]: ["Details": ["ActivityDetails": []]],
                                               keys[1]: ["Notes": []]]]
            let text = try NativeRAIDOResponseSchema.make(from: JSONSerialization.data(withJSONObject: value))
            XCTAssertTrue(text.contains("<\(kind)-key>")); XCTAssertTrue(text.contains("maskedKeyKinds"))
            for key in keys { XCTAssertFalse(text.contains("\"\(key)\"")) }
            XCTAssertTrue(text.contains("ActivityDetails")); XCTAssertTrue(text.contains("Notes"))
        }
    }

    func testSchemaRecognizesReviewedDetailNamesAndMasksTimingExamples() throws {
        let value: [String: Any] = ["ValidFrom": "2026-10-24T05:30:00Z", "ValidTo": "2026-10-25T01:00:00Z",
            "STD": "05:30 (UTC)", "STA": "07:45<br>09:45", "CheckIn": "24/10/2026 04:30",
            "NoteItems": [["Note": "private note", "TextColor": "private color"]],
            "Values": ["private content"], "JumpSeatInfo": "private seat", "PosNote": "private pos"]
        let text = try NativeRAIDOResponseSchema.make(from: JSONSerialization.data(withJSONObject: value))
        for key in value.keys { XCTAssertTrue(text.contains("\"\(key)\""), key) }
        for secret in ["2026", "05:30", "07:45", "09:45", "24/10", "private note", "private color", "private content", "private seat", "private pos", "UTC", "<br>"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        XCTAssertTrue(text.contains("timingStringShapes")); XCTAssertTrue(text.contains("##:## (A)"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let schema = try XCTUnwrap(document["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["CheckIn"]?["timingStringShapes"] as? [String], ["##/##/#### ##:##"])
    }

    func testCapturedSchemaCanBeCopiedAndClearsOnStop() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration), probe = NativeRAIDOExperiment()
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        pasteboard.string = "untouched"
        probe.copySanitizedSchema(to: pasteboard)
        XCTAssertEqual(pasteboard.string, "untouched")
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie()) { continuation.resume() }
        }
        probe.arm(in: webView)
        let source = try XCTUnwrap(webView.configuration.userContentController.userScripts.first?.source)
        let token = try XCTUnwrap(source.components(separatedBy: "const token = '").dropFirst().first?.components(separatedBy: "'").first)
        probe.receive(["token": token, "url": endpoint.absoluteString,
                       "requestBody": String(decoding: request, as: UTF8.self),
                       "responseBody": String(decoding: payload, as: UTF8.self)])
        let completed = expectation(description: "Capture finishes after the cookie-store callback")
        let observation = probe.$isWorking.filter { !$0 }.first().sink { _ in completed.fulfill() }
        await fulfillment(of: [completed], timeout: 15)
        withExtendedLifetime(observation) {}
        _ = try XCTUnwrap(probe.sanitizedSchema, probe.status)
        XCTAssertNotNil(probe.schemaForCopy)
        probe.copySanitizedSchema(to: pasteboard)
        let copied = try XCTUnwrap(pasteboard.string)
        XCTAssertTrue(copied.contains("Native comparison: not run")); XCTAssertTrue(copied.contains("activities"))
        XCTAssertFalse(copied.contains("2026-10-08")); XCTAssertFalse(copied.contains("fixture-only"))
        XCTAssertFalse(copied.contains(endpoint.absoluteString)); XCTAssertFalse(copied.contains("hrId"))
        probe.stop()
        XCTAssertNil(probe.sanitizedSchema); XCTAssertNil(probe.schemaForCopy); XCTAssertNil(probe.copyStatus)
        XCTAssertEqual(pasteboard.string, copied, "Explicitly copied sanitized text survives switching apps")
    }

    private func wireDay(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var activity: [String: Any] = ["Id": 101, "Activity": "SYN101", "Dep": "AAA", "Arr": "BBB",
            "STD": "23h", "STA": "0105", "CheckIn": "2350-1", "CheckOut": "0135",
            "ValidFrom": "2026-10-08T23:50:00.0000000", "ValidTo": "2026-10-09T01:05:00.1234567",
            "Details": [["Label": "fixture text", "Value": "fixture-only detail", "Values": []],
                        ["Label": "fixture nested", "Value": ["Id": "fixture ID", "Label": NSNull(), "Value": "fixture value", "Values": []]],
                        ["Label": "fixture collection", "Value": NSNull(), "Values": [["Value": "fixture child"]]]],
            "JumpSeatInfo": ["Items": [["FirstName": "Fixture", "LastName": "Person", "Id": 700, "Status": "synthetic"]]]]
        activity.merge(overrides) { _, new in new }
        return ["Details": ["ActivityDetails": [activity]],
                "Notes": [["Note": "fixture-only note", "TextColor": "black", "BackgroundColor": "white"]]]
    }

    private func wireData(_ days: [String: Any], hrId: Any = 42) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["d": ["Date": "2026-10-01T00:00:00.0000000", "HrId": hrId,
            "Username": "fixture-only-user", "Roster": ["Days": days]]])
    }

    func testWireDecoderReadsDateKeyedDaysAndKeepsTimingStringsVerbatim() throws {
        let decoded = try NativeRAIDOWire.decode(wireData(["2026-10-08": wireDay()]), for: contract())
        XCTAssertEqual(decoded.days.map(\.calendarDay), ["2026-10-08"])
        let activity = try XCTUnwrap(decoded.days.first?.day.details?.activities?.first)
        XCTAssertEqual(activity.id, 101); XCTAssertEqual(activity.activity, "SYN101")
        XCTAssertEqual(activity.std, "23h"); XCTAssertEqual(activity.sta, "0105"); XCTAssertEqual(activity.checkIn, "2350-1")
        XCTAssertEqual(activity.validTo.rawValue, "2026-10-09T01:05:00.1234567")
        XCTAssertEqual(activity.validTo.calendarDay, "2026-10-09")
        XCTAssertNil(activity.validFrom.zoneSuffix); XCTAssertTrue(decoded.hasUnspecifiedActivityZone)
        XCTAssertEqual(decoded.days.first?.day.notes?.first?.text, "fixture-only note")
    }

    func testWireDecoderKeepsMissingDetailsDistinctFromAnEmptyActivityArray() throws {
        let missing = try NativeRAIDOWire.decode(wireData(["2026-10-08": ["Notes": []]]), for: contract())
        let empty = try NativeRAIDOWire.decode(wireData(["2026-10-08": ["Details": ["ActivityDetails": []]]]), for: contract())
        XCTAssertTrue(missing.hasMissingActivityDetails); XCTAssertFalse(empty.hasMissingActivityDetails)
        let nullable = try NativeRAIDOWire.decode(wireData(["2026-10-08": wireDay(["CheckIn": NSNull()])]), for: contract())
        XCTAssertNil(nullable.days.first?.day.details?.activities?.first?.checkIn)
    }

    func testWireDecoderChecksResponseIdentityWithoutClaimingAuthenticatedUserVerification() throws {
        XCTAssertThrowsError(try NativeRAIDOWire.decode(wireData(["2026-10-08": wireDay()], hrId: 43), for: contract())) {
            XCTAssertEqual($0 as? NativeRAIDOWire.Failure, .identityMismatch)
        }
        for id in [true, 42.5] as [Any] {
            XCTAssertThrowsError(try NativeRAIDOWire.decode(wireData(["2026-10-08": wireDay()], hrId: id), for: contract()))
        }
        let request = Data(#"{"month":10,"year":2026,"hrId":"00042"}"#.utf8)
        let context = try NativeRAIDOContract.capture(url: endpoint, request: request, response: payload)
        XCTAssertNoThrow(try NativeRAIDOWire.decode(wireData(["2026-10-08": wireDay()]), for: context))
    }

    func testWireDecoderRejectsOtherMonthsAndDoesNotTreatMissingRosterAsEmptyImport() throws {
        XCTAssertThrowsError(try NativeRAIDOWire.decode(wireData(["2026-11-08": wireDay()]), for: contract())) {
            XCTAssertEqual($0 as? NativeRAIDOWire.Failure, .monthMismatch)
        }
        XCTAssertThrowsError(try NativeRAIDOWire.decode(wireData([:]), for: contract())) {
            XCTAssertEqual($0 as? NativeRAIDOWire.Failure, .emptyRoster)
        }
        XCTAssertThrowsError(try NativeRAIDOWire.decode(Data(#"{"d":null}"#.utf8), for: contract()))
    }

    func testWireDecoderRejectsInvalidAndDuplicateCalendarDays() throws {
        XCTAssertThrowsError(try NativeRAIDOWire.decode(wireData(["2026-02-30": wireDay()]), for: contract())) {
            XCTAssertEqual($0 as? NativeRAIDOWire.Failure, .invalidDay)
        }
        let days = ["2026-10-08": wireDay(), "2026-10-08T00:00:00.0000000": wireDay()]
        XCTAssertThrowsError(try NativeRAIDOWire.decode(wireData(days), for: contract())) {
            XCTAssertEqual($0 as? NativeRAIDOWire.Failure, .duplicateDay)
        }
        XCTAssertNoThrow(try NativeRAIDOWire.decode(wireData(["2026-10-08T00:00:00.0000000": wireDay()]), for: contract()))
    }

    func testWireDecoderRejectsMalformedKnownFieldsInsteadOfDroppingRecords() throws {
        let invalid: [[String: Any]] = [["Id": true], ["Activity": 4], ["STD": 2350],
            ["ValidFrom": "2026-10-08T25:00:00.0000000"], ["ValidTo": "not a timestamp"],
            ["Details": [["Label": "fixture", "Value": 7]]]]
        for overrides in invalid {
            XCTAssertThrowsError(try NativeRAIDOWire.decode(wireData(["2026-10-08": wireDay(overrides)]), for: contract()))
        }
    }

    func testWireTimestampKeepsUnspecifiedZonesAndValidatesExplicitOffsets() throws {
        XCTAssertNil(try NativeRAIDOWire.Timestamp("2026-10-25T03:30:00.1234567").zoneSuffix)
        XCTAssertEqual(try NativeRAIDOWire.Timestamp("2026-10-25T03:30:00Z").zoneSuffix, "Z")
        XCTAssertEqual(try NativeRAIDOWire.Timestamp("2026-10-25T03:30:00+02:00").zoneSuffix, "+02:00")
        XCTAssertEqual(try NativeRAIDOWire.Timestamp("2026-10-25T03:30:00-0230").zoneSuffix, "-0230")
        for value in ["2026-02-30T12:00:00", "2026-10-25T03:30:00+14:01", "2026-10-25T03:30:60Z"] {
            XCTAssertThrowsError(try NativeRAIDOWire.Timestamp(value))
        }
        for value in ["2026-10-25T03:30:00Z\n", "20٢٦-10-25T03:30:00"] {
            XCTAssertThrowsError(try NativeRAIDOWire.Timestamp(value))
        }
        for key in ["2026-10-08\n", "20٢٦-10-08"] {
            XCTAssertThrowsError(try NativeRAIDOWire.decode(wireData([key: wireDay()]), for: contract())) {
                XCTAssertEqual($0 as? NativeRAIDOWire.Failure, .invalidDay)
            }
        }
    }

    func testWireDecoderPreservesHeterogeneousDetailValues() throws {
        let decoded = try NativeRAIDOWire.decode(wireData(["2026-10-08": wireDay()]), for: contract())
        let details = try XCTUnwrap(decoded.days.first?.day.details?.activities?.first?.details)
        XCTAssertEqual(details.count, 3); XCTAssertEqual(details[0].value, .text("fixture-only detail"))
        guard case .record(let nested)? = details[1].value else { return XCTFail("Expected nested detail value") }
        XCTAssertEqual(nested.id, "fixture ID"); XCTAssertEqual(nested.value, .text("fixture value"))
        XCTAssertNil(details[2].value); XCTAssertEqual(details[2].values?.first?.value, .text("fixture child"))
    }

    func testWireAssessmentContainsOnlyFixedStatusText() throws {
        let status = NativeRAIDOWire.assessment(try wireData(["2026-10-08": wireDay()]), for: try contract())
        XCTAssertTrue(status.contains("zones are unspecified"))
        for value in ["fixture", "2026", "23h", "2350", "SYN101", "AAA", "BBB", "700"] { XCTAssertFalse(status.contains(value)) }
        let wrongID = NativeRAIDOWire.assessment(try wireData(["2026-10-08": wireDay()], hrId: 43), for: try contract())
        XCTAssertTrue(wrongID.contains("identity differs")); XCTAssertFalse(wrongID.contains("43"))
    }
}

private final class NativeRAIDOTestProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, URLProtocolClient, URLProtocol) -> Void
    private static let lock = NSLock()
    private static var handler: Handler?
    static func setHandler(_ value: Handler?) { lock.lock(); handler = value; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        guard let client else { return }
        if let handler { handler(request, client, self) }
        else { client.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
    }
    override func stopLoading() {}
}
