import Combine
import UIKit
import UserNotifications

@MainActor
final class TodayNotificationRouter: ObservableObject {
    static let shared = TodayNotificationRouter()
    @Published var pendingID: String?
    func receive(identifier: String, userInfo: [AnyHashable:Any]) {
        guard identifier.hasPrefix("RAIDO-ROSTER-") else { return }
        pendingID = (userInfo["raidoPriorityID"] as? String).flatMap { $0.count <= 500 ? $0 : nil } ?? "today"
    }
}

final class RaidoNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey:Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        Task { @MainActor in
            TodayNotificationRouter.shared.receive(identifier:request.identifier,userInfo:request.content.userInfo)
        }
        completionHandler()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier.hasPrefix("RAIDO-ROSTER-") ? [.banner,.list,.sound] : [])
    }
}
