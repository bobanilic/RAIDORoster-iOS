// V2.28 Ice presentation. The saved roster and tracking policies remain authoritative.
private struct IcePageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 30, weight: .semibold)).tracking(-0.8)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IceToolRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 21, weight: .regular))
                .foregroundStyle(MidnightTheme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.weight(.medium)).foregroundStyle(.tertiary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).midnightCard(radius: 16)
    }
}

private enum IceAirportClock {
    private static let records: [String: [String]] = {
        guard let url = Bundle.main.url(forResource: "AirportTimeZones", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return result
    }()
    static func zone(for code: String) -> TimeZone? {
        let identifier = CrewCompanionTimeZones.airport[code] ?? records[code]?.last
        return identifier.flatMap(TimeZone.init(identifier:))
    }
    static func city(for code: String) -> String {
        records[code]?.first?.nilIfEmpty ?? code
    }
    static func rosterLocalClock(_ date: Date, item: RosterItem) -> String {
        guard let first = item.operationalActivities.first else { return "Time unavailable" }
        let code = TodayGlobalAirportIndex.routeCodes(first.route).first ?? first.station.uppercased()
        if let zone = zone(for: code) { return crewCompanionClock(date, timeZone: zone) }
        // Preserve the roster's explicit LT/UTC offset when an airport has no
        // known time zone. Never silently substitute the phone's current zone.
        for (localStamp, utcStamp) in [(first.checkInLT, first.checkInUTC), (first.startLT, first.startUTC)] {
            if let local = parseUTCStamp(localStamp), let utc = parseUTCStamp(utcStamp) {
                return crewCompanionClock(date.addingTimeInterval(local.timeIntervalSince(utc)), timeZone: TimeZone(secondsFromGMT: 0)!)
            }
        }
        return "Time unavailable"
    }
}

private struct IceDestinationClock: View {
    let item: RosterItem
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let code = crewCompanionDestinationCode(item, at: context.date)
            let zone = code.flatMap { IceAirportClock.zone(for: $0) }
            let sector = crewCompanionSector(item, at: context.date)
            VStack(alignment: .leading, spacing: 3) {
                Text(code.map { IceAirportClock.city(for: $0) } ?? "Destination")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(zone.map { crewCompanionClock(context.date, timeZone: $0) } ?? "—:—")
                    .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                if let end = sector.flatMap({ parseUTCStamp($0.endUTC) }), let zone {
                    Text("Arrive " + crewCompanionClock(end, timeZone: zone))
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(zone == nil ? "Time zone unavailable" : "Destination local time")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(11).frame(minWidth: 108, alignment: .leading).midnightCard(radius: 13)
                .accessibilityElement(children: .combine)
        }
    }
}

private struct IcePickupCard: View {
    let item: RosterItem
    var body: some View {
        if !item.preDutyPickupDisplay.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(item.pickups, id: \.self) { Text($0) }
                    ForEach(item.transferNotes, id: \.self) { Text($0) }
                    ForEach(groupedHotelDisplayRows(item.hotelAssignments)) { row in
                        Text(row.title)
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 10)
            } label: {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(compactPickupClock(item.preDutyPickupDisplay))
                            .font(.system(size: 28, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(MidnightTheme.accent)
                        Text("PICKUP").font(.caption2).foregroundStyle(.secondary)
                    }.frame(minWidth: 76, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Crew transport", systemImage: "car.side").font(.subheadline.weight(.semibold))
                        if let pickup = item.preDutyPickupUTCDate {
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                Text(pickup > context.date ? calendarPickupCountdown(from: context.date, to: pickup) : "Scheduled pickup")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Transport details").font(.caption).foregroundStyle(.secondary)
                        }
                    }.foregroundStyle(.primary)
                }.padding(.vertical, 4)
            }.padding(15).midnightCard(radius: 16)
        }
    }
}

