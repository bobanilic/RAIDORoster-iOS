"""V2.29.2: soft map edges, gesture ownership, quiet offline labels and action contrast."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
APP = ROOT / 'RAIDORoster'
CONTENT = APP / 'ContentView.swift'
PBX = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
MARKER = '// V2.29.2 map polish'
s = CONTENT.read_text()
if MARKER in s:
    if 'OfflinePlaceLabels.json in Resources' not in PBX.read_text(): raise RuntimeError('Incomplete map polish')
    print('V2.29.2 map polish already applied')
    raise SystemExit(0)

def once(text, old, new):
    if text.count(old) != 1: raise RuntimeError(f'V2.29.2 anchor found {text.count(old)} times: {old[:90]}')
    return text.replace(old, new, 1)

s = once(s, '    static var accent: Color {', '''    // V2.29.2 map polish
    static var actionFill: Color {
        let theme: RaidoTheme = isGetJet ? .getJet : .ice
        return Color(uiColor: adaptive(RaidoActionPalette.fill(theme: theme, dark: true), RaidoActionPalette.fill(theme: theme, dark: false)))
    }
    static var actionInk: Color { Color(uiColor: adaptive(RaidoActionPalette.ink, RaidoActionPalette.ink)) }
    static var mapLabelInk: Color { Color(uiColor: palette(0xAAC3CC, 0x45626C, 0xAEBEB2, 0x4B675C)) }
    static var accent: Color {''')
s = once(s, 'static var highlight: Color { isGetJet ? Color(uiColor: adaptive(0xF39354, 0xCA5B22)) : accent }',
    'static var highlight: Color { isGetJet ? Color(uiColor: adaptive(0xF39354, 0xCA5B22)) : actionFill }')
s = once(s, 'isGetJet ? surfaceUI : UIColor(accent)', 'isGetJet ? surfaceUI : UIColor(actionFill)')
s = once(s, 'theme == .getJet ? MidnightTheme.surfaceUI : UIColor(MidnightTheme.accent)', 'theme == .getJet ? MidnightTheme.surfaceUI : UIColor(MidnightTheme.actionFill)')
s = once(s, '    @State private var mapExpanded = false', '    @AppStorage("RAIDORoster.Map.PlaceLabels") private var showsPlaceLabels = true\n    @State private var mapExpanded = false')
a = s.index('    private var iceMapHeader: some View {')
b = s.index('\n    private func toggleMap()', a)
header = s[a:b]
header = once(header, '                    .frame(height: 155).allowsHitTesting(false)', '''                    .frame(height: 155).allowsHitTesting(false)
                LinearGradient(colors: [.clear, MidnightTheme.background.opacity(0.8), MidnightTheme.background],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 68).frame(maxHeight: .infinity, alignment: .bottom).allowsHitTesting(false)''')
header = once(header, '''            }.frame(height: mapExpanded ? 430 : 280).clipped()''', '''            }.frame(height: mapExpanded ? 430 : 280).clipped()
                .contentShape(Rectangle())
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("today-map-surface")
                .highPriorityGesture(mapExpansionDrag(onHandle: false), including: mapExpanded ? .none : .all)''')
header = once(header, 'Text(mapExpanded ? "Swipe up to collapse" : "Pull down for map")', 'Text(mapExpanded ? "Tap or swipe up to collapse" : "Tap or pull down for map")')
header = once(header, '            }.buttonStyle(.plain)\n', '            }.buttonStyle(.plain)\n                .highPriorityGesture(mapExpansionDrag(onHandle: true))\n                .accessibilityIdentifier("today-map-handle")\n')
header = once(header, '                        Button("Offline local map") { todayMapSource = "offline" }', '                        Button("Offline local map") { todayMapSource = "offline" }\n                        Toggle("Geographic labels", isOn: $showsPlaceLabels)')
gesture = header.index('        .simultaneousGesture(DragGesture(')
header = header[:gesture] + '''    }

    private func mapExpansionDrag(onHandle: Bool) -> some Gesture {
        DragGesture(minimumDistance: 12).onEnded { value in
            if let destination = MapExpansionGesture.destination(expanded: mapExpanded,
                horizontal: value.translation.width, vertical: value.translation.height, onHandle: onHandle) {
                withAnimation(.easeInOut(duration: 0.28)) { mapExpanded = destination }
            }
        }
    }
'''
s = s[:a] + header + s[b:]

a = s.index('private struct OfflineAviationMapCanvas: View {')
b = s.index('\nprivate struct CrewCompanionPhase', a)
canvas = s[a:b]
canvas = once(canvas, '    let points: [TodayAirportMapPoint]', '    @AppStorage("RAIDORoster.Map.PlaceLabels") private var showsPlaceLabels = true\n    let points: [TodayAirportMapPoint]')
canvas = once(canvas, '            if coordinates.count >= 2 {', '''            if showsPlaceLabels {
                OfflineMapPlaces.draw(in: &context, size: size, viewport: viewport, zoom: zoom, pan: pan,
                    airports: coordinates, aircraft: isTracking ? liveLocation?.coordinate : nil)
            }

            if coordinates.count >= 2 {''')
s = s[:a] + canvas + s[b:]
# Apply readable fills to every native prominent action, across all screens.
s = s.replace('.buttonStyle(.borderedProminent)', '.raidoPrimaryAction()')
s += '\n' + (ROOT / 'v2229c_map_labels.swift.inc').read_text()
s = once(s, 'value: "2.29.1"', 'value: "2.29.2"')
other_sources = {}
for source in APP.glob('*.swift'):
    if source.name != 'ContentView.swift':
        old = source.read_text()
        new = old.replace('.buttonStyle(.borderedProminent)', '.raidoPrimaryAction()')
        if old != new: other_sources[source] = new

pbx = PBX.read_text()
for index, name in enumerate(['MapPresentationPolicy.swift', 'OfflinePlaceLabels.json'], 1):
    if not (APP / name).exists(): raise RuntimeError(name + ' missing')
    build, file = f'A2292{index:019d}', f'B2292{index:019d}'
    phase, kind = ('Sources', 'sourcecode.swift') if name.endswith('.swift') else ('Resources', 'text.json')
    pbx = once(pbx, '/* End PBXBuildFile section */', f'{build} /* {name} in {phase} */ = {{isa = PBXBuildFile; fileRef = {file} /* {name} */; }};\n/* End PBXBuildFile section */')
    pbx = once(pbx, '/* End PBXFileReference section */', f'{file} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = {name}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */')
    pbx = once(pbx, 'B00000000000000000000002 /* ContentView.swift */,', f'B00000000000000000000002 /* ContentView.swift */,\n{file} /* {name} */,')
    anchor = 'A00000000000000000000002 /* ContentView.swift in Sources */,' if phase == 'Sources' else 'A00000000000000000000004 /* RosterEnhancements.js in Resources */,'
    pbx = once(pbx, anchor, anchor + f' {build} /* {name} in {phase} */,')
pbx = re.sub(r'MARKETING_VERSION = [^;]+;', 'MARKETING_VERSION = 2.29.2;', pbx)
pbx = re.sub(r'CURRENT_PROJECT_VERSION = [^;]+;', 'CURRENT_PROJECT_VERSION = 2292;', pbx)
CONTENT.write_text(s); PBX.write_text(pbx)
for source, text in other_sources.items(): source.write_text(text)
print('V2.29.2 map labels, fades, gestures and action contrast applied')
