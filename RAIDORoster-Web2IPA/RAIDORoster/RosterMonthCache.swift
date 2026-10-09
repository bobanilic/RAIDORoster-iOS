import Foundation
import WebKit
import UIKit
import os

enum RosterMonthCachePolicy {
    static func isRosterURL(_ url: URL) -> Bool {
        PortalBridgePolicy.isPortal(url) && url.path.lowercased().hasSuffix("/humanresourceroster.aspx")
    }
    static func index(_ key: String) -> Int? {
        guard key.range(of: #"^20\d{2}-(?:0[1-9]|1[0-2])$"#, options: .regularExpression) != nil else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        return parts[0] * 12 + parts[1] - 1
    }
    static func key(_ index: Int) -> String { String(format: "%04d-%02d", index / 12, index % 12 + 1) }
    static func requestURL(source: URL, month: String) -> URL? {
        guard isRosterURL(source), let value = index(month), var parts = URLComponents(url: source, resolvingAgainstBaseURL: false) else { return nil }
        var query = parts.queryItems ?? []
        query.removeAll { ["month", "year"].contains($0.name.lowercased()) }
        query += [URLQueryItem(name: "month", value: String(value % 12 + 1)), URLQueryItem(name: "year", value: String(value / 12))]
        parts.queryItems = query; parts.fragment = nil
        return parts.url
    }
    static func targets(current: String, offered: [String]) -> [String] {
        guard let now = index(current) else { return [] }
        // All years actually offered by RAIDO, plus a year of history when it
        // only exposes Previous/Next. Older requested months extend the queue.
        var keys = Set(offered.filter { index($0) != nil })
        keys.formUnion((-12...2).map { key(now + $0) }.filter { index($0) != nil })
        return keys.sorted {
            let a = index($0)!, b = index($1)!
            if (a > now) != (b > now) { return a <= now }
            return abs(a - now) == abs(b - now) ? a < b : abs(a - now) < abs(b - now)
        }
    }
    static func needsDownload(_ snapshot: RosterSnapshot?, month: String, current: String, now: Date) -> Bool {
        guard let snapshot, snapshot.validation?.isValid == true,
              snapshot.validation?.parser.hasPrefix("raido-duty-envelope") == true,
              snapshot.items.contains(where: { $0.dateISO?.hasPrefix(month + "-") == true }) else { return true }
        // Recheck legacy archives once; verified history is periodically refreshed.
        if month < current && snapshot.validation?.parser.contains("history-3.2") != true { return true }
        return now.timeIntervalSince(snapshot.capturedAt) >= (month < current ? 7 * 24 * 3600 : 6 * 3600)
    }
}

struct RosterHistoryProgress: Codable {
    struct Failure: Codable { var reason: String; var retryAt: Date; var attempts: Int }
    var sourceIdentity: String
    var targets: [String] = []
    var failures: [String: Failure] = [:]
    var empty: [String: Date] = [:]
}

/// Serial foreground worker using the user's existing WebKit session. Direct
/// HTML is the fast path; rendered month controls preserve RAIDO's form state.
@MainActor
final class RosterOfflineCache: NSObject, WKNavigationDelegate {
    struct Timing {
        var load: TimeInterval = 20
        var settle: TimeInterval = 12
        var poll: TimeInterval = 0.4
        var gap: TimeInterval = 1
    }
    private enum Failure: Error {
        case auth, rateLimit(TimeInterval), network, format, navigation, storage
        var reason: String {
            switch self {
            case .auth: return "sign-in-required"
            case .rateLimit: return "server-rate-limit"
            case .network: return "connection-failed"
            case .format: return "month-not-validated"
            case .navigation: return "month-controls-not-ready"
            case .storage: return "device-storage-failed"
            }
        }
    }
    private weak var store: RosterStore?
    private var view: WKWebView?
    private var source: URL?
    private var progress: RosterHistoryProgress?
    private var task: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var navigationWaiter: CheckedContinuation<Void, Error>?
    private var navigationTimeout: Task<Void, Never>?
    private var generation = UUID()
    private var storeGeneration = UUID()
    private var active = true
    private let configurationFactory: (() -> WKWebViewConfiguration)?
    private let fixtureLoader: ((WKWebView, URLRequest) -> Void)?
    private weak var hostView: UIView?
    private let monthOverride: String?
    private let targetsOverride: [String]?
    var timing = Timing()
    private(set) var needsRetry = false
    private(set) var isRunning = false
    var statusChanged: ((String?) -> Void)?

