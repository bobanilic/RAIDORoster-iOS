private final class FleetStubProtocol: URLProtocol {
    static var stall = false
    static var active = 0
    static var peak = 0
    static let lock = NSLock()
    private var counted = false
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); counted = true; Self.active += 1; Self.peak = max(Self.peak, Self.active)
        let stalled = Self.stall; Self.lock.unlock()
        guard !stalled else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let registration = self.request.url!.lastPathComponent
            let hex = self.request.url!.path.contains("/hex/") ? registration : "abc123"
            let data: Data
            if self.request.httpMethod == "POST" { data = Data("[]".utf8) }
            else {
                var aircraft: [String: Any] = ["hex": hex, "lat": 32.0, "lon": 34.0,
                    "alt_baro": "ground", "seen": 0, "seen_pos": 0]
                // Hex queries may omit registration. Returning the hex as a
                // registration would correctly fail the real identity guard.
                if !self.request.url!.path.contains("/hex/") { aircraft["r"] = registration }
                data = try! JSONSerialization.data(withJSONObject: ["now": Date().timeIntervalSince1970,
                    "ac": [aircraft]])
            }
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
            self.finishCounting()
        }
        work = item
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02, execute: item)
    }
    override func stopLoading() {
        work?.cancel()
        finishCounting()
    }
    private func finishCounting() {
        Self.lock.lock()
        if counted { counted = false; Self.active -= 1 }
        Self.lock.unlock()
    }
    static func setStall(_ value: Bool) { lock.lock(); stall = value; lock.unlock() }
}

@main private struct FleetStoreChecks {
    @MainActor static func main() async {
        let keys = ["RAIDORoster.FleetLiveCache.V1", "RAIDORoster.FleetHistory.V2"]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FleetStubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let live = FleetLiveStore(session: session, httpClient: AircraftHTTPClient(spacing: 0, cacheEnabled: false))
        let definitions = Array(FleetAircraftDefinition.all.prefix(8))
        await live.refresh(definitions: definitions)
        precondition(live.snapshots.count == definitions.count && !live.isRefreshing)
        precondition(FleetStubProtocol.peak > 1 && FleetStubProtocol.peak <= 4)
        precondition(live.histories.count == definitions.count)
        precondition(live.intelligence(for: definitions[0].registration)?.phase == .onGround)

        FleetStubProtocol.setStall(true)
        let stalled = Task { await live.refresh(definitions: definitions) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        precondition(live.isRefreshing)
        let started = Date()
        stalled.cancel()
        FleetStubProtocol.setStall(false)
        // Start before the old pass drains: the store must wait, then recover.
        await live.refresh(definitions: definitions)
        await stalled.value
        precondition(Date().timeIntervalSince(started) < 5 && !live.isRefreshing)
        precondition(live.errorText == nil && live.snapshots.count == definitions.count)
        precondition(live.histories.values.allSatisfy { $0.count == 1 }, "duplicate source samples do not inflate history")
        print("Passed generated Fleet store: concurrency, cache/history, cancellation, immediate restart")
    }
}
