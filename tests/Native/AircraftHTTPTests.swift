import XCTest
@testable import RAIDORoster

final class AircraftHTTPTests: XCTestCase {
    private func session(status: Int = 200, headers: [String: String] = [:], failure: URLError.Code? = nil, payloadSize: Int = 2) -> URLSession {
        AircraftURLProtocol.reset(status: status, headers: headers, failure: failure, payloadSize: payloadSize)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AircraftURLProtocol.self]
        return URLSession(configuration: config)
    }
    private func request(_ value: String = "one", host: String = "api.adsb.lol") -> URLRequest {
        URLRequest(url: URL(string: "https://\(host)/v2/reg/\(value)")!)
    }
    func testBackoffAndLateSuccess() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var state = ProviderBackoff()
        state.failed(now: now, jitter: 0)
        XCTAssertEqual(state.blockedUntil, now.addingTimeInterval(5))
        state.succeeded(now: now.addingTimeInterval(1))
        XCTAssertEqual(state.failures, 1, "A late response must not cancel cooldown")
        state.failed(now: now, retryAfter: 120, jitter: 1)
        XCTAssertEqual(state.blockedUntil, now.addingTimeInterval(144))
        state.succeeded(now: now.addingTimeInterval(145))
        XCTAssertEqual(state.failures, 0)
        XCTAssertNil(state.blockedUntil)
        for _ in 0..<20 { state.failed(now: now, jitter: 1) }
        XCTAssertEqual(state.blockedUntil, now.addingTimeInterval(360))
    }
    func testCachedResponseKeepsItsOriginalReceiptTime() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let client = AircraftHTTPClient(spacing: 0)
        let first = try await client.data(for: request(), session: session)
        let cached = try await client.data(for: request(), session: session)
        XCTAssertEqual(cached.receivedAt, first.receivedAt)
        XCTAssertEqual(cached.data, first.data)
        XCTAssertEqual(AircraftURLProtocol.starts.count, 1)
        _ = try await client.data(for: request(), session: session, cacheSeconds: 0)
        XCTAssertEqual(AircraftURLProtocol.starts.count, 2)
    }
    func testCacheEvictsToRespectMemoryBudget() async throws {
        let session = session(payloadSize: 1_500_000); defer { session.invalidateAndCancel() }
        let client = AircraftHTTPClient(spacing: 0)
        for index in 0..<4 { _ = try await client.data(for: request("large-\(index)"), session: session) }
        XCTAssertEqual(AircraftURLProtocol.starts.count, 4)
        _ = try await client.data(for: request("large-3"), session: session)
        XCTAssertEqual(AircraftURLProtocol.starts.count, 4, "Recent entries remain cached")
        _ = try await client.data(for: request("large-0"), session: session)
        XCTAssertEqual(AircraftURLProtocol.starts.count, 5, "Old entries are evicted before total data exceeds 4 MiB")
    }
    func testPostBodiesAreSeparateCacheEntries() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let client = AircraftHTTPClient(spacing: 0)
        var first = request(); first.httpMethod = "POST"; first.httpBody = Data("first".utf8)
        var second = first; second.httpBody = Data("second".utf8)
        _ = try await client.data(for: first, session: session)
        _ = try await client.data(for: second, session: session)
        _ = try await client.data(for: first, session: session)
        XCTAssertEqual(AircraftURLProtocol.starts.count, 2)
    }
    func testRateLimitStopsFurtherRequestsAcrossAircraft() async throws {
        let session = session(status: 429, headers: ["Retry-After": "120"]); defer { session.invalidateAndCancel() }
        let client = AircraftHTTPClient(spacing: 0)
        do { _ = try await client.data(for: request(), session: session); XCTFail("Expected rate limit") }
        catch AircraftHTTPClient.Failure.http(429) { }
        do { _ = try await client.data(for: request("two"), session: session); XCTFail("Expected provider cooldown") }
        catch AircraftHTTPClient.Failure.coolingDown { }
        XCTAssertEqual(AircraftURLProtocol.starts.count, 1)
    }
    func testConnectionFailureOpensCircuit() async throws {
        let session = session(failure: .timedOut); defer { session.invalidateAndCancel() }
        let client = AircraftHTTPClient(spacing: 0)
        do { _ = try await client.data(for: request(), session: session); XCTFail("Expected timeout") }
        catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        do { _ = try await client.data(for: request("two"), session: session); XCTFail("Expected circuit") }
        catch AircraftHTTPClient.Failure.coolingDown { }
        XCTAssertEqual(AircraftURLProtocol.starts.count, 1)
    }
    func testConcurrentCallsArePaced() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let client = AircraftHTTPClient(spacing: 0.05)
        async let one = client.data(for: request("one", host: "opendata.adsb.fi"), session: session)
        async let two = client.data(for: request("two", host: "opendata.adsb.fi"), session: session)
        _ = try await (one, two)
        let starts = AircraftURLProtocol.starts.sorted()
        XCTAssertEqual(starts.count, 2)
        XCTAssertGreaterThanOrEqual(starts[1].timeIntervalSince(starts[0]), 0.035)
    }
    func testCancellationDuringPacingMakesNoRequest() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let client = AircraftHTTPClient(spacing: 3)
        _ = try await client.data(for: request(), session: session)
        let task = Task { try await client.data(for: request("two"), session: session) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertEqual(AircraftURLProtocol.starts.count, 1)
    }
    func testUnknownHostIsRejectedWithoutNetwork() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        do { _ = try await AircraftHTTPClient().data(for: request(host: "example.invalid"), session: session); XCTFail("Expected host rejection") }
        catch AircraftHTTPClient.Failure.unsupportedHost { }
        XCTAssertEqual(AircraftURLProtocol.starts.count, 0)
    }
}

private final class AircraftURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var times: [Date] = []
    private static var status = 200
    private static var headers: [String: String] = [:]
    private static var failure: URLError.Code?
    private static var payloadSize = 2
    static var starts: [Date] { lock.lock(); defer { lock.unlock() }; return times }
    static func reset(status: Int, headers: [String: String], failure: URLError.Code?, payloadSize: Int) {
        lock.lock(); defer { lock.unlock() }
        times = []; self.status = status; self.headers = headers; self.failure = failure; self.payloadSize = payloadSize
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.times.append(Date())
        let code = Self.status, headers = Self.headers, failure = Self.failure, size = Self.payloadSize
        Self.lock.unlock()
        if let failure { client?.urlProtocol(self, didFailWithError: URLError(failure)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 32, count: size))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
