"""V2.29.3: quiet preflight map and exclusive offline pan/pinch ownership."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / 'RAIDORoster/ContentView.swift'
PBX = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
MARKER = '// V2.29.3 offline map interaction'
s = CONTENT.read_text()
if MARKER in s:
    print('V2.29.3 map interaction already applied')
    raise SystemExit(0)

def once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f'V2.29.3 anchor found {text.count(old)} times: {old[:90]}')
    return text.replace(old, new, 1)

a = s.index('    private var iceMapHeader: some View {')
b = s.index('\n    private func mapExpansionDrag', a)
header = s[a:b]
header = once(header, '.padding(.bottom, 42)', '.padding(.bottom, gps.isTracking ? 42 : 8)')
header = once(header, '                    TimelineView(.periodic(from: .now, by: 5)) { context in',
    '                    if gps.isTracking {\n                    TimelineView(.periodic(from: .now, by: 5)) { context in')
header = once(header, '                            .accessibilityHint(status.detail)\n                    }',
    '                            .accessibilityHint(status.detail)\n                            .accessibilityIdentifier("today-map-tracking-status")\n                    }\n                    }')
header = once(header, '.highPriorityGesture(mapExpansionDrag(onHandle: false), including: mapExpanded ? .none : .all)',
    '''.overlay {
                    if !mapExpanded {
                        MapDisclosureGestureSurface(expanded: mapExpanded, onHandle: false, onToggle: toggleMap)
                    }
                }''')
header = once(header, '''            Button { toggleMap() } label: {
                VStack(spacing: 5) {
                    Capsule().fill(MidnightTheme.accent.opacity(0.45)).frame(width: 30, height: 3)
                    Text(mapExpanded ? "Tap or swipe up to collapse" : "Tap or pull down for map").font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.plain)
                .highPriorityGesture(mapExpansionDrag(onHandle: true))
                .accessibilityIdentifier("today-map-handle")
                .accessibilityLabel(mapExpanded ? "Collapse flight map" : "Expand flight map")
                .accessibilityValue(mapExpanded ? "Expanded" : "Collapsed")''',
    '''            VStack(spacing: 5) {
                Capsule().fill(MidnightTheme.accent.opacity(0.45)).frame(width: 30, height: 3)
                Text(mapExpanded ? "Tap or swipe up to collapse" : "Tap or pull down for map").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
            }.frame(maxWidth: .infinity, minHeight: 44)
                .overlay {
                    MapDisclosureGestureSurface(expanded: mapExpanded, onHandle: true, onToggle: toggleMap)
                }''')
s = s[:a] + header + s[b:]
a = s.index('    private func mapExpansionDrag(onHandle: Bool)')
b = s.index('    private func toggleMap()', a)
s = s[:a] + s[b:]

a = s.index('    private var mapSurface: some View {')
b = s.index('                if !iceHeader {', a)
surface = s[a:b]
start = surface.index('                        .simultaneousGesture(')
end = surface.index('\n                    }', start)
surface = surface[:start] + '''                        .overlay {
                            OfflineMapInteractionSurface(zoom: $committedZoom, pan: $committedPan,
                                interactive: !iceHeader || mapExpanded)
                        }''' + surface[end:]
surface = once(surface, 'zoom: effectiveZoom', 'zoom: committedZoom')
surface = once(surface, 'pan: effectivePan', 'pan: committedPan')
s = s[:a] + surface + s[b:]
s = once(s, '    @GestureState private var gestureZoom: CGFloat = 1\n', '')
s = once(s, '    @GestureState private var gesturePan: CGSize = .zero\n', '')
a = s.index('    private var effectiveZoom: CGFloat {')
b = s.index('    private var gpsQuality:', a)
s = s[:a] + s[b:]
s += '\n' + (ROOT / 'v2229d_map_interaction.swift.inc').read_text()
s = once(s, 'value: "2.29.2"', 'value: "2.29.3"')
pbx = re.sub(r'MARKETING_VERSION = [^;]+;', 'MARKETING_VERSION = 2.29.3;', PBX.read_text())
pbx = re.sub(r'CURRENT_PROJECT_VERSION = [^;]+;', 'CURRENT_PROJECT_VERSION = 2293;', pbx)
CONTENT.write_text(s)
PBX.write_text(pbx)
print('V2.29.3 quiet preflight map and exclusive offline gestures applied')
