"""Automatic daily pay from roster duties and inferred home/away location."""
from pathlib import Path
ROOT = Path(__file__).resolve().parent
p = ROOT / 'RAIDORoster/ContentView.swift'
s = p.read_text()
if '// Daily payments 2.20.1' in s: raise RuntimeError('Patch already applied; use a clean checkout')
s = s.replace('"2.20.0"', '"2.20.1"').replace('RAIDORoster/2.20.0', 'RAIDORoster/2.20.1')
s += '''
// Daily payments 2.20.1
@MainActor
func earningsDailyLines(store: RosterStore, month: String, record: EarningsMonth) -> [EarningsDailyLine] {
    var rows = store.rosterViewItems
    // Only neighboring archives inform location at a month boundary.
    if let start = EarningsMath.date(month + "-01") {
        for offset in [-1, 1] {
            if let date = EarningsMath.utc.date(byAdding: .month, value: offset, to: start) {
                let key = String(EarningsMath.day(date).prefix(7))
                rows += store.monthSnapshots[key]?.items ?? []
            }
        }
    }
    var days: [String: EarningsRosterDay] = [:]
    var events: [EarningsLocationEvent] = []
    var seen = Set<String>()
    for row in rows {
        guard let rowDay = row.dateISO else { continue }
        if days[rowDay] == nil { days[rowDay] = EarningsRosterDay(day: rowDay, categories: []) }
        let activities = row.activityList.filter { !["HOTEL", "EXPENSE", "RELOCATION"].contains($0.category.uppercased()) }
        if activities.isEmpty { days[rowDay]?.categories.insert(row.category.uppercased()) }
        for activity in activities {
            let start = parseUTCStamp(activity.startUTC)
            let end = parseUTCStamp(activity.endUTC)
            let day = start.map(EarningsMath.day) ?? rowDay
            let category = activity.category.uppercased()
            if days[day] == nil { days[day] = EarningsRosterDay(day: day, categories: []) }
            days[day]?.categories.insert(category)
            if let station = EarningsDailyPolicy.airport(activity.station) { days[day]?.stations.insert(station) }
            if category == "FLIGHT" || category == "POSITIONING" {
                let (origin, destination) = EarningsDailyPolicy.route(activity.route)
                let departureOrder = activity.startUTC.isEmpty ? day + " 12:00" : activity.startUTC
                let arrivalDay = end.map(EarningsMath.day) ?? day
                let arrivalOrder = activity.endUTC.isEmpty ? day + " 23:59" : activity.endUTC
                let key = [activity.code, activity.route, departureOrder].joined(separator: "|")
                if seen.insert(key).inserted {
                    events.append(EarningsLocationEvent(day: day, order: departureOrder, origin: origin, destination: nil))
                    events.append(EarningsLocationEvent(day: arrivalDay, order: arrivalOrder, origin: nil, destination: destination))
                }
                if let start, let end, end >= start, end.timeIntervalSince(start) <= 86_400, arrivalDay != day {
                    if days[arrivalDay] == nil { days[arrivalDay] = EarningsRosterDay(day: arrivalDay, categories: []) }
                    days[arrivalDay]?.categories.insert(category)
                }
            }
        }
    }
    return EarningsDailyPolicy.lines(month: month, days: Array(days.values), events: events, record: record)
}
'''
p.write_text(s)
pbx = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
pbx.write_text(pbx.read_text().replace('MARKETING_VERSION = 2.20.0;', 'MARKETING_VERSION = 2.20.1;'))
print('V2.20.1 Automatic daily payments applied; RES unpaid')
