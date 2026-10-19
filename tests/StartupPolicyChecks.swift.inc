private struct Sample: Codable, Equatable { var label:String }
struct RosterSnapshot { var validation:Validation?;var items:[Item];var capturedAt:Date }
struct Validation { var isValid:Bool;var parser:String }
struct Item { var dateISO:String? }

@main struct StartupChecks {
    static func main() throws {
        var count = 0
        func check(_ value:Bool,_ message:String) { precondition(value,message);count += 1 }
        let oldQueue = ["2025-01","2026-09","2026-10","2026-11"]
        check(RosterMonthCachePolicy.activeTargets(current:"2026-10",requested:nil,existing:oldQueue) == ["2026-10"],"Old history queue cannot restart")
        check(RosterMonthCachePolicy.activeTargets(current:"2026-10",requested:"2025-07",existing:oldQueue) == ["2025-07","2026-10"],"Explicit requested month remains available")
        check(RosterMonthCachePolicy.activeTargets(current:"2026-10",requested:"invalid",existing:oldQueue) == ["2026-10"],"Reject invalid requested month")
        check(RosterMonthCachePolicy.activeTargets(current:"2027-01",requested:nil,existing:oldQueue) == ["2027-01"],"Year rollover drops old queue")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let file = ProtectedJSONFile<Sample>(url:folder.appendingPathComponent("cache.json"))
        let value = Sample(label:"Synthetic cache")
        let legacy = try JSONEncoder().encode(value)
        try legacy.write(to:file.url)
        let before = try file.url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate
        let restored = try file.load(migrateLegacy:false)
        check(restored == value,"Read-only restore reads legacy data")
        check(try Data(contentsOf:file.url) == legacy,"Restore cannot rewrite the cache")
        check(try file.url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate == before,"Restore leaves file modification time intact")
        let migrated = try file.load()
        check(migrated == value,"Normal migration remains compatible")
        let bytes = try Data(contentsOf:file.url)
        let envelope = try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
        check(envelope["schemaVersion"] as? Int == 1,"Explicit migration writes supported schema")
        check(try file.load(migrateLegacy:false) == value,"Read-only restore reads protected envelopes")
        check(try Data(contentsOf:file.url) == bytes,"Protected envelope is unchanged by restore")
        let corrupted = Data("invalid JSON".utf8)
        try corrupted.write(to:file.url)
        do { _ = try file.load(migrateLegacy:false);preconditionFailure("Corrupt cache accepted") }
        catch { count += 1 }
        check(try Data(contentsOf:file.url) == corrupted,"Corrupt data is retained for recovery")
        print("Passed \(count) startup cache integrity and bounded download checks")
    }
}
