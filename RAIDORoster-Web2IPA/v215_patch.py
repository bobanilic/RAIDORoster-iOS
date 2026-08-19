from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.15 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

companion = r"""
private struct CrewCompanionPhase {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
}

private enum CrewCompanionTimeZones {
    static let airport: [String: String] = [
        "TLV": "Asia/Jerusalem",
        "BUD": "Europe/Budapest",
        "BEG": "Europe/Belgrade",
        "BUS": "Asia/Tbilisi",
        "SKG": "Europe/Athens",
        "CFU": "Europe/Athens",
        "PFO": "Asia/Nicosia",
        "LCA": "Asia/Nicosia",
        "ATH": "Europe/Athens",
        "RHO": "Europe/Athens",
        "HER": "Europe/Athens",
        "CHQ": "Europe/Athens",
        "KGS": "Europe/Athens",
        "VIE": "Europe/Vienna",
        "PRG": "Europe/Prague",
        "WAW": "Europe/Warsaw",
        "KRK": "Europe/Warsaw",
        "SOF": "Europe/Sofia",
        "OTP": "Europe/Bucharest",
        "CLJ": "Europe/Bucharest",
        "TIA": "Europe/Tirane",
        "DBV": "Europe/Zagreb",
        "SPU": "Europe/Zagreb",
        "ZAG": "Europe/Zagreb",
        "FCO": "Europe/Rome",
        "MXP": "Europe/Rome",
        "FRA": "Europe/Berlin",
        "MUC": "Europe/Berlin",
        "BER": "Europe/Berlin",
        "AMS": "Europe/Amsterdam",
        "CDG": "Europe/Paris",
        "BCN": "Europe/Madrid",
        "MAD": "Europe/Madrid",
        "LHR": "Europe/London",
        "LGW": "Europe/London",
        "MAN": "Europe/London",
        "CPH": "Europe/Copenhagen",
        "ARN": "Europe/Stockholm",
        "OSL": "Europe/Oslo",
        "HEL": "Europe/Helsinki",
        "RIX": "Europe/Riga",
        "VNO": "Europe/Vilnius",
        "TLL": "Europe/Tallinn",
        "TBS": "Asia/Tbilisi",
        "KUT": "Asia/Tbilisi",
        "EVN": "Asia/Yerevan",
        "VAR": "Europe/Sofia",
        "BOJ": "Europe/Sofia"
    ]
}

private func crewCompanionRouteCodes(_ route: String) -> [String] {
    let normalized = route
        .uppercased()
        .replacingOccurrences(of: "→", with: " ")
        .replacingOccurrences(of: "–", with: " ")
        .replacingOccurrences(of: "—", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "/", with: " ")

    return normalized
        .split(whereSeparator: { !$0.isLetter })
        .map(String.init)
        .filter { $0.count == 3 }
}

private func crewCompanionSector(_ item: RosterItem, at now: Date) -> RosterActivity? {
    if let active = item.flightActivities.first(where: { activity in
        guard let start = parseUTCStamp(activity.startUTC),
              let end = parseUTCStamp(activity.endUTC) else { return false }
        return now >= start && now < end
    }) {
        return active
    }

    if let next = item.flightActivities
        .compactMap({ activity -> (RosterActivity, Date)? in
            guard let start = parseUTCStamp(activity.startUTC), start > now else { return nil }
            return (activity, start)
        })
        .sorted(by: { $0.1 < $1.1 })
        .first?.0 {
        return next
    }

    return item.flightActivities.last
}

private func crewCompanionDestinationCode(_ item: RosterItem, at now: Date) -> String? {
    if let sector = crewCompanionSector(item, at: now) {
        let codes = crewCompanionRouteCodes(sector.route)
        if let destination = codes.last { return destination }
    }
    return crewCompanionRouteCodes(item.route).last
}

private func crewCompanionClock(_ date: Date, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private func crewCompanionCountdown(from now: Date, to target: Date) -> String {
    let interval = target.timeIntervalSince(now)
    guard interval > 0 else { return "now" }

    let minutes = max(1, Int((interval + 59) / 60))
    if minutes < 60 { return "in \(minutes)m" }

    let hours = minutes / 60
    let remainder = minutes % 60
    if hours < 24 {
        return remainder == 0 ? "in \(hours)h" : "in \(hours)h \(remainder)m"
    }

    let days = hours / 24
    let restHours = hours % 24
    return restHours == 0 ? "in \(days)d" : "in \(days)d \(restHours)h"
}

private func crewCompanionPhase(_ item: RosterItem, at now: Date) -> CrewCompanionPhase {
    if let pickup = item.preDutyPickupUTCDate, pickup > now {
        return .init(
            title: "PICKUP",
            detail: crewCompanionCountdown(from: now, to: pickup),
            systemImage: "car.fill",
            tint: .orange
        )
    }

    if let report = item.dutyStartUTCDate, report > now {
        return .init(
            title: "REPORTING",
            detail: crewCompanionCountdown(from: now, to: report),
            systemImage: "person.badge.clock",
            tint: .blue
        )
    }

    for (index, flight) in item.flightActivities.enumerated() {
        guard let start = parseUTCStamp(flight.startUTC),
              let end = parseUTCStamp(flight.endUTC) else { continue }
        if now >= start && now < end {
            return .init(
                title: item.sectorCount > 1 ? "SECTOR \(index + 1) / \(item.sectorCount)" : "IN FLIGHT",
                detail: flight.route.isEmpty ? flight.title : flight.route,
                systemImage: "airplane",
                tint: .green
            )
        }
    }

    if item.flightActivities.count >= 2 {
        for index in 0..<(item.flightActivities.count - 1) {
            let previous = item.flightActivities[index]
            let next = item.flightActivities[index + 1]
            guard let previousEnd = parseUTCStamp(previous.endUTC),
                  let nextStart = parseUTCStamp(next.startUTC),
                  now >= previousEnd,
                  now < nextStart else { continue }

            let nextRoute = next.route.isEmpty ? next.title : next.route
            return .init(
                title: "TURNAROUND",
                detail: "\(nextRoute) · \(crewCompanionCountdown(from: now, to: nextStart))",
                systemImage: "arrow.triangle.2.circlepath",
                tint: .indigo
            )
        }
    }

    if let active = item.operationalActivities.first(where: { activity in
        guard let start = parseUTCStamp(activity.startUTC),
              let end = parseUTCStamp(activity.endUTC) else { return false }
        return now >= start && now < end
    }) {
        return .init(
            title: prettyCategory(active.category),
            detail: active.route.isEmpty ? active.title : active.route,
            systemImage: active.isFlight ? "airplane" : "clock.fill",
            tint: categoryColor(active.category)
        )
    }

    if let release = item.dutyEndUTCDate, now >= release {
        return .init(
            title: "DUTY COMPLETE",
            detail: item.releaseLocal.isEmpty ? "" : "Released \(item.releaseLocal)",
            systemImage: "checkmark.circle.fill",
            tint: .green
        )
    }

    return .init(
        title: prettyCategory(item.category),
        detail: item.route,
        systemImage: item.sectorCount > 0 ? "airplane" : "clock",
        tint: categoryColor(item.category)
    )
}

private struct CrewCompanionRolePicker: View {
    let dutyID: String
    let sectorID: String

    @AppStorage private var role: String

    init(dutyID: String, sectorID: String) {
        self.dutyID = dutyID
        self.sectorID = sectorID
        self._role = AppStorage(
            wrappedValue: "",
            "RAIDORoster.CrewRole." + dutyID + "." + sectorID
        )
    }

    private let roles = ["SCCM", "Deputy", "CC2", "CC3", "CC4", "CC5", "CC6"]

    var body: some View {
        Menu {
            ForEach(roles, id: \.self) { option in
                Button {
                    role = option
                } label: {
                    HStack {
                        Text(option)
                        if role == option { Image(systemName: "checkmark") }
                    }
                }
            }

            if !role.isEmpty {
                Divider()
                Button("Clear role", role: .destructive) {
                    role = ""
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.text.rectangle")
                Text(role.isEmpty ? "Set role" : role)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(role.isEmpty ? "Set crew role for this sector" : "Crew role \(role)")
    }
}

struct CrewCompanionContextCard: View {
    let item: RosterItem

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let phase = crewCompanionPhase(item, at: context.date)
            let sector = crewCompanionSector(item, at: context.date)
            let destinationCode = crewCompanionDestinationCode(item, at: context.date)
            let destinationZone = destinationCode
                .flatMap { CrewCompanionTimeZones.airport[$0] }
                .flatMap { TimeZone(identifier: $0) }

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: phase.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(phase.tint)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase.title)
                            .font(.caption.bold())
                            .foregroundStyle(phase.tint)
                        if !phase.detail.isEmpty {
                            Text(phase.detail)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                    }

                    Spacer(minLength: 6)

                    if let sector {
                        CrewCompanionRolePicker(dutyID: item.id, sectorID: sector.id)
                            .id(sector.id)
                    }
                }

                Divider()

                HStack(spacing: 0) {
                    CrewCompanionClockCell(
                        label: "LOCAL",
                        value: crewCompanionClock(context.date, timeZone: .current)
                    )

                    Divider().frame(height: 27)

                    if let destinationCode, let destinationZone {
                        CrewCompanionClockCell(
                            label: destinationCode,
                            value: crewCompanionClock(context.date, timeZone: destinationZone)
                        )
                        Divider().frame(height: 27)
                    }

                    CrewCompanionClockCell(
                        label: "UTC",
                        value: crewCompanionClock(
                            context.date,
                            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
                        )
                    )
                }
            }
            .padding(13)
            .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

private struct CrewCompanionClockCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

"""

