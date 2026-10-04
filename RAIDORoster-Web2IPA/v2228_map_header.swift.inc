    // Compact header is passive. Map interaction and existing GPS controls are
    // available only after expansion; this view never starts a second session.
    private var iceMapHeader: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                mapSurface
                    .padding(.top, 96)
                    .allowsHitTesting(mapExpanded)
                LinearGradient(colors: [MidnightTheme.background, MidnightTheme.background.opacity(0.9), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 155).allowsHitTesting(false)
                HStack(alignment: .top, spacing: 10) {
                    IcePageHeading(title: "Today", subtitle: Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    IceDestinationClock(item: item)
                }.padding(.horizontal, 18).padding(.top, 10)
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: gps.fusedLocation == nil ? "location.slash" : "location")
                        Text(gps.fusedLocation == nil ? "GPS unavailable · route saved" : gps.positionSourceText)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }.font(.caption2).foregroundStyle(.secondary).padding(9)
                        .background(MidnightTheme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 9))
                        .padding(.horizontal, 18).padding(.bottom, 8)
                }.allowsHitTesting(false)
            }.frame(height: mapExpanded ? 430 : 280).clipped()
                .background(MidnightTheme.mapSea)
            Button { toggleMap() } label: {
                VStack(spacing: 5) {
                    Capsule().fill(MidnightTheme.accent.opacity(0.45)).frame(width: 30, height: 3)
                    Text(mapExpanded ? "Swipe up to collapse" : "Pull down for map").font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.plain)
                .accessibilityLabel(mapExpanded ? "Collapse flight map" : "Expand flight map")
                .accessibilityValue(mapExpanded ? "Expanded" : "Collapsed")
            if mapExpanded {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(gps.flightPhaseText).font(.subheadline.weight(.semibold))
                        Text(gps.positionSourceText + " · " + speedText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Apple Map / Auto") { todayMapSource = "auto"; onlineCameraPosition = .automatic }
                        Button("Offline local map") { todayMapSource = "offline" }
                        Button("Recenter map") { onlineCameraPosition = .automatic; committedZoom = 1; committedPan = .zero }
                        if gps.isTracking { Button("Stop tracking", role: .destructive) { gps.stop() } }
                        else { Button("Start Live GPS") { gps.start() } }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                    .accessibilityLabel("Flight Companion controls")
                }.padding(13).midnightCard(radius: 14).padding(.horizontal, 18).padding(.bottom, 14)
            }
        }
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
            // Expanded maps retain pan gestures. Collapse from the handle area.
            if !mapExpanded && value.translation.height > 48 && abs(value.translation.width) < 60 {
                withAnimation(.easeInOut(duration: 0.28)) { mapExpanded = true }
            } else if mapExpanded && value.startLocation.y >= 430 && value.translation.height < -48 {
                withAnimation(.easeInOut(duration: 0.28)) { mapExpanded = false }
            }
        })
    }

    private func toggleMap() {
        withAnimation(.easeInOut(duration: 0.28)) { mapExpanded.toggle() }
    }
