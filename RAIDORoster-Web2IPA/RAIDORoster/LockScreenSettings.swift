import SwiftUI

struct LockScreenSettings: View {
    @ObservedObject var store: RosterStore
    @ObservedObject private var controller = LockScreenActivityController.shared
    @AppStorage(LockScreenPolicy.pickupKey) private var pickup = false
    @AppStorage(LockScreenPolicy.precautionKey) private var precaution = false
    @AppStorage(LockScreenPolicy.appearanceKey) private var appearance = "frosted"
    @AppStorage(LockScreenPolicy.layoutKey) private var layout = "card"
    @AppStorage(LockScreenPolicy.leadHoursKey) private var leadHours = 2
    @StateObject private var reminders = DutyReminderScheduler()

    var body: some View {
        Form {
            Section {
                Toggle("Pickup countdown",isOn:$pickup)
                Toggle("Precaution reminders & status",isOn:$precaution)
                Picker("Show before pickup/report",selection:$leadHours) {
                    ForEach(LockScreenPolicy.leadHourOptions,id:\.self) { hours in
                        Text("\(hours) hours").tag(hours)
                    }
                }
            } header: { Text("Lock Screen") } footer: {
                Text("Cards begin within your selected window before saved pickup/report. The default is two hours. Precaution notifications still cover the earlier 12-hour period. iOS limits a Live Activity to eight active hours, so this card cannot stay permanently. No GPS or continuous background scanning is used.")
            }
            Section("Appearance") {
                Picker("Background",selection:$appearance) {
                    Text("Glass").tag("frosted")
                    Text("Solid").tag("solid")
                }.pickerStyle(.segmented)
                Picker("Layout",selection:$layout) {
                    Text("Compact card").tag("card")
                    Text("Circles").tag("circles")
                }.pickerStyle(.segmented)
                DutyActivityCard(state:previewState)
                    .listRowInsets(EdgeInsets(top:12,leading:0,bottom:12,trailing:0))
                    .listRowBackground(Color.clear)
                Text("Glass uses a translucent material. Its appearance follows your wallpaper and iOS accessibility settings; Reduce Transparency uses a solid background.")
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
        .onChange(of:leadHours) { _,_ in store.refreshLockScreenActivities(force:true) }
        .onAppear { store.refreshLockScreenActivities(force:true) }
    }
    private func apply() { store.refreshDutyReminders(forceLockScreen:true) }
    private var previewState: DutyActivityAttributes.ContentState {
        let end = Date().addingTimeInterval(105 * 60)
        return .init(pickupAt:end,referenceAt:end,precautionBegins:Date().addingTimeInterval(-10 * 3600),
            referenceLabel:"Pickup",clock:TodayPriorityAdapter.clock(end,zone:.current),zoneID:TimeZone.current.identifier,
            savedAt:Date(),detail:"Sample times",appearance:appearance,layout:layout,preview:true,
            countdownStartsAt:end.addingTimeInterval(-Double(LockScreenPolicy.normalizedLeadHours(leadHours)) * 3600))
    }
}
