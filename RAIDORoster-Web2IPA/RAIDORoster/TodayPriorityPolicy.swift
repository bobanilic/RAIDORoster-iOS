import Foundation

enum TodayPriorityKind: String, Codable, Hashable { case alcohol, pickup, relocation, transport }

struct TodayPriorityEvent: Identifiable, Equatable {
    let id: String
    let kind: TodayPriorityKind
    let itemID: String
    let title: String
    let detail: String
    let date: Date
    let end: Date
    let hasTime: Bool
    let zoneID: String
    let clock: String
    let capturedAt: Date
    var missing: [String] = []
    var hotelQuery = ""
    var reference = ""
    var notes = ""
    var endClock = ""
}

enum TodayPriorityPolicy {
    static func localDayLabel(_ date: Date, event: TodayPriorityEvent, now: Date) -> String {
        let calendar = Self.calendar(for: event)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "d MMM"
        if calendar.isDate(date, inSameDayAs: now) { return "Today · " + formatter.string(from: date) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow · " + formatter.string(from: date)
        }
        formatter.dateFormat = "EEE, d MMM"
        return formatter.string(from: date)
    }

    static func countdown(to date: Date, now: Date) -> String {
        let minutes = max(0, Int(ceil(date.timeIntervalSince(now) / 60)))
        if minutes == 0 { return "Now" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    static func calendar(for event: TodayPriorityEvent) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: event.zoneID) ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func visible(_ event: TodayPriorityEvent, now: Date) -> Bool {
        guard event.end > now else { return false }
        switch event.kind {
        case .alcohol: return event.date.timeIntervalSince(now) <= 24 * 3600
        case .pickup, .transport: return event.date.timeIntervalSince(now) <= 24 * 3600
        case .relocation:
            let calendar = Self.calendar(for: event)
            let today = calendar.startOfDay(for: now)
            let last = calendar.date(byAdding: .day, value: 8, to: today)!
            return event.date < last
        }
    }

    static func rank(_ event: TodayPriorityEvent, now: Date) -> Int {
        switch event.kind {
        case .pickup where event.date.timeIntervalSince(now) <= 30 * 60: return 0
        case .alcohol where event.date <= now: return 1
        case .relocation where calendar(for: event).isDate(event.date, inSameDayAs: now): return 2
        case .transport: return 3
        case .alcohol: return 4
        case .pickup: return 5
        case .relocation: return 6
        }
    }

    static func ordered(_ events: [TodayPriorityEvent], now: Date) -> [TodayPriorityEvent] {
        var seen = Set<String>()
        return events.filter { visible($0, now: now) && seen.insert($0.id).inserted }.sorted {
            let a = rank($0, now: now), b = rank($1, now: now)
            if a != b { return a < b }
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id < $1.id
        }
    }

    static func status(_ event: TodayPriorityEvent, now: Date) -> String {
        switch event.kind {
        case .alcohol:
            return now < event.date ? "Begins in " + countdown(to: event.date, now: now)
                : "Active · " + countdown(to: event.end, now: now) + " remaining"
        case .pickup:
            return now >= event.date ? "Pickup due" : "In " + countdown(to: event.date, now: now)
        case .transport: return "Pickup time not provided"
        case .relocation:
            let calendar = Self.calendar(for: event)
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: event.date)).day ?? 0
            if days == 0 { return event.hasTime ? "Today · " + (event.date > now ? "in " + countdown(to: event.date, now: now) : "Scheduled time reached") : "Today · Time not provided" }
            if days == 1 { return "Tomorrow" }
            return "In \(days) days"
        }
    }

    static func reminderDates(_ event: TodayPriorityEvent, now: Date, pickupLead: Int,
                              relocationEnabled: Bool, alcoholLead: Int) -> [(String, Date)] {
        var output: [(String, Date)] = []
        switch event.kind {
        case .pickup where pickupLead > 0:
            output.append(("PICKUP-" + event.id, event.date.addingTimeInterval(-Double(pickupLead) * 60)))
        case .alcohol where alcoholLead > 0:
            output.append(("PRECAUTION-" + event.id, event.date.addingTimeInterval(-Double(alcoholLead) * 60)))
        case .relocation where relocationEnabled:
            let calendar = Self.calendar(for: event)
            let day = calendar.startOfDay(for: event.date)
            let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day)!
            let previous = calendar.date(byAdding: .day, value: -1, to: day)!
            output.append(("MOVE-EVE-" + event.id, calendar.date(bySettingHour: 18, minute: 0, second: 0, of: previous)!))
            // A confirmed early move must not receive a later morning reminder.
            let onDay = event.hasTime ? min(morning, event.date.addingTimeInterval(-3600)) : morning
            output.append(("MOVE-DAY-" + event.id, onDay))
        default: break
        }
        return output.filter { $0.1 > now.addingTimeInterval(2) }
    }
}
