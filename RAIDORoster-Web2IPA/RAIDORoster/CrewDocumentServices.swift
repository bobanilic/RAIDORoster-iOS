import SwiftUI
import LocalAuthentication
import Security
import CryptoKit
import PDFKit
import VisionKit
import ImageIO
import UserNotifications

enum CrewDocumentKeychain {
    static let service = "RAIDORoster.CrewDocuments.v1"
    static func key(context: LAContext, existingVault: Bool) throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "encryption-key",
            kSecUseAuthenticationContext as String: context, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound, !existingVault else { throw CrewDocumentError.unavailable }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                          .userPresence, &error) else { throw CrewDocumentError.noPasscode }
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "encryption-key",
            kSecAttrAccessControl as String: access, kSecValueData as String: data,
            kSecAttrSynchronizable as String: false]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw CrewDocumentError.unavailable }
        return data
    }
}

enum CrewDocumentImport {
    static func fromURL(_ url: URL) throws -> (Data, String) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= CrewDocumentVault.maxFileBytes else { throw CrewDocumentError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: CrewDocumentVault.maxFileBytes + 1) ?? Data()
        return (try pdf(data), url.deletingPathExtension().lastPathComponent)
    }
    static func pdf(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw CrewDocumentError.invalidFile }
        guard data.count <= CrewDocumentVault.maxFileBytes else { throw CrewDocumentError.tooLarge }
        if data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil {
            guard let document = PDFDocument(data: data) else { throw CrewDocumentError.invalidFile }
            guard !document.isLocked else { throw CrewDocumentError.passwordPDF }
            guard document.pageCount > 0, document.pageCount <= 500 else { throw CrewDocumentError.invalidFile }
            return data
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3000
              ] as CFDictionary) else { throw CrewDocumentError.invalidFile }
        return try images([UIImage(cgImage: image)])
    }
    static func images(_ images: [UIImage]) throws -> Data {
        try renderPages(count: images.count) { images[$0] }
    }
    static func scan(_ scan: VNDocumentCameraScan) throws -> Data {
        try renderPages(count: scan.pageCount) { scan.imageOfPage(at: $0) }
    }
    private static func renderPages(count: Int, imageAt: (Int) -> UIImage) throws -> Data {
        guard count > 0, count <= 20 else { throw CrewDocumentError.invalidFile }
        var invalid = false
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            for index in 0..<count {
                autoreleasepool {
                    let image = imageAt(index)
                    let size = image.size
                    guard size.width > 0, size.height > 0 else { invalid = true; return }
                    let scale = min(1, 2400 / max(size.width, size.height))
                    let target = CGSize(width: size.width * scale, height: size.height * scale)
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                    let normalized = UIGraphicsImageRenderer(size: target, format: format).image { ctx in
                        UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: target))
                        image.draw(in: CGRect(origin: .zero, size: target))
                    }
                    guard let jpeg = normalized.jpegData(compressionQuality: 0.82), let compressed = UIImage(data: jpeg) else { invalid = true; return }
                    let pageScale = 612 / max(size.width, size.height)
                    let page = CGRect(x: 0, y: 0, width: size.width * pageScale, height: size.height * pageScale)
                    context.beginPage(withBounds: page, pageInfo: [:])
                    compressed.draw(in: page)
                }
            }
        }
        guard !invalid, !data.isEmpty else { throw CrewDocumentError.invalidFile }
        guard data.count <= CrewDocumentVault.maxFileBytes else { throw CrewDocumentError.tooLarge }
        return data
    }
}

enum CrewDocumentReminders {
    static let prefix = "RAIDO.CrewDocument."
    static func reconcile(_ documents: [CrewDocument]) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix(prefix) }.map(\.identifier))
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return !documents.contains(where: \.reminders)
        }
        // Leave room for roster reminders and stay below iOS's pending-request limit.
        let available = max(0, 60 - pending.filter { !$0.identifier.hasPrefix(prefix) }.count)
        let plans = documents.filter(\.reminders).flatMap { item -> [(UUID, Date)] in
            guard let day = item.expiryDay else { return [] }
            return CrewDocumentDates.reminderDates(day).map { (item.id, $0) }
        }.sorted { $0.1 < $1.1 }
        var success = plans.count <= available
        for (id, date) in plans.prefix(available) {
            let content = UNMutableNotificationContent()
            content.title = "Crew document reminder"
            content.body = "A saved document is approaching its expiry or renewal date. Open Documents to review it."
            content.sound = .default
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let request = UNNotificationRequest(identifier: prefix + id.uuidString + "." + CrewDocumentDates.day(date),
                content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            do { try await center.add(request) } catch { success = false }
        }
        return success
    }
    static func removeDelivered(_ id: UUID) {
        let center = UNUserNotificationCenter.current()
        Task {
            let delivered = await center.deliveredNotifications()
            center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier).filter { $0.hasPrefix(prefix + id.uuidString + ".") })
        }
    }
}

