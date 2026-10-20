import SwiftUI
import UIKit

@MainActor
extension RosterStore {
    /// Choose one authoritative snapshot per month, independently of the month
    /// selected in Roster. A superseded snapshot must not restore a deleted move.
    var priorityRosterSources: [(item: RosterItem, capturedAt: Date)] {
        prioritySources(from:nil,through:nil)
    }

    func prioritySources(from lower: String?, through upper: String?) -> [(item: RosterItem, capturedAt: Date)] {
        let snapshots = (Array(monthSnapshots.values) + (snapshot.map { [$0] } ?? []))
            .filter { $0.validation?.isValid == true }.sorted { $0.capturedAt > $1.capturedAt }
        var months = Set<String>()
        var result: [(RosterItem, Date)] = []
        for snapshot in snapshots {
            guard let month = snapshot.validation?.month, months.insert(month).inserted else { continue }
            if let lower, month < String(lower.prefix(7)) { continue }
            if let upper, month > String(upper.prefix(7)) { continue }
            result += snapshot.items.filter {
                guard let day = $0.dateISO, day.hasPrefix(month + "-") else { return false }
                return (lower.map { day >= $0 } ?? true) && (upper.map { day <= $0 } ?? true)
            }.map { ($0, snapshot.capturedAt) }
        }
        return result
    }

    var priorityRosterItems: [RosterItem] { priorityRosterSources.map(\.item) }

    func priorityEventCandidates(at now: Date) -> [TodayPriorityEvent] {
        let lower = EarningsMath.day(now.addingTimeInterval(-2 * 24 * 3600))
        let upper = EarningsMath.day(now.addingTimeInterval(10 * 24 * 3600))
        let zone = TimeZone.current.identifier
        if let cache = priorityEventCache, cache.lower == lower, cache.upper == upper, cache.zone == zone {
            return cache.events
        }
        let events = TodayPriorityAdapter.events(sources: prioritySources(from:lower,through:upper))
        priorityEventCache = (lower,upper,zone,events)
        return events
    }

    func priorityEvents(at now: Date) -> [TodayPriorityEvent] {
        var events = priorityEventCandidates(at:now)
        // Show the next pre-duty precaution, rather than stacking every shift.
        let nextAlcohol = events.filter { $0.kind == .alcohol && $0.end > now }.min { $0.end < $1.end }?.id
        events.removeAll { $0.kind == .alcohol && $0.id != nextAlcohol }
        return TodayPriorityPolicy.ordered(events, now: now)
    }

    func alcoholPrecautionEvent(for item: RosterItem, at now: Date) -> TodayPriorityEvent? {
        priorityEvents(at: now).first { $0.kind == .alcohol && $0.itemID == item.id }
    }

    func todayPriorityEvents(at now: Date) -> [TodayPriorityEvent] {
        let lower = EarningsMath.day(now.addingTimeInterval(-2 * 24 * 3600))
        let upper = EarningsMath.day(now.addingTimeInterval(2 * 24 * 3600))
        let rows = prioritySources(from:lower,through:upper).map(\.item).filter { item in
            let zone = TodayPriorityAdapter.zone(activity:nil,item:item) ?? .current
            var calendar = Calendar(identifier:.gregorian);calendar.timeZone = zone
            if let day = TodayPriorityAdapter.day(item.dateISO,zone:zone), calendar.isDate(day,inSameDayAs:now) { return true }
            return item.operationalActivities.contains { activity in
                guard ["FLIGHT","POSITIONING"].contains(activity.category.uppercased()),
                      let start = parseUTCStamp(activity.startUTC),let end = parseUTCStamp(activity.endUTC) else { return false }
                return start <= now && now < end
            }
        }
        let categories = rows.flatMap { item in
            let operational = item.operationalActivities.map(\.category)
            return operational.isEmpty ? [item.category] : operational
        }
        let allowFuture = LockScreenPolicy.showFutureRelocations(todayCategories:categories)
        return priorityEvents(at:now).filter { event in
            event.kind != .relocation || allowFuture || TodayPriorityPolicy.calendar(for:event).isDate(event.date,inSameDayAs:now)
        }
    }

