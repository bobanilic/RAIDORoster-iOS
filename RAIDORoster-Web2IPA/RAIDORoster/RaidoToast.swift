import Combine
import SwiftUI
import UIKit

struct RaidoToastNotice: Equatable {
    var id = UUID()
    var title:String
    var message:String
    var symbol:String
    var priorityID:String? = nil
    var precaution = false
    static var pickupSample:Self { .init(title:"Pickup approaching",message:"Hotel lobby · 06:30",symbol:"car.side") }
    static var precautionSample:Self { .init(title:"Precaution active",message:"Until report · 03:30 tomorrow",symbol:"wineglass",precaution:true) }
    static var rosterSample:Self { .init(title:"Roster updated",message:"Review changes in Roster",symbol:"calendar.badge.clock") }
}

@MainActor
final class RaidoToastCenter: ObservableObject {
    static let shared = RaidoToastCenter()
    @Published private(set) var notice:RaidoToastNotice?
    func dismiss(_ id:UUID) {
        guard notice?.id == id else { return }
        notice = nil
    }
    func present(_ notice:RaidoToastNotice) {
        guard UIApplication.shared.applicationState == .active else { return }
        self.notice = notice
    }
}

enum RaidoToastPresentation {
    static func make(_ notice:RaidoToastNotice,layout:String,appearance:String) -> AlertToast {
        let solid = appearance == "solid"
        let accent = notice.precaution ? Color(red:1,green:0.64,blue:0.60) : Color(red:0.58,green:0.82,blue:0.94)
        return AlertToast(displayMode:layout == "focus" ? .banner(.pop) : .hud,
            type:.systemImage(notice.symbol,solid ? accent : .primary),title:notice.title,subTitle:notice.message,
            style:.style(backgroundColor:solid ? Color(red:0.065,green:0.10,blue:0.14) : nil,
                         titleColor:solid ? .white : .primary,subTitleColor:solid ? Color.white.opacity(0.85) : .primary,
                         titleFont:.system(size:14,weight:.semibold),subTitleFont:.system(size:12)))
    }
}

// Keep observation and dismissal in an overlay leaf. A hidden message creates
// no geometry reader, glass surface, full-screen hit target or tab invalidation.
struct RaidoToastHost: View {
    @ObservedObject private var center = RaidoToastCenter.shared
    @AppStorage(LockScreenPolicy.layoutKey) private var layout = "card"
    @AppStorage("RAIDORoster.Notifications.Appearance") private var appearance = "glass"
    var body: some View {
        if let notice = center.notice {
            RaidoToastCard(notice:notice,layout:layout,appearance:appearance,duration:5) {
                center.dismiss(notice.id)
            } onTap: {
                if let id = notice.priorityID { TodayNotificationRouter.shared.pendingID = id }
            }
        }
    }
}

/// Retain AlertToast's card and material, using local alignment rather than its
/// legacy screen/geometry presentation wrapper. Only the card receives taps.
struct RaidoToastCard: View {
    let notice:RaidoToastNotice
    let layout:String
    let appearance:String
    let duration:Double
    let dismiss:() -> Void
    var onTap:() -> Void = {}
    var body: some View {
        let toast = RaidoToastPresentation.make(notice,layout:layout,appearance:appearance)
        Group {
            if layout == "focus" {
                // The library's banner includes a full-height Spacer. Render
                // only its card here, keeping the tab bar outside the overlay.
                toast.bannerCard
            } else {
                toast.hud
            }
        }
        .padding(.horizontal,16)
        .accessibilityElement(children:.combine)
        .accessibilityIdentifier("raido-toast")
        .onTapGesture { onTap(); dismiss() }
        .task(id:notice.id) {
            do { try await Task.sleep(for:.seconds(duration)) }
            catch { return }
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }
}
