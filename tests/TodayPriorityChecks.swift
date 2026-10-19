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
        print("Passed \(count) Today priority, countdown, DST and reminder checks")
    }
}