@MainActor
final class CrewDocumentStore: ObservableObject {
    static let shared = CrewDocumentStore()
    @Published private(set) var documents: [CrewDocument] = []
    @Published private(set) var unlocked = false
    @Published private(set) var busy = false
    @Published private(set) var preview: Data?
    @Published var message: String?
    @Published var reminderNotice: String?
    private let root: URL
    private let vault: CrewDocumentVault
    private var context: LAContext?
    private var generation = UUID()
    var sessionID: UUID { generation }

    private init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrewDocuments-v1", isDirectory: true)
        vault = CrewDocumentVault(root: root)
    }
    func unlock() async {
        guard !busy, !unlocked else { return }
        busy = true; message = nil
        let token = generation
        let auth = LAContext(); context = auth
        auth.localizedCancelTitle = "Cancel"
        defer { if token == generation { busy = false } }
        do {
            var error: NSError?
            guard auth.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { throw CrewDocumentError.noPasscode }
            guard try await auth.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Open your private crew documents.") else { return }
            guard token == generation else { return }
            let exists: Bool
            if FileManager.default.fileExists(atPath: root.path) {
                exists = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).contains { $0.pathExtension == "sealed" }
            } else { exists = false }
            let data = try await Task.detached { try CrewDocumentKeychain.key(context: auth, existingVault: exists) }.value
            guard token == generation else { return }
            let items = try await vault.unlock(keyData: data, session: token)
            guard token == generation else { await vault.lock(session: token); return }
            documents = items; unlocked = true
            await refreshReminders(items, token: token)
        } catch {
            if token == generation {
                if let la = error as? LAError, [.userCancel, .appCancel, .systemCancel].contains(la.code) { return }
                message = (error as? CrewDocumentError)?.localizedDescription ?? CrewDocumentError.unavailable.localizedDescription
            }
        }
    }
    func lock() {
        let prior = generation
        generation = UUID(); context?.invalidate(); context = nil
        unlocked = false; busy = false; documents = []; preview = nil; message = nil; reminderNotice = nil
        Task { await vault.lock(session: prior) }
    }
    func importURL(_ url: URL, category: CrewDocumentCategory) async {
        await perform { token in
            let value = try await Task.detached { try CrewDocumentImport.fromURL(url) }.value
            guard token == self.generation, self.unlocked else { throw CrewDocumentError.locked }
            return try await self.vault.add(pdf: value.0, title: value.1, category: category, session: token)
        }
    }
    func importData(_ data: Data, title: String, category: CrewDocumentCategory) async {
        await perform { token in
            let pdf = try await Task.detached { try CrewDocumentImport.pdf(data) }.value
            guard token == self.generation, self.unlocked else { throw CrewDocumentError.locked }
            return try await self.vault.add(pdf: pdf, title: title, category: category, session: token)
        }
    }
    func update(_ document: CrewDocument) async {
        await perform { token in
            guard token == self.generation, self.unlocked else { throw CrewDocumentError.locked }
            return try await self.vault.update(document, session: token)
        }
    }
    func remove(_ id: UUID) async {
        await perform { token in
            guard token == self.generation, self.unlocked else { throw CrewDocumentError.locked }
            return try await self.vault.remove(id, session: token)
        }
        if !documents.contains(where: { $0.id == id }) { CrewDocumentReminders.removeDelivered(id) }
    }
    func open(_ id: UUID) async {
        guard unlocked, !busy else { return }
        busy = true; preview = nil
        let token = generation
        defer { if token == generation { busy = false } }
        do {
            guard token == generation, unlocked else { throw CrewDocumentError.locked }
            let data = try await vault.pdf(id, session: token)
            guard token == generation, unlocked else { return }
            preview = data
        } catch {
            if token == generation { message = CrewDocumentError.unavailable.localizedDescription }
        }
    }
    func clearPreview() { preview = nil }
    private func perform(_ operation: (UUID) async throws -> [CrewDocument]) async {
        guard unlocked, !busy else { return }
        busy = true; message = nil
        let token = generation
        defer { if token == generation { busy = false } }
        do {
            let items = try await operation(token)
            guard token == generation, unlocked else { return }
            documents = items
            await refreshReminders(items, token: token)
        } catch {
            if token == generation { message = (error as? CrewDocumentError)?.localizedDescription ?? "The change could not be saved. Please try again." }
        }
    }
    private func refreshReminders(_ items: [CrewDocument], token: UUID) async {
        let ok = await CrewDocumentReminders.reconcile(items)
        guard token == generation else { return }
        reminderNotice = ok ? nil : "Some reminders could not be scheduled. Check notification permission and review dates in Documents."
    }
}

// Cover every presented document sheet before iOS captures the app switcher.
@MainActor
final class CrewDocumentPrivacyShield {
    static let shared = CrewDocumentPrivacyShield()
    private var window: UIWindow?
    func cover() {
        guard window == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.isUserInteractionEnabled = false
        let controller = UIViewController()
        controller.view.backgroundColor = MidnightTheme.backgroundUI
        let label = UILabel(); label.text = "Documents locked"; label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .headline); label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor), label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)])
        window.rootViewController = controller; window.isHidden = false
        self.window = window
    }
    func uncover() { window?.isHidden = true; window = nil }
}
