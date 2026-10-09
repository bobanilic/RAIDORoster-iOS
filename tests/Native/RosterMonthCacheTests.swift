import XCTest
@testable import RAIDORoster

@MainActor
final class RosterMonthCacheTests: XCTestCase {
    func payload(_ month: String, count: Int = 5) -> [String: Any] {
        ["schemaVersion": 1, "sourceURL": "https://gjt.noc.vmc.navblue.cloud/RaidoMobile/Dialogues/HumanResources/HumanResourceRoster.aspx?year=\(month.prefix(4))&month=\(month.suffix(2))&hrId=fixture",
         "monthlyBLH": "15:15", "validation": ["isValid": true, "parser": "raido-duty-envelope-test", "month": month, "datedRows": count],
         "rows": (1...count).map { ["id": "\(month)-\($0)", "dateISO": "\(month)-\(String(format: "%02d", $0))", "rawText": "Sanitized duty", "category": "OFF", "activities": []] as [String: Any] }]
    }
    func testExactMonthURLAndYearRollover() throws {
        let url = try XCTUnwrap(URL(string: "https://gjt.noc.vmc.navblue.cloud/RaidoMobile/Dialogues/HumanResources/HumanResourceRoster.aspx?hrId=fixture&month=10&year=2026#day"))
        let target = try XCTUnwrap(RosterMonthCachePolicy.requestURL(source: url, month: "2025-12"))
        let query = try XCTUnwrap(URLComponents(url: target, resolvingAgainstBaseURL: false)).queryItems!
        XCTAssertEqual(query.first { $0.name == "hrId" }?.value, "fixture")
        XCTAssertEqual(query.first { $0.name == "year" }?.value, "2025")
        XCTAssertEqual(query.first { $0.name == "month" }?.value, "12")
        XCTAssertNil(target.fragment)
        let months = RosterMonthCachePolicy.targets(current: "2026-01", offered: ["2024-09", "bad", "2026-13"])
        XCTAssertTrue(months.contains("2025-12")); XCTAssertTrue(months.contains("2024-09"))
        XCTAssertEqual(months.first, "2026-01"); XCTAssertFalse(months.contains("2026-13"))
        XCTAssertNil(RosterMonthCachePolicy.requestURL(source: URL(string: "https://example.invalid/HumanResourceRoster.aspx")!, month: "2026-09"))
        XCTAssertNil(RosterMonthCachePolicy.requestURL(source: url, month: "2026-00"))
    }
    func testArchiveImportPreservesSelectionAndSurvivesRelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RosterStore(storageFolderURL: folder, automaticSideEffects: false)
        XCTAssertTrue(store.ingest(messageBody: payload("2026-10")))
        let original = try XCTUnwrap(store.snapshot)
        store.showPendingRosterMonth("2026-08")
        XCTAssertTrue(store.ingest(messageBody: payload("2026-09"), archiveOnly: true, expectedMonth: "2026-09"))
        XCTAssertEqual(store.selectedRosterMonthKey, "2026-08")
        XCTAssertEqual(store.snapshot, original); XCTAssertTrue(store.latestChanges.isEmpty)
        XCTAssertFalse(store.ingest(messageBody: payload("2026-10"), archiveOnly: true, expectedMonth: "2026-08"))
        XCTAssertNil(store.monthSnapshots["2026-08"])
        let loaded = RosterStore(storageFolderURL: folder, automaticSideEffects: false)
        XCTAssertTrue(loaded.selectRosterMonthIfCached("2026-09"))
        XCTAssertEqual(loaded.rosterViewItems.count, 5)
        XCTAssertEqual(loaded.rosterViewSnapshot?.monthlyBLH, "15:15")
        XCTAssertEqual(loaded.monthSnapshots["2026-10"]?.items.count, 5)
    }
    func testSparseArchiveAndInvalidUpdatePreserveGoodCache() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RosterStore(storageFolderURL: folder, automaticSideEffects: false)
        let sparse = payload("2026-11", count: 1)
        XCTAssertThrowsError(try PortalBridgePolicy.snapshot(sparse))
        XCTAssertTrue(store.ingest(messageBody: sparse, archiveOnly: true, expectedMonth: "2026-11"))
        let saved = store.monthSnapshots["2026-11"]
        var broken = sparse; broken["schemaVersion"] = 999
        XCTAssertFalse(store.ingest(messageBody: broken, archiveOnly: true, expectedMonth: "2026-11"))
        XCTAssertEqual(store.monthSnapshots["2026-11"], saved)
        XCTAssertNil(store.portalFormatWarning)
    }
    func testProtectedSourcePersistsAndClearInvalidatesWorker() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RosterStore(storageFolderURL: folder, automaticSideEffects: false)
        let source = try XCTUnwrap(URL(string: payload("2026-10")["sourceURL"] as! String))
        store.rememberRosterSourceURL(source)
        let loaded = RosterStore(storageFolderURL: folder, automaticSideEffects: false)
        XCTAssertEqual(loaded.rosterSourceURL, source)
        let ticket = loaded.cacheGeneration; loaded.clearCache()
        XCTAssertNotEqual(loaded.cacheGeneration, ticket)
        XCTAssertNil(RosterStore(storageFolderURL: folder, automaticSideEffects: false).rosterSourceURL)
    }
}
