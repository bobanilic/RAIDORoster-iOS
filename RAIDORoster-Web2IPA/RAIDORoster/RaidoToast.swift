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

struct RaidoToastHost: ViewModifier {
    @ObservedObject private var center = RaidoToastCenter.shared
    @AppStorage(LockScreenPolicy.layoutKey) private var layout = "card"
    @AppStorage("RAIDORoster.Notifications.Appearance") private var appearance = "glass"
    @State private var presented = false
    func body(content:Content) -> some View {
        content.toast(isPresenting:$presented,duration:5,offsetY:layout == "focus" ? -64 : 0,
            alert:{ RaidoToastPresentation.make(center.notice ?? .rosterSample,layout:layout,appearance:appearance) },
            onTap:{
                if let id = center.notice?.priorityID { TodayNotificationRouter.shared.pendingID = id }
            })
            .onChange(of:center.notice) { _,notice in
                if notice != nil { presented = true }
            }
    }
}
