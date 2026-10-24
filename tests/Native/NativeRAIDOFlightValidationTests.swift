import XCTest
import Foundation
@testable import RAIDORoster

final class NativeRAIDOFlightValidationTests: XCTestCase {
    private func native(code: String = "SYN101", day: String = "2026-10-08", departure: String = "AAA", arrival: String = "BBB",
                        start: String = "2026-10-08T13:00:00", end: String = "2026-10-08T14:00:00", duplicate: Bool = false) throws -> NativeRAIDOWire.Decoded {
        let activity = NativeRAIDOWire.Activity(id: 101, activity: code, departure: departure, arrival: arrival,
            std: "1300", sta: "1400", checkIn: "1200", checkOut: "1430",
            validFrom: try .init(start), validTo: try .init(end), details: nil)
        let value = NativeRAIDOWire.Day(details: .init(activities: duplicate ? [activity, activity] : [activity]), notes: [])
        return .init(responseDate: try .init("2026-10-01T00:00:00"), days: [.init(calendarDay: day, day: value)])
    }

    private func data(_ changes: [String: Any] = [:], version: Int = 2, duplicate: Bool = false) throws -> Data {
        var a: [String: Any] = ["day": "2026-10-08", "code": "SYN101", "category": "FLIGHT", "route": "AAA → BBB",
            "startLT": "2026-10-08 13:00", "startUTC": "2026-10-08 10:00", "endLT": "2026-10-08 14:00", "endUTC": "2026-10-08 11:00",
            "checkInLT": "2026-10-08 12:00", "checkInUTC": "2026-10-08 09:00", "checkOutLT": "2026-10-08 14:30", "checkOutUTC": "2026-10-08 11:30"]
        a.merge(changes) { _, next in next }
        return try JSONSerialization.data(withJSONObject: ["version": version, "sourceURL": "https://gjt.noc.vmc.navblue.cloud/HumanResourceRoster.aspx",
            "month": "2026-10", "valid": true, "activities": duplicate ? [a, a] : [a]])
    }

    private func reference(_ changes: [String: Any] = [:], duplicate: Bool = false) throws -> NativeRAIDOTiming.Reference {
        try .parse(data(changes, duplicate: duplicate), month: "2026-10")
    }

    func testCompactCandidateGrammarRejectsLettersUnicodeTrailingDataAndInvalidClocks() {
        for value in ["23h", "9:00", "2400", "1260", "12٣٠", "1200\n", "1200 ", "1200-", "1200+32", "1200-999", "1200-١", "-100"] {
            XCTAssertNil(NativeRAIDOFlightValidation.CompactClock(value), value)
        }
        let plain = NativeRAIDOFlightValidation.CompactClock("0000")
        XCTAssertEqual(plain?.clock, "00:00"); XCTAssertNil(plain?.signedDay)
        XCTAssertEqual(NativeRAIDOFlightValidation.CompactClock("2350-1")?.signedDay, -1)
        XCTAssertEqual(NativeRAIDOFlightValidation.CompactClock("0010+1")?.signedDay, 1)
    }

    func testPlainClockEvidenceDoesNotClaimCalendarDates() {
        let local = NativeRAIDOFlightValidation.compareClock("1200", local: "2026-10-08 12:00", utc: "2026-10-08 09:00", rosterDay: "2026-10-08")
        XCTAssertEqual(local.localOnly, 1); XCTAssertTrue(local.clockOnly)
        XCTAssertTrue(local.message.contains("do not establish calendar dates"))
        let utc = NativeRAIDOFlightValidation.compareClock("0900", local: "2026-10-08 12:00", utc: "2026-10-08 09:00", rosterDay: "2026-10-08")
        XCTAssertEqual(utc.utcOnly, 1)
        let same = NativeRAIDOFlightValidation.compareClock("1200", local: "2026-10-08 12:00", utc: "2026-10-08 12:00", rosterDay: "2026-10-08")
        XCTAssertEqual(same.coincident, 1)
    }

    func testSignedSuffixIsOnlyACandidateTestedAgainstIndependentFullDates() {
        let result = NativeRAIDOFlightValidation.compareClock("2350-1", local: "2026-10-07 23:50", utc: "2026-10-07 20:50", rosterDay: "2026-10-08")
        XCTAssertEqual(result.localOnly, 1); XCTAssertTrue(result.signedDay); XCTAssertFalse(result.clockOnly)
        XCTAssertTrue(result.message.contains("not an import rule"))
        let wrong = NativeRAIDOFlightValidation.compareClock("2350+1", local: "2026-10-07 23:50", utc: "2026-10-07 20:50", rosterDay: "2026-10-08")
        XCTAssertEqual(wrong.localOnly, 0); XCTAssertEqual(wrong.dayDifference, 1)
    }

