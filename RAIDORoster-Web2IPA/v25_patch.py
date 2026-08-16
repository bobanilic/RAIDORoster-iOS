from pathlib import Path
import json
import subprocess
import textwrap

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "RAIDORoster"
CONTENT = SRC / "ContentView.swift"
WEB = SRC / "RosterWebView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def require_replace(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.5 patch marker not found: {label}")
    return text.replace(old, new, 1)


# -----------------------------------------------------------------------------
# Native V2.5 UI + EventKit export
# -----------------------------------------------------------------------------
content = CONTENT.read_text()
if "import EventKit" not in content:
    content = content.replace("import SwiftUI\n", "import SwiftUI\nimport EventKit\n", 1)

calendar_exporter = r'''
@MainActor
final class CalendarExporter: ObservableObject {
    @Published var message: String?
    @Published var isWorking = false

    private let eventStore = EKEventStore()

    func export(_ item: RosterItem) {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            guard await requestAccess() else { return }
            do {
                let created = try upsert(item)
                try eventStore.commit()
                message = created ? "Duty added to Calendar." : "Calendar duty updated."
            } catch {
                message = "Calendar export failed: \(error.localizedDescription)"
            }
        }
    }

    func exportMonth(_ items: [RosterItem], month: String?) {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            guard await requestAccess() else { return }
            do {
                let selected = items.filter { item in
                    guard let month, !month.isEmpty else { return true }
                    return item.dateISO?.hasPrefix(month) == true
                }
                var created = 0
                var updated = 0
                for item in selected {
                    if try upsert(item) { created += 1 } else { updated += 1 }
                }
                try eventStore.commit()
                message = "Calendar synced • \(selected.count) days • \(created) added • \(updated) updated"
            } catch {
                message = "Calendar export failed: \(error.localizedDescription)"
            }
        }
    }

    private func requestAccess() async -> Bool {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            if !granted { message = "Calendar access was not granted." }
            return granted
        } catch {
            message = "Calendar access failed: \(error.localizedDescription)"
            return false
        }
    }

    private func upsert(_ item: RosterItem) throws -> Bool {
        guard let span = eventSpan(item) else { throw CalendarExportError.invalidDuty }
        let marker = "[RAIDO-ROSTER-ID:\(item.id)]"
        let searchStart = span.start.addingTimeInterval(-86400)
        let searchEnd = span.end.addingTimeInterval(86400)
        let predicate = eventStore.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: nil)
        let existing = eventStore.events(matching: predicate).first { $0.notes?.contains(marker) == true }
        let event = existing ?? EKEvent(eventStore: eventStore)
        let created = existing == nil

        if event.calendar == nil { event.calendar = eventStore.defaultCalendarForNewEvents }
        guard event.calendar != nil else { throw CalendarExportError.noCalendar }

        event.title = eventTitle(item)
        event.startDate = span.start
        event.endDate = span.end
        event.isAllDay = span.allDay
        let notes = eventNotes(item)
        event.notes = notes.isEmpty ? marker : notes + "\n\n" + marker
        event.url = URL(string: "raidoroster://duty/\(item.id)")
        try eventStore.save(event, span: .thisEvent, commit: false)
        return created
    }

    private func eventSpan(_ item: RosterItem) -> (start: Date, end: Date, allDay: Bool)? {
        let allDayCategories = ["OFF", "DND", "REST", "VACATION", "LEAVE"]
        if allDayCategories.contains(item.category.uppercased()),
           let key = item.dateISO,
           let start = localDay(key),
           let end = Calendar.current.date(byAdding: .day, value: 1, to: start) {
            return (start, end, true)
        }

        guard let start = item.dutyStartUTCDate,
              let end = item.dutyEndUTCDate,
              end > start else { return nil }
        return (start, end, false)
    }

    private func localDay(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func eventTitle(_ item: RosterItem) -> String {
        let duty = item.displayTitle.replacingOccurrences(of: " + ", with: "/")
        guard !item.route.isEmpty else { return duty }
        return "\(duty) • \(item.route.replacingOccurrences(of: " → ", with: "-"))"
    }

    private func eventNotes(_ item: RosterItem) -> String {
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

    private enum CalendarExportError: LocalizedError {
        case invalidDuty
        case noCalendar

        var errorDescription: String? {
            switch self {
            case .invalidDuty: return "The roster entry has no usable start/end time."
            case .noCalendar: return "No writable default calendar is available."
            }
        }
    }
}
'''

