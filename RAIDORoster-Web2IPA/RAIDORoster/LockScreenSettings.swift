import SwiftUI

struct LockScreenSettings: View {
    @ObservedObject var store: RosterStore
    @ObservedObject private var controller = LockScreenActivityController.shared
    @AppStorage(LockScreenPolicy.pickupKey) private var pickup = false
    @AppStorage(LockScreenPolicy.precautionKey) private var precaution = false
    @AppStorage(LockScreenPolicy.appearanceKey) private var appearance = "frosted"
    @AppStorage(LockScreenPolicy.layoutKey) private var layout = "card"
    @StateObject private var reminders = DutyReminderScheduler()

    var body: some View {
        Form {
            Section {
                Toggle("Pickup countdown",isOn:$pickup)
                Toggle("Precaution reminders & status",isOn:$precaution)
            } header: { Text("Lock Screen") } footer: {
                Text("Countdowns begin two hours before a saved pickup, or report when no pickup is supplied. Precaution reminders cover the earlier 12-hour period; its red status appears on the countdown card. No GPS or continuous background scanning is used.")
            }
            Section("Appearance") {
                Picker("Background",selection:$appearance) {
                    Text("Frosted").tag("frosted")
                    Text("Solid").tag("solid")
                }.pickerStyle(.segmented)
                Picker("Layout",selection:$layout) {
                    Text("Compact card").tag("card")
                    Text("Circles").tag("circles")
                }.pickerStyle(.segmented)
                DutyActivityCard(state:previewState)
                    .background(appearance == "solid" ? Color(red:0.065,green:0.10,blue:0.14) : MidnightTheme.surface,
                                in:RoundedRectangle(cornerRadius:22))
                    .listRowInsets(EdgeInsets(top:12,leading:0,bottom:12,trailing:0))
                Text("Frosted uses the system background. Its appearance follows iOS, your wallpaper and accessibility settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Status") {
                Text(controller.installationStatus).font(.footnote).foregroundStyle(.secondary)
                Text(controller.status).font(.footnote).foregroundStyle(.secondary)
                if let message = reminders.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                Button("Refresh Lock Screen cards") { store.refreshLockScreenActivities(force:true) }
                Button("Preview on Lock Screen") { controller.preview() }
                Button("Stop preview") { Task { await controller.stopPreview() } }
            }
            Section {
                Text("These are Live Activities, so RAIDO does not appear in the Lock Screen Add Widgets list. Enable an option above, or use Preview on Lock Screen to test immediately.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Automatic scheduled starts require iOS 26. Live Activities must be allowed in iPhone Settings, and your installation must support the bundled widget extension. Opening RAIDO refreshes cards after roster changes. Countdown times remain based on the last saved roster while offline.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Lock Screen").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).midnightCanvas()
        .onChange(of:pickup) { _,_ in apply() }
        .onChange(of:precaution) { _,enabled in
            if enabled {
                reminders.requestAndSchedule(store.priorityRosterItems,
                    pickupLead:UserDefaults.standard.integer(forKey:"RAIDORoster.PickupReminderLead"),
                    reportLead:UserDefaults.standard.integer(forKey:"RAIDORoster.ReportReminderLead"))
            }
            apply()
        }
        .onChange(of:appearance) { _,_ in apply() }
        .onChange(of:layout) { _,_ in apply() }
        .onAppear { store.refreshLockScreenActivities(force:true) }
    }
    private func apply() { store.refreshDutyReminders(forceLockScreen:true) }
    private var previewState: DutyActivityAttributes.ContentState {
        let end = Date().addingTimeInterval(105 * 60)
        return .init(pickupAt:end,referenceAt:end,precautionBegins:Date().addingTimeInterval(-10 * 3600),
            referenceLabel:"Pickup",clock:TodayPriorityAdapter.clock(end,zone:.current),zoneID:TimeZone.current.identifier,
            savedAt:Date(),detail:"Sample times",appearance:appearance,layout:layout,preview:true)
    }
}
