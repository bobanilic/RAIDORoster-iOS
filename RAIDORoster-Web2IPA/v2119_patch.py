from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.11.9 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# -----------------------------------------------------------------------------
# Roster header: title and freshness are one compact navigation-bar unit.
# The large standalone RAIDO status pill is removed from the Roster content.
# -----------------------------------------------------------------------------
roster_header = r'''
struct RosterHeaderPrincipal: View {
    @ObservedObject var store: RosterStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: 1) {
                Text("GetJet / AirHub Roster")
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .accessibilityAddTraits(.isHeader)

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)

                    Text(statusText(at: context.date))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var statusColor: Color {
        if !store.hasCache { return .secondary }
        return store.isCacheValidated ? .green : .orange
    }

    private func statusText(at now: Date) -> String {
        guard store.hasCache else { return "RAIDO · Not synced" }
        guard store.isCacheValidated else { return "Cached roster · Resync required" }
        guard let lastSync = store.lastSync else { return "RAIDO · Offline ready" }
        return "RAIDO · Synced \(compactRelativeAge(from: lastSync, to: now)) · Offline ready"
    }
}

'''
if "struct RosterHeaderPrincipal: View" not in content:
    content = replace_once(
        content,
        "struct RosterHomeView: View {\n",
        roster_header + "struct RosterHomeView: View {\n",
        "Roster compact header component",
    )

content = replace_once(
    content,
    '''                    SyncFreshnessStrip(store: store)

                    Picker("Roster view", selection: $rosterDisplayMode) {
''',
    '''                    Picker("Roster view", selection: $rosterDisplayMode) {
''',
    "remove standalone Roster freshness pill",
)

content = replace_once(
    content,
    '''                ToolbarItem(placement: .principal) {
                    Text("GetJet / AirHub Roster")
                        .font(.system(size: 24, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .accessibilityAddTraits(.isHeader)
                }
''',
    '''                ToolbarItem(placement: .principal) {
                    RosterHeaderPrincipal(store: store)
                }
''',
    "unified Roster title and sync status",
)

# -----------------------------------------------------------------------------
# Pickup is operationally earlier than check-in. Let the existing live status
# select PU as NEXT when a valid pre-duty pickup exists, before CI is considered.
# -----------------------------------------------------------------------------
content = replace_once(
    content,
    '''        var future: [(Date, String, String, String)] = []
        if let first = operationalActivities.first,
''',
    '''        if let pickup = preDutyPickupUTCDate, pickup > now {
            return DutyStatus(
                label: "NEXT • \(relativeText(from: now, to: pickup))",
                title: "Pickup",
                subtitle: compactPickupClock(preDutyPickupDisplay),
                systemImage: "car.fill"
            )
        }

        var future: [(Date, String, String, String)] = []
        if let first = operationalActivities.first,
''',
    "pickup before check-in in live status",
)

pickup_timing = r'''
private func compactPickupClock(_ display: String) -> String {
    let parts = display.components(separatedBy: .whitespacesAndNewlines)
    if let clock = parts.first(where: { token in
        token.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil
    }) {
        return clock
    }
    return display
}

struct TodayPrimaryTimingRow: View {
    let item: RosterItem

    private var values: [(String, String)] {
        let pickup = compactPickupClock(item.preDutyPickupDisplay)
        if !pickup.isEmpty {
            return [
                ("PU", pickup),
                ("CI", item.reportLocal.isEmpty ? "—" : item.reportLocal),
                ("RELEASE", item.releaseLocal.isEmpty ? "—" : item.releaseLocal)
            ]
        }
        return [
            ("CI", item.reportLocal.isEmpty ? "—" : item.reportLocal),
            ("RELEASE", item.releaseLocal.isEmpty ? "—" : item.releaseLocal),
            ("DUTY", item.dutyDuration.isEmpty ? "—" : item.dutyDuration)
        ]
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                VStack(spacing: 4) {
                    Text(value.1)
                        .font(.headline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(value.0)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

'''
if "struct TodayPrimaryTimingRow: View" not in content:
    content = replace_once(
        content,
        "struct DutyBriefingView: View {\n",
        pickup_timing + "struct DutyBriefingView: View {\n",
        "Today pickup timing row component",
    )

content = replace_once(
    content,
    '''                } else {
                    BriefingSectionTitle("Duty")
                    TodayOperationalTimelineCard(item: item)
                }
''',
    '''                } else {
                    TodayPrimaryTimingRow(item: item)
                    BriefingSectionTitle("Duty")
                    TodayOperationalTimelineCard(item: item)
                }
''',
    "Today PU CI Release row",
)

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.11.8")',
    'LabeledContent("RAIDO Roster", value: "2.11.9")',
    1,
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 21;", "CURRENT_PROJECT_VERSION = 22;")
pbx = pbx.replace("MARKETING_VERSION = 2.11.8;", "MARKETING_VERSION = 2.11.9;")
PBX.write_text(pbx)

print("V2.11.9 compact header + pickup-first Today applied")