if "final class CalendarExporter" not in content:
    marker = '''struct SummaryMetric: Identifiable {
    let label: String
    let value: Int
    var id: String { label }
}
'''
    if marker not in content:
        raise RuntimeError("V2.5 patch marker not found: SummaryMetric")
    content = content.replace(marker, marker + "\n" + calendar_exporter + "\n", 1)

# Today: export current duty from the toolbar.
if "@StateObject private var calendarExporter = CalendarExporter()" not in content.split("struct TodayView: View", 1)[1].split("struct DutyBriefingView", 1)[0]:
    content = require_replace(
        content,
        '''struct TodayView: View {
    @ObservedObject var store: RosterStore
    let openPortal: () -> Void
''',
        '''struct TodayView: View {
    @ObservedObject var store: RosterStore
    let openPortal: () -> Void
    @StateObject private var calendarExporter = CalendarExporter()
''',
        "Today calendar state"
    )

if "Export today's duty to Calendar" not in content:
    content = require_replace(
        content,
        '''            .navigationTitle("Today")
        }
    }

    private var emptyToday''',
        '''            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let item = store.todayItems.first {
                        Button { calendarExporter.export(item) } label: {
                            Image(systemName: "calendar.badge.plus")
                        }
                        .disabled(calendarExporter.isWorking)
                        .accessibilityLabel("Export today's duty to Calendar")
                    }
                }
            }
            .alert("Calendar", isPresented: Binding(
                get: { calendarExporter.message != nil },
                set: { if !$0 { calendarExporter.message = nil } }
            )) {
                Button("OK", role: .cancel) { calendarExporter.message = nil }
            } message: {
                Text(calendarExporter.message ?? "")
            }
        }
    }

    private var emptyToday''',
        "Today calendar toolbar"
    )

# Settings: whole-month export.
settings_chunk = content.split("struct SettingsView: View", 1)[1].split("struct DutyHeroCard", 1)[0]
if "@StateObject private var calendarExporter = CalendarExporter()" not in settings_chunk:
    content = require_replace(
        content,
        '''struct SettingsView: View {
    @ObservedObject var store: RosterStore
    @ObservedObject var browser: RosterBrowserModel
    let openPortal: () -> Void
    @State private var confirmClear = false
''',
        '''struct SettingsView: View {
    @ObservedObject var store: RosterStore
    @ObservedObject var browser: RosterBrowserModel
    let openPortal: () -> Void
    @State private var confirmClear = false
    @StateObject private var calendarExporter = CalendarExporter()
''',
        "Settings calendar state"
    )

if 'Section("Calendar")' not in content:
    content = require_replace(
        content,
        '''                Section("Portal") {''',
        '''                Section("Calendar") {
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

                Section("Portal") {''',
        "Settings calendar section"
    )

if 'value: "2.5"' not in content:
    content = content.replace('LabeledContent("RAIDO Roster", value: "2.4")', 'LabeledContent("RAIDO Roster", value: "2.5")', 1)

if "Settings calendar alert" not in content:
    old = '''            .confirmationDialog("Clear the saved offline roster?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Cache", role: .destructive) { store.clearCache() }
            }
        }
    }
}

struct DutyHeroCard'''
    new = '''            .confirmationDialog("Clear the saved offline roster?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Cache", role: .destructive) { store.clearCache() }
            }
            .alert("Calendar", isPresented: Binding(
                get: { calendarExporter.message != nil },
                set: { if !$0 { calendarExporter.message = nil } }
            )) {
                Button("OK", role: .cancel) { calendarExporter.message = nil }
            } message: {
                Text(calendarExporter.message ?? "")
            }
            // Settings calendar alert
        }
    }
}

struct DutyHeroCard'''
    content = require_replace(content, old, new, "Settings calendar alert")

