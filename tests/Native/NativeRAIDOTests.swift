import XCTest
import Foundation
import WebKit
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
