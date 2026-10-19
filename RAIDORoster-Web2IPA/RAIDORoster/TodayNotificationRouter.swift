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
        let request = notification.request
        guard request.identifier.hasPrefix("RAIDO-ROSTER-") else { completionHandler([]); return }
        // Foreground reminders use a single in-app toast. Background delivery
        // remains the existing iOS notification; no second request is created.
        Task { @MainActor in
            let id = request.content.userInfo["raidoPriorityID"] as? String
            let precaution = request.content.title.localizedCaseInsensitiveContains("precaution")
            RaidoToastCenter.shared.present(.init(title:request.content.title,message:request.content.body,
                symbol:precaution ? "wineglass" : "clock",priorityID:id,precaution:precaution))
            completionHandler([.list,.sound])
        }
    }
}
