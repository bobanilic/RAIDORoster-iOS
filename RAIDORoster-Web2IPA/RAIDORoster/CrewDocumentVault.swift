import Foundation
import CryptoKit

enum CrewDocumentCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case passport, certificate, medical, vaccination, travel, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .passport: return "Passport & visas"
        case .certificate: return "Crew certificates"
        case .medical: return "Medical"
        case .vaccination: return "Vaccinations"
        case .travel: return "Travel"
        case .other: return "Other"
        }
    }
    var icon: String {
        switch self {
        case .passport: return "person.text.rectangle"
        case .certificate: return "checkmark.seal"
        case .medical: return "cross.case"
        case .vaccination: return "syringe"
        case .travel: return "airplane"
        case .other: return "doc"
        }
    }
}

struct CrewDocument: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var category: CrewDocumentCategory
    var pinned: Bool
    var expiryDay: String?
    var reminders: Bool
    let created: Date
    let byteCount: Int
}

enum CrewDocumentError: LocalizedError {
    case locked, unavailable, tooLarge, invalidFile, passwordPDF, storageLimit, invalidDate, notFound, noPasscode
    var errorDescription: String? {
        switch self {
        case .locked: return "Unlock Documents to continue."
        case .unavailable: return "Documents could not be opened. Saved files have been retained; no data was reset."
        case .tooLarge: return "Choose a document smaller than 25 MB."
        case .invalidFile: return "Choose a readable PDF, JPEG, PNG or HEIC image. Scans support up to 20 pages."
        case .passwordPDF: return "This PDF is password-protected. Import an unlocked copy."
        case .storageLimit: return "Documents is limited to 100 files or 250 MB. Export and remove files you no longer need."
        case .invalidDate: return "Choose a valid expiry or renewal date."
        case .notFound: return "This document is no longer available."
        case .noPasscode: return "Set an iPhone passcode in Settings to protect Documents."
        }
    }
}

enum CrewDocumentDates {
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    static func date(_ day: String, calendar: Calendar = .current) -> Date? {
        let pieces = day.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let y = Int(pieces[0]), let m = Int(pieces[1]), let d = Int(pieces[2]),
              let value = calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12)),
              self.day(value, calendar: calendar) == day else { return nil }
        return value
    }
    static func daysRemaining(_ day: String, now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let date = date(day, calendar: calendar) else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day
    }
    static func reminderDates(_ day: String, now: Date = Date(), calendar: Calendar = .current) -> [Date] {
        guard let expiry = date(day, calendar: calendar) else { return [] }
        return [30, 7, 1].compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: expiry),
                  let date = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day), date > now else { return nil }
            return date
        }
    }
}

