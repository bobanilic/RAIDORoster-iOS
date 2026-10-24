import Foundation
import CoreFoundation
import CryptoKit
import WebKit
import SwiftUI
import UIKit

/// Transport comparison only. No decoder in this experiment writes to RosterStore.
struct NativeRAIDOContract: Sendable {
    static let maximumResponseBytes = 4 * 1024 * 1024
    let url: URL
    let body: Data
    let month: String
    let expectedDigest: Data

    enum Failure: Error, Equatable {
        case unsupportedRequest, unsupportedResponse, responseTooLarge, signInRequired
        case redirect, http(Int), sessionChanged
    }

    static func permits(_ url: URL) -> Bool {
        guard PortalBridgePolicy.isPortal(url), let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.query == nil, c.fragment == nil, !c.percentEncodedPath.contains("%"),
              c.path.lowercased().hasSuffix("/getroster") else { return false }
        return true
    }

    static func capture(url: URL, request: Data, response: Data) throws -> Self {
        guard permits(url), request.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              Set(object.keys) == Set(["month", "year", "hrId"]),
              let month = integer(object["month"], range: 1...12),
              let year = integer(object["year"], range: 2000...2100),
              validIdentity(object["hrId"]) else { throw Failure.unsupportedRequest }
        return try Self(url: url, body: request, month: String(format: "%04d-%02d", year, month),
                        expectedDigest: digest(response))
    }

    private static func integer(_ value: Any?, range: ClosedRange<Int>) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
              n.doubleValue >= Double(range.lowerBound), n.doubleValue <= Double(range.upperBound) else { return nil }
        return n.intValue
    }

    private static func validIdentity(_ value: Any?) -> Bool {
        if let s = value as? String {
            return !s.isEmpty && s.utf8.count <= 20 && s.utf8.allSatisfy { (48...57).contains($0) } && s.contains { $0 != "0" }
        }
        return integer(value, range: 1...9_007_199_254_740_991) != nil
    }

    static func digest(_ data: Data) throws -> Data {
        guard data.count <= maximumResponseBytes else { throw Failure.responseTooLarge }
        guard let value = try? JSONSerialization.jsonObject(with: data),
              value is [String: Any] || value is [Any] else { throw Failure.unsupportedResponse }
        var nodes = 0
        func bounded(_ value: Any, depth: Int) -> Bool {
            nodes += 1
            guard depth <= 20, nodes <= 100_000 else { return false }
            if let a = value as? [Any] { return a.allSatisfy { bounded($0, depth: depth + 1) } }
            if let d = value as? [String: Any] { return d.values.allSatisfy { bounded($0, depth: depth + 1) } }
            return true
        }
        guard bounded(value, depth: 0), let canonical = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            throw Failure.unsupportedResponse
        }
        return Data(SHA256.hash(data: canonical))
    }

    static func scopedCookies(_ cookies: [HTTPCookie], for url: URL, now: Date = Date()) -> [HTTPCookie] {
        guard permits(url), let host = url.host?.lowercased() else { return [] }
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            let matches = domain.hasPrefix(".") ? (host == String(domain.dropFirst()) || host.hasSuffix(domain)) : host == domain
            let path = cookie.path.isEmpty ? "/" : cookie.path
            let pathMatches = url.path == path || (url.path.hasPrefix(path) && (path.hasSuffix("/") || url.path.dropFirst(path.count).hasPrefix("/")))
            return matches && pathMatches && (cookie.expiresDate.map { $0 > now } ?? true)
        }.sorted {
            if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            return ($0.domain, $0.path, $0.name, $0.value) < ($1.domain, $1.path, $1.name, $1.value)
        }
    }

    static func cookieDigest(_ cookies: [HTTPCookie]) -> Data {
        // Length-delimited encoding avoids collisions between concatenated fields.
        var data = Data()
        for cookie in cookies {
            for value in [cookie.domain, cookie.path, cookie.name, cookie.value] {
                data.append(contentsOf: "\(value.utf8.count):".utf8); data.append(contentsOf: value.utf8)
            }
        }
        return Data(SHA256.hash(data: data))
    }
}

