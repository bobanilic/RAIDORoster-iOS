"""Exercise the exact generated pickup properties and native clock schedule."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
content = (root / 'RAIDORoster-Web2IPA/RAIDORoster/ContentView.swift').read_text()
js = (root / 'RAIDORoster-Web2IPA/RAIDORoster/RosterEnhancements.js').read_text()

def block(anchor):
    a = content.index(anchor)
    opening = content.index('{', a)
    depth = 1
    b = opening + 1
    while depth:
        depth += (content[b] == '{') - (content[b] == '}')
        b += 1
    return content[a:b]

properties = '\n'.join(block(anchor) for anchor in [
    '    var operationalActivities: [RosterActivity]',
    '    var dutyStartUTCDate: Date?',
    '    private var pickupReportUTCDate: Date?',
    '    var preDutyPickupUTCDate: Date?',
    '    var preDutyPickupDisplay: String',
])
helpers = '\n'.join(block(anchor) for anchor in [
    'private func pickupUTCDate(for activity: RosterActivity)',
    'private func parseNominalLocalStamp(_ value: String)',
    'func parseUTCStamp(_ value: String)',
    'private func activitySortKey(_ activity: RosterActivity)',
])
for start, end in [('IceDestinationClock', 'IcePickupCard'), ('IcePickupCard', 'IceReadinessView')]:
    section = content[content.index('private struct ' + start):content.index('private struct ' + end)]
    assert 'TimelineView(.everyMinute)' in section
    assert '.periodic(from: .now, by: 60)' not in section

fixture = '''
import Foundation
import SwiftUI
private struct RosterActivity {
    let category: String
    let pickup: String
    let startLT: String
    let startUTC: String
    let checkInLT: String
    let checkInUTC: String
    let endLT = ""
    let endUTC = ""
    let checkOutLT = ""
    let checkOutUTC = ""
    var isAuxiliary: Bool { ["HOTEL", "EXPENSE", "RELOCATION"].contains(category.uppercased()) }
}
private struct RosterItem {
    let activityList: [RosterActivity]
PROPERTIES
}
HELPERS
@main struct Checks {
    static func main() {
        var count = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label); count += 1
        }
        func activity(_ category: String = "FLIGHT", _ start: String = "23:04",
                      pickup: String = "", ci: String = "21:50", day: String = "2026-10-08") -> RosterActivity {
            // UTC is three hours behind the explicit roster local anchors.
            func utc(_ time: String) -> String {
                guard !time.isEmpty, let date = parseUTCStamp(day + " " + time) else { return "" }
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd HH:mm"
                return formatter.string(from: date.addingTimeInterval(-3 * 3600))
            }
            return RosterActivity(category: category, pickup: pickup, startLT: day + " " + start,
                startUTC: utc(start), checkInLT: ci.isEmpty ? "" : day + " " + ci, checkInUTC: utc(ci))
        }
        let delayed = activity("OTHER", "20:20", ci: "")
        let flight = activity(pickup: "8 OCT • 20:50 LT")
        let tonight = RosterItem(activityList: [flight, delayed])
        expect(tonight.dutyStartUTCDate == parseUTCStamp("2026-10-08 17:20"), "DLRP duty start unchanged")
        expect(tonight.preDutyPickupUTCDate == parseUTCStamp("2026-10-08 17:50"), "20:50 pickup survives DLRP")
        expect(tonight.preDutyPickupDisplay == "8 OCT • 20:50 LT", "Display and reminders share selected pickup")
        expect(RosterItem(activityList: [flight]).preDutyPickupUTCDate == tonight.preDutyPickupUTCDate, "Normal flight unchanged")
        let late = activity(pickup: "8 OCT • 22:00 LT")
        expect(RosterItem(activityList: [delayed, late]).preDutyPickupUTCDate == nil, "Pickup after check-in rejected")
        let early = activity("OTHER", "20:20", pickup: "8 OCT • 19:50 LT", ci: "")
        expect(RosterItem(activityList: [early, flight]).preDutyPickupDisplay == flight.pickup, "Latest applicable pickup selected")
        let returnTransfer = activity("FLIGHT", "04:00", pickup: "9 OCT • 03:00 LT", ci: "03:30", day: "2026-10-09")
        expect(RosterItem(activityList: [returnTransfer, delayed, flight]).preDutyPickupDisplay == flight.pickup, "Return transfer not substituted for hotel pickup")
        let overnight = activity("FLIGHT", "00:30", pickup: "8 OCT • 23:10 LT", ci: "00:00", day: "2026-10-09")
        expect(RosterItem(activityList: [overnight]).preDutyPickupUTCDate == parseUTCStamp("2026-10-08 20:10"), "Explicit pickup date before midnight check-in")
        let positioning = activity("POSITIONING", pickup: "8 OCT • 20:50 LT")
        expect(RosterItem(activityList: [delayed, positioning]).preDutyPickupUTCDate == tonight.preDutyPickupUTCDate, "Positioning check-in supported")
        let noCI = activity("FLIGHT", pickup: "8 OCT • 20:50 LT", ci: "")
        expect(RosterItem(activityList: [delayed, noCI]).preDutyPickupUTCDate == tonight.preDutyPickupUTCDate, "Missing check-in falls back to sector departure")
        let standby = activity("STANDBY", "20:20", pickup: "8 OCT • 20:00 LT", ci: "")
        expect(RosterItem(activityList: [standby]).preDutyPickupUTCDate == parseUTCStamp("2026-10-08 17:00"), "Non-flight pickup preserves duty boundary")
        let standbyLate = activity("STANDBY", "20:20", pickup: "8 OCT • 20:50 LT", ci: "")
        expect(RosterItem(activityList: [standbyLate]).preDutyPickupUTCDate == nil, "Non-flight late pickup still rejected")
        let hotel = activity("HOTEL", "00:00", ci: "")
        expect(RosterItem(activityList: [hotel, flight]).preDutyPickupUTCDate == tonight.preDutyPickupUTCDate, "Hotel does not become report boundary")
        expect(RosterItem(activityList: []).preDutyPickupUTCDate == nil, "No invented pickup")
        let base = parseUTCStamp("2026-10-08 16:02")!
        for seconds in [0, 1, 35, 59, 24 * 3600 + 35] as [TimeInterval] {
            let now = base.addingTimeInterval(seconds)
            let dates = Array(EveryMinuteTimelineSchedule().entries(from: now, mode: .normal).prefix(2))
            let minute = Calendar(identifier: .gregorian).dateInterval(of: .minute, for: now)!.start
            expect(dates[0] == minute, "Launch/resume shows current minute immediately")
            expect(dates[1] == minute.addingTimeInterval(60), "Next update starts at minute boundary")
        }
        print("Passed \\(count) generated pickup and native minute-schedule checks")
    }
}
'''.replace('PROPERTIES', properties).replace('HELPERS', helpers)

a = js.index('  function pickupFrom(note) {')
b = js.index('\n  function aircraftDetails', a)
line = next(line for line in js.splitlines() if '    const pickup = pickupFrom(' in line)
note_checks = '''
const note = 'PU at 08Oct 20:50 local time<br><strong>ON ARRIVAL TO TLV:</strong>';
if (pickupFrom(note) !== '8 OCT • 20:50 LT') throw Error('Screenshot pickup format');
for (const source of ['transfer', 'activity', 'day']) {
  const transferNote = source === 'transfer' ? note : '';
  const activityNote = source === 'activity' ? note : '';
  const dayNote = source === 'day' ? note : '';
LINE
  if (pickup !== '8 OCT • 20:50 LT') throw Error('Pickup missing from ' + source);
}
console.log('Passed pickup extraction from all three labelled note fields');
'''.replace('LINE', line)
subprocess.run(['node', '-e', "const upper = v => v.trim().toUpperCase();\n" + js[a:b] + note_checks], check=True)
with tempfile.TemporaryDirectory(prefix='roster-timing-') as directory:
    source = Path(directory) / 'Checks.swift'
    source.write_text(fixture)
    executable = Path(directory) / 'checks'
    subprocess.run(['swiftc', '-parse-as-library', str(source), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
