import ActivityKit
import Combine
import Foundation
import UIKit
import os

@MainActor
final class LockScreenActivityController: ObservableObject {
    static let shared = LockScreenActivityController()
    @Published private(set) var status = "Enable a Lock Screen option to begin."
    private var tail: Task<Void,Never>?
    private var lastPlans: [DutyLockScreenPlan]?
    private var lastStyle = ""
    private var refreshRevision = UUID()
    private let log = Logger(subsystem:"com.bobanilic.raidoroster",category:"LockScreen")

    var extensionAvailable: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let bundle = Bundle(url:plugins.appendingPathComponent("RAIDODutyWidget.appex")),
              let executable = bundle.executableURL else { return false }
        return FileManager.default.fileExists(atPath:executable.path) &&
            (bundle.infoDictionary?["NSExtension"] as? [String:Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.widgetkit-extension"
    }

    var installationStatus: String {
        extensionAvailable ? "Widget extension is present in this installation." :
            "Widget extension is missing. Import the original IPA into SideStore again and keep app extensions."
    }

    private func canRequestActivity() -> Bool {
        guard extensionAvailable else { status = installationStatus; return false }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status = "Live Activities are disabled. Enable them in iPhone Settings → Apps → RAIDO → Live Activities."
            return false
        }
        return true
    }

    func refresh(events:[TodayPriorityEvent],force:Bool = false) {
        let defaults = UserDefaults.standard
        let plans = LockScreenPolicy.plans(events:events,now:Date(),pickup:defaults.bool(forKey:LockScreenPolicy.pickupKey),
                                           precaution:defaults.bool(forKey:LockScreenPolicy.precautionKey))
        let appearance = defaults.string(forKey:LockScreenPolicy.appearanceKey) ?? "frosted"
        let layout = defaults.string(forKey:LockScreenPolicy.layoutKey) ?? "card"
        let previous = tail
        let revision = UUID(); refreshRevision = revision
        tail = Task { @MainActor in
            if let previous { await previous.value }
            guard self.refreshRevision == revision else { return }
            await self.reconcile(plans,appearance:appearance,layout:layout,force:force)
            if self.refreshRevision == revision { self.tail = nil }
        }
    }

    private func reconcile(_ requested:[DutyLockScreenPlan],appearance:String,layout:String,force:Bool) async {
        guard UIApplication.shared.applicationState == .active else { return }
        let now = Date()
        let plans = requested.filter { $0.referenceAt > now }
        let style = appearance + "|" + layout
        let activities = Activity<DutyActivityAttributes>.activities
        // Ending a changed/deleted/disabled plan comes before any replacement.
        for activity in activities {
            if activity.content.state.preview && activity.content.state.referenceAt > now { continue }
            if !plans.contains(where: { $0.id == activity.attributes.eventID }) {
                await activity.end(nil,dismissalPolicy:.immediate)
            }
        }
        guard !plans.isEmpty else {
            lastPlans = plans;lastStyle = style
            status = "No upcoming pickup or report is available for the selected options."
            return
        }
        guard canRequestActivity() else { return }
        // Do not recreate a card the user dismissed when unchanged data returns.
        if !force && lastPlans == plans && lastStyle == style { return }
        var count = 0
        for plan in plans {
            let state = DutyActivityAttributes.ContentState(pickupAt:plan.pickupAt,referenceAt:plan.referenceAt,
                precautionBegins:plan.precautionBegins,referenceLabel:plan.referenceLabel,clock:plan.clock,
                zoneID:plan.zoneID,savedAt:plan.savedAt,detail:plan.detail,appearance:appearance,layout:layout)
            let content = ActivityContent(state:state,staleDate:plan.referenceAt)
            if let existing = Activity<DutyActivityAttributes>.activities.first(where: { $0.attributes.eventID == plan.id }) {
                await existing.update(content);count += 1
                continue
            }
            do {
                let attributes = DutyActivityAttributes(eventID:plan.id,scheduledStart:max(now,plan.startsAt))
                if plan.startsAt > now {
                    if #available(iOS 26.0, *) {
                        _ = try Activity.request(attributes:attributes,content:content,pushType:nil,style:.standard,
                            alertConfiguration:.init(title:"RAIDO duty countdown",body:LocalizedStringResource(stringLiteral:plan.referenceLabel + " · " + plan.clock + " LT"),sound:.default),
                            start:plan.startsAt)
                    } else {
                        status = "Automatic starts require iOS 26. Open RAIDO within two hours of pickup/report on this iOS version."
                        continue
                    }
                } else {
                    _ = try Activity.request(attributes:attributes,content:content,pushType:nil)
                }
                count += 1
            } catch {
                log.error("Live Activity request failed: \(String(describing:error),privacy:.public)")
                status = "Could not start the Lock Screen card: " + error.localizedDescription
                return
            }
        }
        lastPlans = plans;lastStyle = style
        if count > 0 { status = "\(count) duty countdown\(count == 1 ? "" : "s") ready. Cards begin two hours before pickup/report." }
    }

    func preview() {
        Task { @MainActor in
            guard canRequestActivity() else { return }
            await stopPreview()
            let now = Date(),end = now.addingTimeInterval(5 * 60)
            let state = DutyActivityAttributes.ContentState(pickupAt:end,referenceAt:end,
                precautionBegins:now.addingTimeInterval(-10 * 3600),referenceLabel:"Pickup",clock:end.formatted(date:.omitted,time:.shortened),
                zoneID:TimeZone.current.identifier,savedAt:now,detail:"Sample times",appearance:UserDefaults.standard.string(forKey:LockScreenPolicy.appearanceKey) ?? "frosted",
                layout:UserDefaults.standard.string(forKey:LockScreenPolicy.layoutKey) ?? "card",preview:true)
            do {
                _ = try Activity.request(attributes:DutyActivityAttributes(eventID:"lock-screen-preview",scheduledStart:now),
                    content:ActivityContent(state:state,staleDate:end),pushType:nil)
                status = "Preview requested for five minutes. Lock your phone to check the card. If nothing appears, verify that SideStore kept and registered the widget extension."
            } catch {
                log.error("Live Activity preview failed: \(String(describing:error),privacy:.public)")
                let detail = error as NSError
                status = "Preview unavailable: " + detail.localizedDescription + " (\(detail.domain) \(detail.code))"
            }
        }
    }
    func stopPreview() async {
        for activity in Activity<DutyActivityAttributes>.activities where activity.content.state.preview {
            await activity.end(nil,dismissalPolicy:.immediate)
        }
    }
}