private struct IceReadinessView: View {
    let item: RosterItem
    @ObservedObject var store: RosterStore
    @AppStorage("RAIDORoster.RestAwarenessHours") private var restAwarenessHours = 10
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: 9) {
                if let reference = store.precautionReferenceDate(for: item),
                   let cutoff = store.alcoholPrecautionCutoff(for: item), context.date < reference {
                    let active = context.date >= cutoff
                    DisclosureGroup {
                        Text("12 hours before pickup, or report when pickup is unavailable. Company policy remains authoritative.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "wineglass").font(.system(size: 18))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Alcohol precaution").font(.subheadline.weight(.semibold))
                                Text(active ? "Active · until " + IceAirportClock.rosterLocalClock(reference, item: item)
                                     : "Starts " + IceAirportClock.rosterLocalClock(cutoff, item: item))
                                    .font(.caption)
                            }
                            Spacer(minLength: 0)
                        }.foregroundStyle(active ? MidnightTheme.warningInk : MidnightTheme.accent)
                    }.tint(active ? MidnightTheme.warningInk : MidnightTheme.accent)
                        .padding(13).background(active ? MidnightTheme.warning : MidnightTheme.surface,
                                                in: RoundedRectangle(cornerRadius: 13))
                }
                if let previous = store.previousOperationalDuty(before: item),
                   let release = previous.dutyEndUTCDate,
                   let target = store.precautionReferenceDate(for: item), target > release {
                    let interval = target.timeIntervalSince(release)
                    DisclosureGroup {
                        Text("From previous release to pickup or report. Awareness threshold: \(restAwarenessHours) hours.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    } label: {
                        Label("Rest · \(durationText(interval)) available", systemImage: "bed.double")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(interval < Double(restAwarenessHours * 3600) ? MidnightTheme.warningInk : .secondary)
                    }.padding(12).midnightCard(radius: 13)
                }
            }
        }
    }
}

private struct IceDutyAgenda: View {
    let item: RosterItem
    var onCalendarExport: (() -> Void)? = nil
    var canExport = true
    @State private var crewSector: RosterActivity?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your duty").font(.headline)
                Spacer()
                Text(item.aircraft.first?.aircraftType ?? prettyCategory(item.category))
                    .font(.caption).foregroundStyle(.secondary)
                if let onCalendarExport {
                    Menu {
                        Button("Sync duty to Calendar", systemImage: "calendar.badge.plus", action: onCalendarExport)
                            .disabled(!canExport)
                    } label: { Image(systemName: "ellipsis").frame(width: 36, height: 44) }
                        .accessibilityLabel("Duty options")
                }
            }
            if let first = item.operationalActivities.first, !first.localCheckInTime.isEmpty {
                agendaRow(time: first.localCheckInTime, title: "Report", detail: first.station, arrival: "", sector: nil)
            }
            ForEach(item.operationalActivities) { activity in
                let codes = TodayGlobalAirportIndex.routeCodes(activity.route)
                agendaRow(time: activity.localStartTime,
                          title: activity.isFlight && codes.count >= 2 ? codes.joined(separator: " → ") : activity.title,
                          detail: activity.isFlight ? activity.code : activity.description,
                          arrival: activity.localEndTime, sector: activity.isFlight ? activity : nil)
            }
            if let last = item.operationalActivities.last, !last.localCheckOutTime.isEmpty {
                agendaRow(time: last.localCheckOutTime, title: "Release", detail: "Duty complete", arrival: "", sector: nil)
            }
            if item.operationalActivities.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.displayTitle).font(.subheadline.weight(.semibold))
                    if !item.timeText.isEmpty { Text(item.timeText).font(.caption).foregroundStyle(.secondary) }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).midnightCard(radius: 13)
            }
        }.sheet(item: $crewSector) { sector in
            NavigationStack {
                ScrollView { CrewCard(item: sectorItem(sector)).padding() }.midnightCanvas().navigationTitle("Crew · " + sector.code)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { crewSector = nil } } }
            }
        }
    }
    private func sectorItem(_ sector: RosterActivity) -> RosterItem {
        RosterItem(id: item.id, index: item.index, dateISO: item.dateISO, dateText: item.dateText,
                   category: item.category, title: item.title, route: sector.route, timeText: sector.timeText,
                   rawText: sector.rawText, cells: [], activities: [sector], activeHotels: nil)
    }
    private func agendaRow(time: String, title: String, detail: String, arrival: String, sector: RosterActivity?) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text(time).font(.caption.weight(.semibold)).monospacedDigit()
                .frame(width: 47, alignment: .leading).padding(.top, 14)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 3)
                    if let sector, !sector.crew.isEmpty {
                        Button { crewSector = sector } label: { Image(systemName: "person.2") }
                            .buttonStyle(.plain).frame(minWidth: 30, minHeight: 24)
                            .accessibilityLabel("View crew for " + sector.code)
                    }
                }
                if !arrival.isEmpty || !detail.isEmpty {
                    Text([arrival.isEmpty ? "" : (sector == nil ? "End " : "Arrive ") + arrival, detail].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading).midnightCard(radius: 13)
        }
    }
}

