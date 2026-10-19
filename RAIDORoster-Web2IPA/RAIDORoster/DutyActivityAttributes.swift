import ActivityKit
import Foundation

struct DutyActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var pickupAt: Date?
        var referenceAt: Date
        var precautionBegins: Date?
        var referenceLabel: String
        var clock: String
        var zoneID: String
        var savedAt: Date
        var detail: String
        var appearance: String
        var layout: String
        var preview: Bool = false
    }
    var eventID: String
    var scheduledStart: Date
}
