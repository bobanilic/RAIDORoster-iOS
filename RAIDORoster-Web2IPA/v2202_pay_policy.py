"""Clarify home-base versus away daily-pay rules in the earnings UI."""
from pathlib import Path
ROOT = Path(__file__).resolve().parent
view = ROOT / 'RAIDORoster/EarningsView.swift'
s = view.read_text()
old = 'Flight, standby and positioning: one daily payment. OFF and other days away from home: one daily payment. OFF at home and RES: unpaid. Home airport: \\(record.homeAirport ?? "BEG"). Route-based location estimates can be corrected above. Swipe a date to restore automatic calculation.'
new = 'Away from home base: one EUR50 daily payment on eligible roster days. At home base: STB and positioning receive the daily payment; FLIGHT receives BLH only. OFF at home and RES anywhere are unpaid. Home airport: \\(record.homeAirport ?? "BEG"). Route-based location estimates can be corrected above. Swipe a date to restore automatic calculation.'
if old not in s:
    raise RuntimeError('Earnings footer anchor not found')
s = s.replace(old, new)
view.write_text(s)

content = ROOT / 'RAIDORoster/ContentView.swift'
c = content.read_text()
if '"2.20.1"' not in c:
    raise RuntimeError('Content version anchor not found')
c = c.replace('"2.20.1"', '"2.20.2"').replace('RAIDORoster/2.20.1', 'RAIDORoster/2.20.2')
content.write_text(c)

pbx = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
p = pbx.read_text()
if 'MARKETING_VERSION = 2.20.1;' not in p:
    raise RuntimeError('Project version anchor not found')
pbx.write_text(p.replace('MARKETING_VERSION = 2.20.1;', 'MARKETING_VERSION = 2.20.2;'))
print('V2.20.2 Home-base/away pay policy UI applied')
