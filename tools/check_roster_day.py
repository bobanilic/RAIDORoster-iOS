"""Run the production day-presentation policy with small Foundation-only models."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
fixture = r'''import Foundation
struct RosterActivity {
    let id: String, category: String, route: String, startUTC: String
    var isFlight: Bool { category == "FLIGHT" }
}
struct RosterItem {
    let id: String, index: Int, dateISO: String?, operationalActivities: [RosterActivity]
    var isOperationalDuty: Bool { !operationalActivities.isEmpty }
}
enum TodayGlobalAirportIndex {
    static func routeCodes(_ route: String) -> [String] { route.split(separator:"-").map(String.init) }
}
let day="2026-10-20"
func sector(_ id: String, _ time: String, _ category: String = "FLIGHT", _ route: String = "VNO-LEJ") -> RosterActivity {
    .init(id:id,category:category,route:route,startUTC:day+" "+time)
}
let first=RosterItem(id:"first",index:1,dateISO:day,operationalActivities:[sector("DI9003","06:00"),sector("DI6656","08:00"),sector("DI6657","12:55")])
let last=RosterItem(id:"last",index:2,dateISO:day,operationalActivities:[sector("DI9004","19:10","POSITIONING","LEJ-VNO")])
let other=RosterItem(id:"tomorrow",index:3,dateISO:"2026-10-21",operationalActivities:[sector("tomorrow","06:00")])
let off=RosterItem(id:"off",index:4,dateISO:day,operationalActivities:[])
let duties=RosterDayPresentation.duties(for:first,among:[other,last,off,first,first])
precondition(duties.map(\.id)==["first","last"],"All envelopes appear once, chronologically, without crossing dates")
precondition(RosterDayPresentation.sectors(in:duties).map(\.id)==["DI9003","DI6656","DI6657","DI9004"],"Fourth/positioning sector remains visible")
precondition(RosterDayPresentation.sectors(in:[first,first,last]).count==4,"Duplicate cached references do not inflate the count")
precondition(RosterDayPresentation.duties(for:last,among:[first]).count==2,"Selected late duty is retained even if absent from supplied day rows")
precondition(RosterDayPresentation.duties(for:off,among:[off]).map(\.id)==["off"],"Empty/off day keeps its briefing")
let undated=RosterItem(id:"unknown",index:5,dateISO:nil,operationalActivities:[])
precondition(RosterDayPresentation.duties(for:undated,among:[first]).map(\.id)==["unknown"],"Undated rows never collect unrelated duties")
let surface=RosterItem(id:"surface",index:6,dateISO:day,operationalActivities:[sector("move","11:00","RELOCATION"),sector("no-route","12:00","POSITIONING","")])
precondition(RosterDayPresentation.sectors(in:[surface]).isEmpty,"Non-air activities do not become sectors")
print("Passed 7 day-briefing checks: four sectors, split duties, positioning, duplicates, date isolation and empty days")
'''
with tempfile.TemporaryDirectory() as tmp:
    source=Path(tmp)/'main.swift'; binary=Path(tmp)/'checks'
    source.write_text(fixture)
    subprocess.run(['swiftc',str(root/'RAIDORoster-Web2IPA/RAIDORoster/RosterDayPresentation.swift'),str(source),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
