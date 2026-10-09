import XCTest
@testable import RAIDORoster

final class ProtectedStorageTests: XCTestCase {
    private struct Sample: Codable, Equatable { let name: String; let date: Date }
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private var file: ProtectedJSONFile<Sample> { ProtectedJSONFile(url: folder.appendingPathComponent("sample.json")) }
    private var sample: Sample { Sample(name: "Synthetic duty", date: Date(timeIntervalSince1970: 1_790_000_000)) }

    func testRoundTripSchemaBackupExclusionAndProtection() throws {
        try file.save(sample)
        XCTAssertEqual(try file.load(), sample)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(object["savedAt"])
        XCTAssertEqual(try file.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        // Simulator does not expose device Data Protection attributes.
        #if os(iOS) && !targetEnvironment(simulator)
        let protection = try FileManager.default.attributesOfItem(atPath: file.url.path)[.protectionKey]
        XCTAssertEqual((protection as? FileProtectionType)?.rawValue ?? (protection as? String), FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
        #endif
    }
    func testLegacyRosterJSONIsMigrated() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(sample).write(to: file.url)
        XCTAssertEqual(try file.load(), sample)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
    }
    func testDefaultsAreRemovedOnlyAfterSuccessfulMigration() throws {
        let suite = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = try JSONEncoder().encode(sample)
        defaults.set(legacy, forKey: "legacy")
        // A file in the parent path makes the protected write fail.
        let blocker = folder.appendingPathComponent("blocker")
        try Data("file".utf8).write(to: blocker)
        let blocked = ProtectedJSONFile<Sample>(url: blocker.appendingPathComponent("sample.json"))
        XCTAssertThrowsError(try blocked.loadMigrating(defaults: defaults, key: "legacy"))
        XCTAssertEqual(defaults.data(forKey: "legacy"), legacy)
        XCTAssertEqual(try file.loadMigrating(defaults: defaults, key: "legacy"), sample)
        XCTAssertNil(defaults.object(forKey: "legacy"))
        // A stale defaults duplicate must not override the authoritative file.
        defaults.set(try JSONEncoder().encode(Sample(name: "Stale", date: sample.date)), forKey: "legacy")
        XCTAssertEqual(try file.loadMigrating(defaults: defaults, key: "legacy"), sample)
        XCTAssertNil(defaults.object(forKey: "legacy"))
    }
    func testCorruptedAndFutureSchemasArePreserved() throws {
        for raw in ["broken JSON", "{\"schemaVersion\":99,\"payload\":{}}"] {
            let data = Data(raw.utf8)
            try data.write(to: file.url)
            XCTAssertThrowsError(try file.load())
            XCTAssertThrowsError(try file.save(sample))
            XCTAssertEqual(try Data(contentsOf: file.url), data)
        }
    }
    func testRetentionKeepsRecentAndActiveTrails() throws {
        let now = Date()
        for name in ["old.json", "active.json", "recent.json"] {
            let url = folder.appendingPathComponent(name)
            try Data("{}".utf8).write(to: url)
            let age: TimeInterval = name == "recent.json" ? 24 * 60 * 60 : 31 * 24 * 60 * 60
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try DeviceCacheStorage.removeExpiredTrails(in: folder, keeping: "active.json", now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("old.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("active.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("recent.json").path))
        XCTAssertEqual(DeviceCacheStorage.trailName("flight/key").count, 69)
        XCTAssertFalse(DeviceCacheStorage.trailName("flight/key").contains("/"))
    }
}
