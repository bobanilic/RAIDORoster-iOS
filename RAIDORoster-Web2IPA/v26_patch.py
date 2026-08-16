from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "RAIDORoster"
CONTENT = SRC / "ContentView.swift"
WEB = SRC / "RosterWebView.swift"
JS = SRC / "RosterEnhancements.js"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def require_replace(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.6 patch marker not found: {label}")
    return text.replace(old, new, 1)


# -----------------------------------------------------------------------------
# V2.6: keep the proven V2.4 parser/data model, simplify the live RAIDO view,
# and add an iCalendar (.ics) export fallback for LiveContainer.
# -----------------------------------------------------------------------------
content = CONTENT.read_text()
if "import UIKit" not in content:
    content = content.replace("import EventKit\n", "import EventKit\nimport UIKit\n", 1)

ics_support = r'''
struct ICSShareFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

@MainActor
final class ICSExporter: ObservableObject {
    @Published var shareFile: ICSShareFile?
    @Published var message: String?

    func export(_ item: RosterItem) {
        write(items: [item], month: item.dateISO?.prefix(7).description, filename: "RAIDO-Roster-\(item.dateISO ?? "Duty").ics")
    }

    func exportMonth(_ items: [RosterItem], month: String?) {
        let selected = items.filter { item in
            guard let month, !month.isEmpty else { return true }
            return item.dateISO?.hasPrefix(month) == true
        }
        write(items: selected, month: month, filename: "RAIDO-Roster-\(month ?? "Month").ics")
    }

    private func write(items: [RosterItem], month: String?, filename: String) {
        let events = items.compactMap(icsEvent)
        guard !events.isEmpty else {
            message = "No roster entries with usable dates were available for iCalendar export."
            return
        }

        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//RAIDO Roster//iOS//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
            "X-WR-CALNAME:RAIDO Roster"
        ]
        lines.append(contentsOf: events.flatMap { $0 })
        lines.append("END:VCALENDAR")

        let body = lines.joined(separator: "\r\n") + "\r\n"
        do {
            let safeName = filename.replacingOccurrences(of: "/", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
            try body.data(using: .utf8)?.write(to: url, options: .atomic)
            shareFile = ICSShareFile(url: url)
        } catch {
            message = "iCalendar export failed: \(error.localizedDescription)"
        }
    }

    private func icsEvent(_ item: RosterItem) -> [String]? {
        let uid = "raido-\(safeUID(item.id))@raidoroster.local"
        var lines = ["BEGIN:VEVENT", "UID:\(uid)", "DTSTAMP:\(utcStamp(Date()))"]

        let allDayCategories = ["OFF", "DND", "REST", "VACATION", "LEAVE"]
        if allDayCategories.contains(item.category.uppercased()),
           let key = item.dateISO,
           let next = nextDayISO(key) {
            lines.append("DTSTART;VALUE=DATE:\(key.replacingOccurrences(of: "-", with: ""))")
            lines.append("DTEND;VALUE=DATE:\(next.replacingOccurrences(of: "-", with: ""))")
        } else {
            guard let start = item.dutyStartUTCDate,
                  let end = item.dutyEndUTCDate,
                  end > start else { return nil }
            lines.append("DTSTART:\(utcStamp(start))")
            lines.append("DTEND:\(utcStamp(end))")
        }

        lines.append("SUMMARY:\(escape(eventTitle(item)))")
        if !item.route.isEmpty { lines.append("LOCATION:\(escape(item.route))") }
        let description = eventDescription(item)
        if !description.isEmpty { lines.append("DESCRIPTION:\(escape(description))") }
        lines.append("STATUS:CONFIRMED")
        lines.append("TRANSP:OPAQUE")
        lines.append("END:VEVENT")
        return lines
    }

    private func eventTitle(_ item: RosterItem) -> String {
        let duty = item.displayTitle.replacingOccurrences(of: " + ", with: "/")
        guard !item.route.isEmpty else { return duty }
        return "\(duty) • \(item.route.replacingOccurrences(of: " → ", with: "-"))"
    }

    private func eventDescription(_ item: RosterItem) -> String {
        var lines: [String] = []
        if !item.route.isEmpty { lines.append("Route: \(item.route)") }
        if !item.reportLocal.isEmpty { lines.append("Report: \(item.reportLocal)") }
        if !item.releaseLocal.isEmpty { lines.append("Release: \(item.releaseLocal)") }
        if !item.dutyDuration.isEmpty { lines.append("Duty: \(item.dutyDuration)") }

        if !item.flightActivities.isEmpty {
            lines.append("")
            lines.append("Sectors:")
            for sector in item.flightActivities {
                let times = [sector.localStartTime, sector.localEndTime].filter { !$0.isEmpty }.joined(separator: "–")
                lines.append("• \(sector.title)  \(sector.route)  \(times)")
            }
        }

        if !item.pickups.isEmpty {
            lines.append("")
            lines.append("Pickup:")
            lines.append(contentsOf: item.pickups.map { "• \($0)" })
        }

        if !item.hotelAssignments.isEmpty {
            lines.append("")
            lines.append("Hotel:")
            for hotel in item.hotelAssignments {
                let name = hotel.hotelName.isEmpty ? hotel.title : hotel.hotelName
                lines.append("• \(name)  \(hotelRange(hotel))")
            }
        }

        let notes = uniqueStrings(item.transferNotes + item.dayNotes + item.activityNotes)
        if !notes.isEmpty {
            lines.append("")
            lines.append("RAIDO notes:")
            lines.append(contentsOf: notes.map { "• \($0)" })
        }

        if let aircraft = item.aircraft.first, !aircraft.aircraftDisplay.isEmpty {
            lines.append("")
            lines.append("Aircraft: \(aircraft.aircraftDisplay)")
        }
        return lines.joined(separator: "\n")
    }

    private func utcStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    private func nextDayISO(_ value: String) -> String? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: value),
              let next = f.calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
        return f.string(from: next)
    }

    private func safeUID(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }.joined()
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }
}
'''

if "final class ICSExporter" not in content:
    marker = "@MainActor\nfinal class RosterStore: ObservableObject {"
    if marker not in content:
        raise RuntimeError("V2.6 patch marker not found: RosterStore")
    content = content.replace(marker, ics_support + "\n\n" + marker, 1)

# Today: one compact menu, direct EventKit when installed normally and .ics
# fallback when running under LiveContainer.
today_marker = '''    @StateObject private var calendarExporter = CalendarExporter()\n'''
if "@StateObject private var icsExporter = ICSExporter()" not in content.split("struct TodayView: View", 1)[1].split("struct DutyBriefingView", 1)[0]:
    content = require_replace(
        content,
        today_marker,
        today_marker + "    @StateObject private var icsExporter = ICSExporter()\n",
        "Today ICS state"
    )

old_today_toolbar = '''                ToolbarItem(placement: .topBarTrailing) {
                    if let item = store.todayItems.first {
                        Button { calendarExporter.export(item) } label: {
                            Image(systemName: "calendar.badge.plus")
                        }
                        .disabled(calendarExporter.isWorking)
                        .accessibilityLabel("Export today's duty to Calendar")
                    }
                }
'''
new_today_toolbar = '''                ToolbarItem(placement: .topBarTrailing) {
                    if let item = store.todayItems.first {
                        Menu {
                            Button {
                                calendarExporter.export(item)
                            } label: {
                                Label("Sync to Apple Calendar", systemImage: "calendar.badge.plus")
                            }
                            Button {
                                icsExporter.export(item)
                            } label: {
                                Label("Export .ics file", systemImage: "square.and.arrow.up")
                            }
                        } label: {
                            Image(systemName: "calendar.badge.plus")
                        }
                        .disabled(calendarExporter.isWorking)
                        .accessibilityLabel("Calendar options")
                    }
                }
'''
content = require_replace(content, old_today_toolbar, new_today_toolbar, "Today calendar menu")

# Add the outbound share sheet and export-error alert after the existing Calendar alert.
today_alert = '''            .alert("Calendar", isPresented: Binding(
                get: { calendarExporter.message != nil },
                set: { if !$0 { calendarExporter.message = nil } }
            )) {
                Button("OK", role: .cancel) { calendarExporter.message = nil }
            } message: {
                Text(calendarExporter.message ?? "")
            }
'''
today_share = today_alert + '''            .sheet(item: $icsExporter.shareFile) { file in
                ActivityShareSheet(items: [file.url])
            }
            .alert("iCalendar Export", isPresented: Binding(
                get: { icsExporter.message != nil },
                set: { if !$0 { icsExporter.message = nil } }
            )) {
                Button("OK", role: .cancel) { icsExporter.message = nil }
            } message: {
                Text(icsExporter.message ?? "")
            }
'''
# Replace only the first occurrence (Today).
content = require_replace(content, today_alert, today_share, "Today ICS sheet")

# Settings: explicit choices, with LiveContainer guidance.
settings_chunk = content.split("struct SettingsView: View", 1)[1].split("struct DutyHeroCard", 1)[0]
if "@StateObject private var icsExporter = ICSExporter()" not in settings_chunk:
    settings_marker = '''    @StateObject private var calendarExporter = CalendarExporter()\n'''
    pos = content.find("struct SettingsView: View")
    marker_pos = content.find(settings_marker, pos)
    if marker_pos < 0:
        raise RuntimeError("V2.6 patch marker not found: Settings calendar state")
    insert_pos = marker_pos + len(settings_marker)
    content = content[:insert_pos] + "    @StateObject private var icsExporter = ICSExporter()\n" + content[insert_pos:]

old_settings_calendar = '''                Section("Calendar") {
                    Button {
                        calendarExporter.exportMonth(store.items, month: store.cachedMonth)
                    } label: {
                        Label("Export / update roster month", systemImage: "calendar.badge.plus")
                    }
                    .disabled(!store.hasCache || calendarExporter.isWorking)
                    Text("Repeated exports update RAIDO Roster events instead of creating duplicates.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
'''
new_settings_calendar = '''                Section("Apple Calendar") {
                    Button {
                        calendarExporter.exportMonth(store.items, month: store.cachedMonth)
                    } label: {
                        Label("Sync / update roster month", systemImage: "calendar.badge.plus")
                    }
                    .disabled(!store.hasCache || calendarExporter.isWorking)

                    Button {
                        icsExporter.exportMonth(store.items, month: store.cachedMonth)
                    } label: {
                        Label("Export roster month (.ics)", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!store.hasCache)

                    Text("Direct Calendar sync is intended for a normal SideStore/AltStore installation. When running inside LiveContainer, use the .ics export and import it into Apple Calendar.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
'''
content = require_replace(content, old_settings_calendar, new_settings_calendar, "Settings Calendar choices")

# V2.5 inserted one Calendar alert in Settings; attach the ICS share sheet to it.
settings_anchor = '''            // Settings calendar alert\n'''
if "ActivityShareSheet(items: [file.url])\n            }\n            // Settings ICS share" not in content:
    if settings_anchor not in content:
        raise RuntimeError("V2.6 patch marker not found: Settings alert anchor")
    content = content.replace(
        settings_anchor,
        '''            .sheet(item: $icsExporter.shareFile) { file in
                ActivityShareSheet(items: [file.url])
            }
            .alert("iCalendar Export", isPresented: Binding(
                get: { icsExporter.message != nil },
                set: { if !$0 { icsExporter.message = nil } }
            )) {
                Button("OK", role: .cancel) { icsExporter.message = nil }
            } message: {
                Text(icsExporter.message ?? "")
            }
            // Settings ICS share
''' + settings_anchor,
        1
    )

# Duty detail: same compact calendar menu.
detail_chunk = content.split("struct RosterDetailView: View", 1)[1].split("struct CategoryBadge", 1)[0]
if "@StateObject private var icsExporter = ICSExporter()" not in detail_chunk:
    detail_marker = '''    @StateObject private var calendarExporter = CalendarExporter()\n'''
    pos = content.find("struct RosterDetailView: View")
    marker_pos = content.find(detail_marker, pos)
    if marker_pos < 0:
        raise RuntimeError("V2.6 patch marker not found: Detail calendar state")
    insert_pos = marker_pos + len(detail_marker)
    content = content[:insert_pos] + "    @StateObject private var icsExporter = ICSExporter()\n" + content[insert_pos:]

old_detail_toolbar = '''            ToolbarItem(placement: .topBarTrailing) {
                Button { calendarExporter.export(item) } label: {
                    Image(systemName: "calendar.badge.plus")
                }
                .disabled(calendarExporter.isWorking)
                .accessibilityLabel("Export duty to Calendar")
            }
'''
new_detail_toolbar = '''            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        calendarExporter.export(item)
                    } label: {
                        Label("Sync to Apple Calendar", systemImage: "calendar.badge.plus")
                    }
                    Button {
                        icsExporter.export(item)
                    } label: {
                        Label("Export .ics file", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "calendar.badge.plus")
                }
                .disabled(calendarExporter.isWorking)
                .accessibilityLabel("Calendar options")
            }
'''
content = require_replace(content, old_detail_toolbar, new_detail_toolbar, "Detail calendar menu")

# The next remaining Calendar alert occurrence is the Detail alert. Attach share UI.
# We already expanded the first (Today), so find a Calendar alert inside the detail chunk.
detail_start = content.find("struct RosterDetailView: View")
detail_end = content.find("struct CategoryBadge", detail_start)
detail_text = content[detail_start:detail_end]
if ".sheet(item: $icsExporter.shareFile)" not in detail_text:
    alert = '''        .alert("Calendar", isPresented: Binding(
            get: { calendarExporter.message != nil },
            set: { if !$0 { calendarExporter.message = nil } }
        )) {
            Button("OK", role: .cancel) { calendarExporter.message = nil }
        } message: {
            Text(calendarExporter.message ?? "")
        }
'''
    if alert not in detail_text:
        raise RuntimeError("V2.6 patch marker not found: Detail Calendar alert")
    expanded = alert + '''        .sheet(item: $icsExporter.shareFile) { file in
            ActivityShareSheet(items: [file.url])
        }
        .alert("iCalendar Export", isPresented: Binding(
            get: { icsExporter.message != nil },
            set: { if !$0 { icsExporter.message = nil } }
        )) {
            Button("OK", role: .cancel) { icsExporter.message = nil }
        } message: {
            Text(icsExporter.message ?? "")
        }
'''
    detail_text = detail_text.replace(alert, expanded, 1)
    content = content[:detail_start] + detail_text + content[detail_end:]

# Remove the unreliable live-RAIDO Today button: Today belongs in the native tab.
portal_button = '''                    Button { model.goToday() } label: { Image(systemName: "calendar.circle") }
                        .accessibilityLabel("Scroll RAIDO to today")
'''
content = content.replace(portal_button, "", 1)

content = content.replace('LabeledContent("RAIDO Roster", value: "2.5")', 'LabeledContent("RAIDO Roster", value: "2.6")', 1)
CONTENT.write_text(content)


# -----------------------------------------------------------------------------
# Remove the live-page scrolling dependency entirely. Extraction remains the
# proven V2.4 logical-activity parser and no longer tries to move the web page.
# -----------------------------------------------------------------------------
web = WEB.read_text()
if "    func goToday() {" in web:
    start = web.index("    func goToday() {")
    end_marker = "    func openStartPage() {"
    end = web.index(end_marker, start)
    web = web[:start] + web[end:]

# Remove automatic post-load jump, whether baseline or V2.5-patched.
web = re.sub(
    r'''\n\s*DispatchQueue\.main\.asyncAfter\(deadline: \.now\(\) \+ 0\.7\) \{\n\s*webView\.evaluateJavaScript\("window\.RAIDOPlus && window\.RAIDOPlus\.goToday && window\.RAIDOPlus\.goToday\(\);"\)\n\s*\}\n''',
    "\n",
    web,
    count=1
)
WEB.write_text(web)

js = JS.read_text()
js = js.replace("    window.RAIDOPlus.goToday();\n", "", 1)
# Remove todayToken + goToday block.
start_marker = "  function todayToken() {"
end_marker = "  function redact(text) {"
if start_marker in js and end_marker in js:
    start = js.index(start_marker)
    end = js.index(end_marker, start)
    js = js[:start] + js[end:]
js = js.replace("      post(b);\n      goToday();", "      post(b);", 1)
js = js.replace("    goToday,\n", "", 1)
JS.write_text(js)


# -----------------------------------------------------------------------------
# Bundle version only. V2.5 already creates the app icon + Calendar purpose key.
# -----------------------------------------------------------------------------
pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 5;", "CURRENT_PROJECT_VERSION = 6;")
pbx = pbx.replace("MARKETING_VERSION = 2.5;", "MARKETING_VERSION = 2.6;")
PBX.write_text(pbx)

print("V2.6 source patch applied")
