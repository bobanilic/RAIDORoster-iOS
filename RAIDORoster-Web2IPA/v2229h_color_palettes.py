"""V2.29.7: independent coordinated palettes and clearer GetJet dividers."""
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parent
APP = ROOT / 'RAIDORoster'
CONTENT = APP / 'ContentView.swift'
PBX = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
s = CONTENT.read_text()
if '// V2.29.7 coordinated colour palettes.' in s:
    print('V2.29.7 colour palettes already applied')
    raise SystemExit(0)

def once(text, old, new):
    if text.count(old) != 1: raise RuntimeError(f'V2.29.7 anchor found {text.count(old)} times: {old[:90]}')
    return text.replace(old, new, 1)

a=s.index('    private static func palette(')
b=s.index('    @MainActor static func navigationAppearance()',a)
roles = '''    static var colorPalette: RaidoPalette {
        let defaults = UserDefaults.standard
        return RaidoAppearancePreferences.selectedPalette(theme: isGetJet ? .getJet : .ice,
            ice: defaults.string(forKey: RaidoAppearancePreferences.icePaletteKey) ?? "iceBlue",
            getJet: defaults.string(forKey: RaidoAppearancePreferences.getJetPaletteKey) ?? "forestGreen")
    }
    private static func tone(_ role: KeyPath<RaidoPaletteColors, UInt32>) -> UIColor {
        let palette = colorPalette
        return adaptive(palette.colors(dark: true)[keyPath: role], palette.colors(dark: false)[keyPath: role])
    }
    // V2.29.2 map polish: retain readable filled actions separately from links.
    static var actionFill: Color { Color(uiColor: tone(\\.actionFill)) }
    static var actionInk: Color { .white }
'''
for name in ['accent','border','ink','warning','warningInk','mapSea','mapLand','mapBorder','offInk','calendarDivider','mapLabelInk']:
    roles+=f'    static var {name}: Color {{ Color(uiColor: tone(\\.{name})) }}\n'
for name in ['background','surface','elevated']:
    roles+=f'    static var {name}UI: UIColor {{ tone(\\.{name}) }}\n    static var {name}: Color {{ Color(uiColor: {name}UI) }}\n'
roles+='''    static var highlight: Color { isGetJet ? Color(uiColor: tone(\\.highlight)) : actionFill }
    static var selectionInk: Color { isGetJet ? Color(uiColor: tone(\\.selectionInk)) : .white }
    static var standbyInk: Color { warningInk }

'''
s=s[:a]+roles+s[b:]
s=once(s,'    let appearance: RaidoAppearance\n','    let appearance: RaidoAppearance\n    let palette: RaidoPalette\n')
s=once(s,'context.stroke(path, with: .color(MidnightTheme.border), style: StrokeStyle(lineWidth: 0.65, lineCap: .round))',
    'context.stroke(path, with: .color(MidnightTheme.calendarDivider), style: StrokeStyle(lineWidth: 1.15, lineCap: .round))')
a=s.index('struct SettingsView:');b=s.index('struct DutyHeroCard:',a)
t=s[a:b]
t=once(t,'    private var appearanceSelection: Binding<String> {','''    @AppStorage("RAIDORoster.Palette.Ice") private var icePalette = "iceBlue"
    @AppStorage("RAIDORoster.Palette.GetJet") private var getJetPalette = "forestGreen"
    private var paletteSelection: Binding<String> {
        Binding(get: { selectedTheme == "getJet" ? getJetPalette : icePalette },
                set: { if selectedTheme == "getJet" { getJetPalette = $0 } else { icePalette = $0 } })
    }
    private var chosenPalette: RaidoPalette {
        RaidoAppearancePreferences.selectedPalette(theme: .init(rawValue: selectedTheme) ?? .ice,
            ice: icePalette, getJet: getJetPalette)
    }
    private var appearanceSelection: Binding<String> {''')
t=once(t,'                    Text("System follows your iPhone. Each theme remembers its own appearance.")','''                    NavigationLink {
                        RaidoPalettePicker(selection: paletteSelection, theme: .init(rawValue: selectedTheme) ?? .ice)
                    } label: {
                        HStack {
                            Text("Color palette")
                            Spacer()
                            Text(chosenPalette.title).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("settings-color-palette")
                    Text("Each theme remembers its own palette and appearance. System follows your iPhone.")''')
s=s[:a]+t+s[b:]
s+= '\n'+(ROOT/'v2229h_palette_views.swift.inc').read_text()

# Invalidate each existing view in place, preserving all model/task identities.
def observe_palette(text):
    starts=list(re.finditer(r'\bstruct\s+\w+\s*:\s*View(?:Modifier)?\s*\{',text))
    for i in range(len(starts)-1,-1,-1):
        match=starts[i];end=starts[i+1].start() if i+1<len(starts) else len(text)
        part=text[match.end():end]
        if '@Environment(\\.raidoPalette)' in part.split('var body:',1)[0]:continue
        body=re.search(r'(?:var body: some View|func body\(content: Content\) -> some View)\s*\{',part)
        if not body:continue
        part=part[:body.end()]+'\n        let _ = raidoColorPalette\n'+part[body.end():]
        part='\n    @Environment(\\.raidoPalette) private var raidoColorPalette'+part
        text=text[:match.end()]+part+text[end:]
    return text
s=observe_palette(s)
s=once(s,'value: "2.29.6"','value: "2.29.7"')
CONTENT.write_text(s)
for p in APP.glob('*.swift'):
    if p.name in ['ContentView.swift','RAIDORosterApp.swift']:continue
    t=p.read_text()
    if 'MidnightTheme.' in t:p.write_text(observe_palette(t))
p=APP/'RAIDORosterApp.swift';t=p.read_text()
t=once(t,'    private var theme: RaidoTheme {','''    @AppStorage("RAIDORoster.Palette.Ice") private var icePalette = "iceBlue"
    @AppStorage("RAIDORoster.Palette.GetJet") private var getJetPalette = "forestGreen"
    private var colorPalette: RaidoPalette {
        RaidoAppearancePreferences.selectedPalette(theme: theme, ice: icePalette, getJet: getJetPalette)
    }
    private var theme: RaidoTheme {''')
t=once(t,'.environment(\\.raidoTheme, theme)','.environment(\\.raidoTheme, theme)\n                .environment(\\.raidoPalette, colorPalette)')
t=once(t,'RaidoChromeRefresh(theme: theme, appearance: appearance)','RaidoChromeRefresh(theme: theme, appearance: appearance, palette: colorPalette)')
p.write_text(t)
pbx=re.sub(r'MARKETING_VERSION = [^;]+;','MARKETING_VERSION = 2.29.7;',PBX.read_text())
pbx=re.sub(r'CURRENT_PROJECT_VERSION = [^;]+;','CURRENT_PROJECT_VERSION = 2297;',pbx)
PBX.write_text(pbx)
print('V2.29.7 coordinated colour palettes and GetJet divider refinement applied')
