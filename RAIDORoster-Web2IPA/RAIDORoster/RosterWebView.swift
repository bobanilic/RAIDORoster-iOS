import SwiftUI
import WebKit
import UIKit
import os

@MainActor
final class RosterBrowserModel: ObservableObject {
    static let startURL = URL(string: "https://gjt.noc.vmc.navblue.cloud/")!

    @Published var canGoBack = false
    @Published var pageTitle = ""
    @Published var currentURL: URL?
    @Published var loadError: String?
    @Published var diagnosticStatus: String?
    @Published var monthNavigationStatus: String?
    @Published private(set) var offlineMonthStatus: String?
    private lazy var offlineCache: RosterOfflineCache = {
        let cache = RosterOfflineCache(store: store)
        cache.statusChanged = { [weak self] in self?.offlineMonthStatus = $0 }
        return cache
    }()

    fileprivate var webView: WKWebView?
    fileprivate let store: RosterStore
    fileprivate var hasLoadedInitialURL = false

    init(store: RosterStore) {
        self.store = store
    }

    var preferredStartURL: URL {
        if let saved = UserDefaults.standard.string(forKey: "RAIDORoster.LastPortalURL"),
           let url = URL(string: saved),
           PortalBridgePolicy.isPortal(url) {
            return url
        }
        return Self.startURL
    }

    func reload() {
        loadError = nil
        webView?.reload()
    }

    func resumeOfflineMonths() {
        offlineCache.resume()
        let source = store.rosterSourceURL ?? (RosterMonthCachePolicy.isRosterURL(preferredStartURL) ? preferredStartURL : nil)
        if let source { offlineCache.start(source: source) }
    }

    func pauseOfflineMonths() { offlineCache.pause() }

    fileprivate func rosterPageLoaded(_ url: URL) {
        store.rememberRosterSourceURL(url)
        offlineCache.start(source: url, force: true)
    }

    func cacheRosterMonth(_ month: String) {
        guard RosterMonthCachePolicy.index(month) != nil else { return }
        let source = store.rosterSourceURL ?? (RosterMonthCachePolicy.isRosterURL(preferredStartURL) ? preferredStartURL : nil)
        guard let source else {
            offlineMonthStatus = "Sign in to Live RAIDO once to save your roster months."; return
        }
        offlineCache.start(source: source, requestedMonth: month)
    }

    func goBack() {
        webView?.goBack()
    }

    func openStartPage() {
        loadError = nil
        webView?.load(URLRequest(url: Self.startURL, cachePolicy: .useProtocolCachePolicy))
    }

    func switchRosterMonth(_ direction: String) {
        guard let webView else {
            monthNavigationStatus = "Open RAIDO once to enable online month loading."
            return
        }
        let want = direction.lowercased() == "previous" ? "previous" : "next"
        let script = """
        (() => {
          const want = '\(want)';
          const controls = Array.from(document.querySelectorAll('button.switch-month-button, button, a'));
          const button = controls.find(el => {
            const text = (el.innerText || el.textContent || '').trim().toLowerCase();
            return text === want && !el.disabled && el.getAttribute('aria-disabled') !== 'true';
          });
          if (!button) return false;
          button.click();
          setTimeout(() => {
            try { window.RAIDOPlus?.extractNow?.(); } catch (_) {}
          }, 900);
          return true;
        })();
        """
        webView.evaluateJavaScript(script) { result, error in
            DispatchQueue.main.async {
                if result as? Bool == true {
                    self.monthNavigationStatus = "Loading \(want) roster month…"
                } else if let error {
                    self.monthNavigationStatus = "Could not switch month: \(error.localizedDescription)"
                } else {
                    self.monthNavigationStatus = "RAIDO \(want) month is unavailable."
                }
            }
        }
    }

