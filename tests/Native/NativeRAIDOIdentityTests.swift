import XCTest
import Foundation
@testable import RAIDORoster

final class NativeRAIDOIdentityTests: XCTestCase {
    private func activity(id: Int = 101, code: String = "SYN101", day: String = "2026-10-09", dep: String = "AAA", arr: String = "BBB",
                          start: String? = nil, end: String? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["Id": id, "Activity": code, "Dep": dep, "Arr": arr, "STD": "1300", "STA": "23h",
            "CheckIn": "1200-1", "CheckOut": "1430", "ValidFrom": start ?? day + "T13:00:00.0000000",
            "ValidTo": end ?? day + "T14:00:00.0000000", "Details": []]
        value.merge(extra) { _, next in next }; return value
    }
    private func native(_ days: [String: [[String: Any]]]) throws -> NativeRAIDOWire.Decoded {
        let mapped = days.mapValues { ["Details": ["ActivityDetails": $0], "Notes": []] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: ["d": ["Date": "2026-10-01T00:00:00", "HrId": 42,
            "Username": "private-user", "Roster": ["Days": mapped]]])
        let query = try NativeRAIDOContract.query(url: URL(string: "https://gjt.noc.vmc.navblue.cloud/synthetic/GetRoster")!,
            body: Data(#"{"month":10,"year":2026,"hrId":42}"#.utf8))
        return try NativeRAIDOWire.decode(data, for: query)
    }
    private func portal(code: String = "SYN101", day: String = "2026-10-09", category: String = "FLIGHT", route: String = "AAA → BBB",
                        changes: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["day": day, "code": code, "category": category, "route": route, "station": "VNO",
            "startLT": day + " 13:00", "startUTC": day + " 10:00", "endLT": day + " 14:00", "endUTC": day + " 11:00",
            "checkInLT": day + " 12:00", "checkInUTC": day + " 09:00", "checkOutLT": day + " 14:30", "checkOutUTC": day + " 11:30"]
        value.merge(changes) { _, next in next }; return value
    }
    private func reference(_ values: [[String: Any]]) throws -> NativeRAIDOTiming.Reference {
        func primary(_ value: [String: Any]) -> Bool {
            (value["day"] as? String ?? "").hasPrefix("2026-10-") && ["FLIGHT", "POSITIONING"].contains(value["category"] as? String ?? "")
        }
        let data = try JSONSerialization.data(withJSONObject: ["version": 3, "month": "2026-10", "valid": true,
            "sourceURL": "https://gjt.noc.vmc.navblue.cloud/HumanResourceRoster.aspx",
            "activities": values.filter(primary), "otherActivities": values.filter { !primary($0) }])
        return try .parse(data, month: "2026-10")
    }

    func testExactCopiesAcrossDifferentBucketsRetainEveryOccurrenceAndRawDisplay() throws {
        let a = activity(extra: ["Unreviewed": "private crew value"])
        let wire = try native(["2026-10-08": [a], "2026-10-09": [a]])
        XCTAssertEqual(wire.days[0].recordDigests, wire.days[1].recordDigests)
        let normalized = NativeRAIDOIdentity.normalize(wire)
        XCTAssertTrue(normalized.groupedCopies); XCTAssertEqual(normalized.records.count, 1)
        XCTAssertEqual(normalized.records[0].occurrences, 2)
        XCTAssertEqual(normalized.records[0].containerDays, ["2026-10-08", "2026-10-09"])
        let result = NativeRAIDOIdentity.assess(wire, reference: try reference([portal()]))
        XCTAssertEqual(result.matches.count, 1); XCTAssertEqual(result.flights.pairs.count, 1)
        XCTAssertTrue(result.usedMonthUnique); XCTAssertEqual(result.localCandidates.first?.end, "2026-10-09 14:00")
        XCTAssertEqual(result.localCandidates.first?.source.activity.sta, "23h", "Complete native validity bounds supply the candidate; display forms remain intact")
        let fields = NativeRAIDOFlightValidation.assess(result.flights)
        XCTAssertTrue(fields.checkIn.ambiguousAnchor, "A grouped record has no unique dictionary-day anchor")
    }

    func testUnrecognizedRawDifferencesPreventGroupingEvenWhenKnownModelsAreEqual() throws {
        let a = activity(extra: ["Unreviewed": "first"]), b = activity(extra: ["Unreviewed": "second"])
        let wire = try native(["2026-10-08": [a], "2026-10-09": [b]])
        XCTAssertEqual(wire.days[0].day.details?.activities, wire.days[1].day.details?.activities)
        XCTAssertNotEqual(wire.days[0].recordDigests, wire.days[1].recordDigests)
        let result = NativeRAIDOIdentity.normalize(wire)
        XCTAssertTrue(result.conflictingIDs); XCTAssertFalse(result.groupedCopies); XCTAssertEqual(result.records.count, 2)
        XCTAssertTrue(result.records.allSatisfy { $0.occurrences == 1 })
    }

    func testIdenticalRecordsWithinOneBucketStayAmbiguous() throws {
        let a = activity()
        let result = NativeRAIDOIdentity.assess(try native(["2026-10-09": [a, a]]), reference: try reference([portal()]))
        XCTAssertTrue(result.normalized.repeatedWithinDay); XCTAssertEqual(result.normalized.records.count, 2)
        XCTAssertTrue(result.matches.isEmpty); XCTAssertTrue(result.localCandidates.isEmpty); XCTAssertTrue(result.ambiguous)
    }

    func testMonthUniqueIdentityTestsDateDifferenceWithoutUsingTheDateToPair() throws {
        let wire = try native(["2026-10-08": [activity()]])
        let result = NativeRAIDOIdentity.assess(wire, reference: try reference([portal()]))
        XCTAssertEqual(result.matches.count, 1); XCTAssertTrue(result.usedMonthUnique); XCTAssertTrue(result.independentDayAgreement)
        XCTAssertEqual(result.localCandidates.first?.start, "2026-10-09 13:00")
        XCTAssertEqual(result.localCandidates.first?.source.containerDays, ["2026-10-08"])
        let wrong = try native(["2026-10-08": [activity(start: "2026-10-09T16:00:00", end: "2026-10-09T17:00:00")]])
        let mismatch = NativeRAIDOIdentity.assess(wrong, reference: try reference([portal()]))
        XCTAssertEqual(mismatch.matches.count, 1, "Pairing is unchanged even when the tested times are wrong")
        XCTAssertTrue(mismatch.localCandidates.isEmpty); XCTAssertTrue(mismatch.dayUnresolved)
        XCTAssertEqual(NativeRAIDOTiming.compare(mismatch.flights).different, 2)
    }

    func testRepeatedRoutesNeverUseValidityDatesOrTimesAsFallbackIdentity() throws {
        let wire = try native(["2026-10-08": [activity(), activity(id: 102, day: "2026-10-10")]])
        let result = NativeRAIDOIdentity.assess(wire, reference: try reference([portal(), portal(day: "2026-10-10")]))
        XCTAssertTrue(result.matches.isEmpty); XCTAssertTrue(result.ambiguous); XCTAssertTrue(result.dayUnresolved)
        let invalid = NativeRAIDOIdentity.assess(try native(["2026-10-09": [activity()]]), reference: try reference([portal(route: "AAA → BBB → CCC")]))
        XCTAssertTrue(invalid.flights.invalidPortalRoute); XCTAssertTrue(invalid.matches.isEmpty)
    }

    func testRepeatedDailyRoutesUseMutuallyUniqueContainerDayEdges() throws {
        let wire = try native(["2026-10-08": [activity(day: "2026-10-08")], "2026-10-09": [activity(id: 102)]])
        let result = NativeRAIDOIdentity.assess(wire, reference: try reference([portal(day: "2026-10-08"), portal()]))
        XCTAssertEqual(result.matches.count, 2); XCTAssertFalse(result.usedMonthUnique)
        XCTAssertEqual(NativeRAIDOTiming.compare(result.flights).localOnly, 4)
    }

    func testNonFlightOnlyRosterValidatesStandbyAndRepeatedDaysOff() throws {
        let standby = try native(["2026-10-08": [activity(code: "STB", dep: "", arr: "")]])
        let one = NativeRAIDOIdentity.assess(standby, reference: try reference([portal(code: "STB", category: "STANDBY", route: "")]))
        XCTAssertEqual(one.localCandidates.first?.category, "STANDBY"); XCTAssertTrue(one.flights.pairs.isEmpty)
        XCTAssertTrue(one.nonFlightMessages.joined().contains("LT minutes")); XCTAssertTrue(one.independentDayAgreement)
        let off = try native(["2026-10-08": [activity(code: "OFF", day: "2026-10-08", dep: "", arr: "")],
                              "2026-10-09": [activity(id: 102, code: "OFF", dep: "", arr: "")]])
        let two = NativeRAIDOIdentity.assess(off, reference: try reference([portal(code: "OFF", day: "2026-10-08", category: "OFF", route: ""),
            portal(code: "OFF", category: "OFF", route: "")]))
        XCTAssertEqual(two.matches.count, 2); XCTAssertEqual(two.localCandidates.count, 2); XCTAssertFalse(two.usedMonthUnique)
    }

    func testSpanningHotelKeepsStartDateOutsideSelectedMonthAndAllBuckets() throws {
        let a = activity(code: "HTL", dep: "", arr: "", start: "2026-09-29T13:00:00", end: "2026-10-20T14:00:00")
        let p = portal(code: "HTL", day: "2026-09-29", category: "HOTEL", route: "",
            changes: ["endLT": "2026-10-20 14:00", "endUTC": "2026-10-20 11:00", "checkOutLT": "2026-10-20 14:30", "checkOutUTC": "2026-10-20 11:30"])
        let result = NativeRAIDOIdentity.assess(try native(["2026-10-08": [a], "2026-10-09": [a]]), reference: try reference([p]))
        XCTAssertTrue(result.independentDayAgreement); XCTAssertEqual(result.localCandidates.first?.start, "2026-09-29 13:00")
        XCTAssertEqual(result.localCandidates.first?.end, "2026-10-20 14:00")
        XCTAssertEqual(result.localCandidates.first?.source.occurrences, 2)
    }

    func testFullGraphDegreesPreventGreedyResolutionOfSpanningRecord() throws {
        let a = activity(code: "HTL", dep: "", arr: "")
        let result = NativeRAIDOIdentity.assess(try native(["2026-10-08": [a], "2026-10-09": [a]]), reference: try reference([
            portal(code: "HTL", day: "2026-10-08", category: "HOTEL", route: ""), portal(code: "HTL", category: "HOTEL", route: "")]))
        XCTAssertEqual(result.normalized.records.count, 1); XCTAssertTrue(result.matches.isEmpty)
        XCTAssertTrue(result.ambiguous); XCTAssertTrue(result.localCandidates.isEmpty)
    }

    func testExplicitZonesPrecisionAndUnknownCategoriesCannotBecomeLocalCandidates() throws {
        for stamp in ["2026-10-09T13:00:00Z", "2026-10-09T13:00:00.0000001"] {
            let result = NativeRAIDOIdentity.assess(try native(["2026-10-09": [activity(start: stamp)]]), reference: try reference([portal()]))
            XCTAssertEqual(result.matches.count, 1); XCTAssertTrue(result.localCandidates.isEmpty)
        }
        let result = NativeRAIDOIdentity.assess(try native(["2026-10-09": [activity(code: "ZZZ", dep: "", arr: "")]]),
            reference: try reference([portal(code: "ZZZ", category: "OTHER", route: "")]))
        XCTAssertTrue(result.localCandidates.isEmpty); XCTAssertTrue(result.summary.contains("Classification remains unverified"))
    }

    func testEdgeAndOccurrenceLimitsReturnNoPartialMapping() throws {
        let wire = try native(["2026-10-09": (1...150).map { activity(id: $0, code: "OFF", dep: "", arr: "") }])
        let ref = try reference(Array(repeating: portal(code: "OFF", category: "OFF", route: ""), count: 150))
        let result = NativeRAIDOIdentity.assess(wire, reference: ref)
        XCTAssertTrue(result.limit); XCTAssertTrue(result.matches.isEmpty); XCTAssertTrue(result.localCandidates.isEmpty)
        let value = try XCTUnwrap(wire.days[0].day.details?.activities?.first)
        let oversized = NativeRAIDOWire.Decoded(responseDate: wire.responseDate,
            days: [.init(calendarDay: "2026-10-09", day: .init(details: .init(activities: Array(repeating: value, count: 6001)), notes: []))])
        XCTAssertTrue(NativeRAIDOIdentity.normalize(oversized).limit)
    }

    func testExtendedReferenceStabilityAndFixedSummaryExcludePrivateValues() throws {
        let wire = try native(["2026-10-08": [activity(extra: ["Unreviewed": "private crew value"])]]), ref = try reference([portal()])
        let result = NativeRAIDOIdentity.assess(wire, reference: ref)
        for secret in ["SYN101", "AAA", "BBB", "VNO", "2026", "13:00", "23h", "101", "private crew value", "navblue"] {
            XCTAssertFalse(result.summary.contains(secret))
        }
        let before = try reference([portal(code: "STB", category: "STANDBY", route: "")])
        let after = try reference([portal(code: "STB", category: "STANDBY", route: "", changes: ["station": "HER"])])
        XCTAssertNotEqual(before, after)
        XCTAssertTrue(NativeRAIDOTiming.assessment(wire, before: .ready(before), after: .ready(after), jsonMatched: true).fields.contains("required"))
        XCTAssertTrue(NativeRAIDOTiming.assessment(wire, before: .ready(ref), after: .ready(ref), jsonMatched: false).fields.contains("required"))
    }

    func testMissingDayDetailsCannotClaimCompleteCoverage() throws {
        let wire = try native(["2026-10-09": [activity()]])
        let partial = NativeRAIDOWire.Decoded(responseDate: wire.responseDate,
            days: wire.days + [.init(calendarDay: "2026-10-10", day: .init(details: nil, notes: []))])
        let result = NativeRAIDOIdentity.assess(partial, reference: try reference([portal()]))
        XCTAssertTrue(result.incompleteSource); XCTAssertTrue(result.summary.contains("roster coverage is unverified"))
    }

    func testReferenceV3RejectsWrongPartitionAndInconsistentDayWithoutSilentlyFiltering() throws {
        let ref = try reference([portal()])
        XCTAssertEqual(ref.version, 3); XCTAssertEqual(ref.otherActivities?.count, 0)
        XCTAssertThrowsError(try reference([portal(changes: ["station": NSNull()])]))
        XCTAssertThrowsError(try reference([portal(changes: ["startLT": "2026-10-10 13:00"])]))
        let invalid = try JSONSerialization.data(withJSONObject: ["version": 3, "month": "2026-10", "valid": true,
            "sourceURL": "https://gjt.noc.vmc.navblue.cloud/HumanResourceRoster.aspx",
            "activities": [], "otherActivities": [portal()]])
        XCTAssertThrowsError(try NativeRAIDOTiming.Reference.parse(invalid, month: "2026-10"))
    }
}
