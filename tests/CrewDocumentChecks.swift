import Foundation
import CryptoKit

@main struct CrewDocumentChecks {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) {
        checks += 1
        if !value { fatalError("Crew Documents check failed: " + label) }
    }
    static func rejects(_ label: String, _ action: () async throws -> Void) async {
        do { try await action(); fatalError("Expected rejection: " + label) }
        catch { checks += 1 }
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = CrewDocumentVault(root: root)
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let session = UUID()
        let payload = Data("%PDF-test SECRET PASSPORT RECORD".utf8)
        await rejects("locked add") { _ = try await vault.add(pdf: payload, title: "Passport", category: .passport, session: session) }
        let empty = try await vault.unlock(keyData: key, session: session)
        check(empty.isEmpty, "new vault")
        check(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.sealed").path), "empty manifest precedes first file write")
        var items = try await vault.add(pdf: payload, title: "  Private passport  ", category: .passport, session: session)
        let id = items[0].id
        check(items[0].title == "Private passport", "name trimming")
        check(items[0].expiryDay == nil && !items[0].reminders, "no invented expiry/reminder")
        let plain = try await vault.pdf(id, session: session)
        check(plain == payload, "round trip")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        check(files.count == 2, "encrypted index and blob only")
        for url in files {
            let bytes = try Data(contentsOf: url)
            check(bytes.range(of: Data("Private passport".utf8)) == nil && bytes.range(of: Data("SECRET".utf8)) == nil, "no cleartext content or name")
        }
        let retained = try Data(contentsOf: root.appendingPathComponent("index.sealed"))
        await vault.lock()
        await rejects("locked read") { _ = try await vault.pdf(id, session: session) }
        await rejects("wrong key") { _ = try await vault.unlock(keyData: Data(repeating: 0, count: 32), session: session) }
        check(try Data(contentsOf: root.appendingPathComponent("index.sealed")) == retained, "failed unlock retains index")
        let nextSession = UUID()
        items = try await vault.unlock(keyData: key, session: nextSession)
        check(items.count == 1, "reopen persisted index")
        await vault.lock(session: session)
        let stillOpen = try await vault.pdf(id, session: nextSession)
        check(stillOpen == payload, "late old-session lock cannot close new unlock")
        await rejects("stale session write") { _ = try await vault.add(pdf: payload, title: "late import", category: .other, session: session) }
        await rejects("stale session read") { _ = try await vault.pdf(id, session: session) }
        var edited = items[0]; edited.category = .vaccination; edited.pinned = true; edited.expiryDay = "2028-02-29"; edited.reminders = true
        items = try await vault.update(edited, session: nextSession)
        check(items[0].category == .vaccination && items[0].pinned, "vaccination and pin persist")
        edited.expiryDay = "2027-02-29"
        await rejects("invalid expiry") { _ = try await vault.update(edited, session: nextSession) }
        await rejects("empty file") { _ = try await vault.add(pdf: Data(), title: "empty", category: .other, session: nextSession) }
        await rejects("oversized file") { _ = try await vault.add(pdf: Data(count: CrewDocumentVault.maxFileBytes + 1), title: "large", category: .other, session: nextSession) }
        items = try await vault.add(pdf: payload, title: "Medical", category: .medical, session: nextSession)
        let second = items.last!.id
        let firstURL = root.appendingPathComponent(id.uuidString + ".sealed")
        let secondURL = root.appendingPathComponent(second.uuidString + ".sealed")
        let ciphertext = try Data(contentsOf: firstURL)
        let secondCiphertext = try Data(contentsOf: secondURL)
        check(ciphertext != secondCiphertext, "fresh nonce and per-document binding")
        try ciphertext.write(to: secondURL)
        await rejects("ciphertext cannot be swapped between IDs") { _ = try await vault.pdf(second, session: nextSession) }
        var corrupt = ciphertext; corrupt[corrupt.count - 1] ^= 1; try corrupt.write(to: firstURL)
        await rejects("authentication detects tampering") { _ = try await vault.pdf(id, session: nextSession) }
        try ciphertext.write(to: firstURL); try secondCiphertext.write(to: secondURL)
        items = try await vault.remove(second, session: nextSession)
        check(items.count == 1 && !FileManager.default.fileExists(atPath: secondURL.path), "delete removes file/reference")
        let manifest = root.appendingPathComponent("index.sealed")
        let goodIndex = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        await rejects("failed index commit rolls back new blob") { _ = try await vault.add(pdf: payload, title: "Uncommitted", category: .other, session: nextSession) }
        check(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count == 2, "no blob from failed add")
        try FileManager.default.removeItem(at: manifest); try goodIndex.write(to: manifest)
        await vault.lock()
        items = try await vault.unlock(keyData: key, session: UUID())
        check(items.count == 1 && items[0].id == id, "previous state survives failed transaction")
        var brokenIndex = goodIndex; brokenIndex[0] ^= 1; try brokenIndex.write(to: manifest)
        await rejects("corrupt manifest rejected") { _ = try await vault.unlock(keyData: key, session: UUID()) }
        check(try Data(contentsOf: manifest) == brokenIndex, "corrupt manifest never overwritten")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        check(CrewDocumentDates.date("2027-02-29", calendar: calendar) == nil, "reject invalid leap day")
        check(CrewDocumentDates.date("2028-02-29", calendar: calendar) != nil, "accept leap day")
        check(CrewDocumentDates.date("2028-2-29", calendar: calendar) == nil, "strict stored date")
        let now = CrewDocumentDates.date("2026-09-10", calendar: calendar)!
        check(CrewDocumentDates.daysRemaining("2026-09-09", now: now, calendar: calendar) == -1, "expired")
        check(CrewDocumentDates.daysRemaining("2026-09-10", now: now, calendar: calendar) == 0, "expires today")
        check(CrewDocumentDates.reminderDates("2026-09-11", now: now, calendar: calendar).isEmpty, "no past reminder")
        let reminders = CrewDocumentDates.reminderDates("2026-10-20", now: now, calendar: calendar)
        check(reminders.map { CrewDocumentDates.day($0, calendar: calendar) } == ["2026-09-20", "2026-10-13", "2026-10-19"], "30/7/1 day schedule")
        print("Crew Documents: \(checks) checks passed")
    }
}
