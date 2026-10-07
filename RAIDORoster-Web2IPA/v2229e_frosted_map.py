"""V2.29.4: frosted map edges and deliberate swipes across Today."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / 'RAIDORoster/ContentView.swift'
PBX = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
MARKER = '// V2.29.4 frosted map disclosure'
s = CONTENT.read_text()
if MARKER in s:
    print('V2.29.4 frosted map already applied')
    raise SystemExit(0)

def once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f'V2.29.4 anchor found {text.count(old)} times: {old[:90]}')
    return text.replace(old, new, 1)

a = s.index('    private var iceMapHeader: some View {')
b = s.index('    private func toggleMap()', a)
header = s[a:b]
# Keep the original total footprint: 280 + 44 compact, 430 + 44 expanded.
c = header.index('            if mapExpanded {')
details = header[c:header.index('\n        }\n        .contentShape(Rectangle())', c)]
s = s[:a] + (ROOT / 'v2229e_frosted_header.swift.inc').read_text().replace('/* EXPANDED_DETAILS */', details) + '\n\n' + s[b:]
s = once(s, 'withAnimation(.easeInOut(duration: 0.28)) { mapExpanded.toggle() }',
    '''if mapExpanded { committedPan = .zero; committedZoom = 1; onlineCameraPosition = .automatic }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { mapExpanded.toggle() }''')
# The obsolete handle-only recognizer is superseded by the page observer.
a = s.index('private struct MapDisclosureGestureSurface: UIViewRepresentable {')
b = s.index('private struct OfflineMapInteractionSurface: UIViewRepresentable {', a)
s = s[:a] + s[b:]
s += '\n' + (ROOT / 'v2229e_map_disclosure.swift.inc').read_text()
s = once(s, 'value: "2.29.3"', 'value: "2.29.4"')
pbx = re.sub(r'MARKETING_VERSION = [^;]+;', 'MARKETING_VERSION = 2.29.4;', PBX.read_text())
pbx = re.sub(r'CURRENT_PROJECT_VERSION = [^;]+;', 'CURRENT_PROJECT_VERSION = 2294;', pbx)
CONTENT.write_text(s)
PBX.write_text(pbx)
print('V2.29.4 frosted map and broad swipe disclosure applied')