/// One bounded request per instance. Redirects never receive portal cookies.
final class NativeRAIDOHTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var cancelled = false
    private var started = false

    func fetch(_ contract: NativeRAIDOContract, cookies: [HTTPCookie], configuration: URLSessionConfiguration = .ephemeral) async throws -> Data {
        guard NativeRAIDOContract.permits(contract.url) else { throw NativeRAIDOContract.Failure.unsupportedRequest }
        let scoped = NativeRAIDOContract.scopedCookies(cookies, for: contract.url)
        guard !scoped.isEmpty else { throw NativeRAIDOContract.Failure.signInRequired }
        var request = URLRequest(url: contract.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"; request.httpBody = contract.body
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        for (key, value) in HTTPCookie.requestHeaderFields(with: scoped) { request.setValue(value, forHTTPHeaderField: key) }
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 25
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                if started { lock.unlock(); continuation.resume(throwing: NativeRAIDOContract.Failure.unsupportedRequest); return }
                started = true
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request); self.task = task
                lock.unlock(); task.resume()
            }
        }, onCancel: { self.cancel() })
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let continuation = self.continuation, session = self.session
        self.continuation = nil; self.session = nil; self.task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); finish(.failure(NativeRAIDOContract.Failure.redirect))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.url == dataTask.originalRequest?.url else {
            completionHandler(.cancel); finish(.failure(NativeRAIDOContract.Failure.unsupportedResponse)); return
        }
        let failure: NativeRAIDOContract.Failure?
        if [401, 403].contains(response.statusCode) { failure = .signInRequired }
        else if response.statusCode != 200 { failure = .http(response.statusCode) }
        else if response.expectedContentLength > NativeRAIDOContract.maximumResponseBytes { failure = .responseTooLarge }
        else if response.mimeType?.lowercased() != "application/json" && response.mimeType?.lowercased() != "text/json" { failure = .unsupportedResponse }
        else { failure = nil }
        if let failure { completionHandler(.cancel); finish(.failure(failure)) }
        else { completionHandler(.allow) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= NativeRAIDOContract.maximumResponseBytes else {
            finish(.failure(NativeRAIDOContract.Failure.responseTooLarge)); return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) } else { finish(.success(data)) }
    }
}

@MainActor
final class NativeRAIDOExperiment: ObservableObject {
    @Published private(set) var status = "Capture a live roster request to check native access."
    @Published private(set) var armed = false
    @Published private(set) var isWorking = false
    @Published private(set) var capturedMonth: String?
    private weak var webView: WKWebView?
    private var contract: NativeRAIDOContract?
    private var cookiesAtCapture: Data?
    private var token = UUID().uuidString
    private var generation = UUID()
    private var work: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func arm(in webView: WKWebView?) {
        stop()
        guard let webView, let resource = Bundle.main.url(forResource: "NativeRAIDORecorder", withExtension: "js"),
              let template = try? String(contentsOf: resource, encoding: .utf8) else {
            status = "Open Live RAIDO once, then return here to start capture."; return
        }
        self.webView = webView; token = UUID().uuidString; armed = true
        let source = template.replacingOccurrences(of: "__CAPTURE_TOKEN__", with: token)
        webView.configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let url = webView.url, PortalBridgePolicy.isPortal(url) { webView.evaluateJavaScript(source, completionHandler: nil) }
        status = "Listening. Open Live RAIDO and refresh the roster, then return here."
    }

    func navigationChanged() {
        guard armed else { return }
        invalidate(); status = "Listening for a roster request from the new page."
    }

    private func invalidate() {
        generation = UUID(); work?.cancel(); work = nil
        contract = nil; cookiesAtCapture = nil; capturedMonth = nil; isWorking = false
    }

    func stop() {
        invalidate(); armed = false
        if let webView {
            let controller = webView.configuration.userContentController
            let others = controller.userScripts.filter { !$0.source.contains("const token = '\(token)'") }
            controller.removeAllUserScripts(); others.forEach(controller.addUserScript)
            if let url = webView.url, PortalBridgePolicy.isPortal(url) {
                webView.evaluateJavaScript("window.__RAIDONativeExperiment?.stop()", completionHandler: nil)
            }
        }
        webView = nil; status = "Capture stopped; captured session data cleared."
    }

