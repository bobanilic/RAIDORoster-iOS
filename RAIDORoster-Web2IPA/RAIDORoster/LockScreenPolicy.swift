import Foundation

struct DutyLockScreenPlan: Equatable {
    let id: String
    let pickupAt: Date?
    let referenceAt: Date
    let precautionBegins: Date?
    let referenceLabel: String
    let clock: String
    let zoneID: String
    let savedAt: Date
    let detail: String
    var startsAt: Date { referenceAt.addingTimeInterval(-2 * 3600) }
}

enum LockScreenPolicy {
    static let pickupKey = "RAIDORoster.LockScreen.Pickup"
    static let precautionKey = "RAIDORoster.LockScreen.Precaution"
    static let appearanceKey = "RAIDORoster.LockScreen.Appearance"
    static let layoutKey = "RAIDORoster.LockScreen.Layout"

    /// Only real roster dates qualify; no polling or synthetic pickup times.
    static func plans(events: [TodayPriorityEvent], now: Date, pickup: Bool, precaution: Bool) -> [DutyLockScreenPlan] {
        let future = events.filter { $0.end > now }
        var plans: [DutyLockScreenPlan] = []
        if pickup {
            for event in future where event.kind == .pickup && event.date > now && event.date.timeIntervalSince(now) <= 7 * 86400 {
                let alcohol = precaution ? future.first { $0.kind == .alcohol && $0.itemID == event.itemID } : nil
                plans.append(.init(id:event.id,pickupAt:event.date,referenceAt:event.date,
                    precautionBegins:alcohol?.date,referenceLabel:"Pickup",clock:event.clock,zoneID:event.zoneID,
                    savedAt:event.capturedAt,detail:event.detail))
            }
        }
        if precaution {
            for event in future where event.kind == .alcohol && event.end > now && event.end.timeIntervalSince(now) <= 7 * 86400 {
                if plans.contains(where: { $0.referenceAt == event.end }) { continue }
                plans.append(.init(id:event.id,pickupAt:nil,referenceAt:event.end,precautionBegins:event.date,
                    referenceLabel:event.reference == "PU" ? "Pickup" : "Report",clock:event.clock,zoneID:event.zoneID,
                    savedAt:event.capturedAt,detail:"Pre-duty precaution"))
            }
        }
        var seen = Set<String>()
        return Array(plans.sorted { $0.referenceAt < $1.referenceAt }.filter { seen.insert($0.id).inserted }.prefix(2))
    }

    static func showFutureRelocations(todayCategories: [String]) -> Bool {
        let categories = Set(todayCategories.map { $0.uppercased() })
        return !categories.isEmpty && categories.isSubset(of:["OFF","STANDBY","RESERVE","REST","DND","VACATION","LEAVE"])
    }

    static func cleanLogisticsNote(_ note: String) -> String {
        // A collapsed next hotel row can leak into the final Activity Note.
        // Match the whole structured suffix, never arbitrary prose containing HTL.
        let pattern = #"\s+HTL\s+(?:[0-2][0-9][0-5][0-9]|[0-3]?[0-9][A-Z]{3}(?:[0-9]{2})?)\s+[A-Z]{3}\s+[A-Z]{3}\s+(?:[0-2][0-9][0-5][0-9]|[0-3]?[0-9][A-Z]{3}(?:[0-9]{2})?)\s+(?:BKD|OPT|CNL)\s*$"#
        return note.replacingOccurrences(of:pattern,with:"",options:[.regularExpression,.caseInsensitive])
            .trimmingCharacters(in:.whitespacesAndNewlines)
    }
}