    func testSignedDateEvidenceCrossesMonthYearAndLeapDayWithoutDeviceZone() {
        for (day, local, utc, compact) in [
            ("2026-01-01", "2025-12-31 23:50", "2025-12-31 20:50", "2350-1"),
            ("2026-10-31", "2026-11-01 00:10", "2026-10-31 21:10", "0010+1"),
            ("2024-03-01", "2024-02-29 23:50", "2024-02-29 20:50", "2350-1")
        ] {
            let result = NativeRAIDOFlightValidation.compareClock(compact, local: local, utc: utc, rosterDay: day)
            XCTAssertEqual(result.localOnly, 1); XCTAssertEqual(result.dayDifference, 0)
        }
    }

    func testUnsupportedMissingAndDifferentValuesDoNotBecomeMatches() {
        let lt = "2026-10-08 12:00", utc = "2026-10-08 09:00", day = "2026-10-08"
        XCTAssertTrue(NativeRAIDOFlightValidation.compareClock("12h", local: lt, utc: utc, rosterDay: day).unsupported)
        XCTAssertTrue(NativeRAIDOFlightValidation.compareClock(nil, local: lt, utc: utc, rosterDay: day).absentNative)
        XCTAssertTrue(NativeRAIDOFlightValidation.compareClock("1200", local: lt, utc: nil, rosterDay: day).absentPortal)
        XCTAssertTrue(NativeRAIDOFlightValidation.compareClock("1200", local: lt + "\n", utc: utc, rosterDay: day).absentPortal)
        XCTAssertEqual(NativeRAIDOFlightValidation.compareClock("1600", local: lt, utc: utc, rosterDay: day).different, 1)
        XCTAssertTrue(NativeRAIDOFlightValidation.compareClock(nil, local: "", utc: "", rosterDay: day).message.contains("No comparable"))
    }

    func testPairedFieldAssessmentKeepsSTDSTACheckInAndCheckOutSeparate() throws {
        let pairing = NativeRAIDOTiming.pair(try native(), reference: try reference())
        let result = NativeRAIDOFlightValidation.assess(pairing)
        XCTAssertEqual(result.std.localOnly, 1); XCTAssertEqual(result.sta.localOnly, 1)
        XCTAssertEqual(result.checkIn.localOnly, 1); XCTAssertEqual(result.checkOut.localOnly, 1)
        XCTAssertFalse(result.overnightObserved); XCTAssertFalse(result.orderUnknown); XCTAssertFalse(result.orderDifferent)
        XCTAssertTrue(result.summary.contains("No paired overnight records"))
        XCTAssertTrue(result.summary.contains("full roster parity and import dates remain unverified"))
    }

    func testAmbiguousIdentitiesAreExcludedFromEveryClockCheck() throws {
        let pairing = NativeRAIDOTiming.pair(try native(duplicate: true), reference: try reference())
        XCTAssertEqual(pairing.ambiguous, 1); XCTAssertFalse(pairing.routeDifference); XCTAssertFalse(pairing.dayDifference)
        let result = NativeRAIDOFlightValidation.assess(pairing)
        XCTAssertEqual(result.std.localOnly, 0); XCTAssertEqual(result.checkIn.localOnly, 0)
        XCTAssertTrue(result.summary.contains("Repeated flight identities")); XCTAssertTrue(result.summary.contains("No paired flight records"))
    }

    func testUnmatchedReasonsUseCodeDayAndRouteWithoutTimingFallback() throws {
        let wire = try native()
        let route = NativeRAIDOTiming.pair(wire, reference: try reference(["route": "BBB → AAA"]))
        XCTAssertTrue(route.routeDifference); XCTAssertTrue(route.pairs.isEmpty)
        let day = NativeRAIDOTiming.pair(wire, reference: try reference(["day": "2026-10-09"]))
        XCTAssertTrue(day.dayDifference); XCTAssertTrue(day.pairs.isEmpty)
        let code = NativeRAIDOTiming.pair(wire, reference: try reference(["code": "OTHER101"]))
        XCTAssertTrue(code.nativeOnly); XCTAssertTrue(code.portalOnly); XCTAssertTrue(code.pairs.isEmpty)
        let unkeyed = NativeRAIDOTiming.pair(try native(departure: ""), reference: try reference())
        XCTAssertTrue(unkeyed.excludedNative); XCTAssertTrue(unkeyed.portalOnly)
        let invalidRoute = NativeRAIDOTiming.pair(wire, reference: try reference(["route": "AAA → BBB → CCC"]))
        XCTAssertTrue(invalidRoute.invalidPortalRoute); XCTAssertTrue(invalidRoute.unpaired)
    }