private struct IceSelectedRosterDay: View {
    let item: RosterItem
    let isChanged: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.dateISO.flatMap(rosterCalendarDate)?.formatted(.dateTime.weekday(.wide).day().month(.wide)) ?? item.dateText)
                        .font(.headline)
                    Text("Local times" + (isChanged ? " · Roster changed" : "")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if item.sectorCount > 0 { Text("\(item.sectorCount) sectors").font(.caption).foregroundStyle(.secondary) }
            }
            IcePickupCard(item: item)
            IceDutyAgenda(item: item)
            NavigationLink { RosterDetailView(item: item) } label: {
                Label("Full briefing & notes", systemImage: "doc.text").font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }.padding(.top, 12)
    }
}

struct TodayView: View {
    @ObservedObject var store: RosterStore
    let openPortal: () -> Void
    @StateObject private var calendarExporter = CalendarExporter()
    private enum CompanionSheet: String, Identifiable {
        case crewControl, announcements, documents
        var id: String { rawValue }
    }
    @State private var activeSheet: CompanionSheet?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if store.isCacheValidated, let item = store.todayPrimaryItem, TodayRouteMapCard.canDisplay(item) {
                        TodayRouteMapCard(item: item, iceHeader: true)
                    } else {
                        IcePageHeading(title: "Today", subtitle: Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 22)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        if store.isCacheValidated, let item = store.todayPrimaryItem {
                            IcePickupCard(item: item)
                            IceReadinessView(item: item, store: store)
                            IceDutyAgenda(item: item, onCalendarExport: { calendarExporter.export(item) }, canExport: !calendarExporter.isWorking)
                            TodayPersonalNoteDisclosure(item: item)
                            if let sector = crewCompanionSector(item, at: Date()) {
                                HStack { Text("My position").font(.caption).foregroundStyle(.secondary); Spacer()
                                    CrewCompanionRolePicker(dutyID: item.id, sectorID: sector.id).id(sector.id) }
                            }
                            if !item.aircraft.isEmpty {
                                DisclosureGroup("Aircraft") { AircraftCard(item: item).padding(.top, 8) }
                                    .font(.subheadline).padding(13).midnightCard(radius: 13)
                            }
                            if !item.hotelAssignments.isEmpty || !item.transferNotes.isEmpty {
                                DisclosureGroup("Hotel & transport") { LogisticsCard(item: item).padding(.top, 8) }
                                    .font(.subheadline).padding(13).midnightCard(radius: 13)
                            }
                            if !item.dayNotes.isEmpty || !item.activityNotes.isEmpty {
                                DisclosureGroup("Duty notes") { NotesCard(item: item).padding(.top, 8) }
                                    .font(.subheadline).padding(13).midnightCard(radius: 13)
                            }
                            if let next = store.nextOperationalDuty(after: item), let interval = store.restInterval(after: item, before: next) {
                                RestToNextDutyCard(next: next, interval: interval)
                            }
                        } else {
                            ContentUnavailableView(store.hasCache ? "Roster needs a resync" : "Import your roster", systemImage: "calendar.badge.exclamationmark",
                                description: Text("Open Live RAIDO while online to save your duty briefing."))
                            Button("Open Live RAIDO", action: openPortal).buttonStyle(.borderedProminent)
                        }
                        HStack(spacing: 9) {
                            MidnightQuickAction(title: "Announcements", symbol: "megaphone") { activeSheet = .announcements }
                            MidnightQuickAction(title: "Crew Control", symbol: "headphones") { activeSheet = .crewControl }
                            MidnightQuickAction(title: "Documents", symbol: "lock.doc") { activeSheet = .documents }
                        }.padding(.top, 5)
                        SyncFreshnessStrip(store: store)
                    }.padding(.horizontal, 18).padding(.bottom, 20)
                }
            }.midnightCanvas().toolbar(.hidden, for: .navigationBar)
                .sheet(item: $activeSheet) { sheet in
                    switch sheet {
                    case .crewControl: CrewControlSheet(item: store.todayPrimaryItem ?? store.nextDuty)
                    case .announcements: AnnouncementsView(item: store.isCacheValidated ? store.todayPrimaryItem : nil)
                    case .documents: CrewDocumentsView()
                    }
                }
                .alert("Calendar", isPresented: Binding(get: { calendarExporter.message != nil }, set: { if !$0 { calendarExporter.message = nil } })) {
                    Button("OK", role: .cancel) { calendarExporter.message = nil }
                } message: { Text(calendarExporter.message ?? "") }
        }
    }
}

