"""V2.29.5: feathered map imagery and exclusive disclosure gestures."""
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / 'RAIDORoster/ContentView.swift'
PBX = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
s = CONTENT.read_text()
if '// V2.29.5 blended map disclosure' in s:
    print('V2.29.5 blended map already applied')
    raise SystemExit(0)
a = s.index('    private var iceMapHeader: some View {')
b = s.index('    private func toggleMap()', a)
header = s[a:b]
c = header.index('            if mapExpanded {')
details = header[c:header.index('\n        }\n        .background(TodayMapDisclosureObserver', c)]
s = s[:a] + (ROOT / 'v2229f_blended_header.swift.inc').read_text().replace('/* EXPANDED_DETAILS */', details) + '\n\n' + s[b:]
a = s.index('// V2.29.4 frosted map disclosure')
s = s[:a] + (ROOT / 'v2229f_map_disclosure.swift.inc').read_text()
s = s.replace('Use the handle below to collapse.', 'Swipe up to collapse. Tap the handle to toggle.')
assert s.count('value: "2.29.4"') == 1
s = s.replace('value: "2.29.4"', 'value: "2.29.5"')
pbx = re.sub(r'MARKETING_VERSION = [^;]+;', 'MARKETING_VERSION = 2.29.5;', PBX.read_text())
pbx = re.sub(r'CURRENT_PROJECT_VERSION = [^;]+;', 'CURRENT_PROJECT_VERSION = 2295;', pbx)
CONTENT.write_text(s)
PBX.write_text(pbx)
print('V2.29.5 feathered map and scroll-exclusive disclosure applied')
