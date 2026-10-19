import XCTest
@testable import RAIDORoster

@MainActor
final class TodayPriorityTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from:text)! }
    private func event(_ kind: TodayPriorityKind, start: String, end: String, timed: Bool = true,
                       id: String = "event") -> TodayPriorityEvent {
        .init(id:id,kind:kind,itemID:"item",title:"Fixture",detail:"Sanitized fixture",date:date(start),end:date(end),
              hasTime:timed,zoneID:"Europe/Vilnius",clock:"08:00",capturedAt:date("2026-10-19T08:00:00Z"))
    }
    func testImminentPickupOverridesPrecautionAndFutureRelocation() {
        let now = date("2026-10-19T09:00:00Z")
        let pickup = event(.pickup,start:"2026-10-19T09:15:00Z",end:"2026-10-19T10:00:00Z",id:"pickup")
        let alcohol = event(.alcohol,start:"2026-10-18T21:15:00Z",end:"2026-10-19T09:15:00Z",id:"alcohol")
        let move = event(.relocation,start:"2026-10-23T10:00:00Z",end:"2026-10-23T11:00:00Z",id:"move")
        XCTAssertEqual(TodayPriorityPolicy.ordered([move,alcohol,pickup,pickup],now:now).map(\.id),["pickup","alcohol","move"])
    }
    func testPickupDueNeverShowsNegativeCountdownOrClaimsCompletion() {
        let pickup = event(.pickup,start:"2026-10-19T09:00:00Z",end:"2026-10-19T10:00:00Z")
        XCTAssertEqual(TodayPriorityPolicy.status(pickup,now:date("2026-10-19T09:05:00Z")),"Pickup due")
        XCTAssertEqual(TodayPriorityPolicy.countdown(to:pickup.date,now:date("2026-10-19T09:05:00Z")),"Now")
        XCTAssertFalse(TodayPriorityPolicy.visible(pickup,now:pickup.end))
    }
    func testPrecautionSwitchesAtCutoffAndExpiresAtReference() {
        let alcohol = event(.alcohol,start:"2026-10-19T09:00:00Z",end:"2026-10-19T21:00:00Z")
        XCTAssertEqual(TodayPriorityPolicy.status(alcohol,now:date("2026-10-19T08:15:00Z")),"Begins in 45 min")
        XCTAssertEqual(TodayPriorityPolicy.status(alcohol,now:alcohol.date),"Active · 12h remaining")
        XCTAssertFalse(TodayPriorityPolicy.visible(alcohol,now:alcohol.end))
    }
    func testCountdownUsesElapsedTimeAcrossMidnightAndCeilsPartialMinutes() {
        let now = date("2026-10-19T23:58:30Z")
        XCTAssertEqual(TodayPriorityPolicy.countdown(to:date("2026-10-20T00:00:00Z"),now:now),"2 min")
        XCTAssertEqual(TodayPriorityPolicy.countdown(to:date("2026-10-20T01:00:00Z"),now:now),"1h 2m")
    }
    func testCalendarDaysAndMorningReminderAcrossDST() {
        let now = date("2026-10-24T21:00:00Z") // Midnight 25 October in Vilnius.
        let move = event(.relocation,start:"2026-10-25T22:00:00Z",end:"2026-10-26T22:00:00Z",timed:false)
        XCTAssertEqual(TodayPriorityPolicy.status(move,now:now),"Tomorrow")
        let dstDay = event(.relocation,start:"2026-10-24T21:00:00Z",end:"2026-10-25T22:00:00Z",timed:false)
        let reminders = TodayPriorityPolicy.reminderDates(dstDay,now:date("2026-10-23T00:00:00Z"),pickupLead:0,relocationEnabled:true,alcoholLead:0)
        XCTAssertEqual(reminders.first { $0.0.hasPrefix("MOVE-DAY") }?.1,date("2026-10-25T06:00:00Z"))
    }
    func testEarlyRelocationReminderPrecedesMoveAndMissingTimeGetsNoFalseClock() {
        let early = event(.relocation,start:"2026-10-23T01:00:00Z",end:"2026-10-23T02:00:00Z")
        let reminders = TodayPriorityPolicy.reminderDates(early,now:date("2026-10-19T00:00:00Z"),pickupLead:0,relocationEnabled:true,alcoholLead:0)
        XCTAssertEqual(reminders.count,2)
        XCTAssertTrue(reminders.allSatisfy { $0.1 < early.date })
        let untimed = event(.relocation,start:"2026-10-22T21:00:00Z",end:"2026-10-23T21:00:00Z",timed:false)
        XCTAssertEqual(TodayPriorityPolicy.status(untimed,now:date("2026-10-23T12:00:00Z")),"Today · Time not provided")
        XCTAssertTrue(TodayPriorityPolicy.reminderDates(untimed,now:date("2026-10-23T12:00:00Z"),pickupLead:0,relocationEnabled:true,alcoholLead:0).isEmpty)
    }
    func testDisabledReminderOptionsProduceNoRequests() {
        let move = event(.relocation,start:"2026-10-23T10:00:00Z",end:"2026-10-23T11:00:00Z")
        XCTAssertTrue(TodayPriorityPolicy.reminderDates(move,now:date("2026-10-19T00:00:00Z"),pickupLead:0,relocationEnabled:false,alcoholLead:0).isEmpty)
    }

    private func activity(id: String, category: String, day: String, pickup: String = "", notes: String = "", timed: Bool = true) -> [String:Any] {
        ["id":id,"code":category == "RELOCATION" ? "RLCN" : "6H501","category":category,"title":category,
         "route":category == "FLIGHT" ? "TLV → HER" : "", "station":category == "FLIGHT" ? "TLV" : "VNO",
         "startLT":timed ? day+" 11:00" : "", "startUTC":timed ? day+" 08:00" : "",
         "endLT":timed ? day+" 13:00" : "", "endUTC":timed ? day+" 10:00" : "",
         "checkInLT":category == "FLIGHT" ? day+" 10:00" : "", "checkInUTC":category == "FLIGHT" ? day+" 07:00" : "",
         "hotelName":category == "RELOCATION" ? "Fixture Hotel" : "", "pickup":pickup,"transferNote":notes,
         "rawText":"Sanitized activity"]
    }
    private func ingest(_ store: RosterStore, day: String, category: String, activities: [[String:Any]], activeHotels: [[String:Any]] = []) {
        let month = String(day.prefix(7))
        let value: [String:Any] = ["schemaVersion":1,"sourceURL":"https://gjt.noc.vmc.navblue.cloud/RaidoMobile/HumanResourceRoster.aspx",
            "validation":["isValid":true,"parser":"raido-duty-envelope-test","month":month,"datedRows":1],
            "rows":[["id":"day-"+day,"dateISO":day,"category":category,"title":category,"rawText":"Sanitized day","activities":activities,"activeHotels":activeHotels]]]
        XCTAssertTrue(store.ingest(messageBody:value,archiveOnly:true,expectedMonth:month))
    }
    private func store(_ body: (RosterStore) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        try body(RosterStore(storageFolderURL:folder,automaticSideEffects:false))
    }
    func testUpcomingRelocationOnOffDayAndHistoricalSelection() throws {
        try store { store in
            ingest(store,day:"2026-10-23",category:"OFF",activities:[activity(id:"move",category:"RELOCATION",day:"2026-10-23",timed:false)])
            store.showPendingRosterMonth("2026-07")
            let events = store.priorityEvents(at:date("2026-10-19T09:00:00Z"))
            let move = try XCTUnwrap(events.first { $0.kind == .relocation })
            XCTAssertEqual(TodayPriorityPolicy.status(move,now:date("2026-10-19T09:00:00Z")),"In 4 days")
            XCTAssertFalse(move.hasTime); XCTAssertTrue(move.missing.contains("Relocation time not provided"))
            XCTAssertFalse(events.contains { $0.kind == .alcohol })
            XCTAssertEqual(store.selectedRosterMonthKey,"2026-07")
        }
    }
    func testNextMonthPickupAndPrecautionAppearBeforeItsDutyDay() throws {
        try store { store in
            var flight = activity(id:"flight",category:"FLIGHT",day:"2026-11-01",pickup:"1 NOV 09:00 LT")
            flight["startUTC"]="2026-11-01 09:00"; flight["endUTC"]="2026-11-01 11:00"; flight["checkInUTC"]="2026-11-01 08:00"
            ingest(store,day:"2026-11-01",category:"FLIGHT",activities:[flight])
            let events = store.priorityEvents(at:date("2026-10-31T20:00:00Z"))
            let pickup = try XCTUnwrap(events.first { $0.kind == .pickup })
            XCTAssertEqual(pickup.date,date("2026-11-01T07:00:00Z"))
            XCTAssertEqual(events.first { $0.kind == .alcohol }?.end,pickup.date)
        }
    }
    func testMissingTransportIsFlaggedOnlyWhenTransportIsMentioned() throws {
        try store { store in
            ingest(store,day:"2026-10-19",category:"FLIGHT",activities:[activity(id:"f",category:"FLIGHT",day:"2026-10-19",notes:"Pickup arranged; time pending")])
            XCTAssertTrue(store.priorityEvents(at:date("2026-10-19T06:00:00Z")).contains { $0.kind == .transport })
            ingest(store,day:"2026-10-19",category:"FLIGHT",activities:[activity(id:"f",category:"FLIGHT",day:"2026-10-19",notes:"Own transport")])
            XCTAssertFalse(store.priorityEvents(at:date("2026-10-19T06:00:00Z")).contains { $0.kind == .transport })
        }
    }
    func testRevisedRosterRemovesOldMoveAndNoEstimatedPickupIsCreated() throws {
        try store { store in
            ingest(store,day:"2026-10-23",category:"OFF",activities:[activity(id:"move",category:"RELOCATION",day:"2026-10-23",timed:false)])
            XCTAssertTrue(store.priorityEvents(at:date("2026-10-19T09:00:00Z")).contains { $0.kind == .relocation })
            ingest(store,day:"2026-10-23",category:"OFF",activities:[])
            XCTAssertFalse(store.priorityEvents(at:date("2026-10-19T09:00:00Z")).contains { $0.kind == .relocation || $0.kind == .pickup })
        }
    }
    func testAllDayUTCSpanDoesNotBecomeMidnightRelocationCountdown() throws {
        try store { store in
            var move = activity(id:"move",category:"RELOCATION",day:"2026-10-23")
            move["startLT"]="2026-10-23 03:00"; move["startUTC"]="2026-10-23 00:00"
            move["endLT"]="2026-10-24 02:59"; move["endUTC"]="2026-10-23 23:59"
            ingest(store,day:"2026-10-23",category:"OFF",activities:[move])
            XCTAssertFalse(try XCTUnwrap(store.priorityEvents(at:date("2026-10-19T09:00:00Z")).first).hasTime)
        }
    }
    func testHistoricalKeysMatchRecordedSessionAndSeparateFlightDates() throws {
        try store { store in
            var row = activity(id:"flight",category:"FLIGHT",day:"2026-10-19")
            row["aircraftReg"]="LYTEN"
            ingest(store,day:"2026-10-19",category:"FLIGHT",activities:[row])
            let flight = try XCTUnwrap(store.priorityRosterItems.first?.flightActivities.first)
            let key = "RAIDORoster.FlightTrail.V1." + Data("2026-10-19 08:00|2026-10-19 10:00|TLV → HER|LY-TEN".utf8).base64EncodedString()
            XCTAssertTrue(HistoricalRoutePolicy.sessionKeys(for:flight,defaultRegistration:"").contains(key))
            XCTAssertFalse(HistoricalRoutePolicy.sessionKeys(for:flight,defaultRegistration:"").contains("RAIDORoster.FlightTrail.V1."+Data("2026-10-18 08:00|2026-10-18 10:00|TLV → HER|LY-TEN".utf8).base64EncodedString()))
        }
    }
    func testReminderTapRoutesOnlyAppDutyRequests() {
        let router = TodayNotificationRouter()
        router.receive(identifier:"other-request",userInfo:["raidoPriorityID":"move"])
        XCTAssertNil(router.pendingID)
        router.receive(identifier:"RAIDO-ROSTER-MOVE-DAY-move",userInfo:["raidoPriorityID":"move"])
        XCTAssertEqual(router.pendingID,"move")
        router.receive(identifier:"RAIDO-ROSTER-REPORT-item",userInfo:[:])
        XCTAssertEqual(router.pendingID,"today")
    }
    func testLegacyRelocationInHotelMetadataSurvivesWithoutReimport() throws {
        try store { store in
            var move = activity(id:"old-move",category:"HOTEL",day:"2026-10-23")
            move["code"]="RLCN";move["hotelName"]="relocation"
            move["activityNote"]="Please use Bolt for the relocation"
            move["startLT"]="2026-10-23 12:00";move["startUTC"]="2026-10-23 09:00"
            let standby = activity(id:"standby",category:"STANDBY",day:"2026-10-23")
            ingest(store,day:"2026-10-23",category:"STANDBY",activities:[standby],activeHotels:[move])
            let item = try XCTUnwrap(store.priorityRosterItems.first)
            XCTAssertEqual(item.relocationActivities.count,1)
            XCTAssertTrue(item.hotelAssignments.isEmpty)
            XCTAssertEqual(item.operationalActivities.count,1)
            let event = try XCTUnwrap(store.priorityEvents(at:date("2026-10-19T12:55:00Z")).first { $0.kind == .relocation })
            XCTAssertEqual(event.clock,"12:00");XCTAssertEqual(event.endClock,"13:00")
            XCTAssertTrue(event.notes.contains("Bolt"))
            XCTAssertFalse(event.missing.contains("Transport details not provided"))
        }
    }
    func testPrecautionLabelsItsStartAndNextDayReferenceSeparately() {
        let event = event(.alcohol,start:"2026-10-19T12:30:00Z",end:"2026-10-20T00:30:00Z")
        let now = date("2026-10-19T12:55:00Z")
        XCTAssertEqual(TodayPriorityPolicy.localDayLabel(event.date,event:event,now:now),"Today · 19 Oct")
        XCTAssertEqual(TodayPriorityPolicy.localDayLabel(event.end,event:event,now:now),"Tomorrow · 20 Oct")
        XCTAssertEqual(TodayPriorityPolicy.status(event,now:now),"Active · 11h 35m remaining")
    }

    func testStandbyPeriodSurvivesGenericCachedDayTitle() throws {
        try store { store in
            for (code,description,label) in [
                ("STM32","STB Morning320 ADHOC","STB M"),
                ("STA32","STB Afternoon320 ADHOC","STB A"),
                ("STN32","STB Night320 ADHOC","STB N"),
                ("STBN","","STB N"),
                ("STB","Standby","STB")
            ] {
                var row = activity(id:"standby",category:"STANDBY",day:"2026-10-20")
                row["code"]=code;row["title"]="STANDBY";row["description"]=description
                ingest(store,day:"2026-10-20",category:"STANDBY",activities:[row])
                XCTAssertEqual(try XCTUnwrap(store.priorityRosterItems.first).standbyCalendarLabel,label)
            }
        }
        XCTAssertNil(rosterStandbyPeriod(code:"STB",details:"STB NORMAL"))
    }

    func testHotelMoveMarkerUsesActualLocalMoveDateIncludingLegacyMetadata() throws {
        try store { store in
            var move = activity(id:"old-move",category:"HOTEL",day:"2026-10-23")
            move["code"]="RLCN"
            let standby = activity(id:"standby",category:"STANDBY",day:"2026-10-23")
            ingest(store,day:"2026-10-23",category:"STANDBY",activities:[standby],activeHotels:[move])
            XCTAssertTrue(try XCTUnwrap(store.priorityRosterItems.first).hasHotelRelocationOnRosterDate)
            ingest(store,day:"2026-10-24",category:"STANDBY",activities:[standby],activeHotels:[move])
            let adjacent = try XCTUnwrap(store.priorityRosterItems.first { $0.dateISO == "2026-10-24" })
            XCTAssertFalse(adjacent.hasHotelRelocationOnRosterDate)
        }
    }
}
