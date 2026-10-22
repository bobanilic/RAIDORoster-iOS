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
        // Optional so cards created by earlier versions remain decodable.
        var countdownStartsAt: Date? = nil
    }
    var eventID: String
    var scheduledStart: Date
}
