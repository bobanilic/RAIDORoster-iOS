"""Monthly earnings, appended after the 2.19.9 build patches."""
from pathlib import Path
ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / 'RAIDORoster/ContentView.swift'
PBX = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
s = CONTENT.read_text()

def replace(old, new):
    global s
    if s.count(old) != 1: raise RuntimeError(f'Earnings anchor mismatch: {old[:90]}')
    s = s.replace(old, new)

replace('''struct RosterHomeView: View {
    @ObservedObject var store: RosterStore''', '''struct RosterHomeView: View {
    @StateObject private var earnings = EarningsStore()
    @ObservedObject var store: RosterStore''')
replace('RosterMonthCalendarView(store: store, browser: browser, changedDates: store.changedDates)',
        'RosterMonthCalendarView(store: store, browser: browser, earnings: earnings, changedDates: store.changedDates)')
replace('''                    } else {
                        if let duty = store.rosterViewDuty {''', '''                    } else {
                        rosterMonthNavigator
                        if let month = store.selectedRosterMonth {
                            MonthlyEarningsCard(roster: store, earnings: earnings, month: month)
                        }
                        if let duty = store.rosterViewDuty {''')
replace('''struct RosterMonthCalendarView: View {
    @ObservedObject var store: RosterStore
    @ObservedObject var browser: RosterBrowserModel''', '''struct RosterMonthCalendarView: View {
    @ObservedObject var store: RosterStore
    @ObservedObject var browser: RosterBrowserModel
    @ObservedObject var earnings: EarningsStore''')
replace('''            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(weekdays,''', '''            if let month = store.selectedRosterMonth {
                MonthlyEarningsCard(roster: store, earnings: earnings, month: month)
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(weekdays,''')
s = s.replace('"2.19.9"', '"2.20.0"').replace('RAIDORoster/2.19.9', 'RAIDORoster/2.20.0')
s += '''
// Monthly earnings 2.20.0
@MainActor
func earningsFlights(store: RosterStore, month: String, now: Date = Date()) -> [EarningsFlight] {
    // Selected snapshot wins. Adjacent archives recover sectors crossing a UTC month boundary.
    var rows = store.rosterViewItems
    for key in store.monthSnapshots.keys.sorted() where key != store.selectedRosterMonth {
        rows += store.monthSnapshots[key]?.items ?? []
    }
    var result: [EarningsFlight] = []
    var seen = Set<String>()
    for row in rows {
        for activity in row.activityList where activity.category.uppercased() == "FLIGHT" {
            let start = parseUTCStamp(activity.startUTC)
            let end = parseUTCStamp(activity.endUTC)
            let day = start.map(EarningsMath.day) ?? row.dateISO ?? ""
            guard day.hasPrefix(month + "-") else { continue }
            let id = [activity.code, activity.route, activity.startUTC.isEmpty ? day + "|" + activity.id : activity.startUTC].joined(separator: "|")
            guard seen.insert(id).inserted else { continue }
            let minutes: Int?
            if let start, let end, end >= start, end.timeIntervalSince(start) <= 86_400 {
                minutes = Int(end.timeIntervalSince(start) / 60)
            } else { minutes = nil }
            let fingerprint = [id, activity.endUTC, activity.aircraftReg].joined(separator: "|")
            result.append(EarningsFlight(id: id, day: day,
                title: [activity.code, activity.route].filter { !$0.isEmpty }.joined(separator: " · "),
                fingerprint: fingerprint, scheduledMinutes: minutes,
                ended: end.map { $0 <= now } ?? (day < EarningsMath.day(now))))
        }
    }
    return result.sorted { $0.day == $1.day ? $0.id < $1.id : $0.day < $1.day }
}
'''
CONTENT.write_text(s)
pbx = PBX.read_text()
def project_replace(old, new):
    global pbx
    if pbx.count(old) != 1: raise RuntimeError(f'PBX earnings anchor mismatch: {old}')
    pbx = pbx.replace(old, new)
for i, name in enumerate(['EarningsModels.swift', 'EarningsView.swift'], 1):
    a, b = f'A220{i:020d}', f'B220{i:020d}'
    project_replace('/* End PBXBuildFile section */', f'{a} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {b} /* {name} */; }};\n/* End PBXBuildFile section */')
    project_replace('/* End PBXFileReference section */', f'{b} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */')
    anchor = 'B00000000000000000000002 /* ContentView.swift */,'
    project_replace(anchor, anchor + f'\n {b} /* {name} */,')
    anchor = 'A00000000000000000000002 /* ContentView.swift in Sources */,'
    project_replace(anchor, anchor + f' {a} /* {name} in Sources */,')
pbx = pbx.replace('MARKETING_VERSION = 2.19.9;', 'MARKETING_VERSION = 2.20.0;')
PBX.write_text(pbx)
print('V2.20.0 Monthly block hours and earnings applied')