# Duty detail: single-duty calendar export.
detail_chunk = content.split("struct RosterDetailView: View", 1)[1].split("struct CategoryBadge", 1)[0]
if "@StateObject private var calendarExporter = CalendarExporter()" not in detail_chunk:
    content = require_replace(
        content,
        '''struct RosterDetailView: View {
    let item: RosterItem
''',
        '''struct RosterDetailView: View {
    let item: RosterItem
    @StateObject private var calendarExporter = CalendarExporter()
''',
        "Duty detail calendar state"
    )

if "Export duty to Calendar" not in content:
    content = require_replace(
        content,
        '''        .navigationTitle("Duty")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CategoryBadge''',
        '''        .navigationTitle("Duty")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { calendarExporter.export(item) } label: {
                    Image(systemName: "calendar.badge.plus")
                }
                .disabled(calendarExporter.isWorking)
                .accessibilityLabel("Export duty to Calendar")
            }
        }
        .alert("Calendar", isPresented: Binding(
            get: { calendarExporter.message != nil },
            set: { if !$0 { calendarExporter.message = nil } }
        )) {
            Button("OK", role: .cancel) { calendarExporter.message = nil }
        } message: {
            Text(calendarExporter.message ?? "")
        }
    }
}

struct CategoryBadge''',
        "Duty detail calendar toolbar"
    )

CONTENT.write_text(content)


# -----------------------------------------------------------------------------
# Robust RAIDO Today jump: independent direct DOM fallback.
# -----------------------------------------------------------------------------
web = WEB.read_text()
old_go_today = '''    func goToday() {
        loadError = nil
        webView?.evaluateJavaScript("window.RAIDOPlus && window.RAIDOPlus.goToday && window.RAIDOPlus.goToday();")
    }
'''
new_go_today = r'''    func goToday() {
        loadError = nil
        let script = """
        (() => {
          try {
            const months = ['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'];
            const n = new Date();
            const token = String(n.getDate()).padStart(2,'0') + months[n.getMonth()] + String(n.getFullYear()).slice(-2);
            const tables = Array.from(document.querySelectorAll('table.activity-table'));
            let target = tables.find(t => {
              const text = (t.innerText || t.textContent || '').replace(/\\s+/g,' ').toUpperCase();
              return text.includes('CHECKIN ' + token) || text.includes('START ' + token);
            });
            if (!target && window.RAIDOPlus?.goToday) {
              const result = window.RAIDOPlus.goToday();
              if (result) return true;
            }
            if (!target) return false;

            const rect = target.getBoundingClientRect();
            const desiredOffset = 150;
            window.scrollTo({ top: Math.max(0, window.scrollY + rect.top - desiredOffset), behavior: 'smooth' });

            let parent = target.parentElement;
            while (parent) {
              const style = getComputedStyle(parent);
              const scrollable = /(auto|scroll)/.test(style.overflowY) && parent.scrollHeight > parent.clientHeight;
              if (scrollable) {
                const pr = parent.getBoundingClientRect();
                parent.scrollTo({
                  top: Math.max(0, parent.scrollTop + rect.top - pr.top - desiredOffset),
                  behavior: 'smooth'
                });
              }
              parent = parent.parentElement;
            }

            target.scrollIntoView({ behavior: 'smooth', block: 'center' });
            const oldOutline = target.style.outline;
            const oldOffset = target.style.outlineOffset;
            target.style.outline = '3px solid #0A84FF';
            target.style.outlineOffset = '3px';
            setTimeout(() => {
              target.style.outline = oldOutline;
              target.style.outlineOffset = oldOffset;
            }, 2500);
            return true;
          } catch (_) {
            return false;
          }
        })();
        """
        webView?.evaluateJavaScript(script)
    }
'''
if new_go_today not in web:
    if old_go_today not in web:
        raise RuntimeError("V2.5 patch marker not found: RosterBrowserModel.goToday")
    web = web.replace(old_go_today, new_go_today, 1)
