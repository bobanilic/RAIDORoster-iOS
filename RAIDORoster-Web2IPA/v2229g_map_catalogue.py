"""V2.29.6: revised offline map catalogue."""
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / 'RAIDORoster/ContentView.swift'
PBX = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
s = CONTENT.read_text()
if 'value: "2.29.6"' in s:
    print('V2.29.6 map catalogue release already applied')
    raise SystemExit(0)
assert s.count('value: "2.29.5"') == 1, 'V2.29.6 version anchor missing'
s = s.replace('value: "2.29.5"', 'value: "2.29.6"')
pbx = re.sub(r'MARKETING_VERSION = [^;]+;', 'MARKETING_VERSION = 2.29.6;', PBX.read_text())
pbx = re.sub(r'CURRENT_PROJECT_VERSION = [^;]+;', 'CURRENT_PROJECT_VERSION = 2296;', pbx)
CONTENT.write_text(s)
PBX.write_text(pbx)
print('V2.29.6 map catalogue release applied')
