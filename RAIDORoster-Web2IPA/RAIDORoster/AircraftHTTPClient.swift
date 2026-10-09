import Foundation
import os

struct ProviderBackoff: Sendable {
    private(set) var failures = 0
    private(set) var blockedUntil: Date?
    func permits(_ now: Date) -> Bool { blockedUntil.map { now >= $0 } ?? true }
    mutating func succeeded(now: Date) {
        // A late parallel success cannot undo a newer rate-limit response.
        guard permits(now) else { return }
        failures = 0; blockedUntil = nil
    }
    mutating func failed(now: Date, retryAfter: TimeInterval? = nil, jitter: Double) {
        failures = min(7, failures + 1)
        let base = min(300, 5 * pow(2, Double(failures - 1)))
        let wait = max(base, retryAfter ?? 0) * (1 + 0.2 * min(1, max(0, jitter)))
        blockedUntil = max(blockedUntil ?? now, now.addingTimeInterval(wait))
    }
}

/// Shared pacing and cooldowns across Fleet, Flight Companion and photo metadata.
/// Cached responses keep their original receipt time; cached data never becomes a fresh fix.
actor AircraftHTTPClient {
    static let shared = AircraftHTTPClient()
    private static let networkSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()
    struct Response: Sendable {
        let data: Data
        let http: HTTPURLResponse
        let receivedAt: Date
    }
    enum Failure: Error { case unsupportedHost, coolingDown, http(Int) }
    private struct Entry { let response: Response; let expiresAt: Date }
    private var backoffs: [String: ProviderBackoff] = [:]
    private var nextStart: [String: Date] = [:]
    private var cache: [String: Entry] = [:]
    private let spacingOverride: TimeInterval?
    private let cacheEnabled: Bool
    private static let logger = Logger(subsystem: "com.bobanilic.raidoroster", category: "AircraftNetwork")
    init(spacing: TimeInterval? = nil, cacheEnabled: Bool = true) { spacingOverride = spacing; self.cacheEnabled = cacheEnabled }

    private func interval(host: String) throws -> TimeInterval {
        switch host {
        case "opendata.adsb.fi", "api.adsb.one": return spacingOverride ?? 1.05
        case "api.adsb.lol", "api.planespotters.net": return spacingOverride ?? 0.3
        default: throw Failure.unsupportedHost
        }
    }
    func data(for request: URLRequest, session: URLSession? = nil,
              cacheSeconds: TimeInterval = 10) async throws -> Response {
        guard let url = request.url, url.scheme == "https", let host = url.host else { throw Failure.unsupportedHost }
        let spacing = try interval(host: host)
        let key = (request.httpMethod ?? "GET") + " " + url.absoluteString + " " + (request.httpBody?.base64EncodedString() ?? "")
        while true {
            try Task.checkCancellation()
            let now = Date()
            if cacheEnabled, cacheSeconds > 0, let entry = cache[key], entry.expiresAt > now {
                return entry.response
            }
            guard backoffs[host]?.permits(now) ?? true else { throw Failure.coolingDown }
            let delay = max(0, (nextStart[host] ?? now).timeIntervalSince(now))
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(min(5, delay) * 1_000_000_000))
                continue // Recheck after actor reentrancy; never reserve a burst of simultaneous starts.
            }
            nextStart[host] = now.addingTimeInterval(spacing)
            break
        }
        do {
            let (bytes, response) = try await (session ?? Self.networkSession).data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let now = Date()
            guard (200..<300).contains(http.statusCode) else {
                let retry = http.value(forHTTPHeaderField: "Retry-After").map { FleetTrackingPolicy.retryDelay($0, now: now) }
                    ?? (http.statusCode == 429 ? 300 : nil)
                fail(host, now: now, retry: retry)
                throw Failure.http(http.statusCode)
            }
            var state = backoffs[host] ?? ProviderBackoff(); state.succeeded(now: now); backoffs[host] = state
            let value = Response(data: bytes, http: http, receivedAt: now)
            if cacheEnabled, cacheSeconds > 0, bytes.count <= 2 * 1_024 * 1_024 {
                cache = cache.filter { $0.value.expiresAt > now }
                while cache.count >= 128 || cache.values.reduce(0, { $0 + $1.response.data.count }) + bytes.count > 4 * 1_024 * 1_024 {
                    guard let oldest = cache.min(by: { $0.value.response.receivedAt < $1.value.response.receivedAt })?.key else { break }
                    cache.removeValue(forKey: oldest)
                }
                cache[key] = Entry(response: value, expiresAt: now.addingTimeInterval(cacheSeconds))
            }
            return value
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let failure = error as? Failure, case .http = failure { throw error } // Already recorded above.
            fail(host, now: Date(), retry: nil)
            throw error
        }
    }
    private func fail(_ host: String, now: Date, retry: TimeInterval?) {
        var state = backoffs[host] ?? ProviderBackoff()
        state.failed(now: now, retryAfter: retry, jitter: Double.random(in: 0...1))
        backoffs[host] = state
        Self.logger.notice("Aircraft provider cooldown: \(host, privacy: .public), consecutive failures: \(state.failures)")
    }
}