WEB.write_text(web)


# -----------------------------------------------------------------------------
# App icon asset catalogue. Generate the 1024px source with AppKit, then derive
# legacy iPhone sizes with sips. No binary blob needs to live in the repository.
# -----------------------------------------------------------------------------
assets = SRC / "Assets.xcassets"
appicon = assets / "AppIcon.appiconset"
appicon.mkdir(parents=True, exist_ok=True)
(assets / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2))

icon_swift = ROOT / ".v25_generate_icon.swift"
icon_swift.write_text(r'''
import AppKit

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

let canvas = NSRect(origin: .zero, size: size)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.018, green: 0.050, blue: 0.102, alpha: 1),
    NSColor(calibratedRed: 0.025, green: 0.145, blue: 0.245, alpha: 1)
])!
gradient.draw(in: canvas, angle: 90)

let blue = NSColor(calibratedRed: 0.145, green: 0.600, blue: 1.0, alpha: 1)
let white = NSColor(calibratedRed: 0.95, green: 0.975, blue: 1.0, alpha: 1)
let muted = NSColor(calibratedRed: 0.28, green: 0.42, blue: 0.55, alpha: 1)

let calendar = NSBezierPath(roundedRect: NSRect(x: 190, y: 190, width: 644, height: 644), xRadius: 105, yRadius: 105)
calendar.lineWidth = 30
blue.setStroke()
calendar.stroke()

let header = NSBezierPath()
header.move(to: NSPoint(x: 220, y: 660))
header.line(to: NSPoint(x: 804, y: 660))
header.lineWidth = 26
blue.setStroke()
header.stroke()

white.setFill()
NSBezierPath(roundedRect: NSRect(x: 328, y: 774, width: 64, height: 100), xRadius: 30, yRadius: 30).fill()
NSBezierPath(roundedRect: NSRect(x: 632, y: 774, width: 64, height: 100), xRadius: 30, yRadius: 30).fill()

muted.setFill()
for y in [532.0, 432.0, 332.0] {
    NSBezierPath(roundedRect: NSRect(x: 280, y: y, width: 464, height: 22), xRadius: 11, yRadius: 11).fill()
}

let plane = NSBezierPath()
let points = [
    NSPoint(x: 170, y: 494), NSPoint(x: 430, y: 524), NSPoint(x: 562, y: 704),
    NSPoint(x: 633, y: 704), NSPoint(x: 565, y: 524), NSPoint(x: 795, y: 550),
    NSPoint(x: 846, y: 510), NSPoint(x: 570, y: 468), NSPoint(x: 650, y: 304),
    NSPoint(x: 588, y: 304), NSPoint(x: 505, y: 450), NSPoint(x: 250, y: 412)
]
plane.move(to: points[0])
for p in points.dropFirst() { plane.line(to: p) }
plane.close()
white.setFill()
plane.fill()

let tail = NSBezierPath()
tail.move(to: NSPoint(x: 236, y: 464))
tail.line(to: NSPoint(x: 315, y: 472))
tail.line(to: NSPoint(x: 274, y: 404))
tail.line(to: NSPoint(x: 224, y: 401))
tail.close()
blue.setFill()
tail.fill()

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
''')

source_icon = appicon / "AppIcon-1024.png"
subprocess.run(["/usr/bin/xcrun", "swift", str(icon_swift), str(source_icon)], check=True)
icon_swift.unlink(missing_ok=True)

sizes = [
    ("AppIcon-20@2x.png", 40), ("AppIcon-20@3x.png", 60),
    ("AppIcon-29@2x.png", 58), ("AppIcon-29@3x.png", 87),
    ("AppIcon-40@2x.png", 80), ("AppIcon-40@3x.png", 120),
    ("AppIcon-60@2x.png", 120), ("AppIcon-60@3x.png", 180),
]
for name, pixels in sizes:
    subprocess.run(["/usr/bin/sips", "-z", str(pixels), str(pixels), str(source_icon), "--out", str(appicon / name)], check=True, stdout=subprocess.DEVNULL)