    func refreshRosterCalendarFeed() {
        guard let webView, let url = webView.url, PortalBridgePolicy.isPortal(url) else { return }
        let script = #"""
        (() => {
          const downloadPage = '/RaidoMobile/Dialogues/HumanResources/DownloadRosterAsExternalCalendar.aspx';
          const unfold = text => text.replace(/\r\n[ \t]/g, '').replace(/\n[ \t]/g, '');
          const unescapeICS = value => String(value || '')
            .replace(/\\n/gi, '\n').replace(/\\,/g, ',').replace(/\\;/g, ';').replace(/\\\\/g, '\\');
          const prop = (block, name) => {
            const re = new RegExp('(?:^|\\n)' + name + '(?:;[^:]*)?:([^\\n\\r]*)', 'i');
            const m = block.match(re); return m ? unescapeICS(m[1].trim()) : '';
          };
          const utcParts = stamp => {
            const m = String(stamp || '').match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?Z$/);
            if (!m) return null;
            return { y:+m[1], mo:+m[2], d:+m[3], h:+m[4], mi:+m[5], s:+(m[6]||0) };
          };
          const localClock = (desc, label) => {
            const re = new RegExp(label + '\\s+(\\d{4})Z\\s*\\/\\s*(\\d{4})L', 'i');
            const m = String(desc || '').match(re); return m ? { z:m[1], l:m[2] } : null;
          };
          const localDateFrom = (utcStamp, pair) => {
            const p = utcParts(utcStamp); if (!p) return '';
            let date = Date.UTC(p.y,p.mo-1,p.d,p.h,p.mi,p.s);
            if (pair) {
              const zh=+pair.z.slice(0,2), zm=+pair.z.slice(2), lh=+pair.l.slice(0,2), lm=+pair.l.slice(2);
              let diff=(lh*60+lm)-(zh*60+zm); if(diff>720)diff-=1440; if(diff < -720)diff+=1440;
              date += diff*60000;
            }
            const d=new Date(date); return `${d.getUTCFullYear()}-${String(d.getUTCMonth()+1).padStart(2,'0')}-${String(d.getUTCDate()).padStart(2,'0')}`;
          };
          const utcISO = stamp => {
            const p=utcParts(stamp); if(!p)return '';
            return `${p.y}-${String(p.mo).padStart(2,'0')}-${String(p.d).padStart(2,'0')} ${String(p.h).padStart(2,'0')}:${String(p.mi).padStart(2,'0')}`;
          };

          fetch(downloadPage, { credentials:'include', cache:'no-store' })
            .then(r => r.text())
            .then(html => {
              const doc = new DOMParser().parseFromString(html, 'text/html');
              const field = doc.querySelector('#MasterMain_txtDownloadLink');
              if (!field || !field.value) throw new Error('N-OC calendar subscription link unavailable');
              const feedURL = field.value.replace(/^webcal:/i, 'https:');
              const u = new URL(feedURL, location.href);
              if (u.protocol !== 'https:' || u.hostname !== 'gjt.noc.vmc.navblue.cloud' || (u.port && u.port !== '443')) throw new Error('Unexpected calendar host');
              return fetch(u.href, { cache:'no-store', redirect:'error' });
            })
            .then(r => { if(!r.ok) throw new Error('Calendar feed HTTP '+r.status); return r.text(); })
            .then(raw => {
              const text=unfold(raw);
              const blocks=text.split(/BEGIN:VEVENT/i).slice(1).map(x => x.split(/END:VEVENT/i)[0]);
              const events=blocks.map((block,index) => {
                const summary=prop(block,'SUMMARY'), description=prop(block,'DESCRIPTION');
                const dtstart=prop(block,'DTSTART'), dtend=prop(block,'DTEND');
                const startPair=localClock(description,'Start'), endPair=localClock(description,'End');
                const dateISO=localDateFrom(dtstart,startPair);
                return {
                  uid: prop(block,'UID') || `ics-${dateISO}-${index}`,
                  summary, description, dateISO,
                  startLocal: startPair ? `${startPair.l.slice(0,2)}:${startPair.l.slice(2)}` : '',
                  endLocal: endPair ? `${endPair.l.slice(0,2)}:${endPair.l.slice(2)}` : '',
                  startUTC: utcISO(dtstart), endUTC: utcISO(dtend)
                };
              }).filter(x => x.dateISO);
              window.webkit.messageHandlers.rosterCalendarFeed.postMessage({
                schemaVersion:1, source:'n-oc-webcal', capturedAt:new Date().toISOString(), events
              });
            })
            .catch(() => {});
          return true;
        })();
        """#
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func copyDiagnostics() {
        guard let webView else {
            diagnosticStatus = "Open the RAIDO tab first, then try again."
            return
        }

        let script = #"""
        (() => {
          const endpoint = '/RaidoMobile/Dialogues/HumanResources/DownloadRosterAsExternalCalendar.aspx';
          const redactURL = raw => {
            try {
              const u = new URL(raw.replace(/^webcal:/i, 'https:'), location.href);
              return {
                scheme: u.protocol.replace(':',''),
                host: u.host,
                path: u.pathname,
                queryParameterNames: Array.from(new Set(Array.from(u.searchParams.keys()))).sort()
              };
            } catch (_) { return { invalid: true }; }
          };
          const unfold = text => String(text || '').replace(/\r\n[ \t]/g, '').replace(/\n[ \t]/g, '');
          const unescapeICS = value => String(value || '')
            .replace(/\\n/gi, '\n')
            .replace(/\\,/g, ',')
            .replace(/\\;/g, ';')
            .replace(/\\\\/g, '\\');
          const safeValue = (name, value) => {
            const upper = name.toUpperCase();
            if (upper === 'UID' || upper === 'URL' || upper === 'ATTACH') return '[redacted]';
            let out = unescapeICS(value).trim();
            if (out.length > 500) out = out.slice(0, 500) + '…';
            return out;
          };
          const parseEvents = text => {
            const body = unfold(text);
            const blocks = body.match(/BEGIN:VEVENT[\s\S]*?END:VEVENT/gi) || [];
            return blocks.slice(0, 5).map(block => {
              const props = {};
              const names = [];
              for (const line of block.split(/\r?\n/)) {
                if (!line || /^BEGIN:|^END:/i.test(line)) continue;
                const colon = line.indexOf(':');
                if (colon <= 0) continue;
                const lhs = line.slice(0, colon);
                const value = line.slice(colon + 1);
                const name = lhs.split(';')[0].toUpperCase();
                if (!names.includes(name)) names.push(name);
                if (!['UID','URL','ATTACH'].includes(name) && props[name] === undefined) {
                  props[name] = safeValue(name, value);
                }
              }
              return { propertyNames: names.sort(), values: props };
            });
          };

          const result = {
            diagnosticVersion: '2.19.2-direct-webcal-feed-probe',
            page: redactURL(location.href),
            feedDiscovery: {}
          };

          try {
            const pageXHR = new XMLHttpRequest();
            pageXHR.open('GET', endpoint, false);
            pageXHR.withCredentials = true;
            pageXHR.send(null);
            result.feedDiscovery.downloadPageStatus = pageXHR.status;
            const doc = new DOMParser().parseFromString(pageXHR.responseText || '', 'text/html');
            const input = doc.querySelector('#MasterMain_txtDownloadLink, input[name="ctl00$MasterMain$txtDownloadLink"]');
            const webcal = input?.value || '';
            result.feedDiscovery.subscriptionLinkPresent = /^webcal:\/\//i.test(webcal);
            result.feedDiscovery.subscriptionEndpoint = webcal ? redactURL(webcal) : null;

            if (!webcal) throw new Error('Download page did not expose the roster subscription link');

            const feedURL = webcal.replace(/^webcal:/i, 'https:');
            const feedXHR = new XMLHttpRequest();
            feedXHR.open('GET', feedURL, false);
            feedXHR.withCredentials = true;
            feedXHR.send(null);
            const ct = feedXHR.getResponseHeader('content-type') || '';
            const body = feedXHR.responseText || '';
            const unfolded = unfold(body);
            result.feed = {
              status: feedXHR.status,
              contentType: ct.split(';')[0],
              bodyLength: body.length,
              hasVCALENDAR: /BEGIN:VCALENDAR/i.test(body),
              eventCount: (unfolded.match(/BEGIN:VEVENT/gi) || []).length,
              calendarPropertyNames: Array.from(new Set(
                unfolded.split(/\r?\n/)
                  .filter(line => line && !/^BEGIN:VEVENT/i.test(line))
                  .map(line => line.includes(':') ? line.split(':',1)[0].split(';')[0].toUpperCase() : '')
                  .filter(Boolean)
              )).sort().slice(0,80),
              sampleEvents: parseEvents(body)
            };
          } catch (e) {
            result.error = String(e && e.message ? e.message : e);
          }

          return JSON.stringify(result, null, 2);
        })();
        """#

        webView.evaluateJavaScript(script) { result, error in
            DispatchQueue.main.async {
                if let text = result as? String, !text.isEmpty {
                    UIPasteboard.general.string = text
                    self.diagnosticStatus = "Direct roster calendar feed probe copied. Paste it into ChatGPT."
                } else if let error {
                    self.diagnosticStatus = "Could not inspect roster calendar feed: \(error.localizedDescription)"
                } else {
                    self.diagnosticStatus = "Roster calendar feed returned no diagnostics."
                }
            }
        }
    }
}

struct RosterWebView: UIViewRepresentable {
    @ObservedObject var model: RosterBrowserModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        if let existing = model.webView {
            let controller = existing.configuration.userContentController
            controller.removeScriptMessageHandler(forName: "rosterCache")
            controller.removeScriptMessageHandler(forName: "rosterCalendarFeed")
            controller.add(context.coordinator, name: "rosterCache")
            controller.add(context.coordinator, name: "rosterCalendarFeed")
            existing.navigationDelegate = context.coordinator
            existing.uiDelegate = context.coordinator
            let refresh = UIRefreshControl()
            refresh.addTarget(context.coordinator, action: #selector(Coordinator.refresh(_:)), for: .valueChanged)
            existing.scrollView.refreshControl = refresh
            return existing
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "rosterCache")
        controller.add(context.coordinator, name: "rosterCalendarFeed")
        config.userContentController = controller

        if let source = Self.extractorSource() {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true
        #endif

        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.refresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        model.webView = webView
        if !model.hasLoadedInitialURL {
            model.hasLoadedInitialURL = true
            webView.load(URLRequest(url: model.preferredStartURL, cachePolicy: .useProtocolCachePolicy))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        model.webView = webView
    }

    static func extractorSource() -> String? {
        guard let url = Bundle.main.url(forResource: "RosterEnhancements", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func requestExtraction(in webView: WKWebView) {
        webView.evaluateJavaScript("window.RAIDOPlus && window.RAIDOPlus.extractNow && window.RAIDOPlus.extractNow();")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private weak var model: RosterBrowserModel?

        init(model: RosterBrowserModel) {
            self.model = model
        }

        @objc func refresh(_ sender: UIRefreshControl) {
            guard let model else { return }
            model.loadError = nil
            model.webView?.reload()
            sender.endRefreshing()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let model else { return }
            let origin = message.frameInfo.securityOrigin
            guard PortalBridgePolicy.acceptsOrigin(scheme: origin.protocol, host: origin.host,
                port: origin.port, mainFrame: message.frameInfo.isMainFrame) else {
                Logger(subsystem: "com.bobanilic.raidoroster", category: "Portal").warning("Rejected script message from untrusted frame")
                return
            }
            switch message.name {
            case "rosterCache":
                Task { @MainActor in model.store.ingest(messageBody: message.body) }
            case "rosterCalendarFeed":
                Task { @MainActor in model.store.ingestCalendarFeed(messageBody: message.body) }
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard let model else { return }
            Task { @MainActor in model.loadError = nil }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let model else { return }
            Task { @MainActor in
                model.canGoBack = webView.canGoBack
                model.pageTitle = webView.title ?? "RAIDO"
                model.currentURL = webView.url
                model.loadError = nil

                if let url = webView.url,
                   url.host == RosterBrowserModel.startURL.host,
                   url.absoluteString != RosterBrowserModel.startURL.absoluteString {
                    UserDefaults.standard.set(url.absoluteString, forKey: "RAIDORoster.LastPortalURL")
                }

                RosterWebView.requestExtraction(in: webView)
                model.refreshRosterCalendarFeed()
                if let url = webView.url, RosterMonthCachePolicy.isRosterURL(url) {
                    model.rosterPageLoaded(url)
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            showOfflineError(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            showOfflineError(error)
        }

        private func showOfflineError(_ error: Error) {
            guard let model else { return }
            Task { @MainActor in
                model.loadError = model.store.hasCache
                    ? "The live RAIDO website needs a connection. Your native offline roster is still available."
                    : "The live RAIDO website needs an internet connection."
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
            let action = PortalBridgePolicy.navigation(url,
                userTapped: navigationAction.navigationType == .linkActivated,
                popup: navigationAction.targetFrame == nil)
            switch action {
            case .portal: decisionHandler(.allow)
            case .external:
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
            case .blocked:
                decisionHandler(.cancel)
                if navigationAction.targetFrame?.isMainFrame == true {
                    model?.loadError = "This destination is outside the approved RAIDO portal. Your saved roster is available."
                }
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Never replace the signed-in portal with popup content. User-tapped
            // supported links are handled by the navigation policy above.
            return nil
        }

    }
}