// One actor serializes all file and manifest transactions. Filenames contain only UUIDs.
actor CrewDocumentVault {
    static let maxFileBytes = 25 * 1024 * 1024
    static let maxTotalBytes = 250 * 1024 * 1024
    private struct Index: Codable { var version = 1; var items: [CrewDocument] = [] }
    private let root: URL
    private var key: SymmetricKey?
    private var session: UUID?
    private var index = Index()
    init(root: URL) { self.root = root }
    private var manifest: URL { root.appendingPathComponent("index.sealed") }
    private func file(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".sealed") }
    private func aad(_ name: String) -> Data { Data(("RAIDO.CrewDocuments.v1." + name).utf8) }

    func unlock(keyData: Data, session: UUID) throws -> [CrewDocument] {
        guard keyData.count == 32 else { throw CrewDocumentError.unavailable }
        key = nil; self.session = nil; index = Index()
        let candidate = SymmetricKey(data: keyData)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try protect(root)
        var loaded = Index()
        if manager.fileExists(atPath: manifest.path) {
            let sealed = try Data(contentsOf: manifest)
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: candidate, authenticating: aad("index"))
            loaded = try JSONDecoder().decode(Index.self, from: plain)
            guard loaded.version == 1, loaded.items.count <= 100,
                  Set(loaded.items.map(\.id)).count == loaded.items.count else { throw CrewDocumentError.unavailable }
            for item in loaded.items {
                guard !item.title.isEmpty, item.title.count <= 120,
                      item.byteCount > 0, item.byteCount <= Self.maxFileBytes,
                      item.expiryDay.map({ CrewDocumentDates.date($0) != nil }) ?? true,
                      manager.fileExists(atPath: file(item.id).path) else { throw CrewDocumentError.unavailable }
            }
            guard loaded.items.reduce(0, { $0 + $1.byteCount }) <= Self.maxTotalBytes else { throw CrewDocumentError.unavailable }
        } else {
            let existing = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            guard !existing.contains(where: { $0.pathExtension == "sealed" }) else { throw CrewDocumentError.unavailable }
        }
        key = candidate; self.session = session; index = loaded
        return loaded.items
    }
    func lock() { key = nil; self.session = nil; index = Index() }

    func add(pdf: Data, title: String, category: CrewDocumentCategory, session: UUID) throws -> [CrewDocument] {
        guard let key, self.session == session else { throw CrewDocumentError.locked }
        guard !pdf.isEmpty else { throw CrewDocumentError.invalidFile }
        guard pdf.count <= Self.maxFileBytes else { throw CrewDocumentError.tooLarge }
        guard index.items.count < 100, index.items.reduce(0, { $0 + $1.byteCount }) + pdf.count <= Self.maxTotalBytes else { throw CrewDocumentError.storageLimit }
        let title = cleanTitle(title)
        let item = CrewDocument(id: UUID(), title: title, category: category, pinned: false,
                                expiryDay: nil, reminders: false, created: Date(), byteCount: pdf.count)
        let encrypted = try AES.GCM.seal(pdf, using: key, authenticating: aad(item.id.uuidString)).combined!
        try write(encrypted, to: file(item.id))
        var next = index; next.items.append(item)
        do { try commit(next) }
        catch { try? FileManager.default.removeItem(at: file(item.id)); throw error }
        return index.items
    }
    func update(_ edited: CrewDocument, session: UUID) throws -> [CrewDocument] {
        guard key != nil, self.session == session else { throw CrewDocumentError.locked }
        guard let offset = index.items.firstIndex(where: { $0.id == edited.id }) else { throw CrewDocumentError.notFound }
        guard edited.expiryDay.map({ CrewDocumentDates.date($0) != nil }) ?? true else { throw CrewDocumentError.invalidDate }
        var next = index
        next.items[offset].title = cleanTitle(edited.title)
        next.items[offset].category = edited.category
        next.items[offset].pinned = edited.pinned
        next.items[offset].expiryDay = edited.expiryDay
        next.items[offset].reminders = edited.reminders && edited.expiryDay != nil
        try commit(next)
        return index.items
    }
    func remove(_ id: UUID, session: UUID) throws -> [CrewDocument] {
        guard key != nil, self.session == session else { throw CrewDocumentError.locked }
        guard index.items.contains(where: { $0.id == id }) else { throw CrewDocumentError.notFound }
        var next = index; next.items.removeAll { $0.id == id }
        // Remove the reference first: interruption can leave an encrypted orphan, never a dangling item.
        try commit(next)
        try? FileManager.default.removeItem(at: file(id))
        return index.items
    }
    func pdf(_ id: UUID, session: UUID) throws -> Data {
        guard let key, self.session == session else { throw CrewDocumentError.locked }
        guard let item = index.items.first(where: { $0.id == id }) else { throw CrewDocumentError.notFound }
        let encrypted = try Data(contentsOf: file(id))
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key, authenticating: aad(id.uuidString))
        guard data.count == item.byteCount else { throw CrewDocumentError.unavailable }
        return data
    }
    private func cleanTitle(_ title: String) -> String {
        let value = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        return value.isEmpty ? "Document" : value
    }
    private func commit(_ next: Index) throws {
        guard let key else { throw CrewDocumentError.locked }
        let plain = try JSONEncoder().encode(next)
        let encrypted = try AES.GCM.seal(plain, using: key, authenticating: aad("index")).combined!
        try write(encrypted, to: manifest)
        index = next
    }
    private func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        // The protected parent is excluded from backup recursively. No fallible
        // post-write work here: callers treat a successful atomic write as commit.
    }
    private func protect(_ url: URL) throws {
        var target = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try target.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
}
