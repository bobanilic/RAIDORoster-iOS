import XCTest
import Foundation
@testable import RAIDORoster

final class NativeRAIDOTimingTests: XCTestCase {
    private func native(start: String = "2026-10-08T10:00:00.0000000", end: String = "2026-10-08T11:00:00.0000000",
                        code: String = "SYN101", departure: String = "AAA", arrival: String = "BBB", duplicate: Bool = false) throws -> NativeRAIDOWire.Decoded {
        let activity = NativeRAIDOWire.Activity(id: 101, activity: code, departure: departure, arrival: arrival,
            std: "1000", sta: "1100", checkIn: nil, checkOut: nil,
            validFrom: try .init(start), validTo: try .init(end), details: nil)
        let day = NativeRAIDOWire.Day(details: .init(activities: duplicate ? [activity, activity] : [activity]), notes: [])
        return NativeRAIDOWire.Decoded(responseDate: try .init("2026-10-01T00:00:00"), days: [.init(calendarDay: "2026-10-08", day: day)])
    }

    private func referenceData(_ changes: [String: Any] = [:], rootChanges: [String: Any] = [:], duplicate: Bool = false) throws -> Data {
        var activity: [String: Any] = ["day": "2026-10-08", "code": "SYN101", "category": "FLIGHT", "route": "AAA → BBB",
            "startLT": "2026-10-08 13:00", "startUTC": "2026-10-08 10:00", "endLT": "2026-10-08 14:00", "endUTC": "2026-10-08 11:00"]
        activity.merge(changes) { _, new in new }
        var root: [String: Any] = ["version": 1, "sourceURL": "https://gjt.noc.vmc.navblue.cloud/HumanResourceRoster.aspx",
            "month": "2026-10", "valid": true, "activities": duplicate ? [activity, activity] : [activity]]
        root.merge(rootChanges) { _, new in new }
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func reference(_ changes: [String: Any] = [:], duplicate: Bool = false) throws -> NativeRAIDOTiming.Reference {
        try .parse(referenceData(changes, duplicate: duplicate), month: "2026-10")
    }

    func testUTCMinuteEvidenceUsesIndependentCodeRouteDayIdentity() throws {
        let result = NativeRAIDOTiming.compare(try native(), reference: try reference())
        XCTAssertEqual(result.paired, 1); XCTAssertEqual(result.utcOnly, 2); XCTAssertEqual(result.localOnly, 0)
        XCTAssertTrue(result.message.contains("UTC minutes")); XCTAssertTrue(result.message.contains("Evidence only"))
    }

    func testLocalMinuteEvidenceDoesNotConvertToUTC() throws {
        let result = NativeRAIDOTiming.compare(try native(start: "2026-10-08T13:00:00", end: "2026-10-08T14:00:00"), reference: try reference())
        XCTAssertEqual(result.localOnly, 2); XCTAssertEqual(result.utcOnly, 0)
        XCTAssertTrue(result.message.contains("LT minutes"))
    }

    func testCoincidentUTCAndLocalValuesAreInconclusive() throws {
        let result = NativeRAIDOTiming.compare(try native(), reference: try reference(["startLT": "2026-10-08 10:00", "endLT": "2026-10-08 11:00"]))
        XCTAssertEqual(result.coincident, 2); XCTAssertTrue(result.message.contains("indistinguishable"))
    }

    func testMixedAndDifferentValiditySemanticsStayUnresolved() throws {
        let mixed = NativeRAIDOTiming.compare(try native(), reference: try reference(["endLT": "2026-10-08 11:00", "endUTC": "2026-10-08 08:00"]))
        XCTAssertEqual(mixed.utcOnly, 1); XCTAssertEqual(mixed.localOnly, 1); XCTAssertTrue(mixed.message.contains("mixed"))
        let different = NativeRAIDOTiming.compare(try native(start: "2026-10-08T04:00:00", end: "2026-10-08T05:00:00"), reference: try reference())
        XCTAssertEqual(different.different, 2); XCTAssertTrue(different.message.contains("semantics remain unresolved"))
    }

    func testPrecisionExplicitZonesAndMissingFieldsDoNotEstablishABasis() throws {
        let precise = NativeRAIDOTiming.compare(try native(start: "2026-10-08T10:00:00.0000001"), reference: try reference())
        XCTAssertEqual(precise.precision, 1); XCTAssertTrue(precise.message.contains("precision"))
        let zoned = NativeRAIDOTiming.compare(try native(start: "2026-10-08T10:00:00Z"), reference: try reference())
        XCTAssertEqual(zoned.explicitZone, 1); XCTAssertTrue(zoned.message.contains("inconclusive"))
        let missing = NativeRAIDOTiming.compare(try native(), reference: try reference(["startUTC": ""]))
        XCTAssertEqual(missing.missing, 1); XCTAssertTrue(missing.message.contains("inconclusive"))
    }

    func testDuplicateNativeOrPortalRecordsAreNeverPairedByOrderOrTime() throws {
        for (nativeDuplicate, portalDuplicate) in [(true, false), (false, true)] {
            let result = NativeRAIDOTiming.compare(try native(duplicate: nativeDuplicate), reference: try reference(duplicate: portalDuplicate))
            XCTAssertEqual(result.paired, 0); XCTAssertEqual(result.ambiguous, 1); XCTAssertTrue(result.unpaired)
        }
    }

    func testCodeRouteAndDayMismatchesDoNotUseTimingToGuessIdentity() throws {
        for changes in [["code": "OTHER101"], ["route": "BBB → AAA"], ["day": "2026-10-09"], ["category": "STANDBY"]] {
            let result = NativeRAIDOTiming.compare(try native(), reference: try reference(changes))
            XCTAssertEqual(result.paired, 0); XCTAssertTrue(result.message.contains("undetermined"))
        }
    }

    func testOvernightCalendarDatesAreComparedVerbatim() throws {
        let ref = try reference(["startLT": "2026-10-08 23:30", "endLT": "2026-10-09 01:30",
                                 "startUTC": "2026-10-08 20:30", "endUTC": "2026-10-08 22:30"])
        let result = NativeRAIDOTiming.compare(try native(start: "2026-10-08T20:30:00", end: "2026-10-08T22:30:00"), reference: ref)
        XCTAssertEqual(result.utcOnly, 2); XCTAssertEqual(result.different, 0)
    }

    func testReferenceBoundaryRejectsWrongOriginMonthTypesAndCalendarStrings() throws {
        let invalid: [[String: Any]] = [["sourceURL": "https://example.invalid/HumanResourceRoster.aspx"],
            ["sourceURL": "https://gjt.noc.vmc.navblue.cloud:444/HumanResourceRoster.aspx"], ["sourceURL": "https://user@gjt.noc.vmc.navblue.cloud/HumanResourceRoster.aspx"],
            ["month": "2026-09"], ["version": true], ["valid": false], ["activities": []]]
        for changes in invalid {
            XCTAssertThrowsError(try NativeRAIDOTiming.Reference.parse(referenceData(rootChanges: changes), month: "2026-10"))
        }
        for changes in [["day": "2026-10-08\n"], ["day": "20٢٦-10-08"], ["startUTC": "2026-10-08 24:00"], ["startUTC": "2026-10-08 10:00\n"]] {
            XCTAssertThrowsError(try reference(changes))
        }
    }

    func testFixedTimingMessagesExposeNoRosterValues() throws {
        let result = NativeRAIDOTiming.compare(try native(), reference: try reference())
        for value in ["SYN101", "AAA", "BBB", "2026", "10:00", "13:00"] { XCTAssertFalse(result.message.contains(value)) }
    }
}
