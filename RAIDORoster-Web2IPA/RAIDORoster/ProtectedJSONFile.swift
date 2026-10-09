import Foundation
import CryptoKit
import os

/// Device-local cache, readable during a flight after the device's first unlock.
/// Callers retain their in-memory value when a read or write fails.
struct ProtectedJSONFile<Value: Codable> {
    let url: URL
    private struct Envelope: Codable {
        let schemaVersion: Int
        let savedAt: Date
        let payload: Value
    }
    enum Failure: Error { case unsupportedSchema }

    func save(_ value: Value, now: Date = Date()) throws {
        let manager = FileManager.default
        // Do not overwrite an unknown future schema, corrupted file or a locked file.
        if manager.fileExists(atPath: url.path) {
            let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            if let object = existing as? [String: Any], let schema = object["schemaVersion"] {
                guard schema as? Int == 1 else { throw Failure.unsupportedSchema }
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                _ = try decoder.decode(Envelope.self, from: Data(contentsOf: url))
            } else {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let bytes = try Data(contentsOf: url)
                do { _ = try decoder.decode(Value.self, from: bytes) }
                catch {
                    decoder.dateDecodingStrategy = .deferredToDate
                    _ = try decoder.decode(Value.self, from: bytes)
                }
            }
        }
        let folder = url.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.protect(folder)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Envelope(schemaVersion: 1, savedAt: now, payload: value))
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try Self.protect(url)
    }

    /// Existing unwrapped roster JSON is decoded and migrated without deleting it first.
    func load(legacyDatesISO8601: Bool = true) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["schemaVersion"] != nil {
            guard object["schemaVersion"] as? Int == 1 else { throw Failure.unsupportedSchema }
            let value = try decoder.decode(Envelope.self, from: data).payload
            try Self.protect(url)
            return value
        }
        if !legacyDatesISO8601 { decoder.dateDecodingStrategy = .deferredToDate }
        let value = try decoder.decode(Value.self, from: data)
        try save(value)
        return value
    }

    /// Remove the legacy defaults entry only after the protected file is safely written.
    func loadMigrating(defaults: UserDefaults = .standard, key: String) throws -> Value? {
        if FileManager.default.fileExists(atPath: url.path) {
            let value = try load()
            if value != nil { defaults.removeObject(forKey: key) }
            return value
        }
        guard let data = defaults.data(forKey: key) else { return nil }
        let value = try JSONDecoder().decode(Value.self, from: data)
        try save(value)
        defaults.removeObject(forKey: key)
        return value
    }

    static func protect(_ url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        var protectedURL = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
    }
}

enum DeviceCacheStorage {
    private static let logger = Logger(subsystem: "com.bobanilic.raidoroster", category: "Storage")
    static func folder(_ name: String) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return root.appendingPathComponent("RAIDORoster", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }
    static func file<Value: Codable>(_ name: String, folder: String = "Flight") throws -> ProtectedJSONFile<Value> {
        ProtectedJSONFile(url: try self.folder(folder).appendingPathComponent(name))
    }
    static func trailName(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }
    static func report(_ operation: String, error: Error) {
        // Only a static operation name and error domain/code; never roster contents or URLs.
        let ns = error as NSError
        logger.error("\(operation, privacy: .public) failed (\(ns.domain, privacy: .public):\(ns.code))")
    }
    static func removeExpiredTrails(in folder: URL, keeping activeName: String?, now: Date = Date()) throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        for file in files where file.pathExtension == "json" && file.lastPathComponent != activeName {
            if let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               now.timeIntervalSince(modified) > 30 * 24 * 60 * 60 {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
}
