import SwiftUI
import WebKit
import UIKit

@MainActor
final class RosterBrowserModel: ObservableObject {
    static let startURL = URL(string: "https://gjt.noc.vmc.navblue.cloud/")!

    @Published var canGoBack = false
    @Published var pageTitle = ""
    @Published var currentURL: URL?
    @Published var loadError: String?
    @Published var diagnosticStatus: String?

    fileprivate weak var webView: WKWebView?
    fileprivate let store: RosterStore
    fileprivate var hasLoadedInitialURL = false

    init(store: RosterStore) {
        self.store = store
    }

    var preferredStartURL: URL {
        if let saved = UserDefaults.standard.string(forKey: "RAIDORoster.LastPortalURL"),
           let url = URL(string: saved),
           url.host == Self.startURL.host {
            return url
        }
        return Self.startURL
    }

    func reload() {
        loadError = nil
        webView?.reload()
    }

    func goBack() {
        webView?.goBack()
    }

    func goToday() {
        loadError = nil
        webView?.evaluateJavaScript("window.RAIDOPlus && window.RAIDOPlus.goToday && window.RAIDOPlus.goToday();")
    }

    func openStartPage() {
        loadError = nil
        webView?.load(URLRequest(url: Self.startURL, cachePolicy: .useProtocolCachePolicy))
    }

    func copyDiagnostics() {
        guard let webView else {
            diagnosticStatus = "Open the RAIDO tab first, then try again."
            return
        }

        webView.evaluateJavaScript("window.RAIDOPlus && window.RAIDOPlus.diagnostics ? window.RAIDOPlus.diagnostics() : null;") { result, error in
            DispatchQueue.main.async {
                if let text = result as? String, !text.isEmpty {
                    UIPasteboard.general.string = text
                    self.diagnosticStatus = "Diagnostics copied. Paste them into ChatGPT."
                } else if let error {
                    self.diagnosticStatus = "Could not collect diagnostics: \(error.localizedDescription)"
                } else {
                    self.diagnosticStatus = "Diagnostics are not available on this RAIDO page yet."
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
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "rosterCache")
        config.userContentController = controller

        if let source = Self.extractorSource() {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true

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
        private let model: RosterBrowserModel

        init(model: RosterBrowserModel) {
            self.model = model
        }

        @objc func refresh(_ sender: UIRefreshControl) {
            model.loadError = nil
            model.webView?.reload()
            sender.endRefreshing()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "rosterCache" else { return }
            Task { @MainActor in
                self.model.store.ingest(messageBody: message.body)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in self.model.loadError = nil }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                self.model.canGoBack = webView.canGoBack
                self.model.pageTitle = webView.title ?? "RAIDO"
                self.model.currentURL = webView.url
                self.model.loadError = nil

                if let url = webView.url,
                   url.host == RosterBrowserModel.startURL.host,
                   url.absoluteString != RosterBrowserModel.startURL.absoluteString {
                    UserDefaults.standard.set(url.absoluteString, forKey: "RAIDORoster.LastPortalURL")
                }

                RosterWebView.requestExtraction(in: webView)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    webView.evaluateJavaScript("window.RAIDOPlus && window.RAIDOPlus.goToday && window.RAIDOPlus.goToday();")
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
            Task { @MainActor in
                self.model.loadError = self.model.store.hasCache
                    ? "The live RAIDO website needs a connection. Your native offline roster is still available."
                    : "The live RAIDO website needs an internet connection."
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               !["http", "https", "about"].contains(scheme) {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}