    func priorityItem(id: String) -> RosterItem? { priorityRosterItems.first { $0.id == id } }
}

enum TodayPriorityAdapter {
    static func events(sources: [(item: RosterItem, capturedAt: Date)]) -> [TodayPriorityEvent] {
        let events = sources.flatMap { Self.events(item: $0.item, capturedAt: $0.capturedAt) }
        let duties = sources.compactMap { source -> PrecautionDutyWindow? in
            let item = source.item
            guard item.isOperationalDuty, !item.operationalActivities.isEmpty,
                  let start = item.dutyStartUTCDate,
                  let reference = item.preDutyPickupUTCDate ?? item.dutyStartUTCDate else { return nil }
            return .init(itemID: item.id, dayKey: item.dateISO ?? item.id, reference: reference,
                         start: start, end: max(start, item.dutyEndUTCDate ?? start))
        }
        return TodayPriorityPolicy.preparePrecautions(events, duties: duties)
    }

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
        for activity in item.relocationActivities {
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
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !["-","–","N/A","RELOCATION","HOTEL RELOCATION"].contains($0.uppercased()) }
            let hotels = NSOrderedSet(array: hotelNames).array as? [String] ?? []
            let detail = hotels.isEmpty ? "Hotel relocation" : hotels.joined(separator: " · ")
            var missing = [String]()
            if !timed { missing.append("Relocation time not provided") }
            if hotels.isEmpty { missing.append("Hotel details not provided") }
            let noteValues = [activity.transferNote,activity.activityNote,activity.dayNote].map(LockScreenPolicy.cleanLogisticsNote).filter { !$0.isEmpty }
            let notes = (NSOrderedSet(array: noteValues).array as? [String] ?? []).joined(separator: "\n\n")
            let transportProvided = !activity.pickup.isEmpty || !activity.transferNote.isEmpty || notes.range(of: #"\b(bolt|uber|taxi|transfer|transport|shuttle|pickup|pick.up)\b"#, options: [.regularExpression,.caseInsensitive]) != nil
            if !transportProvided { missing.append("Transport details not provided") }
            events.append(.init(id: "relocation-" + activity.id, kind: .relocation, itemID: item.id,
                title: "Hotel relocation", detail: detail, date: date, end: end, hasTime: timed,
                zoneID: (moveZone ?? fallbackZone).identifier, clock: timed ? clock(date, zone: moveZone) : "Time not provided",
                capturedAt: capturedAt, missing: missing,
                hotelQuery: hotels.last.map { $0 + " " + (TodayGlobalAirportIndex.point(for: activity.station)?.name ?? activity.station) } ?? "",
                notes: notes, endClock: timed ? finish.map { clock($0, zone: moveZone) } ?? "" : ""))
        }
        let transportText = (item.transferNotes + item.activityList.map(\.pickup)).joined(separator: " ")
        let explicitTransport = item.activityList.contains { !$0.pickup.isEmpty } || transportText.range(of: #"\b(pickup|pick.up|PU\s+at|transport arranged|transfer arranged|shuttle)\b"#, options: [.regularExpression,.caseInsensitive]) != nil
        let ownTransport = transportText.range(of: #"\b(no (pickup|transport|transfer)|own transport|self.transfer)\b"#, options: [.regularExpression,.caseInsensitive]) != nil
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

// Countdown ticks invalidate only these small leaves. The cached briefing,
// NavigationStack, scroll position and route map live outside the timeline.
struct TodayPriorityLiveContent: View {
    @ObservedObject var store: RosterStore
    let tabActive: Bool
    var strip = false
    let select: (TodayPriorityEvent) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var foregroundDate = Date.distantPast

    var body: some View {
        if tabActive && scenePhase == .active {
            TimelineView(.everyMinute) { context in
                let now = max(context.date, foregroundDate)
                let events = store.todayPriorityEvents(at: now)
                if strip {
                    TodayPriorityStrip(events: events, now: now, select: select)
                } else {
                    TodayPriorityPanel(events: panelEvents(events), now: now, select: select)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                foregroundDate = Date()
            }
        }
    }

    private func panelEvents(_ events: [TodayPriorityEvent]) -> [TodayPriorityEvent] {
        var counts: [TodayPriorityKind: Int] = [:]
        return events.filter { event in
            let limit = event.kind == .relocation ? 2 : 1
            let count = counts[event.kind, default: 0]
            counts[event.kind] = count + 1
            return count < limit
        }
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
        let _ = palette
        let _ = theme
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
                if event.kind == .alcohol {
                    HStack {
                        Text(event.title).font(.headline)
                        Spacer(minLength:4)
                        Text(activeAlcohol ? "ACTIVE" : "UPCOMING").font(.system(size:8,weight:.bold)).tracking(0.8)
                            .padding(.horizontal,7).padding(.vertical,4).background(color.opacity(0.10),in:Capsule())
                    }
                    HStack(alignment:.firstTextBaseline,spacing:7) {
                        Text(TodayPriorityPolicy.countdown(to:activeAlcohol ? event.end : event.date,now:now))
                            .font(.system(.title,design:.rounded).weight(.semibold)).monospacedDigit()
                        Text(activeAlcohol ? "remaining" : "until precaution").font(.caption)
                    }
                } else {
                    Text(event.title).font(.subheadline.weight(.semibold))
                    Text(TodayPriorityPolicy.status(event, now: now)).font(.title3.weight(.semibold)).monospacedDigit()
                }
                Text(schedule(event)).font(.caption).foregroundStyle(.secondary)
                if event.kind == .relocation { Text(event.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if event.kind == .relocation && !event.notes.isEmpty { Text(event.notes).font(.caption).lineLimit(2) }
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
        if event.kind == .alcohol { return (event.reference == "PU" ? "Pickup · " : "Report · ") + TodayPriorityPolicy.localDayLabel(event.end, event: event, now: now) + " · " + event.clock + " LT" }
        return formatter.string(from: event.date) + " · " + event.clock + (event.hasTime ? " LT" : "")
    }
}

struct TodayPriorityStrip: View {
    let events: [TodayPriorityEvent]
    let now: Date
    let select: (TodayPriorityEvent) -> Void
    var body: some View {
        if let pickup = events.first(where: { $0.kind == .pickup }) {
            Button { select(pickup) } label: {
                HStack {
                    Label(pickup.date <= now ? "PU due" : "PU in " + TodayPriorityPolicy.countdown(to:pickup.date,now:now),systemImage:"car.side")
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                    Spacer()
                    Text(pickup.clock + " LT").font(.caption)
                }.foregroundStyle(MidnightTheme.accent).padding(.horizontal,18).padding(.vertical,12)
                    .background(.regularMaterial)
            }.buttonStyle(.plain).accessibilityIdentifier("today-pickup-countdown")
        }
    }
}

struct RosterChangeSummaryCard: View {
    @ObservedObject var store: RosterStore
    var body: some View {
        if !store.latestChanges.isEmpty {
            NavigationLink { RosterChangesView(changes:store.latestChanges) } label: {
                HStack(spacing:12) {
                    Image(systemName:"calendar.badge.exclamationmark").font(.title3)
                    VStack(alignment:.leading,spacing:3) {
                        Text("Roster updated").font(.headline)
                        Text("\(store.latestChanges.count) changed day\(store.latestChanges.count == 1 ? "" : "s") · Review changes")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                    Image(systemName:"chevron.right").font(.caption.weight(.semibold))
                }.foregroundStyle(MidnightTheme.accent).padding(15).midnightCard(radius:18)
            }.buttonStyle(.plain).accessibilityIdentifier("today-roster-changes")
        }
    }
}

struct RosterRelocationSection: View {
    let items: [RosterItem]
    @EnvironmentObject private var store: RosterStore
    @Environment(\.raidoPalette) private var palette
    @Environment(\.raidoTheme) private var theme
    @State private var selected: TodayPriorityEvent?
    private var events: [TodayPriorityEvent] {
        var seen = Set<String>()
        return items.flatMap { item in
            TodayPriorityAdapter.events(item:item,capturedAt:store.monthSnapshots[String((item.dateISO ?? "").prefix(7))]?.capturedAt ?? .distantPast)
        }.filter { $0.kind == .relocation && seen.insert($0.id).inserted }.sorted { $0.date < $1.date }
    }
    var body: some View {
        let _ = palette
        let _ = theme
        ForEach(events) { event in
            Button { selected = event } label: {
                HStack(alignment:.top,spacing:13) {
                    Image(systemName:"building.2.crop.circle").font(.title2).foregroundStyle(MidnightTheme.accent)
                    VStack(alignment:.leading,spacing:7) {
                        Text("Hotel relocation").font(.headline)
                        Text(event.hasTime ? event.clock + (event.endClock.isEmpty ? "" : "–" + event.endClock) + " LT" : "Time not provided")
                            .font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(MidnightTheme.accent)
                        if event.detail != "Hotel relocation" { Text(event.detail).font(.subheadline).foregroundStyle(.secondary) }
                        if !event.notes.isEmpty { Text(event.notes).font(.subheadline).fixedSize(horizontal:false,vertical:true) }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                    Image(systemName:"chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top,5)
                }.padding(17).midnightCard(radius:20)
            }.buttonStyle(.plain).accessibilityIdentifier("roster-relocation-card")
        }
        .sheet(item:$selected) { event in TodayPriorityDetails(event:event,store:store) }
    }
}

struct TodayPriorityDetails: View {
    let event: TodayPriorityEvent
    @ObservedObject var store: RosterStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.raidoPalette) private var palette
    @Environment(\.raidoTheme) private var theme
    var body: some View {
        let _ = palette
        let _ = theme
        NavigationStack {
            TimelineView(.everyMinute) { context in
                ScrollView {
                    VStack(alignment:.leading,spacing:16) {
                        if event.kind == .alcohol { precaution(now:context.date) }
                        else { logistics(now:context.date) }
                        if event.capturedAt != .distantPast {
                            Label("Roster updated " + event.capturedAt.formatted(date:.abbreviated,time:.shortened),systemImage:"checkmark.icloud")
                                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal,3)
                        }
                    }.padding(20)
                }.midnightCanvas()
            }.navigationTitle(event.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents(event.kind == .alcohol ? [.medium,.large] : [.large])
        .presentationDragIndicator(.visible)
    }
    private func precaution(now: Date) -> some View {
        let active = TodayPriorityPolicy.visible(event, now: now)
        let finished = now >= event.end
        let color: Color = colorScheme == .dark ? Color(red:1,green:0.74,blue:0.71) : Color(red:0.58,green:0.16,blue:0.20)
        return VStack(alignment:.leading,spacing:16) {
            VStack(alignment:.leading,spacing:9) {
                Label(finished ? "Pre-duty window ended" : active ? "Precaution active" : "Precaution begins in",systemImage:"wineglass")
                    .font(.subheadline.weight(.semibold))
                if !finished {
                    Text(TodayPriorityPolicy.countdown(to:active ? event.end : event.date,now:now))
                        .font(.system(size:34,weight:.semibold,design:.rounded)).monospacedDigit()
                    Text(active ? "Remaining until " + (event.reference == "PU" ? "pickup" : "report") : "Until the pre-duty precaution starts")
                        .font(.subheadline)
                }
            }.foregroundStyle(color).padding(20).frame(maxWidth:.infinity,alignment:.leading)
                .background(colorScheme == .dark ? Color(red:0.21,green:0.13,blue:0.15) : Color(red:0.99,green:0.95,blue:0.93),in:RoundedRectangle(cornerRadius:22))
            VStack(spacing:14) {
                timeRow("Precaution begins",date:event.date,now:now)
                Divider()
                timeRow(event.reference == "PU" ? "Crew pickup" : "Report",date:event.end,now:now)
            }.padding(17).midnightCard(radius:20)
            Text("Based on 12 hours before rostered pickup, or report when no pickup is provided. Duty restrictions and company policy still apply.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).padding(.horizontal,3)
        }
    }
    private func timeRow(_ title: String, date: Date, now: Date) -> some View {
        HStack(alignment:.firstTextBaseline,spacing:12) {
            VStack(alignment:.leading,spacing:5) {
                Text(title).font(.subheadline.weight(.medium))
                Text(TodayPriorityPolicy.localDayLabel(date,event:event,now:now)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength:6)
            Text(TodayPriorityAdapter.clock(date,zone:TimeZone(identifier:event.zoneID)) + " LT")
                .font(.headline).monospacedDigit()
        }
    }
    private func logistics(now: Date) -> some View {
        VStack(alignment:.leading,spacing:16) {
            VStack(alignment:.leading,spacing:10) {
                Label(TodayPriorityPolicy.status(event,now:now),systemImage:event.kind == .relocation ? "building.2" : "car.side")
                    .font(.headline).foregroundStyle(MidnightTheme.accent)
                Text(TodayPriorityPolicy.localDayLabel(event.date,event:event,now:now)).font(.subheadline).foregroundStyle(.secondary)
                Text(event.clock + (event.endClock.isEmpty ? "" : "–" + event.endClock) + (event.hasTime ? " LT" : ""))
                    .font(.title2.weight(.semibold)).monospacedDigit()
                if event.detail != event.title { Text(event.detail).font(.subheadline) }
            }.padding(20).frame(maxWidth:.infinity,alignment:.leading).midnightCard(radius:22)
            if !event.notes.isEmpty {
                VStack(alignment:.leading,spacing:9) {
                    Label("Instructions",systemImage:"text.bubble").font(.subheadline.weight(.semibold))
                    Text(event.notes).font(.subheadline).textSelection(.enabled)
                }.padding(17).frame(maxWidth:.infinity,alignment:.leading).midnightCard(radius:20)
            }
            if !event.missing.isEmpty {
                VStack(alignment:.leading,spacing:9) {
                    ForEach(event.missing,id:\.self) { text in Label(text,systemImage:"exclamationmark.circle").font(.caption) }
                }.foregroundStyle(MidnightTheme.warningInk).padding(16).frame(maxWidth:.infinity,alignment:.leading).midnightCard(radius:18)
            }
            if !event.hotelQuery.isEmpty {
                Button(action:openHotel) { detailAction("Find hotel in Maps",symbol:"map") }.buttonStyle(.plain)
            }
            if let item = store.priorityItem(id:event.itemID) {
                NavigationLink { CrewControlSheet(item:item) } label: { detailAction("Crew Control",symbol:"headphones") }
                NavigationLink { RosterDetailView(item:item) } label: { detailAction("Full briefing & notes",symbol:"doc.text") }
            }
        }
    }
    private func detailAction(_ title: String, symbol: String) -> some View {
        HStack(spacing:12) {
            Label(title,systemImage:symbol).font(.subheadline.weight(.medium))
            Spacer()
            Image(systemName:"chevron.right").font(.caption.weight(.semibold))
        }.foregroundStyle(MidnightTheme.accent).padding(16).frame(minHeight:48).midnightCard(radius:16).accessibilityLabel(title)
    }
    private func openHotel() {
        var url = URLComponents(string:"https://maps.apple.com/")!
        url.queryItems = [URLQueryItem(name:"q",value:event.hotelQuery)]
        if let url = url.url { openURL(url) }
    }
}
