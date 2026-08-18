from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
WEBVIEW = ROOT / "RAIDORoster" / "RosterWebView.swift"
JS = ROOT / "RAIDORoster" / "RosterEnhancements.js"


def replace_between(text: str, start_marker: str, end_marker: str, replacement: str, label: str) -> str:
    start = text.find(start_marker)
    end = text.find(end_marker, start + len(start_marker))
    if start < 0 or end < 0:
        raise RuntimeError(f"V2.11.4 cleanup range not found: {label}")
    return text[:start] + replacement + text[end:]


# -----------------------------------------------------------------------------
# Remove the retired crew-history model/store implementation entirely. Keep one
# small one-time deletion of the old archive so upgrading users do not retain it.
# -----------------------------------------------------------------------------
content = CONTENT.read_text()

if "struct CrewHistoryOccurrence:" in content:
    content = replace_between(
        content,
        "struct CrewHistoryOccurrence:",
        "struct SummaryMetric:",
        "",
        "crew history models",
    )

content = content.replace(
    '    @Published private(set) var crewHistoryMonths: [String: CrewHistoryMonth] = [:]\n',
    '',
    1,
)

old_init = '''    init() {
        load()
        loadChangeState()
        // V2.11.3 retires historical crew counting and removes any previously
        // generated archive from this device.
        crewHistoryMonths = []
        try? FileManager.default.removeItem(at: crewHistoryURL)
    }
'''
new_init = '''    init() {
        load()
        loadChangeState()
        try? FileManager.default.removeItem(at: storageFolderURL.appendingPathComponent("crew-history.json"))
    }
'''
if old_init in content:
    content = content.replace(old_init, new_init, 1)

if "    func crewHistory(for member: CrewMember)" in content:
    content = replace_between(
        content,
        "    func crewHistory(for member: CrewMember)",
        "    func clearCache()",
        "",
        "crew history lookup",
    )

content = content.replace('        crewHistoryMonths = []\n', '', 1)
content = content.replace(
    '        try? FileManager.default.removeItem(at: crewHistoryURL)\n',
    '        try? FileManager.default.removeItem(at: storageFolderURL.appendingPathComponent("crew-history.json"))\n',
    1,
)

if "    private func crewHistoryKey(" in content:
    content = replace_between(
        content,
        "    private func crewHistoryKey(",
        "    private func currentMonthKey()",
        "",
        "crew history indexing helpers",
    )

content = content.replace(
    '    private var crewHistoryURL: URL { storageFolderURL.appendingPathComponent("crew-history.json") }\n',
    '',
    1,
)

if "    private func saveCrewHistory()" in content:
    content = replace_between(
        content,
        "    private func saveCrewHistory()",
        "    private var cacheURL:",
        "",
        "crew history persistence helpers",
    )

CONTENT.write_text(content)


# -----------------------------------------------------------------------------
# Remove native backfill state/actions/bridge that V2.11.3 made unreachable.
# Current roster extraction and sanitized diagnostics remain untouched.
# -----------------------------------------------------------------------------
web = WEBVIEW.read_text()
web = web.replace('    @Published var historyBackfillStatus: String?\n', '', 1)
web = web.replace('    @Published var historyBackfillRunning = false\n', '', 1)

if "    func backfillCrewHistory()" in web:
    web = replace_between(
        web,
        "    func backfillCrewHistory()",
        "    func copyDiagnostics()",
        "",
        "native backfill methods",
    )

web = web.replace('        controller.add(context.coordinator, name: "historyBackfill")\n', '', 1)

if '            if message.name == "historyBackfill" {' in web:
    handler = '''        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "rosterCache" else { return }
            Task { @MainActor in
                self.model.store.ingest(messageBody: message.body)
            }
        }

'''
    web = replace_between(
        web,
        "        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {",
        "        func webView(_ webView: WKWebView, didStartProvisionalNavigation",
        handler,
        "history message bridge",
    )

WEBVIEW.write_text(web)


# -----------------------------------------------------------------------------
# Remove the unused JavaScript month-traversal implementation as well. The
# month-navigation diagnostic remains useful for troubleshooting and is tiny.
# -----------------------------------------------------------------------------
js = JS.read_text()
if "  let historyBackfillRunning = false;" in js:
    js = replace_between(
        js,
        "  let historyBackfillRunning = false;",
        "  window.RAIDOPlus = {",
        "",
        "retired JS history traversal",
    )
JS.write_text(js)

print("V2.11.4 retired crew-history code fully stripped")
