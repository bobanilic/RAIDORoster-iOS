import Foundation

struct CrewMember: Codable, Equatable, Identifiable {
    let role: String
    let code: String
    let name: String
    let country: String?
    let phone: String?

    var id: String { "\(role)|\(code)|\(name)" }
}

struct RosterActivity: Codable, Equatable, Identifiable {
    let id: String
    let code: String
    let category: String
    let title: String
    let description: String
    let route: String
    let station: String
    let checkInLT: String
    let checkInUTC: String
    let startLT: String
    let startUTC: String
    let endLT: String
    let endUTC: String
    let checkOutLT: String
    let checkOutUTC: String
    let hotelName: String
    let pickup: String
    let transferNote: String
    let activityNote: String
    let dayNote: String
    let aircraftReg: String
    let aircraftType: String
    let aircraftVersion: String
    let aircraftPhone: String
    let crew: [CrewMember]
    let rawText: String

    // Earlier caches classified RLCN's "Hotel relocation" description as HOTEL.
    var isHotelRelocation: Bool { code.uppercased() == "RLCN" || category.uppercased() == "RELOCATION" }

    var isAuxiliary: Bool {
        isHotelRelocation || ["HOTEL", "EXPENSE", "RELOCATION"].contains(category.uppercased())
    }

    var isFlight: Bool { category.uppercased() == "FLIGHT" }

    var localStartTime: String { clockPart(startLT) }
    var localEndTime: String { clockPart(endLT) }
    var localCheckInTime: String { clockPart(checkInLT) }
    var localCheckOutTime: String { clockPart(checkOutLT) }

    var timeText: String {
        let span = [localStartTime, localEndTime].filter { !$0.isEmpty }.joined(separator: "–")
        if !localCheckInTime.isEmpty && ["FLIGHT", "POSITIONING"].contains(category.uppercased()) {
            return "CI \(localCheckInTime)  •  \(span)"
        }
        return span
    }

    var aircraftDisplay: String {
        var pieces: [String] = []
        if !aircraftReg.isEmpty { pieces.append(aircraftReg) }
        let typeLabel = aircraftTypeLabel(aircraftType)
        if !typeLabel.isEmpty { pieces.append(typeLabel) }
        if !aircraftVersion.isEmpty { pieces.append(aircraftVersion) }
        return pieces.joined(separator: " • ")
    }
}

struct RosterItem: Identifiable, Codable, Equatable {
    let id: String
    let index: Int
    let dateISO: String?
    let dateText: String
    let category: String
    let title: String
    let route: String
    let timeText: String
    let rawText: String
    let cells: [String]
    let activities: [RosterActivity]?
    let activeHotels: [RosterActivity]?

    var displayTitle: String { title.isEmpty ? category.capitalized : title }

    var displaySubtitle: String {
        if !route.isEmpty && !timeText.isEmpty { return "\(route)  •  \(timeText)" }
        if !route.isEmpty { return route }
        if !timeText.isEmpty { return timeText }
        return rawText
    }

    var isOperationalDuty: Bool {
        !["OFF", "DND", "REST", "VACATION", "LEAVE"].contains(category.uppercased())
    }

    var activityList: [RosterActivity] { activities ?? [] }

    var operationalActivities: [RosterActivity] {
        activityList
            .filter { !$0.isAuxiliary }
            .sorted { activitySortKey($0) < activitySortKey($1) }
    }

    var flightActivities: [RosterActivity] {
        operationalActivities.filter(\.isFlight)
    }

    var sectorCount: Int { flightActivities.count }

    var hotelAssignments: [RosterActivity] {
        uniqueActivities((activeHotels ?? []) + activityList.filter { $0.category.uppercased() == "HOTEL" })
            .filter { !$0.isHotelRelocation }
    }

    var relocationActivities: [RosterActivity] {
        uniqueActivities(activityList + (activeHotels ?? [])).filter(\.isHotelRelocation)
    }

    var standbyCalendarLabel: String {
        let periods = Set(operationalActivities.filter { $0.category.uppercased() == "STANDBY" }
            .compactMap { rosterStandbyPeriod(code: $0.code, details: $0.title + " " + $0.description) })
        let ordered = ["M", "A", "N"].filter { periods.contains($0) }
        if !ordered.isEmpty { return "STB " + ordered.joined(separator: "/") }
        return rosterStandbyPeriod(code: "", details: displayTitle).map { "STB " + $0 } ?? "STB"
    }

