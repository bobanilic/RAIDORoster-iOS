import Foundation
import WebKit
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
        // Discover the portal's offered years/months. When controls are absent,
        // cache the preceding year plus the current and two following months.
        var keys = Set(offered.filter { index($0) != nil })
        keys.formUnion((-12...2).map { key(now + $0) })
        return keys.sorted {
            let a = index($0)!, b = index($1)!
            let da = abs(a - now), db = abs(b - now)
            return da == db ? a > b : da < db
        }.prefix(120).map { $0 }
    }
    static func needsDownload(_ snapshot: RosterSnapshot?, month: String, current: String, now: Date) -> Bool {
        guard let snapshot, snapshot.validation?.isValid == true,
              snapshot.validation?.parser.hasPrefix("raido-duty-envelope") == true else { return true }
        return month >= current && now.timeIntervalSince(snapshot.capturedAt) >= 6 * 3600
    }
}

/// One serial foreground-only cache worker. Shares the existing WebKit login,
/// but never navigates or executes fetched scripts in the visible portal.
@MainActor
final class RosterOfflineCache: NSObject, WKNavigationDelegate {
    private weak var store: RosterStore?
    private var webView: WKWebView?
    private var source: URL?
    private var queue: [String] = []
    private var task: Task<Void, Never>?
    private var bootstrapTimeout: Task<Void, Never>?
    private var generation = UUID()
    private var storeGeneration = UUID()
    private var attempts: [String: Date] = [:]
    private var active = true
    private var ready = false
    var statusChanged: ((String?) -> Void)?
    init(store: RosterStore) { self.store = store }

    private var currentMonth: String { String(EarningsMath.day(Date()).prefix(7)) }

    func start(source url: URL, requestedMonth: String? = nil, force: Bool = false) {
        guard active, RosterMonthCachePolicy.isRosterURL(url), let store else { return }
        if force { attempts.removeAll() }
        if storeGeneration != store.cacheGeneration {
            stop(); storeGeneration = store.cacheGeneration
        }
        if let requestedMonth, RosterMonthCachePolicy.index(requestedMonth) != nil {
            queue.removeAll { $0 == requestedMonth }
            if force || RosterMonthCachePolicy.needsDownload(store.monthSnapshots[requestedMonth], month: requestedMonth, current: currentMonth, now: Date()) {
                queue.insert(requestedMonth, at: 0)
            }
        }
        if ready { drain(); return }
        guard webView == nil else { return }
        source = url; storeGeneration = store.cacheGeneration
        let controller = WKUserContentController()
        if let script = RosterWebView.extractorSource() {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default(); config.userContentController = controller
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        view.navigationDelegate = self; webView = view
        statusChanged?("Saving roster months for offline use…")
        let ticket = generation
        bootstrapTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, self.generation == ticket, !self.ready else { return }
            self.fail("Connect to save more months. Your saved roster is available.")
        }
        view.load(URLRequest(url: url))
    }

    func resume() { active = true }
    func pause() { active = false; stop() }
    private func stop() {
        generation = UUID(); task?.cancel(); task = nil
        bootstrapTimeout?.cancel(); bootstrapTimeout = nil
        if let webView {
            webView.evaluateJavaScript("window.__RAIDOCacheAbort?.abort()", completionHandler: nil)
            webView.stopLoading(); webView.navigationDelegate = nil
        }
        webView = nil; ready = false; queue = []; source = nil
    }
    private func fail(_ message: String) { stop(); statusChanged?(message) }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, PortalBridgePolicy.isPortal(url), navigationAction.targetFrame != nil else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        bootstrapTimeout?.cancel(); bootstrapTimeout = nil
        guard let url = webView.url, RosterMonthCachePolicy.isRosterURL(url) else {
            fail("Sign in to Live RAIDO once to save more months. Saved months remain available."); return
        }
        ready = true
        let ticket = generation
        task = Task { [weak self] in
            guard let self else { return }
            let offered: [String]
            do {
                let value = try await webView.callAsyncJavaScript(Self.discoverScript, arguments: [:], in: nil, contentWorld: .page)
                offered = value as? [String] ?? []
            } catch { offered = [] }
            guard !Task.isCancelled, self.generation == ticket else { return }
            let targets = RosterMonthCachePolicy.targets(current: self.currentMonth, offered: offered)
            for key in targets where !self.queue.contains(key) { self.queue.append(key) }
            self.task = nil; self.drain()
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail("Connect to save more months. Your saved roster is available.")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("Connect to save more months. Your saved roster is available.")
    }