appicon_contents = {
    "images": [
        {"filename": "AppIcon-20@2x.png", "idiom": "iphone", "scale": "2x", "size": "20x20"},
        {"filename": "AppIcon-20@3x.png", "idiom": "iphone", "scale": "3x", "size": "20x20"},
        {"filename": "AppIcon-29@2x.png", "idiom": "iphone", "scale": "2x", "size": "29x29"},
        {"filename": "AppIcon-29@3x.png", "idiom": "iphone", "scale": "3x", "size": "29x29"},
        {"filename": "AppIcon-40@2x.png", "idiom": "iphone", "scale": "2x", "size": "40x40"},
        {"filename": "AppIcon-40@3x.png", "idiom": "iphone", "scale": "3x", "size": "40x40"},
        {"filename": "AppIcon-60@2x.png", "idiom": "iphone", "scale": "2x", "size": "60x60"},
        {"filename": "AppIcon-60@3x.png", "idiom": "iphone", "scale": "3x", "size": "60x60"},
        {"filename": "AppIcon-1024.png", "idiom": "ios-marketing", "scale": "1x", "size": "1024x1024"}
    ],
    "info": {"author": "xcode", "version": 1}
}
(appicon / "Contents.json").write_text(json.dumps(appicon_contents, indent=2))


# -----------------------------------------------------------------------------
# Xcode project: Assets catalogue, icon, EventKit permission purpose string,
# and V2.5 bundle version.
# -----------------------------------------------------------------------------
pbx = PBX.read_text()
if "Assets.xcassets in Resources" not in pbx:
    pbx = pbx.replace(
        'A00000000000000000000004 /* RosterEnhancements.js in Resources */ = {isa = PBXBuildFile; fileRef = B00000000000000000000004 /* RosterEnhancements.js */; };',
        'A00000000000000000000004 /* RosterEnhancements.js in Resources */ = {isa = PBXBuildFile; fileRef = B00000000000000000000004 /* RosterEnhancements.js */; };\n\t\tA00000000000000000000005 /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = B00000000000000000000007 /* Assets.xcassets */; };'
    )
    pbx = pbx.replace(
        'B00000000000000000000004 /* RosterEnhancements.js */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.javascript; path = RosterEnhancements.js; sourceTree = "<group>"; };',
        'B00000000000000000000004 /* RosterEnhancements.js */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.javascript; path = RosterEnhancements.js; sourceTree = "<group>"; };\n\t\tB00000000000000000000007 /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; };'
    )
    pbx = pbx.replace(
        '\t\t\t\tB00000000000000000000004 /* RosterEnhancements.js */,',
        '\t\t\t\tB00000000000000000000004 /* RosterEnhancements.js */,\n\t\t\t\tB00000000000000000000007 /* Assets.xcassets */,'
    )
    pbx = pbx.replace(
        'files = (A00000000000000000000004 /* RosterEnhancements.js in Resources */,);',
        'files = (A00000000000000000000004 /* RosterEnhancements.js in Resources */, A00000000000000000000005 /* Assets.xcassets in Resources */,);'
    )

if "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;" not in pbx:
    pbx = pbx.replace("\t\t\tCODE_SIGN_STYLE = Automatic;", "\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;\n\t\t\tCODE_SIGN_STYLE = Automatic;")
if "INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription" not in pbx:
    pbx = pbx.replace(
        "\t\t\tGENERATE_INFOPLIST_FILE = YES;",
        "\t\t\tGENERATE_INFOPLIST_FILE = YES;\n\t\t\tINFOPLIST_KEY_NSCalendarsFullAccessUsageDescription = \"Allow RAIDO Roster to add and update your duty schedule in Calendar.\";"
    )
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 3;", "CURRENT_PROJECT_VERSION = 5;")
pbx = pbx.replace("MARKETING_VERSION = 2.1;", "MARKETING_VERSION = 2.5;")
PBX.write_text(pbx)

print("V2.5 source patch applied")
