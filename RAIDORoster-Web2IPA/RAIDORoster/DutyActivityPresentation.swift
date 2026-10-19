import SwiftUI

/// Shared by the real extension and Settings. Timers are rendered by iOS;
/// this view starts no tasks, location sessions, network requests or animations.
struct DutyActivityCard: View {
    let state: DutyActivityAttributes.ContentState
    var stale = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isLuminanceReduced) private var dimmed
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var solid: Bool { state.appearance == "solid" || reduceTransparency }
    private var ink: Color { solid ? .white : .primary }
    private var coral: Color { solid || scheme == .dark ? Color(red:1,green:0.64,blue:0.60) : Color(red:0.63,green:0.17,blue:0.20) }
    private var blue: Color { solid || scheme == .dark ? Color(red:0.58,green:0.82,blue:0.94) : Color(red:0.13,green:0.37,blue:0.51) }
    var body: some View {
        VStack(alignment:.leading,spacing:9) {
            HStack {
                Text(state.preview ? "RAIDO · PREVIEW" : "RAIDO").font(.system(size:9,weight:.semibold)).tracking(2)
                Spacer()
                if Date().timeIntervalSince(state.savedAt) >= 86400 { Label("Saved roster",systemImage:"clock").font(.system(size:9)) }
            }.foregroundStyle(ink.opacity(0.65))
            if stale {
                Label("Scheduled time reached",systemImage:"clock.badge.exclamationmark").font(.headline)
                Text("Open RAIDO to check your latest duty.").font(.caption).foregroundStyle(ink.opacity(0.7))
            } else {
                HStack(alignment:.center,spacing:18) {
                    if state.precautionBegins != nil {
                        column(color:coral) {
                            Image(systemName:"wineglass").font(.title3.weight(.light))
                            if state.layout != "circles" { label("PRECAUTION") }
                            Text("Active").font(.system(.title3,design:.rounded).weight(.semibold))
                            if state.layout != "circles" { Text("Until " + state.clock).font(.caption2) }
                        }
                    }
                    if state.precautionBegins != nil && state.layout != "circles" { Rectangle().fill(ink.opacity(0.12)).frame(width:1,height:66) }
                    column(color:blue) {
                        Image(systemName:state.pickupAt == nil ? "clock" : "car.side").font(.title3.weight(.light))
                        if state.layout != "circles" { label(state.referenceLabel.uppercased() + " IN") }
                        Text(timerInterval:(state.countdownStartsAt ?? state.referenceAt.addingTimeInterval(-2 * 3600))...state.referenceAt,countsDown:true,showsHours:true)
                            .font(.system(.title3,design:.rounded).weight(.semibold)).monospacedDigit()
                            .multilineTextAlignment(state.layout == "circles" ? .center : .leading)
                            .frame(maxWidth:.infinity,alignment:state.layout == "circles" ? .center : .leading)
                            .minimumScaleFactor(0.7).lineLimit(1)
                        if state.layout != "circles" { Text(state.clock + " · " + dayLabel).font(.caption2) }
                    }
                }
            }
        }.foregroundStyle(ink).padding(.horizontal,18).padding(.vertical,13)
            .opacity(dimmed ? 0.85 : 1)
            .modifier(DutyActivitySurface(appearance:state.appearance))
    }
    private var dayLabel: String {
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = TimeZone(identifier:state.zoneID) ?? .current
        if calendar.isDateInToday(state.referenceAt) { return "Today" }
        if calendar.isDateInTomorrow(state.referenceAt) { return "Tomorrow" }
        let formatter = DateFormatter();formatter.timeZone = calendar.timeZone;formatter.dateFormat = "d MMM"
        return formatter.string(from:state.referenceAt)
    }
    private func label(_ text: String) -> some View {
        Text(text).font(.system(size:8,weight:.medium)).tracking(1).lineLimit(1)
    }
    @ViewBuilder private func column<Content:View>(color:Color,@ViewBuilder content:() -> Content) -> some View {
        if state.layout == "circles" {
            VStack(spacing:5) {
                VStack(spacing:3,content:content).frame(width:82,height:82)
                    .overlay(Circle().strokeBorder(color.opacity(0.8),lineWidth:1.3))
                Text(color == coral ? "Precaution" : state.referenceLabel + " · " + state.clock).font(.caption2)
            }.frame(maxWidth:.infinity).foregroundStyle(color)
        } else {
            VStack(alignment:.leading,spacing:4,content:content).frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(color)
        }
    }
}

/// Share the actual surface with Settings; an opaque host tint would obscure it.
private struct DutyActivitySurface: ViewModifier {
    let appearance: String
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius:24,style:.continuous) }
    func body(content:Content) -> some View {
        // WidgetKit can lose foreground content captured by glassEffect.
        // Keep the card content outside the effect in both appearance modes.
        content.background {
            if appearance == "solid" || reduceTransparency {
                shape.fill(Color(red:0.065,green:0.10,blue:0.14))
            } else if #available(iOS 26.0, *) {
                shape.fill(Color.clear).glassEffect(.regular,in:shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
        }
    }
}
