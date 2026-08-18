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
)

# V2.11.3 may generate either [] or [:] depending on the intermediate source.
# Remove every stale assignment/reference rather than relying on one exact init.
content = content.replace('        crewHistoryMonths = []\n', '')
content = content.replace('        crewHistoryMonths = [:]\n', '')
content = content.replace('        try? FileManager.default.removeItem(at: crewHistoryURL)\n', '')

if "    func crewHistory(for member: CrewMember)" in content:
    content = replace_between(
        content,
        "    func crewHistory(for member: CrewMember)",
        "    func clearCache()",
        "",
        "crew history lookup",
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
)

if "    private func saveCrewHistory()" in content:
    content = replace_between(
        content,
        "    private func saveCrewHistory()",
        "    private var cacheURL:",
        "",
        "crew history persistence helpers",
    )

archive_delete = '        try? FileManager.default.removeItem(at: storageFolderURL.appendingPathComponent("crew-history.json"))\n'
if archive_delete not in content:
    marker = '        loadChangeState()\n'
    if marker not in content:
        raise RuntimeError("V2.11.4 cleanup marker not found: loadChangeState for archive cleanup")
    content = content.replace(marker, marker + archive_delete, 1)

CONTENT.write_text(content)


# -----------------------------------------------------------------------------
# Remove native backfill state/actions/bridge that V2.11.3 made unreachable.
# Current roster extraction and sanitized diagnostics remain untouched.
# -----------------------------------------------------------------------------
web = WEBVIEW.read_text()
web = web.replace('    @Published var historyBackfillStatus: String?\n', '')
web = web.replace('    @Published var historyBackfillRunning = false\n', '')

if "    func backfillCrewHistory()" in web:
    web = replace_between(
        web,
        "    func backfillCrewHistory()",
        "    func copyDiagnostics()",
        "",
        "native backfill methods",
    )

web = web.replace('        controller.add(context.coordinator, name: "historyBackfill")\n', '')

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
