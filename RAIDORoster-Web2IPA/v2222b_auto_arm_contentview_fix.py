from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster/ContentView.swift"
s = CONTENT.read_text()


def block_end(text: str, start: int) -> int:
    brace = text.find('{', start)
    if brace < 0:
        return -1
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return i + 1
    return -1


vs = s.find('struct ContentView: View {')
ve = s.find('\nstruct RosterHomeView: View {', vs)
if vs < 0 or ve < 0:
    raise RuntimeError('auto-arm fix: ContentView bounds missing')

v = s[vs:ve]
mods = '''        .onAppear { TodayLiveFlightLocationManager.shared.configureAutomaticFlight(from: appState.rosterStore.items) }\n        .onChange(of: appState.rosterStore.snapshot) { _, _ in\n            TodayLiveFlightLocationManager.shared.configureAutomaticFlight(from: appState.rosterStore.items)\n        }'''

v = v.replace('\n' + mods, '')
body_start = v.find('    var body: some View {')
body_end = block_end(v, body_start) if body_start >= 0 else -1
if body_start < 0 or body_end < 0:
    raise RuntimeError('auto-arm fix: ContentView body bounds missing')
body = v[body_start:body_end]
if 'TodayLiveFlightLocationManager.shared.configureAutomaticFlight' not in body:
    close = body.rfind('\n    }')
    if close < 0:
        raise RuntimeError('auto-arm fix: ContentView body close missing')
    body = body[:close] + '\n' + mods + body[close:]
    v = v[:body_start] + body + v[body_end:]
body_start = v.find('    var body: some View {')
body_end = block_end(v, body_start)
body = v[body_start:body_end]
if mods not in body:
    raise RuntimeError('auto-arm fix: modifiers are not attached to ContentView body')
if v.count('TodayLiveFlightLocationManager.shared.configureAutomaticFlight') != 2:
    raise RuntimeError('auto-arm fix: unexpected automatic-flight configuration copies')
s = s[:vs] + v + s[ve:]

ms = s.find('private final class TodayLiveFlightLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {')
me = s.find('\nstruct TodayRouteMapCard: View {', ms)
if ms < 0 or me < 0:
    raise RuntimeError('companion state: manager bounds missing')
m = s[ms:me]
anchor = '    func start() {\n'
if anchor not in m:
    raise RuntimeError('companion state: start anchor missing')
if 'func companionStateText' not in m:
    helper = '''    func companionStateText() -> String {\n        [\n            "version=2.23.0-companion-state",\n            "phase=\\(flightPhaseText)",\n            "tracking=\\(isTracking)",\n            "source=\\(positionSourceText)",\n            "estimated=\\(positionIsEstimated)"\n        ].joined(separator: "\\n")\n    }\n\n'''
    m = m.replace(anchor, helper + anchor, 1)
s = s[:ms] + m + s[me:]

ss = s.find('struct SettingsView: View {')
se = s.find('\nstruct DutyHeroCard: View {', ss)
if ss < 0 or se < 0:
    raise RuntimeError('companion state: SettingsView bounds missing')
settings = s[ss:se]
section = '                Section("Diagnostics") {\n'
if section not in settings:
    raise RuntimeError('companion state: Diagnostics section missing')
if 'Flight Companion state' not in settings:
    settings = settings.replace(section, section + '''                    DisclosureGroup("Flight Companion state") {\n                        Text(TodayLiveFlightLocationManager.shared.companionStateText())\n                            .font(.caption.monospaced())\n                            .textSelection(.enabled)\n                    }\n''', 1)
s = s[:ss] + settings + s[se:]

CONTENT.write_text(s)
print('Flight Companion ContentView fix + state panel applied')