private struct IceMoreView: View {
    @ObservedObject var store: RosterStore
    @ObservedObject var browser: RosterBrowserModel
    let openPortal: () -> Void
    private enum Destination: String, Identifiable {
        case earnings, documents, announcements, manuals, settings, crew
        var id: String { rawValue }
    }
    @State private var destination: Destination?
    @State private var pendingPortal = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    IcePageHeading(title: "More", subtitle: "Your crew essentials").padding(.bottom, 14)
                    Button(action: openPortal) { IceToolRow(title: "Live RAIDO", subtitle: "Open the original crew portal", symbol: "globe") }
                    Text("Crew tools").font(.headline).padding(.top, 15).padding(.bottom, 3)
                    tool("Earnings", "Monthly pay, block hours & pay profiles", "eurosign.circle", .earnings)
                    tool("Crew Documents", "Your private document vault", "lock.doc", .documents)
                    tool("Announcements", "Scripts for your aircraft and airline", "megaphone", .announcements)
                    tool("Manuals", "Access through the live company portal", "book.closed", .manuals)
                    tool("Crew Control", "Phone, WhatsApp & email", "headphones", .crew)
                    Text("Preferences").font(.headline).padding(.top, 15).padding(.bottom, 3)
                    tool("Settings", "Appearance, reminders, units & diagnostics", "gearshape", .settings)
                    SyncFreshnessStrip(store: store)
                }.buttonStyle(.plain).padding(18)
            }.midnightCanvas().toolbar(.hidden, for: .navigationBar)
                .sheet(item: $destination, onDismiss: {
                    if pendingPortal { pendingPortal = false; openPortal() }
                }) { selected in
                    switch selected {
                    case .earnings:
                        NavigationStack {
                            MonthlyEarningsView(roster: store, earnings: EarningsStore.shared,
                                month: store.selectedRosterMonth ?? String(EarningsMath.day(Date()).prefix(7)))
                                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { destination = nil } } }
                        }
                    case .documents: CrewDocumentsView()
                    case .announcements: AnnouncementsView(item: store.isCacheValidated ? store.todayPrimaryItem : nil)
                    case .crew: CrewControlSheet(item: store.todayPrimaryItem ?? store.nextDuty)
                    case .settings: SettingsView(store: store, browser: browser) { pendingPortal = true; destination = nil }
                    case .manuals:
                        NavigationStack {
                            VStack(spacing: 18) {
                                Image(systemName: "book.closed").font(.system(size: 40)).foregroundStyle(MidnightTheme.accent)
                                Text("Company manuals").font(.title2.weight(.semibold))
                                Text("Open Live RAIDO to access your company’s manuals. Documents saved in Crew Documents remain available offline.")
                                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                Button("Open Live RAIDO") { pendingPortal = true; destination = nil }.buttonStyle(.borderedProminent)
                            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).midnightCanvas()
                                .navigationTitle("Manuals").navigationBarTitleDisplayMode(.inline)
                                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { destination = nil } } }
                        }
                    }
                }
        }
    }
    private func tool(_ title: String, _ subtitle: String, _ symbol: String, _ target: Destination) -> some View {
        Button { destination = target } label: { IceToolRow(title: title, subtitle: subtitle, symbol: symbol) }
    }
}