if "struct CrewCompanionContextCard: View" not in content:
    content = replace_once(
        content,
        "struct TodayPersonalNoteDisclosure: View {\n",
        companion + "struct TodayPersonalNoteDisclosure: View {\n",
        "Crew Companion context components",
    )

content = replace_once(
    content,
    """        VStack(alignment: .leading, spacing: showTechnical ? 16 : 14) {
            DutyHeroCard(item: item)

            if !showTechnical, TodayRouteMapCard.canDisplay(item) {
                TodayRouteMapCard(item: item)
            }
""",
    """        VStack(alignment: .leading, spacing: showTechnical ? 16 : 14) {
            DutyHeroCard(item: item)

            if !showTechnical, item.isOperationalDuty {
                CrewCompanionContextCard(item: item)
            }

            if !showTechnical, TodayRouteMapCard.canDisplay(item) {
                TodayRouteMapCard(item: item)
            }
""",
    "Today companion placement",
)

content = replace_once(
    content,
    """    private var livePlaneCoordinate: CLLocationCoordinate2D? {
        if gps.isTracking { return gps.location?.coordinate }
        return staticAirplaneCoordinate
    }
""",
    """    private var livePlaneCoordinate: CLLocationCoordinate2D? {
        guard gps.isTracking else { return nil }
        return gps.location?.coordinate
    }
""",
    "no decorative aircraft position while GPS is off",
)