    private func drain() {
        guard task == nil, active, ready, let webView, let source, let store else { return }
        let ticket = generation, cacheTicket = storeGeneration
        task = Task { [weak self] in
            guard let self else { return }
            while !self.queue.isEmpty {
                guard !Task.isCancelled, self.generation == ticket, store.cacheGeneration == cacheTicket else { return }
                let key = self.queue.removeFirst()
                if !RosterMonthCachePolicy.needsDownload(store.monthSnapshots[key], month: key, current: self.currentMonth, now: Date()) { continue }
                if let attempted = self.attempts[key], Date().timeIntervalSince(attempted) < 6 * 3600 { continue }
                guard let url = RosterMonthCachePolicy.requestURL(source: source, month: key) else { continue }
                self.statusChanged?("Saving \(key) for offline use…")
                do {
                    let value = try await webView.callAsyncJavaScript(Self.fetchScript,
                        arguments: ["targetURL": url.absoluteString, "month": key], in: nil, contentWorld: .page)
                    guard !Task.isCancelled, self.generation == ticket, store.cacheGeneration == cacheTicket else { return }
                    guard let payload = value as? [String: Any] else { throw CacheError.network }
                    if payload["unavailable"] as? Bool == true { self.attempts[key] = Date() }
                    else if !store.ingest(messageBody: payload, archiveOnly: true, expectedMonth: key) { self.attempts[key] = Date() }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    guard !Task.isCancelled, self.generation == ticket else { return }
                    Logger(subsystem: "com.bobanilic.raidoroster", category: "OfflineRoster").notice("Month download paused; saved months retained")
                    self.fail("Connect or sign in to save more months. Your saved roster is available.")
                    return
                }
            }
            guard self.generation == ticket else { return }
            self.task = nil
            self.statusChanged?("\(store.rosterMonthKeys.count) months saved for offline use")
        }
    }
    private enum CacheError: Error { case network }

    private static let discoverScript = #"""
    const years = new Set(), keys = new Set();
    for (const select of document.querySelectorAll('select')) {
      const values = Array.from(select.options).map(o => String(o.value || o.textContent).trim());
      const valid = values.filter(v => /^20\d{2}$/.test(v));
      if (/year/i.test(select.id + ' ' + select.name) || (valid.length && valid.length === values.filter(Boolean).length)) {
        valid.forEach(y => years.add(y));
      }
    }
    for (const year of years) for (let m=1;m<=12;m++) keys.add(`${year}-${String(m).padStart(2,'0')}`);
    for (const link of document.querySelectorAll('a[href]')) {
      try { const u = new URL(link.href, location.href);
        if(u.origin !== location.origin || u.pathname.toLowerCase() !== location.pathname.toLowerCase()) continue;
        const y=u.searchParams.get('year'), m=Number(u.searchParams.get('month'));
        if(/^20\d{2}$/.test(y || '') && Number.isInteger(m) && m>=1 && m<=12) keys.add(`${y}-${String(m).padStart(2,'0')}`);
      } catch (_) {}
    }
    return Array.from(keys);
    """#

    private static let fetchScript = #"""
    const u = new URL(targetURL);
    if(u.origin !== location.origin || !/\/HumanResourceRoster\.aspx$/i.test(u.pathname)) throw new Error('Invalid month URL');
    const controller = new AbortController(); window.__RAIDOCacheAbort = controller;
    const timeout = setTimeout(() => controller.abort(), 10000);
    try {
      const response = await fetch(u.href, {credentials:'include', cache:'no-store', redirect:'error', signal:controller.signal});
      if(!response.ok) throw new Error('Month download failed');
      const html = await response.text();
      if(html.length > 4*1024*1024) throw new Error('Month page too large');
      const loginCheck = new DOMParser().parseFromString(html, 'text/html');
      if(loginCheck.querySelector('input[type="password"]')) throw new Error('Sign in required');
      if(!window.RAIDOPlus?.extractHTML) throw new Error('Extractor unavailable');
      try { return window.RAIDOPlus.extractHTML(html, u.href, month); }
      catch (_) { return {unavailable:true}; }
    } finally { clearTimeout(timeout); if(window.__RAIDOCacheAbort === controller) window.__RAIDOCacheAbort = null; }
    """#
}
