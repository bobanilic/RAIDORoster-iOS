import SwiftUI

/// Settings and the extension share this foreground. iOS renders the Text timer;
/// the card never starts tasks, animations, polling or location sessions.
struct DutyActivityCard: View {
    let state: DutyActivityAttributes.ContentState
    var stale = false
    var systemBackground = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var solid: Bool { state.appearance == "solid" || reduceTransparency }
    private var ink: Color { solid ? .white : .primary }
    private var coral: Color { solid || scheme == .dark ? Color(red:1,green:0.64,blue:0.60) : Color(red:0.63,green:0.17,blue:0.20) }
    private var blue: Color { solid || scheme == .dark ? Color(red:0.58,green:0.82,blue:0.94) : Color(red:0.13,green:0.37,blue:0.51) }
    private var hasPrecaution: Bool { state.precautionBegins != nil }
    private var referenceIcon: String { state.pickupAt == nil ? "clock" : "car.side" }

    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text(state.preview ? "RAIDO · PREVIEW" : "RAIDO").font(.system(size:9,weight:.semibold)).tracking(2)
                Spacer()
                if state.layout == "circles" { Text(dayLabel).font(.system(size:9)) }
                if Date().timeIntervalSince(state.savedAt) >= 86400 {
                    Label("Saved roster",systemImage:"clock").font(.system(size:9))
                }
            }.foregroundStyle(ink.opacity(0.65))
            if stale {
                VStack(alignment:.leading,spacing:5) {
                    Label("Scheduled time reached",systemImage:"clock.badge.exclamationmark").font(.headline)
                    Text("Open RAIDO to check your latest duty.").font(.caption).foregroundStyle(ink.opacity(0.7))
                }.frame(minHeight:96,alignment:.leading)
            } else {
                Group {
                    switch state.layout {
                    case "circles": orbit
                    case "focus": focus
                    default: compact
                    }
                }.frame(minHeight:96)
            }
        }.foregroundStyle(ink).padding(.horizontal,18).padding(.vertical,12)
            .modifier(DutyActivitySurface(appearance:state.appearance,systemBackground:systemBackground))
    }
    private var compact: some View {
        HStack(alignment:.center,spacing:14) {
            if hasPrecaution {
                VStack(alignment:.leading,spacing:4) {
                    Image(systemName:"wineglass").font(.title3.weight(.light))
                    label("PRECAUTION")
                    Text("Active").font(.system(.title3,design:.rounded).weight(.semibold))
                    Text("Until " + state.clock).font(.caption2)
                }.frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(coral)
                Rectangle().fill(ink.opacity(0.12)).frame(width:1,height:66)
            }
            VStack(alignment:.leading,spacing:4) {
                Image(systemName:referenceIcon).font(.title3.weight(.light))
                label(state.referenceLabel.uppercased() + " IN")
                timer.font(.system(.title3,design:.rounded).weight(.semibold))
                    .multilineTextAlignment(.leading).frame(maxWidth:.infinity,alignment:.leading)
                Text(state.clock + " · " + dayLabel).font(.caption2)
            }.frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(blue)
        }
    }
    private var orbit: some View {
        HStack(spacing:12) {
            if hasPrecaution {
                ring(color:coral) {
                    Image(systemName:"wineglass").font(.title3.weight(.light))
                    Text("Active").font(.system(.title3,design:.rounded).weight(.semibold))
                    label("PRECAUTION")
                    Text("Until " + state.clock).font(.caption2)
                }
            }
            ring(color:blue) {
                Image(systemName:referenceIcon).font(.title3.weight(.light))
                orbitTimer
                label(state.referenceLabel.uppercased() + " IN")
                Text(state.clock).font(.caption2).lineLimit(1)
            }
        }
    }
    private var focus: some View {
        VStack(alignment:.leading,spacing:7) {
            HStack(spacing:11) {
                Image(systemName:referenceIcon).font(.title3.weight(.light))
                    .frame(width:36,height:36)
                    .background(blue.opacity(0.10),in:RoundedRectangle(cornerRadius:12))
                VStack(alignment:.leading,spacing:2) {
                    label(state.referenceLabel.uppercased() + " IN")
                    timer.font(.system(size:30,weight:.semibold,design:.rounded))
                        .multilineTextAlignment(.leading).frame(maxWidth:.infinity,alignment:.leading)
                    Text(state.clock + " · " + dayLabel).font(.caption2)
                }
            }.foregroundStyle(blue)
            if hasPrecaution {
                HStack(spacing:6) {
                    Image(systemName:"wineglass")
                    Text("Precaution active · Until " + state.clock)
                }.font(.caption2).foregroundStyle(coral)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private var timer: some View {
        Text(timerInterval:(state.countdownStartsAt ?? state.referenceAt.addingTimeInterval(-2 * 3600))...state.referenceAt,countsDown:true,showsHours:true)
            .monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
    }
    @ViewBuilder private var orbitTimer: some View {
        if #available(iOS 18.0, *) {
            // Use a system-known formatter: custom DiscreteFormatStyle types
            // cannot reliably decode in the Live Activity renderer. This native
            // duration source updates at minute boundaries without waking RAIDO.
            // A future anchor produces a negative offset. Reserve exactly the
            // five HH:MM glyphs, align the live text to their trailing edge and
            // clip only the leading sign. The stale-date view handles expiry.
            Text("00:00").hidden().fixedSize()
                .overlay(alignment:.trailing) {
                    Text(TimeDataSource<Date>.durationOffset(to:state.referenceAt),
                         format:Duration.TimeFormatStyle(pattern:.hourMinute(padHourToLength:2,roundSeconds:.awayFromZero),locale:Locale(identifier:"en_US_POSIX")))
                        .multilineTextAlignment(.trailing)
                        .frame(width:96,height:26,alignment:.trailing)
                }
                .clipped()
                .font(.system(size:20,weight:.semibold,design:.rounded)).monospacedDigit()
                .frame(width:80,height:26)
        } else {
            // The older system timer remains supported, with explicit bounds.
            timer.font(.system(size:20,weight:.semibold,design:.rounded))
                .multilineTextAlignment(.center).frame(width:80,height:26)
        }
    }
    private func ring<Content:View>(color:Color,@ViewBuilder content:() -> Content) -> some View {
        VStack(spacing:2,content:content).padding(5).frame(width:96,height:96)
            .overlay(Circle().strokeBorder(color.opacity(0.8),lineWidth:1.3))
            .frame(maxWidth:.infinity).foregroundStyle(color)
    }
    private func label(_ text:String) -> some View {
        Text(text).font(.system(size:8,weight:.medium)).tracking(1).lineLimit(1)
    }
    private var dayLabel:String {
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = TimeZone(identifier:state.zoneID) ?? .current
        if calendar.isDateInToday(state.referenceAt) { return "Today" }
        if calendar.isDateInTomorrow(state.referenceAt) { return "Tomorrow" }
        let formatter = DateFormatter();formatter.timeZone = calendar.timeZone;formatter.dateFormat = "d MMM"
        return formatter.string(from:state.referenceAt)
    }
}

/// WidgetKit owns the real Lock Screen backdrop. This material is only for the
/// in-app sample. No glassEffect captures or alters the foreground on locking.
private struct DutyActivitySurface: ViewModifier {
    let appearance:String
    let systemBackground:Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var shape:RoundedRectangle { RoundedRectangle(cornerRadius:24,style:.continuous) }
    func body(content:Content) -> some View {
        content.background {
            if !systemBackground {
                if appearance == "solid" || reduceTransparency {
                    shape.fill(Color(red:0.065,green:0.10,blue:0.14))
                } else {
                    shape.fill(.regularMaterial)
                }
            }
        }
    }
}
