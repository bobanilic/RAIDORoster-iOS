import SwiftUI
import UIKit

@MainActor
extension RosterStore {
    /// Choose one authoritative snapshot per month, independently of the month
    /// selected in Roster. A superseded snapshot must not restore a deleted move.
    var priorityRosterSources: [(item: RosterItem, capturedAt: Date)] {
        let snapshots = (Array(monthSnapshots.values) + (snapshot.map { [$0] } ?? []))
            .filter { $0.validation?.isValid == true }.sorted { $0.capturedAt > $1.capturedAt }
        var months = Set<String>()
        var result: [(RosterItem, Date)] = []
        for snapshot in snapshots {
            guard let month = snapshot.validation?.month, months.insert(month).inserted else { continue }
            result += snapshot.items.filter { $0.dateISO?.hasPrefix(month + "-") == true }.map { ($0, snapshot.capturedAt) }
        }
        return result
    }

    var priorityRosterItems: [RosterItem] { priorityRosterSources.map(\.item) }

    func priorityEvents(at now: Date) -> [TodayPriorityEvent] {
        var events: [TodayPriorityEvent] = []
        let lower = EarningsMath.day(now.addingTimeInterval(-2 * 24 * 3600))
        let upper = EarningsMath.day(now.addingTimeInterval(10 * 24 * 3600))
        for source in priorityRosterSources where (source.item.dateISO ?? "") >= lower && (source.item.dateISO ?? "") <= upper {
            events += TodayPriorityAdapter.events(item: source.item, capturedAt: source.capturedAt)
        }
        // Show the next pre-duty precaution, rather than stacking every shift.
        let nextAlcohol = events.filter { $0.kind == .alcohol && $0.end > now }.min { $0.end < $1.end }?.id
        events.removeAll { $0.kind == .alcohol && $0.id != nextAlcohol }
        return TodayPriorityPolicy.ordered(events, now: now)
    }

    func priorityItem(id: String) -> RosterItem? { priorityRosterItems.first { $0.id == id } }
}

enum TodayPriorityAdapter {
    static func zone(activity: RosterActivity?, item: RosterItem) -> TimeZone? {
        let activities = (activity.map { [$0] } ?? []) + item.operationalActivities + item.hotelAssignments
        for candidate in activities {
            for code in [candidate.station] + TodayGlobalAirportIndex.routeCodes(candidate.route) {
                if let zone = IceAirportClock.zone(for: code.uppercased()) { return zone }
            }
        }
        for candidate in activities {
            for pair in [(candidate.checkInLT, candidate.checkInUTC), (candidate.startLT, candidate.startUTC)] {
                if let nominal = parseUTCStamp(pair.0), let actual = parseUTCStamp(pair.1),
                   abs(nominal.timeIntervalSince(actual)) <= 14 * 3600 {
                    return TimeZone(secondsFromGMT: Int(nominal.timeIntervalSince(actual)))
                }
            }
        }
        return nil
    }