content = replace_once(
    content,
    """    private var progressText: String? {
        guard gps.isTracking,
              let location = gps.location,
              let estimate = Self.routeProgress(location: location, coordinates: coordinates) else { return nil }
        return "\\(estimate.percent)% route • \\(estimate.remainingKM.formatted()) km remaining"
    }
""",
    """    private var progressText: String? {
        guard gps.isTracking,
              let location = gps.location,
              let estimate = Self.routeProgress(location: location, coordinates: coordinates) else { return nil }

        let base = "\\(estimate.percent)% route • \\(estimate.remainingKM.formatted()) km remaining"
        guard location.speed >= 30, estimate.remainingKM > 0 else { return base }

        let seconds = (Double(estimate.remainingKM) * 1_000) / location.speed
        guard seconds.isFinite, seconds > 0, seconds < 24 * 60 * 60 else { return base }

        let minutes = max(1, Int((seconds / 60).rounded()))
        let eta: String
        if minutes < 60 {
            eta = "\\(minutes)m"
        } else {
            let hours = minutes / 60
            let remainder = minutes % 60
            eta = remainder == 0 ? "\\(hours)h" : "\\(hours)h \\(remainder)m"
        }
        return base + " • ~" + eta
    }
""",
    "GPS remaining-time estimate",
)

content = replace_once(
    content,
    """        VStack(alignment: .leading, spacing: gps.isTracking ? 9 : 0) {
            Map(position: $cameraPosition, bounds: cameraBounds, interactionModes: [.pan, .zoom]) {
""",
    """        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Flight Companion", systemImage: "airplane.circle.fill")
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)

                HStack(spacing: 5) {
                    Circle()
                        .fill(gps.isTracking ? gpsQuality.color : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(gps.isTracking ? "LIVE GPS" : "ROUTE OVERVIEW")
                        .font(.caption2.bold())
                        .foregroundStyle(gps.isTracking ? gpsQuality.color : Color.secondary)
                }
            }
            .padding(.horizontal, 2)

            Map(position: $cameraPosition, bounds: cameraBounds, interactionModes: [.pan, .zoom]) {
""",
    "Flight Companion header",
)

content = replace_once(
    content,
    """            if isExpanded {
                PersonalDutyNoteCard(item: item)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
""",
    """            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    PersonalDutyNoteCard(item: item)
                    Text("Stored only on this iPhone. Avoid sensitive passenger information.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
""",
    "local note privacy hint",
)

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.14.1")',
    'LabeledContent("RAIDO Roster", value: "2.15")',
    1,
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 32;", "CURRENT_PROJECT_VERSION = 33;")
pbx = pbx.replace("MARKETING_VERSION = 2.14.1;", "MARKETING_VERSION = 2.15;")
PBX.write_text(pbx)

print("V2.15 Crew Companion foundation applied")
