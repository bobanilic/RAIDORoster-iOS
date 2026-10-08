"""V2.29.8: minute-aligned clocks and pickup before flight check-in."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / 'RAIDORoster/ContentView.swift'
PBX = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
s = CONTENT.read_text()
if '// V2.29.8 flight-associated transport.' in s:
    print('V2.29.8 roster timing already applied')
    raise SystemExit(0)

def once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f'V2.29.8 anchor found {text.count(old)} times: {old[:90]}')
    return text.replace(old, new, 1)

s = once(s, '    var preDutyPickupUTCDate: Date? {', '''    // V2.29.8 flight-associated transport.
    // DLRP may begin before the hotel pickup. Preserve the duty envelope, but
    // match pre-flight transport against the first sector's own check-in.
    private var pickupReportUTCDate: Date? {
        if let sector = operationalActivities.first(where: {
            ["FLIGHT", "POSITIONING"].contains($0.category.uppercased())
        }) {
            return parseUTCStamp(sector.checkInUTC) ?? parseUTCStamp(sector.startUTC) ?? dutyStartUTCDate
        }
        return dutyStartUTCDate
    }

    var preDutyPickupUTCDate: Date? {''')
s = once(s, '''        if let dutyStart = dutyStartUTCDate {
            return all.filter { $0.0 <= dutyStart }.sorted { $0.0 < $1.0 }.last?.0
''', '''        if let report = pickupReportUTCDate {
            return all.filter { $0.0 <= report }.sorted { $0.0 < $1.0 }.last?.0
''')
for start, end in [('private struct IceDestinationClock: View {', 'private struct IcePickupCard: View {'),
                   ('private struct IcePickupCard: View {', 'private struct IceReadinessView: View {')]:
    a = s.index(start)
    b = s.index(end, a + len(start))
    section = once(s[a:b], 'TimelineView(.periodic(from: .now, by: 60))', 'TimelineView(.everyMinute)')
    s = s[:a] + section + s[b:]
s = once(s, 'value: "2.29.7"', 'value: "2.29.8"')

# A PU instruction can be stored under any of RAIDO's labelled note fields.
js = ROOT / 'RAIDORoster/RosterEnhancements.js'
t = once(js.read_text(), '    const pickup = pickupFrom(transferNote);',
         '    const pickup = pickupFrom(transferNote) || pickupFrom(activityNote) || pickupFrom(dayNote);')
CONTENT.write_text(s)
js.write_text(t)
pbx = re.sub(r'MARKETING_VERSION = [^;]+;', 'MARKETING_VERSION = 2.29.8;', PBX.read_text())
pbx = re.sub(r'CURRENT_PROJECT_VERSION = [^;]+;', 'CURRENT_PROJECT_VERSION = 2298;', pbx)
PBX.write_text(pbx)
print('V2.29.8 minute-aligned clocks and flight-associated pickup applied')