    static func clock(_ date: Date, zone: TimeZone?) -> String {
        guard let zone else { return "Time zone unconfirmed" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = zone; formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func day(_ key: String?, zone: TimeZone) -> Date? {
        guard let key else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone; formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter.date(from: key)
    }

    static func events(item: RosterItem, capturedAt: Date) -> [TodayPriorityEvent] {
        var events: [TodayPriorityEvent] = []
        let baseZone = zone(activity: nil, item: item)
        let fallbackZone = baseZone ?? TimeZone(secondsFromGMT: 0)!
        let dutyCalendar = calendar(fallbackZone)
        let baseDay = day(item.dateISO, zone: fallbackZone)
        let primary = item.preDutyPickupUTCDate ?? item.dutyStartUTCDate
        if item.isOperationalDuty, !item.operationalActivities.isEmpty, let primary {
            events.append(.init(id: "precaution-" + item.id, kind: .alcohol, itemID: item.id,
                title: "Alcohol precaution", detail: "Pre-duty precaution · based on " + (item.preDutyPickupUTCDate != nil ? "pickup" : "report"),
                date: primary.addingTimeInterval(-12 * 3600), end: primary, hasTime: true,
                zoneID: fallbackZone.identifier, clock: clock(primary, zone: baseZone), capturedAt: capturedAt,
                reference: item.preDutyPickupUTCDate != nil ? "PU" : "CI"))
        }
        var pickupDates = Set<Date>()
        for activity in item.activityList where !activity.pickup.isEmpty {
            guard let date = pickupUTCDate(for: activity), pickupDates.insert(date).inserted else { continue }
            let pickupZone = zone(activity: activity, item: item) ?? baseZone
            var end = date.addingTimeInterval(3600)
            if date == item.preDutyPickupUTCDate,
               let first = item.operationalActivities.first(where: { ["FLIGHT","POSITIONING"].contains($0.category.uppercased()) }),
               let report = parseUTCStamp(first.checkInUTC), report > date { end = min(end, report) }
            events.append(.init(id: "pickup-\(Int(date.timeIntervalSince1970))", kind: .pickup, itemID: item.id,
                title: "Crew pickup", detail: activity.route.isEmpty ? activity.title : activity.route,
                date: date, end: end, hasTime: true, zoneID: (pickupZone ?? fallbackZone).identifier,
                clock: clock(date, zone: pickupZone), capturedAt: capturedAt))
        }
        for activity in item.activityList where activity.category.uppercased() == "RELOCATION" {
            let moveZone = zone(activity: activity, item: item)
            let moveCalendar = calendar(moveZone ?? fallbackZone)
            let stamp = parseUTCStamp(activity.startUTC)
            let finish = parseUTCStamp(activity.endUTC)
            let allDay = (finish?.timeIntervalSince(stamp ?? .distantFuture) ?? 0) >= 23 * 3600 ||
                (activity.localStartTime == "00:00" && activity.localEndTime == "23:59")
            let timed = stamp != nil && !allDay
            let localDay = day(activity.startLT.isEmpty ? item.dateISO : String(activity.startLT.prefix(10)), zone: moveZone ?? fallbackZone) ?? baseDay
            guard let date = timed ? stamp : (localDay ?? stamp) else { continue }
            let dateEnd = moveCalendar.date(byAdding: .day, value: 1, to: moveCalendar.startOfDay(for: date))!
            let end = timed ? max(finish ?? date.addingTimeInterval(3600), date.addingTimeInterval(3600)) : dateEnd
            let hotelNames = ([activity.hotelName] + item.hotelAssignments.map(\.hotelName))
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !["-","–","N/A"].contains($0.uppercased()) }
            let hotels = NSOrderedSet(array: hotelNames).array as? [String] ?? []
            let detail = hotels.isEmpty ? "Hotel relocation" : hotels.joined(separator: " · ")
            var missing = [String]()
            if !timed { missing.append("Relocation time not provided") }
            if hotels.isEmpty { missing.append("Hotel details not provided") }
            if activity.pickup.isEmpty && activity.transferNote.isEmpty { missing.append("Transport details not provided") }
            events.append(.init(id: "relocation-" + activity.id, kind: .relocation, itemID: item.id,
                title: "Hotel relocation", detail: detail, date: date, end: end, hasTime: timed,
                zoneID: (moveZone ?? fallbackZone).identifier, clock: timed ? clock(date, zone: moveZone) : "Time not provided",
                capturedAt: capturedAt, missing: missing,
                hotelQuery: hotels.last.map { $0 + " " + (TodayGlobalAirportIndex.point(for: activity.station)?.name ?? activity.station) } ?? ""))
        }
        let transportText = (item.transferNotes + item.activityList.map(\.pickup)).joined(separator: " ")
        let explicitTransport = item.activityList.contains { !$0.pickup.isEmpty } || transportText.range(of: #"\b(pickup|pick.up|PU\s+at|transport arranged|transfer arranged|shuttle)\b"#, options: .caseInsensitive) != nil
        let ownTransport = transportText.range(of: #"\b(no (pickup|transport|transfer)|own transport|self.transfer)\b"#, options: .caseInsensitive) != nil
        if item.isOperationalDuty, !item.operationalActivities.isEmpty, pickupDates.isEmpty,
           explicitTransport, !ownTransport, let date = item.dutyStartUTCDate {
            events.append(.init(id: "transport-" + item.id, kind: .transport, itemID: item.id,
                title: "Transport details to check", detail: transportText, date: date,
                end: item.dutyEndUTCDate ?? dutyCalendar.date(byAdding: .day, value: 1, to: date)!, hasTime: false,
                zoneID: fallbackZone.identifier, clock: "Pickup time not confirmed", capturedAt: capturedAt,
                missing: ["Pickup time not confirmed"]))
        }
        return events
    }

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone; return calendar
    }
}

struct TodayPriorityPanel: View {
    let events: [TodayPriorityEvent]
    let now: Date
    let select: (TodayPriorityEvent) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.raidoPalette) private var palette
    @Environment(\.raidoTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !events.isEmpty {
                HStack {
                    Text("Your priorities").font(.headline)
                    Spacer()
                    Text("ROSTER LOCAL TIMES").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }.padding(.bottom, 2)
            }
            ForEach(events) { event in
                Button { select(event) } label: { card(event) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("today-priority-" + event.kind.rawValue)
            }
        }.id("today-priorities")
    }

    private func card(_ event: TodayPriorityEvent) -> some View {
        let activeAlcohol = event.kind == .alcohol && event.date <= now
        let urgent = TodayPriorityPolicy.rank(event, now: now) <= 2
        let color: Color = event.kind == .alcohol ? (colorScheme == .dark ? Color(red:1,green:0.69,blue:0.66) : Color(red:0.60,green:0.13,blue:0.18)) : MidnightTheme.accent
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(event.kind)).font(.system(size: event.kind == .alcohol ? 25 : 20, weight: .light))
                .frame(width: 28).padding(.top, 4)
            VStack(alignment: .leading, spacing: 5) {
                Text(event.title).font(event.kind == .alcohol ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                Text(TodayPriorityPolicy.status(event, now: now)).font(event.kind == .alcohol ? .title2.weight(.semibold) : .title3.weight(.semibold)).monospacedDigit()
                Text(schedule(event)).font(.caption).foregroundStyle(.secondary)
                if event.kind == .relocation { Text(event.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if !event.missing.isEmpty {
                    Label("Details to check", systemImage: "exclamationmark.circle").font(.caption.weight(.medium))
                }
                if now.timeIntervalSince(event.capturedAt) >= 24 * 3600 {
                    Label("Saved roster · Check for changes", systemImage: "clock.arrow.circlepath").font(.caption2).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).padding(.top, 5)
        }
        .foregroundStyle(color)
        .padding(event.kind == .alcohol ? 18 : 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(event, active: activeAlcohol), in: RoundedRectangle(cornerRadius: MidnightTheme.isGetJet ? 22 : 18))
        .overlay(RoundedRectangle(cornerRadius: MidnightTheme.isGetJet ? 22 : 18).stroke(color.opacity(urgent ? 0.25 : 0.10), lineWidth: 1))
    }
    private func background(_ event: TodayPriorityEvent, active: Bool) -> Color {
        if event.kind == .alcohol {
            return colorScheme == .dark ? Color(red:0.21,green:0.13,blue:0.15) : Color(red:0.99,green:0.95,blue:0.93)
        }
        return MidnightTheme.surface
    }
    private func icon(_ kind: TodayPriorityKind) -> String {
        switch kind { case .alcohol: return "wineglass"; case .pickup: return "car.side"; case .relocation: return "building.2"; case .transport: return "questionmark.circle" }
    }
    private func schedule(_ event: TodayPriorityEvent) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TodayPriorityPolicy.calendar(for:event).timeZone; formatter.dateFormat = "d MMM"
        if event.kind == .alcohol { return "Until \(event.clock) · \(event.reference)" }
        return formatter.string(from: event.date) + " · " + event.clock + (event.hasTime ? " LT" : "")
    }
}

struct TodayPriorityStrip: View {
    let events: [TodayPriorityEvent]
    let now: Date
    let select: (TodayPriorityEvent) -> Void
    @Environment(\.raidoPalette) private var palette
    @Environment(\.raidoTheme) private var theme
    var body: some View {
        let pickup = events.first { $0.kind == .pickup }
        let alcohol = events.first { $0.kind == .alcohol }
        if pickup != nil || alcohol != nil {
            HStack(spacing: 12) {
                if let pickup {
                    Button { select(pickup) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(pickup.date <= now ? "PU due" : "PU in " + TodayPriorityPolicy.countdown(to: pickup.date, now: now), systemImage: "car.side")
                                .font(.subheadline.weight(.semibold)).monospacedDigit()
                            Text(pickup.clock + " LT").font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(pickup.date.timeIntervalSince(now) <= 15 * 60 ? MidnightTheme.warningInk : MidnightTheme.accent)
                    }.accessibilityIdentifier("today-pickup-countdown")
                }
                if pickup != nil && alcohol != nil { Divider().frame(height: 32) }
                if let alcohol {
                    Button { select(alcohol) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(alcohol.date <= now ? "Precaution active" : "Precaution upcoming", systemImage: "wineglass")
                                .font(.caption.weight(.semibold))
                            Text(alcohol.date <= now ? "Until " + alcohol.clock : "In " + TodayPriorityPolicy.countdown(to: alcohol.date, now: now))
                                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.accessibilityIdentifier("today-alcohol-status")
                }
            }.buttonStyle(.plain).foregroundStyle(MidnightTheme.accent)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.regularMaterial)
                .overlay(alignment: .top) { Rectangle().fill(MidnightTheme.accent.opacity(0.15)).frame(height: 0.5) }
        }
    }
}

struct TodayPriorityDetails: View {
    let event: TodayPriorityEvent
    @ObservedObject var store: RosterStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TimelineView(.everyMinute) { context in
                        Text(TodayPriorityPolicy.status(event, now: context.date)).font(.title2.bold()).monospacedDigit()
                    }
                    Text(dateLabel)
                        .font(.subheadline).foregroundStyle(.secondary)
                    LabeledContent(event.kind == .alcohol ? "Until " + event.reference : "Scheduled time", value: event.clock)
                    Text(event.detail).font(.body).textSelection(.enabled)
                    ForEach(event.missing, id: \.self) { text in
                        Label(text, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(MidnightTheme.warningInk)
                    }
                    if event.kind == .alcohol {
                        Text("Pre-duty reminder: 12 hours before rostered pickup, or report when no pickup is supplied. Duty restrictions and company policy still apply.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !event.hotelQuery.isEmpty {
                        Button("Find hotel in Maps", systemImage: "map") { openHotel() }
                            .frame(minHeight: 44)
                    }
                    if let item = store.priorityItem(id: event.itemID) {
                        NavigationLink("Crew Control") { CrewControlSheet(item:item) }
                        NavigationLink("Full briefing & notes") { RosterDetailView(item:item) }
                    }
                    Text("Saved " + event.capturedAt.formatted(date:.abbreviated,time:.shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.midnightCanvas().navigationTitle(event.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private var dateLabel: String {
        let formatter = DateFormatter(); formatter.locale = .current
        formatter.timeZone = TodayPriorityPolicy.calendar(for: event).timeZone
        formatter.dateStyle = .long; formatter.timeStyle = .none
        return formatter.string(from: event.date)
    }
    private func openHotel() {
        var url = URLComponents(string:"https://maps.apple.com/")!
        url.queryItems = [URLQueryItem(name:"q",value:event.hotelQuery)]
        if let url = url.url { openURL(url) }
    }
}
