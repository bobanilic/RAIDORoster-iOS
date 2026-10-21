import Foundation

// A calendar day may contain several duty envelopes. Keep their timing separate,
// but never silently discard the later envelopes from a day briefing.
enum RosterDayPresentation {
    static func duties(for item: RosterItem, among items: [RosterItem]) -> [RosterItem] {
        guard let day = item.dateISO else { return [item] }
        var ids = Set<String>()
        let rows = (items + [item]).filter { $0.dateISO == day && ids.insert($0.id).inserted }
            .sorted {
                let lhs = $0.operationalActivities.first?.startUTC ?? ""
                let rhs = $1.operationalActivities.first?.startUTC ?? ""
                return lhs == rhs ? $0.index < $1.index : lhs < rhs
            }
        let operational = rows.filter { $0.isOperationalDuty && !$0.operationalActivities.isEmpty }
        return operational.isEmpty ? [item] : operational
    }

    static func sectors(in items: [RosterItem]) -> [RosterActivity] {
        var ids = Set<String>()
        return items.flatMap(\.operationalActivities).filter {
            ($0.isFlight || $0.category.uppercased() == "POSITIONING") &&
            TodayGlobalAirportIndex.routeCodes($0.route).count >= 2 && ids.insert($0.id).inserted
        }.sorted { $0.startUTC == $1.startUTC ? $0.id < $1.id : $0.startUTC < $1.startUTC }
    }
}

