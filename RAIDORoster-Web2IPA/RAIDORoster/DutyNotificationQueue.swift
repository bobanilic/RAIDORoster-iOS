import Foundation
import UserNotifications

/// Serialize replacement across Settings and automatic roster refreshes. An
/// earlier write must finish before a newer snapshot replaces its requests.
actor DutyNotificationQueue {
    static let shared = DutyNotificationQueue()
    private var tail: Task<Int, Error>?
    private var revision = UUID()

    func replace(_ requests: [UNNotificationRequest], prefix: String) async throws -> Int {
        let predecessor = tail, token = UUID()
        revision = token
        let work = Task<Int, Error> {
            if let predecessor { _ = try? await predecessor.value }
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
            for request in requests { try await center.add(request) }
            return requests.count
        }
        tail = work
        do {
            let result = try await work.value
            if revision == token { tail = nil }
            return result
        } catch {
            if revision == token { tail = nil }
            throw error
        }
    }
}
