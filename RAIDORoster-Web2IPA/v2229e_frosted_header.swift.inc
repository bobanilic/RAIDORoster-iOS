    private var iceMapHeader: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                mapSurface
                    .padding(.top, 96)
                    .allowsHitTesting(mapExpanded)
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(MidnightTheme.background.opacity(0.15))
                    .mask(LinearGradient(colors: [.white, .white.opacity(0.85), .clear], startPoint: .top, endPoint: .bottom))
                    .frame(height: 155).allowsHitTesting(false)
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(MidnightTheme.background.opacity(0.12))
                    .mask(LinearGradient(colors: [.clear, .white.opacity(0.65), .white], startPoint: .top, endPoint: .bottom))
                    .frame(height: 100).frame(maxHeight: .infinity, alignment: .bottom).allowsHitTesting(false)
                HStack(alignment: .top, spacing: 10) {
                    IcePageHeading(title: "Today", subtitle: Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    IceDestinationClock(item: item)
                }.padding(.horizontal, 18).padding(.top, 10)
                VStack {
                    Spacer()
                    if gps.isTracking {
                        TimelineView(.periodic(from: .now, by: 5)) { context in
                            let status = gps.mapStatus(now: context.date)
                            HStack(spacing: 6) {
                                Image(systemName: status.symbol)
                                Text(status.title).lineLimit(2)
                                Spacer(minLength: 0)
                            }.font(.caption2).foregroundStyle(.secondary).padding(9)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
                                .padding(.horizontal, 18).padding(.bottom, 30)
                                .accessibilityElement(children: .combine)
                                .accessibilityHint(status.detail)
                                .accessibilityIdentifier("today-map-tracking-status")
                        }
                    }
                }.allowsHitTesting(false)
                VStack {
                    Spacer()
                    Capsule().fill(MidnightTheme.accent.opacity(0.5)).frame(width: 30, height: 3)
                        .padding(.bottom, 12)
                }.allowsHitTesting(false).accessibilityHidden(true)
            }.frame(height: mapExpanded ? 474 : 324).clipped()
                .contentShape(Rectangle())
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("today-map-surface")
                .overlay(alignment: .bottom) {
                    MapHeaderTapControl(expanded: mapExpanded, onToggle: toggleMap).frame(height: 44)
                }
                .background(MidnightTheme.mapSea)
                .clipShape(RoundedRectangle(cornerRadius: MidnightTheme.isGetJet ? 28 : 0, style: .continuous))
/* EXPANDED_DETAILS */
        }
        .background(TodayMapDisclosureObserver(expanded: mapExpanded, onToggle: toggleMap))
        .contentShape(Rectangle())
    }
