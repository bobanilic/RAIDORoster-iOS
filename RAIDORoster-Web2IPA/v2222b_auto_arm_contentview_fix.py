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

# v2222 originally used the last closing brace in ContentView. Later patches add
# helper/computed properties after body, so that can attach SwiftUI modifiers to
# a String or another computed property instead of the body expression. Remove
# the misplaced copy first, then attach it specifically to body.
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

# Fail closed if the automatic configuration escaped body again.
body_start = v.find('    var body: some View {')
body_end = block_end(v, body_start)
body = v[body_start:body_end]
if mods not in body:
    raise RuntimeError('auto-arm fix: modifiers are not attached to ContentView body')
if v.count('TodayLiveFlightLocationManager.shared.configureAutomaticFlight') != 2:
    raise RuntimeError('auto-arm fix: unexpected automatic-flight configuration copies')

s = s[:vs] + v + s[ve:]
CONTENT.write_text(s)
print('Flight Companion ContentView auto-arm placement fixed')
