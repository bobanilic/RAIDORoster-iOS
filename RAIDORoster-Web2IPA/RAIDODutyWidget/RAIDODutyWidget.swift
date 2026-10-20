import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RAIDODutyWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for:DutyActivityAttributes.self) { context in
            DutyLockScreenView(state:context.state,stale:context.isStale)
                .widgetURL(link(context.attributes.eventID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label((context.isStale || context.state.precautionBegins == nil) ? "RAIDO" : "Precaution active",systemImage:(context.isStale || context.state.precautionBegins == nil) ? "airplane" : "wineglass")
                        .font(.caption).foregroundStyle((context.isStale || context.state.precautionBegins == nil) ? .white : Color(red:1,green:0.64,blue:0.60))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timer(context.state).font(.headline).frame(maxWidth:110)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.isStale ? "Scheduled time reached · Open RAIDO" : context.state.referenceLabel + " · " + context.state.clock + " LT")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName:context.state.pickupAt == nil ? "wineglass" : "car.side")
            } compactTrailing: {
                timer(context.state).font(.caption2).frame(width:65)
            } minimal: {
                Image(systemName:context.state.pickupAt == nil ? "wineglass" : "car.side")
            }
            .widgetURL(link(context.attributes.eventID))
            .keylineTint(Color(red:0.58,green:0.82,blue:0.94))
        }
    }
    private func timer(_ state:DutyActivityAttributes.ContentState) -> some View {
        Text(timerInterval:(state.countdownStartsAt ?? state.referenceAt.addingTimeInterval(-2 * 3600))...state.referenceAt,countsDown:true,showsHours:true)
            .monospacedDigit().multilineTextAlignment(.trailing).minimumScaleFactor(0.6).lineLimit(1)
    }
    private func link(_ id:String) -> URL? {
        var value = URLComponents();value.scheme = "raidoroster";value.host = "priority"
        value.queryItems = [URLQueryItem(name:"id",value:id)]
        return value.url
    }
}

private struct DutyLockScreenView: View {
    let state:DutyActivityAttributes.ContentState
    let stale:Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isLuminanceReduced) private var dimmed
    private var solid:Bool { state.appearance == "solid" || reduceTransparency || dimmed }
    private var customBackdrop:Bool { state.appearance == "glass" }
    var body:some View {
        DutyActivityCard(state:state,stale:stale,systemBackground:true)
            .activityBackgroundTint(solid ? Color(red:0.065,green:0.10,blue:0.14) : customBackdrop ? Color.clear : nil)
            .activitySystemActionForegroundColor(solid ? .white : .primary)
    }
}