    init(store: RosterStore, configuration: (() -> WKWebViewConfiguration)? = nil,
         loader: ((WKWebView, URLRequest) -> Void)? = nil, hostView: UIView? = nil,
         currentMonth: String? = nil, targets: [String]? = nil) {
        self.store = store; configurationFactory = configuration; fixtureLoader = loader
        self.hostView = hostView; monthOverride = currentMonth; targetsOverride = targets
    }
    private var currentMonth: String { monthOverride ?? String(EarningsMath.day(Date()).prefix(7)) }
    var diagnosticText: String {
        let value: [String: Any] = ["version":"2.29.17-history-recovery", "running":isRunning,
            "plannedMonths":progress?.targets ?? [], "savedMonths":store?.rosterMonthKeys ?? [],
            "emptyMonths":Array(progress?.empty.keys ?? Dictionary<String,Date>().keys).sorted(),
            "failures":progress?.failures.mapValues { ["reason":$0.reason,"attempts":String($0.attempts)] } ?? [:]]
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys,.prettyPrinted]),
              let text = String(data: bytes, encoding: .utf8) else { return "History diagnostics unavailable" }
        return text // No employee identifiers, URLs, tokens or roster activities.
    }
    func resume() { active = true }
    func pause() { active = false; cancel() }
    private func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        retryTask?.cancel(); retryTask = nil
        finishNavigation(.failure(CancellationError()))
        view?.evaluateJavaScript("window.__RAIDOCacheAbort?.abort()", completionHandler: nil)
        releaseView(); isRunning = false
    }
    private func releaseView() {
        view?.navigationDelegate = nil; view?.stopLoading(); view?.removeFromSuperview(); view = nil
    }
    private func publish(_ text: String, retry: Bool = false) { needsRetry = retry; statusChanged?(text) }
    private func checkpoint() throws {
        guard let store, let progress else { throw Failure.storage }
        do { try ProtectedJSONFile<RosterHistoryProgress>(url: store.offlineHistoryStateURL).save(progress) }
        catch { DeviceCacheStorage.report("Save history progress", error: error); throw Failure.storage }
    }
    func start(source url: URL, requestedMonth: String? = nil, force: Bool = false) {
        guard active, let store, RosterMonthCachePolicy.isRosterURL(url),
              let identity = RosterMonthCachePolicy.requestURL(source: url, month: "2000-01")?.absoluteString else { return }
        if source != nil && (progress?.sourceIdentity != identity || storeGeneration != store.cacheGeneration) {
            cancel(); progress = nil
        }
        source = url; storeGeneration = store.cacheGeneration
        if progress == nil {
            do {
                let saved = try ProtectedJSONFile<RosterHistoryProgress>(url: store.offlineHistoryStateURL).load()
                progress = saved?.sourceIdentity == identity ? saved : RosterHistoryProgress(sourceIdentity: identity)
            } catch { DeviceCacheStorage.report("Read history progress", error: error); publish("History progress could not be opened. Saved months are safe.", retry: true); return }
        }
        let planned = targetsOverride ?? RosterMonthCachePolicy.targets(current: currentMonth, offered: progress?.targets ?? [])
        for key in planned where progress?.targets.contains(key) == false { progress?.targets.append(key) }
        // A manual retry must still respect a server Retry-After response.
        if force {
            let rateLimits = progress?.failures.filter { $0.value.reason == "server-rate-limit" && $0.value.retryAt > Date() } ?? [:]
            progress?.failures = rateLimits
        }
        if let requestedMonth, RosterMonthCachePolicy.index(requestedMonth) != nil {
            progress?.targets.removeAll { $0 == requestedMonth }; progress?.targets.insert(requestedMonth, at: 0)
            if force { progress?.empty.removeValue(forKey: requestedMonth) }
        }
        do { try checkpoint() } catch { publish("Cannot save history progress on this device.", retry: true); return }
        guard task == nil else { return }
        if pendingMonths.isEmpty { reportCompletion(); scheduleRetry(); return }
        retryTask?.cancel(); retryTask = nil
        let ticket = generation, cacheTicket = storeGeneration
        isRunning = true; publish("Preparing offline roster history…")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run(ticket: ticket, cacheTicket: cacheTicket)
            } catch is CancellationError {
                if self.generation == ticket { self.task = nil; self.isRunning = false; self.releaseView() }
                return
            }
            catch {
                guard self.generation == ticket else { return }
                let failure = error as? Failure ?? .network
                if let key = self.pendingMonths.first { self.record(key, failure: failure) }
                do { try self.checkpoint() } catch { DeviceCacheStorage.report("Save paused history", error: error) }
                self.publish(self.message(failure), retry: true)
            }
            guard self.generation == ticket else { return }
            self.task = nil; self.isRunning = false; self.releaseView()
            self.scheduleRetry()
        }
    }
    private func scheduleRetry() {
        retryTask?.cancel(); retryTask = nil
        guard active, let source,
              let next = progress?.failures.values.filter({ $0.attempts < 3 && !["sign-in-required","device-storage-failed"].contains($0.reason) }).map(\.retryAt).min() else { return }
        retryTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(max(1, next.timeIntervalSinceNow)) } catch { return }
            guard self.active else { return }
            self.start(source: source)
        }
    }
    private var pendingMonths: [String] {
        guard let store else { return [] }
        let now = Date()
        return (progress?.targets ?? []).filter { key in
            if let failure = progress?.failures[key], failure.attempts >= 3 { return false }
            if let retry = progress?.failures[key]?.retryAt, retry > now { return false }
            if let empty = progress?.empty[key], now.timeIntervalSince(empty) < 6 * 3600 { return false }
            return RosterMonthCachePolicy.needsDownload(store.monthSnapshots[key], month: key, current: currentMonth, now: now)
        }
    }
    private func check(_ ticket: UUID, _ cacheTicket: UUID) throws {
        guard !Task.isCancelled, active, generation == ticket, store?.cacheGeneration == cacheTicket else { throw CancellationError() }
    }
    private func sleep(_ seconds: TimeInterval) async throws { try await Task.sleep(nanoseconds: UInt64(max(0,seconds) * 1_000_000_000)) }
    private func makeView() throws -> WKWebView {
        guard let script = RosterWebView.extractorSource() else { throw Failure.format }
        let config = configurationFactory?() ?? WKWebViewConfiguration()
        if configurationFactory == nil { config.websiteDataStore = .default() }
        config.userContentController.addUserScript(WKUserScript(source: Self.networkScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let result = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        result.navigationDelegate = self; result.isUserInteractionEnabled = false
        result.accessibilityElementsHidden = true; result.alpha = 0.01
        // A hosted web view allows the portal's JavaScript/render lifecycle to run.
        let host = hostView ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        host?.insertSubview(result, at: 0)
        view = result; return result
    }
    private func run(ticket: UUID, cacheTicket: UUID) async throws {
        guard let source, let store else { throw CancellationError() }
        let web = try makeView()
        try await load(source, web: web)
        try check(ticket, cacheTicket)
        // Bootstrap need not have a valid roster yet (a JavaScript shell is common).
        _ = try await inspect(web)
        let discovered = try await web.callAsyncJavaScript("return window.RAIDOPlus?.history.discover() || [];", arguments: [:], in: nil, contentWorld: .page) as? [String] ?? []
        if targetsOverride == nil {
            for key in RosterMonthCachePolicy.targets(current: currentMonth, offered: discovered) where progress?.targets.contains(key) == false { progress?.targets.append(key) }
            try checkpoint()
        }
        while let key = pendingMonths.first {
            try check(ticket, cacheTicket)
            publish("Saving \(key) · \(store.rosterMonthKeys.count) months available offline…")
            try check(ticket, cacheTicket)
            do {
                let result = try await download(key, web: web, source: source)
                try check(ticket, cacheTicket)
                if result["kind"] as? String == "empty" {
                    progress?.empty[key] = Date()
                } else {
                    guard var payload = result["payload"] as? [String: Any], var validation = payload["validation"] as? [String: Any] else { throw Failure.format }
                    validation["parser"] = "raido-duty-envelope-history-3.2"
                    payload["validation"] = validation
                    guard store.ingest(messageBody: payload, archiveOnly: true, expectedMonth: key) else { throw Failure.storage }
                    progress?.empty.removeValue(forKey: key)
                }
                progress?.failures.removeValue(forKey: key)
                extendTargets(result["offered"] as? [String] ?? [])
                try checkpoint()
            } catch is CancellationError { throw CancellationError() }
            catch {
                try check(ticket, cacheTicket)
                let failure = error as? Failure ?? .network
                record(key, failure: failure); try checkpoint()
                // Do not continue issuing requests after login expiry or throttling.
                switch failure {
                case .auth, .rateLimit, .network, .storage: publish(message(failure), retry: true); return
                case .format, .navigation:
                    // An unpublished hole must not hide older offered history.
                    let offered = try await web.callAsyncJavaScript("return window.RAIDOPlus?.history.discover() || [];", arguments: [:], in: nil, contentWorld: .page) as? [String] ?? []
                    extendTargets(offered); try checkpoint()
                }
            }
            try await sleep(timing.gap)
        }
        try check(ticket, cacheTicket); reportCompletion()
    }
    private func extendTargets(_ offered: [String]) {
        guard targetsOverride == nil else { return }
        for key in offered where RosterMonthCachePolicy.index(key) != nil && progress?.targets.contains(key) == false { progress?.targets.append(key) }
    }
    private func record(_ key: String, failure: Failure) {
        let count = (progress?.failures[key]?.attempts ?? 0) + 1
        let cooldown: TimeInterval
        switch failure {
        case .rateLimit(let delay): cooldown = max(60, min(24 * 3600, delay))
        case .auth, .storage: cooldown = 300
        default: cooldown = min(1800, 30 * pow(2, Double(min(count,6)))) + Double.random(in: 0...5)
        }
        progress?.failures[key] = .init(reason: failure.reason, retryAt: Date().addingTimeInterval(cooldown), attempts: count)
    }
    private func message(_ failure: Failure) -> String {
        switch failure {
        case .auth: return "Sign in to Live RAIDO, then return here to resume saving history."
        case .rateLimit: return "RAIDO asked us to wait. History will resume after its retry delay."
        case .storage: return "A month could not be saved on this device. Saved months are safe."
        default: return "History download paused. Connect and retry; saved months are safe."
        }
    }
    private func reportCompletion() {
        let saved = store?.rosterMonthKeys.count ?? 0, failed = progress?.failures.count ?? 0
        publish(failed == 0 ? "\(saved) months saved for offline use" : "\(saved) months saved · \(failed) months need retry", retry: failed > 0)
    }
    private func download(_ key: String, web: WKWebView, source: URL) async throws -> [String: Any] {
        guard let url = RosterMonthCachePolicy.requestURL(source: source, month: key) else { throw Failure.format }
        // Direct HTML avoids a rendered navigation when the portal supports it.
        let raw = try await web.callAsyncJavaScript(Self.fetchScript, arguments: ["targetURL":url.absoluteString,"month":key], in: nil, contentWorld: .page) as? [String: Any] ?? [:]
        try classify(raw)
        if raw["kind"] as? String == "ready" { return raw }
        try await load(url, web: web)
        if let rendered = try await settled(key, web: web) { return rendered }
        // Query parameters may be ignored; use the actual selectors/postbacks or
        // Previous/Next on the private rendered page, one verified step at a time.
        for _ in 0..<1200 {
            try Task.checkCancellation()
            let before = try await inspect(web)
            if before["month"] as? String == key, let ready = try await settled(key, web: web) { return ready }
            let change: [String: Any]
            do {
                change = try await web.callAsyncJavaScript("return window.RAIDOPlus.history.navigate(month);", arguments: ["month":key], in: nil, contentWorld: .page) as? [String: Any] ?? [:]
            } catch {
                // A real form submit can replace the JavaScript context immediately.
                if web.isLoading { try await sleep(timing.poll); continue }
                throw Failure.navigation
            }
            guard change["kind"] as? String == "started", let expected = change["month"] as? String else { throw Failure.navigation }
            guard let value = try await settled(expected, web: web, requirePayload: expected == key,
                                               yearChange: change["mode"] as? String == "year") else { throw Failure.navigation }
            if value["month"] as? String == key { return value }
            // Empty intermediate months still carry a valid month heading.
        }
        throw Failure.navigation
    }
    private func classify(_ value: [String: Any]) throws {
        switch value["kind"] as? String {
        case "auth": throw Failure.auth
        case "rate": throw Failure.rateLimit(value["retryAfter"] as? Double ?? 60)
        case "network": throw Failure.network
        default: break
        }
    }
    private func inspect(_ web: WKWebView) async throws -> [String: Any] {
        let value = try await web.callAsyncJavaScript("return window.RAIDOPlus?.history.inspect() || {kind:'loading'};", arguments: [:], in: nil, contentWorld: .page) as? [String: Any] ?? [:]
        try classify(value); return value
    }
    private func settled(_ key: String, web: WKWebView, requirePayload: Bool = true, yearChange: Bool = false) async throws -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timing.settle)
        var previous: Data?
        while Date() < deadline {
            try await sleep(timing.poll); try Task.checkCancellation()
            if web.isLoading { previous = nil; continue }
            let value: [String: Any]
            do {
                value = try await web.callAsyncJavaScript("return window.RAIDOPlus?.history.inspect(yearChange ? null : month) || {kind:'loading'};", arguments: ["month":key,"yearChange":yearChange], in: nil, contentWorld: .page) as? [String: Any] ?? [:]
            } catch { if web.isLoading { continue }; throw error }
            try classify(value)
            if yearChange && !(value["month"] as? String ?? "").hasPrefix(String(key.prefix(4)) + "-") { previous = nil; continue }
            let ready = ["ready","empty"].contains(value["kind"] as? String ?? "")
            let intermediate = !requirePayload && value["month"] as? String == key && value["kind"] as? String == "format"
            guard ready || intermediate else { previous = nil; continue }
            let bytes = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
            if previous == bytes { return value }
            previous = bytes
        }
        return nil
    }
    private func load(_ url: URL, web: WKWebView) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationWaiter = continuation
            navigationTimeout = Task { [weak self] in
                guard let self else { return }
                do { try await self.sleep(self.timing.load) } catch { return }
                self.finishNavigation(.failure(Failure.network)); web.stopLoading()
            }
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            if let fixtureLoader { fixtureLoader(web, request) } else { web.load(request) }
        }
    }
    private func finishNavigation(_ result: Result<Void, Error>) {
        let waiter = navigationWaiter; navigationWaiter = nil
        navigationTimeout?.cancel(); navigationTimeout = nil
        waiter?.resume(with: result)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let fixtureBlank = fixtureLoader != nil && url?.absoluteString == "about:blank"
        decisionHandler(view === webView && navigationAction.targetFrame != nil && (url.map(PortalBridgePolicy.isPortal) == true || fixtureBlank) ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard view === webView else { return }
        guard let url = webView.url, RosterMonthCachePolicy.isRosterURL(url) else { finishNavigation(.failure(Failure.auth)); return }
        finishNavigation(.success(()))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard view === webView else { return }; finishNavigation(.failure(Failure.network))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard view === webView else { return }; finishNavigation(.failure(Failure.network))
    }
    static let networkScript = #"""
    (() => {
      const state = window.__RAIDOHistoryNetwork = {pending:0};
      const fetch = window.fetch;
      window.fetch = function(...args) { state.pending++; return fetch.apply(this,args).finally(() => state.pending--); };
      const send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function(...args) { state.pending++; this.addEventListener('loadend',() => state.pending--,{once:true});
        try { return send.apply(this,args); } catch(e) { state.pending--; throw e; } };
    })();
    """#
    static let fetchScript = #"""
    const u = new URL(targetURL);
    if(u.origin !== location.origin || !/\/HumanResourceRoster\.aspx$/i.test(u.pathname)) return {kind:'format'};
    const controller = new AbortController(); window.__RAIDOCacheAbort = controller;
    const timeout = setTimeout(() => controller.abort(),10000);
    try {
      const response = await fetch(u.href,{credentials:'include',cache:'no-store',signal:controller.signal});
      if(response.status === 401 || response.status === 403) return {kind:'auth'};
      if(response.status === 429 || response.status === 503) {
        const header=response.headers.get('Retry-After'); let delay=Number(header);
        if(header && !Number.isFinite(delay)) delay=Math.max(0,(Date.parse(header)-Date.now())/1000);
        return {kind:'rate',retryAfter:Number.isFinite(delay) && delay>0 ? delay : 60};
      }
      if(!response.ok) return {kind:'network'};
      const finalURL = new URL(response.url || u.href);
      if(finalURL.origin !== u.origin || !/\/HumanResourceRoster\.aspx$/i.test(finalURL.pathname)) return {kind:'auth'};
      const html = await response.text();
      if(html.length > 4*1024*1024) return {kind:'format'};
      if(new DOMParser().parseFromString(html,'text/html').querySelector('input[type="password"]')) return {kind:'auth'};
      try { return {kind:'ready',offered:window.RAIDOPlus.history.discoverHTML(html,u.href),payload:window.RAIDOPlus.extractHTML(html,u.href,month)}; }
      catch (_) { return {kind:'render-required'}; }
    } catch (_) { return {kind:'network'}; }
    finally { clearTimeout(timeout); if(window.__RAIDOCacheAbort === controller) window.__RAIDOCacheAbort = null; }
    """#
}
