    private var iceMapHeader: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Both layers share the same projection. The blurred layer is
                // passive local geography, even when Apple Maps is selected.
                OfflineAviationMapCanvas(points: points, trail: gps.fusedTrail,
                    liveLocation: gps.fusedLocation, isTracking: gps.isTracking,
                    zoom: committedZoom, pan: committedPan, colorScheme: colorScheme)
                    .blur(radius: 12).allowsHitTesting(false).accessibilityHidden(true)
                mapSurface
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(0.12), location: 0.18),
                        .init(color: .white, location: 0.40),
                        .init(color: .white, location: 0.68),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom))
                    .allowsHitTesting(mapExpanded)
                // Fully meet the page colour at both boundaries. No material
                // panel: coastlines soften gradually beneath the title/handle.
                LinearGradient(stops: [
                    .init(color: MidnightTheme.background, location: 0),
                    .init(color: MidnightTheme.background.opacity(0.78), location: 0.16),
                    .init(color: MidnightTheme.background.opacity(0.20), location: 0.32),
                    .init(color: .clear, location: 0.44),
                    .init(color: .clear, location: 0.67),
                    .init(color: MidnightTheme.background.opacity(0.40), location: 0.82),
                    .init(color: MidnightTheme.background.opacity(0.90), location: 0.95),
                    .init(color: MidnightTheme.background, location: 1)
                ], startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
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
                                .background(MidnightTheme.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 9))
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
                .background(MidnightTheme.background)
/* EXPANDED_DETAILS */
        }
        .background(TodayMapDisclosureObserver(expanded: mapExpanded, onToggle: toggleMap))
        .contentShape(Rectangle())
    }
