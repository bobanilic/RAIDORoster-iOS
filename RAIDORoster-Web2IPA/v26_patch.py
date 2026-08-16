from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "RAIDORoster"
CONTENT = SRC / "ContentView.swift"
WEB = SRC / "RosterWebView.swift"
JS = SRC / "RosterEnhancements.js"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"

# V2.6 deliberately keeps V2.5's native EventKit Calendar sync and the proven
# V2.4 RAIDO parser. The only functional cleanup is removing the unreliable
# live-page "jump to today" feature and all DOM scrolling code behind it.

content = CONTENT.read_text()
portal_button = '''                    Button { model.goToday() } label: { Image(systemName: "calendar.circle") }
                        .accessibilityLabel("Scroll RAIDO to today")
'''
content = content.replace(portal_button, "", 1)
content = content.replace('LabeledContent("RAIDO Roster", value: "2.5")', 'LabeledContent("RAIDO Roster", value: "2.6")', 1)
CONTENT.write_text(content)

web = WEB.read_text()
start_marker = "    func goToday() {"
end_marker = "    func openStartPage() {"
if start_marker in web and end_marker in web:
    start = web.index(start_marker)
    end = web.index(end_marker, start)
    web = web[:start] + web[end:]

auto_jump = '''                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    webView.evaluateJavaScript("window.RAIDOPlus && window.RAIDOPlus.goToday && window.RAIDOPlus.goToday();")
                }
'''
web = web.replace(auto_jump, "", 1)
WEB.write_text(web)

js = JS.read_text()
# Remove the stale call in the script's already-loaded guard as well.
js = js.replace("    window.RAIDOPlus.goToday();\n", "", 1)
start_marker = "  function todayToken() {"
end_marker = "  function redact(text) {"
if start_marker in js and end_marker in js:
    start = js.index(start_marker)
    end = js.index(end_marker, start)
    js = js[:start] + js[end:]
js = js.replace("      post(b);\n      goToday();", "      post(b);", 1)
js = js.replace("    goToday,\n", "", 1)
JS.write_text(js)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 5;", "CURRENT_PROJECT_VERSION = 6;")
pbx = pbx.replace("MARKETING_VERSION = 2.5;", "MARKETING_VERSION = 2.6;")
PBX.write_text(pbx)

print("V2.6 minimal SideStore patch applied")