    func receive(_ body: Any) {
        guard armed, !isWorking, contract == nil, let webView,
              let message = body as? [String: Any], message["token"] as? String == token,
              let rawURL = message["url"] as? String, let url = URL(string: rawURL),
              let request = message["requestBody"] as? String, let response = message["responseBody"] as? String,
              request.utf8.count <= 4096, response.utf8.count <= NativeRAIDOContract.maximumResponseBytes else { return }
        let ticket = generation, requestData = Data(request.utf8), responseData = Data(response.utf8)
        isWorking = true
        work = Task { [weak self] in
            do {
                let contract = try await Task.detached(priority: .utility) {
                    try NativeRAIDOContract.capture(url: url, request: requestData, response: responseData)
                }.value
                let allCookies = await webView.configuration.websiteDataStore.httpCookieStore.nativeExperimentCookies()
                let cookies = NativeRAIDOContract.scopedCookies(allCookies, for: contract.url)
                guard let self, self.generation == ticket, !Task.isCancelled else { return }
                guard !cookies.isEmpty else { throw NativeRAIDOContract.Failure.signInRequired }
                self.contract = contract; self.cookiesAtCapture = NativeRAIDOContract.cookieDigest(cookies)
                self.capturedMonth = contract.month; self.isWorking = false; self.work = nil
                self.status = "Captured \(contract.month). Ready for a native read-only comparison."
            } catch {
                guard let self, self.generation == ticket else { return }
                self.isWorking = false; self.work = nil
                self.status = "The observed request is unsupported. Saved roster was not changed."
            }
        }
    }

    func compare() {
        guard !isWorking, let contract, let webView else { return }
        let ticket = generation; isWorking = true; status = "Comparing through the native connection…"
        work = Task { [weak self] in
            do {
                let allCookies = await webView.configuration.websiteDataStore.httpCookieStore.nativeExperimentCookies()
                let cookies = NativeRAIDOContract.scopedCookies(allCookies, for: contract.url)
                guard let self, self.generation == ticket, !Task.isCancelled else { return }
                guard NativeRAIDOContract.cookieDigest(cookies) == self.cookiesAtCapture else { throw NativeRAIDOContract.Failure.sessionChanged }
                let response = try await NativeRAIDOHTTPClient().fetch(contract, cookies: cookies)
                let digest = try await Task.detached(priority: .utility) { try NativeRAIDOContract.digest(response) }.value
                guard self.generation == ticket, !Task.isCancelled else { return }
                self.status = digest == contract.expectedDigest
                    ? "Native and portal JSON match for \(contract.month). Saved roster was not changed."
                    : "Native and portal JSON differ. This may include a newer revision or changing fields. Nothing was imported."
                self.isWorking = false; self.work = nil
            } catch {
                guard let self, self.generation == ticket else { return }
                self.isWorking = false; self.work = nil
                if let failure = error as? NativeRAIDOContract.Failure, [.signInRequired, .sessionChanged, .redirect].contains(failure) {
                    self.contract = nil; self.cookiesAtCapture = nil; self.capturedMonth = nil
                    self.status = "The session changed or needs sign-in. Open Live RAIDO and capture again."
                } else {
                    self.status = "Native comparison could not be verified. Saved roster was not changed."
                }
            }
        }
    }
}

private extension WKHTTPCookieStore {
    func nativeExperimentCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in getAllCookies { continuation.resume(returning: $0) } }
    }
}

struct NativeRAIDOExperimentView: View {
    @ObservedObject var experiment: NativeRAIDOExperiment
    let startCapture: () -> Void
    let openPortal: () -> Void

    var body: some View {
        Form {
            Section("Native connection experiment") {
                Text("Compare a native roster response with the live portal. This check keeps your current importer and saved roster in place.")
                Button(experiment.armed ? "Start a new capture" : "Capture next roster request", action: startCapture)
                    .disabled(experiment.isWorking)
                Button("Open Live RAIDO", action: openPortal)
                Button("Compare natively") { experiment.compare() }
                    .disabled(experiment.capturedMonth == nil || experiment.isWorking)
                if experiment.isWorking { ProgressView() }
                Text(experiment.status).font(.footnote).accessibilityIdentifier("native-raido-status")
                if experiment.armed { Button("Stop and clear capture") { experiment.stop() } }
            }
            Section {
                Text("Captures one observed GetRoster request. If this portal page uses HTML instead, no native request will be captured. A matching response verifies transport only; the native importer is not enabled.")
                Text("Request details remain in memory and clear when capture stops or the app backgrounds. No captured roster, cookie, or account identifier is copied to diagnostics.")
            }.font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("Native RAIDO").navigationBarTitleDisplayMode(.inline)
    }
}
