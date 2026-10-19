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
    private let log = Logger(subsystem:"com.bobanilic.raidoroster",category:"LockScreen")

    func refresh(events:[TodayPriorityEvent],force:Bool = false) {
        let defaults = UserDefaults.standard
        let plans = LockScreenPolicy.plans(events:events,now:Date(),pickup:defaults.bool(forKey:LockScreenPolicy.pickupKey),
                                           precaution:defaults.bool(forKey:LockScreenPolicy.precautionKey))
        let appearance = defaults.string(forKey:LockScreenPolicy.appearanceKey) ?? "frosted"
        let layout = defaults.string(forKey:LockScreenPolicy.layoutKey) ?? "card"
        let previous = tail
        tail = Task { @MainActor in
            if let previous { await previous.value }
            await self.reconcile(plans,appearance:appearance,layout:layout,force:force)
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
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status = "Live Activities are unavailable or disabled. Check iPhone Settings → RAIDO → Live Activities."
            return
        }
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
            await stopPreview()
            let now = Date(),end = now.addingTimeInterval(5 * 60)
            let state = DutyActivityAttributes.ContentState(pickupAt:end,referenceAt:end,
                precautionBegins:now.addingTimeInterval(-10 * 3600),referenceLabel:"Pickup",clock:end.formatted(date:.omitted,time:.shortened),
                zoneID:TimeZone.current.identifier,savedAt:now,detail:"Sample times",appearance:UserDefaults.standard.string(forKey:LockScreenPolicy.appearanceKey) ?? "frosted",
                layout:UserDefaults.standard.string(forKey:LockScreenPolicy.layoutKey) ?? "card",preview:true)
            do {
                _ = try Activity.request(attributes:DutyActivityAttributes(eventID:"lock-screen-preview",scheduledStart:now),
                    content:ActivityContent(state:state,staleDate:end),pushType:nil)
                status = "Preview started with sample times. Lock your phone to view it; use Stop preview when finished."
            } catch {
                log.error("Live Activity preview failed: \(String(describing:error),privacy:.public)")
                status = "Preview unavailable: " + error.localizedDescription
            }
        }
    }
    func stopPreview() async {
        for activity in Activity<DutyActivityAttributes>.activities where activity.content.state.preview {
            await activity.end(nil,dismissalPolicy:.immediate)
        }
    }
}