    func testWhitespaceNormalizationMatchesPortalCompactionWithoutGuessingCodeAliases() throws {
        let compact = NativeRAIDOTiming.pair(try native(code: " syn\t 101 "), reference: try reference(["code": "SYN 101"]))
        XCTAssertEqual(compact.pairs.count, 1)
        let different = NativeRAIDOTiming.pair(try native(code: "SYN 101"), reference: try reference())
        XCTAssertTrue(different.pairs.isEmpty)
    }

    func testOvernightValidityUsesCalendarDatesAndDoesNotInferCheckOutDate() throws {
        let ref = try reference(["startLT": "2026-10-08 23:30", "endLT": "2026-10-09 01:30",
            "startUTC": "2026-10-08 20:30", "endUTC": "2026-10-08 22:30",
            "checkInLT": "2026-10-08 22:30", "checkInUTC": "2026-10-08 19:30",
            "checkOutLT": "2026-10-09 02:00", "checkOutUTC": "2026-10-08 23:00"])
        let wire = try native(start: "2026-10-08T23:30:00", end: "2026-10-09T01:30:00")
        let result = NativeRAIDOFlightValidation.assess(NativeRAIDOTiming.pair(wire, reference: ref))
        XCTAssertTrue(result.overnightObserved); XCTAssertEqual(result.overnight.localOnly, 2)
        XCTAssertTrue(result.summary.contains("LT minutes")); XCTAssertFalse(result.orderDifferent)
        let wrong = try native(start: "2026-10-08T23:30:00", end: "2026-10-08T01:30:00")
        let rejected = NativeRAIDOFlightValidation.assess(NativeRAIDOTiming.pair(wrong, reference: ref))
        XCTAssertEqual(rejected.overnight.different, 1)
    }

    func testRepeatedDutyEnvelopeOrderingAndInvalidUTCOrderingRemainDistinct() throws {
        let valid = try reference(["checkInUTC": "2026-10-08 05:00", "checkOutUTC": "2026-10-08 20:00"])
        XCTAssertFalse(NativeRAIDOFlightValidation.assess(NativeRAIDOTiming.pair(try native(), reference: valid)).orderDifferent)
        for change in [["checkInUTC": "2026-10-08 12:00"], ["checkOutUTC": "2026-10-08 09:00"], ["endUTC": "2026-10-08 09:00"]] {
            let bad = NativeRAIDOFlightValidation.assess(NativeRAIDOTiming.pair(try native(), reference: try reference(change)))
            XCTAssertTrue(bad.orderDifferent); XCTAssertTrue(bad.summary.contains("inconsistent"))
        }
    }

    func testReferenceV2RequiresExplicitDutyFieldsAndIncludesThemInStability() throws {
        let first = try reference()
        XCTAssertNotEqual(first, try reference(["checkOutUTC": "2026-10-08 11:31"]))
        for change in [["checkInLT": NSNull()], ["checkOutUTC": "2026-10-08 25:00"], ["checkInUTC": "2026-10-08 09:00\n"]] as [[String: Any]] {
            XCTAssertThrowsError(try reference(change))
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data()) as? [String: Any])
        var activities = try XCTUnwrap(object["activities"] as? [[String: Any]])
        activities[0].removeValue(forKey: "checkOutUTC"); object["activities"] = activities
        XCTAssertThrowsError(try NativeRAIDOTiming.Reference.parse(JSONSerialization.data(withJSONObject: object), month: "2026-10"))
        object["version"] = 1
        XCTAssertNoThrow(try NativeRAIDOTiming.Reference.parse(JSONSerialization.data(withJSONObject: object), month: "2026-10"))
    }

    func testDetailedStatusIsValueFreeAndGatedByStableReferences() throws {
        let wire = try native(), first = NativeRAIDOTiming.Observation.ready(try reference())
        let report = NativeRAIDOTiming.assessment(wire, before: first, after: first, jsonMatched: true)
        for secret in ["SYN101", "AAA", "BBB", "2026", "13:00", "1300", "101", "navblue", "HrId"] { XCTAssertFalse(report.fields.contains(secret)) }
        let changed = NativeRAIDOTiming.Observation.ready(try reference(["checkInUTC": "2026-10-08 09:01"]))
        XCTAssertTrue(NativeRAIDOTiming.assessment(wire, before: first, after: changed, jsonMatched: true).fields.contains("required"))
        XCTAssertTrue(NativeRAIDOTiming.assessment(wire, before: first, after: first, jsonMatched: false).fields.contains("required"))
    }
}