    var hasHotelRelocationOnRosterDate: Bool {
        relocationActivities.contains { activity in
            let localDay = String(activity.startLT.prefix(10))
            // Hotel metadata can also be attached to adjacent days.
            if localDay.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                return localDay == dateISO
            }
            return true
        }
    }

    var reportLocal: String {
        if let value = operationalActivities.compactMap({ $0.localCheckInTime.nilIfEmpty }).first { return value }
        return operationalActivities.first?.localStartTime ?? ""
    }

    var releaseLocal: String {
        if let value = operationalActivities.reversed().compactMap({ $0.localCheckOutTime.nilIfEmpty }).first { return value }
        return operationalActivities.last?.localEndTime ?? ""
    }

    var dutyDuration: String {
        guard let start = dutyStartUTCDate, let end = dutyEndUTCDate, end >= start else { return "" }
        return durationText(end.timeIntervalSince(start))
    }

    var dutyStartUTCDate: Date? {
        for activity in operationalActivities {
            if let date = parseUTCStamp(activity.checkInUTC) { return date }
            if let date = parseUTCStamp(activity.startUTC) { return date }
        }
        return nil
    }

    var dutyEndUTCDate: Date? {
        for activity in operationalActivities.reversed() {
            if let date = parseUTCStamp(activity.checkOutUTC) { return date }
            if let date = parseUTCStamp(activity.endUTC) { return date }
        }
        return nil
    }

    var transferNotes: [String] {
        uniqueStrings(activityList.map(\.transferNote).filter { !$0.isEmpty })
    }

    var activityNotes: [String] {
        uniqueStrings(activityList.map(\.activityNote).filter { !$0.isEmpty })
    }

    var dayNotes: [String] {
        uniqueStrings(activityList.map(\.dayNote).filter { !$0.isEmpty })
    }

    var pickups: [String] {
        uniqueStrings(activityList.map(\.pickup).filter { !$0.isEmpty })
    }

    var aircraft: [RosterActivity] {
        var seen = Set<String>()
        return flightActivities.filter { activity in
            let key = "\(activity.aircraftReg)|\(activity.aircraftType)|\(activity.aircraftVersion)"
            guard !key.replacingOccurrences(of: "|", with: "").isEmpty, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    var crewMembers: [CrewMember] {
        var seen = Set<String>()
        var unique: [CrewMember] = []

        for member in flightActivities.flatMap(\.crew) {
            // RAIDO can repeat the same person once per sector and decorate the
            // display name with operational markers such as (x), (y), (p) or
            // combinations of those markers. Employee/crew code is the stable
            // identity when available; otherwise use a normalized clean name.
            let cleanName = member.name
                .replacingOccurrences(
                    of: #"\s*\((?i:[xyp](?:\s+[xyp])*)\)\s*"#,
                    with: " ",
                    options: .regularExpression
                )
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let normalizedCode = member.code
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            let normalizedName = cleanName
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .uppercased()
            let identity = normalizedCode.isEmpty ? "NAME|\(normalizedName)" : "CODE|\(normalizedCode)"

            guard !identity.hasSuffix("|"), !seen.contains(identity) else { continue }
            seen.insert(identity)
            unique.append(CrewMember(
                role: member.role,
                code: member.code,
                name: cleanName.isEmpty ? member.name : cleanName,
                country: member.country,
                phone: member.phone
            ))
        }
        return unique
    }


    // V2.29.8 flight-associated transport.
    // DLRP may begin before the hotel pickup. Preserve the duty envelope, but
    // match pre-flight transport against the first sector's own check-in.
    private var pickupReportUTCDate: Date? {
        if let sector = operationalActivities.first(where: {
            ["FLIGHT", "POSITIONING"].contains($0.category.uppercased())
        }) {
            return parseUTCStamp(sector.checkInUTC) ?? parseUTCStamp(sector.startUTC) ?? dutyStartUTCDate
        }
        return dutyStartUTCDate
    }

    var preDutyPickupUTCDate: Date? {
        let all = activityList.compactMap { activity -> (Date, String)? in
            guard !activity.pickup.isEmpty, let date = pickupUTCDate(for: activity) else { return nil }
            return (date, activity.pickup)
        }
        guard !all.isEmpty else { return nil }
        if let report = pickupReportUTCDate {
            return all.filter { $0.0 <= report }.sorted { $0.0 < $1.0 }.last?.0
        }
        return all.sorted { $0.0 < $1.0 }.first?.0
    }

    var preDutyPickupDisplay: String {
        guard let selected = preDutyPickupUTCDate else { return "" }
        return activityList.compactMap { activity -> (Date, String)? in
            guard !activity.pickup.isEmpty, let date = pickupUTCDate(for: activity) else { return nil }
            return (date, activity.pickup)
        }
        .min { abs($0.0.timeIntervalSince(selected)) < abs($1.0.timeIntervalSince(selected)) }?.1 ?? ""
    }

    func nextPickup(at now: Date) -> PickupStatus? {
        let candidates: [PickupStatus] = activityList.compactMap { activity in
            guard !activity.pickup.isEmpty,
                  let date = pickupUTCDate(for: activity),
                  date >= now else { return nil }
            return PickupStatus(
                date: date,
                displayTime: activity.pickup,
                title: "Pickup",
                subtitle: activity.route.isEmpty ? activity.title : activity.route
            )
        }
        return candidates.sorted { $0.date < $1.date }.first
    }

    func liveStatus(at now: Date) -> DutyStatus? {
        guard isOperationalDuty, !operationalActivities.isEmpty else { return nil }

        for activity in operationalActivities {
            if let start = parseUTCStamp(activity.startUTC),
               let end = parseUTCStamp(activity.endUTC),
               now >= start, now < end {
                return DutyStatus(
                    label: "NOW",
                    title: activity.title,
                    subtitle: activity.route.isEmpty ? activity.description : activity.route,
                    systemImage: activity.isFlight ? "airplane" : "clock.fill"
                )
            }
        }

        if let pickup = preDutyPickupUTCDate, pickup > now {
            return DutyStatus(
                label: "NEXT • \(relativeText(from: now, to: pickup))",
                title: "Pickup",
                subtitle: compactPickupClock(preDutyPickupDisplay),
                systemImage: "car.fill"
            )
        }

        var future: [(Date, String, String, String)] = []
        if let first = operationalActivities.first,
           let date = parseUTCStamp(first.checkInUTC), date > now {
            future.append((date, "Check-in", first.localCheckInTime, "person.badge.clock"))
        }
        for activity in operationalActivities {
            if let date = parseUTCStamp(activity.startUTC), date > now {
                future.append((date, activity.title, activity.route, activity.isFlight ? "airplane.departure" : "clock"))
            }
        }
        if let last = operationalActivities.last,
           let date = parseUTCStamp(last.checkOutUTC), date > now {
            future.append((date, "Check-out", last.localCheckOutTime, "checkmark.circle"))
        }

        if let next = future.sorted(by: { $0.0 < $1.0 }).first {
            return DutyStatus(
                label: "NEXT • \(relativeText(from: now, to: next.0))",
                title: next.1,
                subtitle: next.2,
                systemImage: next.3
            )
        }

        if let end = dutyEndUTCDate, now >= end {
            return DutyStatus(label: "COMPLETE", title: "Duty finished", subtitle: releaseLocal.isEmpty ? "" : "Released \(releaseLocal)", systemImage: "checkmark.circle.fill")
        }
        return nil
    }
}

struct DutyStatus {
    let label: String
    let title: String
    let subtitle: String
    let systemImage: String
}

struct PickupStatus {
    let date: Date
    let displayTime: String
    let title: String
    let subtitle: String
}

struct RosterValidation: Codable, Equatable {
    let isValid: Bool
    let parser: String
    let month: String
    let datedRows: Int
    let message: String
}

struct RosterSnapshot: Codable, Equatable {
    let capturedAt: Date
    let sourceURL: String
    let pageTitle: String
    let items: [RosterItem]
    let validation: RosterValidation?
    // Authoritative monthly BLH displayed by N-OC/RAIDO (for example "70:48").
    // Optional preserves decoding of older cached snapshots.
    let monthlyBLH: String?
}


struct RosterChangeField: Codable, Equatable, Identifiable {
    let label: String
    let oldValue: String
    let newValue: String
    var id: String { label }
}

struct RosterDayChange: Codable, Equatable, Identifiable {
    let dateISO: String
    let dateText: String
    let fields: [RosterChangeField]
    var id: String { dateISO }
}

struct RosterChangeBundle: Codable, Equatable {
    let capturedAt: Date
    let changes: [RosterDayChange]
}

extension RosterSnapshot {
    // Compatibility for feed/archive paths created before monthlyBLH existed.
    // Live RAIDO page snapshots use the six-argument initializer and preserve monthlyBLH.
    init(capturedAt: Date, sourceURL: String, pageTitle: String, items: [RosterItem], validation: RosterValidation?) {
        self.init(
            capturedAt: capturedAt,
            sourceURL: sourceURL,
            pageTitle: pageTitle,
            items: items,
            validation: validation,
            monthlyBLH: nil
        )
    }
}

struct SummaryMetric: Identifiable {
    let label: String
    let value: Int
    var id: String { label }
}

struct OperationalMetric: Identifiable {
    let label: String
    let value: String
    let systemImage: String
    var id: String { label }
}

private func clockPart(_ value: String) -> String {
    guard !value.isEmpty else { return "" }
    return value.split(separator: " ").last.map(String.init) ?? value
}

private func activitySortKey(_ activity: RosterActivity) -> String {
    if !activity.startUTC.isEmpty { return activity.startUTC }
    return activity.startLT
}

private func uniqueActivities(_ values: [RosterActivity]) -> [RosterActivity] {
    var seen = Set<String>()
    return values.filter { activity in
        let key = "\(activity.code)|\(activity.startLT)|\(activity.endLT)|\(activity.hotelName)"
        guard !seen.contains(key) else { return false }
        seen.insert(key)
        return true
    }
}
