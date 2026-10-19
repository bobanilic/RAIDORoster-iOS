import Foundation

@main struct TodayPriorityChecks {
    static func main() {
        var count = 0
        func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label); count += 1
        }
        func event(_ kind: TodayPriorityKind, _ start: String, _ end: String,
                   id: String = "fixture", timed: Bool = true) -> TodayPriorityEvent {
            .init(id: id, kind: kind, itemID: "duty", title: "Fixture", detail: "Sanitized fixture",
                  date: date(start), end: date(end), hasTime: timed, zoneID: "Europe/Vilnius",
                  clock: "08:00", capturedAt: date("2026-10-19T08:00:00Z"))
        }
        let now = date("2026-10-19T09:00:00Z")
        let pickup = event(.pickup, "2026-10-19T09:15:00Z", "2026-10-19T10:00:00Z", id: "pickup")
        let alcohol = event(.alcohol, "2026-10-18T21:15:00Z", "2026-10-19T09:15:00Z", id: "alcohol")
        let move = event(.relocation, "2026-10-23T10:00:00Z", "2026-10-23T11:00:00Z", id: "move")
        expect(TodayPriorityPolicy.ordered([move, alcohol, pickup, pickup], now: now).map(\.id) == ["pickup", "alcohol", "move"],
               "Imminent pickup leads and duplicate reminders collapse")
        expect(TodayPriorityPolicy.status(move, now: now) == "In 4 days", "Future move uses calendar days")
        expect(TodayPriorityPolicy.status(pickup, now: pickup.date) == "Pickup due", "Scheduled pickup never implies transport occurred")
        expect(TodayPriorityPolicy.countdown(to: pickup.date, now: pickup.end) == "Now", "No negative countdown")
        expect(!TodayPriorityPolicy.visible(pickup, now: pickup.end), "Expired pickup leaves priorities")
        expect(!TodayPriorityPolicy.visible(alcohol, now: alcohol.end), "Pre-duty precaution expires at its reference")
        let next = event(.alcohol, "2026-10-19T10:00:00Z", "2026-10-19T22:00:00Z")
        expect(TodayPriorityPolicy.status(next, now: now) == "Begins in 1h", "Upcoming precaution counts to cutoff")
        expect(TodayPriorityPolicy.status(next, now: next.date) == "Active · 12h remaining", "Active precaution counts to pickup/report")
        expect(TodayPriorityPolicy.countdown(to: date("2026-10-20T00:00:00Z"), now: date("2026-10-19T23:58:30Z")) == "2 min",
               "Midnight countdown rounds partial minutes up")
        let dst = event(.relocation, "2026-10-24T21:00:00Z", "2026-10-25T22:00:00Z", timed: false)
        let reminders = TodayPriorityPolicy.reminderDates(dst, now: now, pickupLead: 0, relocationEnabled: true, alcoholLead: 0)
        expect(reminders.first { $0.0.hasPrefix("MOVE-DAY") }?.1 == date("2026-10-25T06:00:00Z"), "DST morning is 08:00 local wall time")
        expect(reminders.first { $0.0.hasPrefix("MOVE-EVE") }?.1 == date("2026-10-24T15:00:00Z"), "Previous evening is 18:00 in its own offset")
        expect(TodayPriorityPolicy.status(dst, now: dst.date) == "Today · Time not provided", "Date-only relocation has no invented clock")
        let early = event(.relocation, "2026-10-23T01:00:00Z", "2026-10-23T02:00:00Z")
        expect(TodayPriorityPolicy.reminderDates(early, now: now, pickupLead: 0, relocationEnabled: true, alcoholLead: 0).allSatisfy { $0.1 < early.date },
               "Early relocation is never reminded after the move")
        expect(TodayPriorityPolicy.reminderDates(move, now: now, pickupLead: 0, relocationEnabled: false, alcoholLead: 0).isEmpty,
               "Disabled reminders remain disabled")
        expect(TodayPriorityPolicy.reminderDates(pickup, now: now, pickupLead: 10, relocationEnabled: false, alcoholLead: 0).first?.1 == date("2026-10-19T09:05:00Z"),
               "Existing pickup lead time is retained")
        expect(TodayPriorityPolicy.reminderDates(next, now: now, pickupLead: 0, relocationEnabled: false, alcoholLead: 15).first?.1 == date("2026-10-19T09:45:00Z"),
               "Optional precaution reminder precedes cutoff")
        expect(TodayPriorityPolicy.reminderDates(pickup, now: pickup.date, pickupLead: 10, relocationEnabled: false, alcoholLead: 0).isEmpty,
               "Past reminders are not rescheduled")
        let overnight = event(.alcohol,"2026-10-19T12:30:00Z","2026-10-20T00:30:00Z")
        let afternoon = date("2026-10-19T12:55:00Z")
        expect(TodayPriorityPolicy.localDayLabel(overnight.date,event:overnight,now:afternoon) == "Today · 19 Oct", "Precaution starts today")
        expect(TodayPriorityPolicy.localDayLabel(overnight.end,event:overnight,now:afternoon) == "Tomorrow · 20 Oct", "Reference correctly names tomorrow")
        expect(TodayPriorityPolicy.status(overnight,now:afternoon) == "Active · 11h 35m remaining", "Overnight remaining time matches report")
        let plans = LockScreenPolicy.plans(events:[pickup,alcohol],now:now,pickup:true,precaution:true)
        expect(plans.count == 1, "Pickup and precaution share one Lock Screen card")
        expect(plans.first?.startsAt == pickup.date.addingTimeInterval(-7200), "Countdown starts two hours before pickup")
        expect(plans.first?.precautionBegins == alcohol.date, "Card retains precaution cutoff")
        for hours in LockScreenPolicy.leadHourOptions {
            let plan = LockScreenPolicy.plans(events:[pickup,alcohol],now:now,pickup:true,precaution:true,leadHours:hours).first!
            expect(plan.startsAt == pickup.date.addingTimeInterval(-Double(hours) * 3600), "Selected lead time schedules the full window")
        }
        expect(LockScreenPolicy.plans(events:[pickup],now:now,pickup:true,precaution:false,leadHours:24).first?.leadHours == 2, "Unsupported saved lead uses safe default")
        let twoHour = plans.first!
        let earlier = now.addingTimeInterval(-10 * 3600)
        expect(LockScreenPolicy.needsReschedule(twoHour,scheduledStart:pickup.date.addingTimeInterval(-8 * 3600),referenceAt:pickup.date,isPending:true,now:earlier), "Changing a pending start replaces its immutable schedule")
        expect(!LockScreenPolicy.needsReschedule(twoHour,scheduledStart:twoHour.startsAt,referenceAt:pickup.date,isPending:true,now:earlier), "Unchanged pending schedule is retained")
        expect(LockScreenPolicy.needsReschedule(twoHour,scheduledStart:pickup.date.addingTimeInterval(-8 * 3600),referenceAt:pickup.date,isPending:false,now:pickup.date.addingTimeInterval(-4 * 3600)), "Shortening an active eight-hour card hides it until two hours before duty")
        expect(!LockScreenPolicy.needsReschedule(twoHour,scheduledStart:now,referenceAt:pickup.date,isPending:false,now:now), "Already active countdown is not restarted on every refresh")
        expect(LockScreenPolicy.plans(events:[pickup,alcohol],now:now,pickup:false,precaution:false).isEmpty, "Disabled Lock Screen creates no activities")
        expect(LockScreenPolicy.plans(events:[pickup,alcohol],now:pickup.end,pickup:true,precaution:true).isEmpty, "Expired plans are removed")
        expect(LockScreenPolicy.plans(events:[alcohol],now:now,pickup:false,precaution:true).first?.referenceLabel == "Report", "Missing pickup uses report only for precaution")
        expect(LockScreenPolicy.showFutureRelocations(todayCategories:["OFF","STANDBY"]), "Off and standby days show future moves")
        expect(!LockScreenPolicy.showFutureRelocations(todayCategories:["STANDBY","FLIGHT"]), "Flight duty takes precedence over standby")
        expect(!LockScreenPolicy.showFutureRelocations(todayCategories:["POSITIONING"]), "Positioning days stay focused on travel")
        expect(!LockScreenPolicy.showFutureRelocations(todayCategories:[]), "Unknown day does not invent an off day")
        expect(LockScreenPolicy.cleanLogisticsNote("Please use Bolt for the relocation HTL 1455 VNO VNO 26OCT BKD") == "Please use Bolt for the relocation", "Cached note loses collapsed hotel suffix")
        expect(LockScreenPolicy.cleanLogisticsNote("HTL will confirm the address.") == "HTL will confirm the address.", "Legitimate hotel prose is preserved")
        // Characterize the actual Foundation style used by the native Orbit
        // TimeDataSource, especially the last minute and hour rollover.
        let orbitFormat = Duration.TimeFormatStyle(pattern:.hourMinute(padHourToLength:2,roundSeconds:.awayFromZero),locale:Locale(identifier:"en_US_POSIX"))
        for (seconds,expected) in [(0,"00:00"),(1,"00:01"),(59,"00:01"),(60,"00:01"),(61,"00:02"),
                                   (3599,"01:00"),(3600,"01:00"),(3601,"01:01"),(28800,"08:00")] {
            let nativeOffset = orbitFormat.format(.seconds(-seconds))
            expect(String(nativeOffset.suffix(5)) == expected,"Orbit minute precision and padded hours at \(seconds) seconds")
        }
        print("Passed \(count) Today priority, countdown, DST and reminder checks")
    }
}
