"""Render the generated native Ice screens using synthetic roster data only.

The simulator host is temporary. The already-packaged release IPA is hashed and
must remain unchanged. No real roster, credentials or live ADS-B are used.
"""
from pathlib import Path
import hashlib
import json
import plistlib
import subprocess
import time
import shutil
import zipfile

root = Path(__file__).resolve().parents[1] / 'RAIDORoster-Web2IPA'
ipa = root / 'RAIDORoster-unsigned.ipa'
assert ipa.exists(), 'Package the release IPA before rendering'
before = hashlib.sha256(ipa.read_bytes()).hexdigest()
content = root / 'RAIDORoster/ContentView.swift'
app = root / 'RAIDORoster/RAIDORosterApp.swift'
original_content, original_app = content.read_text(), app.read_text()
preview = r'''
extension RosterStore {
    fileprivate func installIceFixture() {
        let today = Date(), calendar = Calendar.current
        let year = calendar.component(.year, from: today), month = calendar.component(.month, from: today)
        let currentDay = calendar.component(.day, from: today)
        let start = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
        let days = calendar.range(of: .day, in: .month, for: start)!
        let members = [CrewMember(role: "SCCM", code: "AAA", name: "Alex Morgan", country: nil, phone: nil),
                       CrewMember(role: "CCM", code: "BBB", name: "Jamie Taylor", country: nil, phone: nil)]
        let items = days.map { day -> RosterItem in
            let iso = String(format: "%04d-%02d-%02d", year, month, day)
            let fly = day == currentDay || day % 3 == 0
            let category = fly ? "FLIGHT" : day % 4 == 0 ? "STANDBY" : "OFF"
            func sector(_ inbound: Bool) -> RosterActivity {
                RosterActivity(id: iso + (inbound ? "-b" : "-a"), code: inbound ? "GJT102" : "GJT101", category: "FLIGHT", title: "Flight",
                    description: "Sample flight", route: inbound ? "PFO-TLV" : "TLV-PFO", station: inbound ? "PFO" : "TLV",
                    checkInLT: inbound ? "" : iso + " 11:30", checkInUTC: inbound ? "" : iso + " 08:30",
                    startLT: iso + (inbound ? " 14:10" : " 12:15"), startUTC: iso + (inbound ? " 11:10" : " 09:15"),
                    endLT: iso + (inbound ? " 15:10" : " 13:15"), endUTC: iso + (inbound ? " 12:10" : " 10:15"),
                    checkOutLT: inbound ? iso + " 15:40" : "", checkOutUTC: inbound ? iso + " 12:40" : "",
                    hotelName: "", pickup: "10:40", transferNote: "Sample hotel pickup", activityNote: "", dayNote: "",
                    aircraftReg: "LY-GYM", aircraftType: "A320", aircraftVersion: "", aircraftPhone: "", crew: members, rawText: "Sample duty")
            }
            return RosterItem(id: iso, index: day, dateISO: iso, dateText: iso, category: category,
                title: fly ? "Flight duty" : category.capitalized, route: fly ? "TLV-PFO-TLV" : "", timeText: fly ? "11:30–15:40" : "",
                rawText: "Sample roster", cells: [], activities: fly ? [sector(false), sector(true)] : [], activeHotels: nil)
        }
        let monthKey = String(format: "%04d-%02d", year, month)
        let value = RosterSnapshot(capturedAt: today, sourceURL: "https://example.invalid/preview", pageTitle: "Sample roster", items: items,
            validation: RosterValidation(isValid: true, parser: "preview", month: monthKey, datedRows: items.count, message: "Sample data"), monthlyBLH: "40:00")
        snapshot = value; monthSnapshots = [monthKey: value]; selectedRosterMonthKey = monthKey
    }
}

struct IcePreviewRoot: View {
    @StateObject private var store: RosterStore
    @StateObject private var browser: RosterBrowserModel
    @State private var selected: MainTab
    init() {
        let store = RosterStore(); store.installIceFixture()
        _store = StateObject(wrappedValue: store)
        _browser = StateObject(wrappedValue: RosterBrowserModel(store: store))
        let name = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--tab=") })?.dropFirst(6) ?? "today"
        _selected = State(initialValue: name == "roster" ? .roster : name == "fleet" ? .fleet : name == "more" ? .more : .today)
    }
    var body: some View {
        TabView(selection: $selected) {
            TodayView(store: store) {}.tabItem { Label("Today", systemImage: "sun.max") }.tag(MainTab.today)
            RosterHomeView(store: store, browser: browser) {}.tabItem { Label("Roster", systemImage: "calendar") }.tag(MainTab.roster)
            FleetView(store: store, tabActive: false, showsDismissButton: false).tabItem { Label("Fleet", systemImage: "airplane") }.tag(MainTab.fleet)
            IceMoreView(store: store, browser: browser) {}.tabItem { Label("More", systemImage: "ellipsis") }.tag(MainTab.more)
        }.environmentObject(store).tint(MidnightTheme.accent).foregroundStyle(MidnightTheme.ink)
    }
}
'''

def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

try:
    generated = original_content.replace('@State private var mapExpanded = false',
        '@State private var mapExpanded = ProcessInfo.processInfo.arguments.contains("--expanded")')
    # Force the local basemap in the disposable preview, independent of network.
    generated = generated.replace('private var todayMapSource = "auto"', 'private var todayMapSource = "offline"')
    # Display all Fleet definitions immediately, without polling or network data.
    generated = generated.replace('@State private var showOtherFleet = false', '@State private var showOtherFleet = true')
    content.write_text(generated + preview)
    app.write_text(original_app.replace('ContentView()', 'IcePreviewRoot()').replace('.preferredColorScheme(preferredScheme)',
        '.preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--dark") ? .dark : .light)'))
    with open('/tmp/raido-ice-preview-build.log', 'w') as log:
        try:
            run(['xcodebuild', '-project', str(root / 'RAIDORoster.xcodeproj'), '-scheme', 'RAIDORoster', '-configuration', 'Debug',
                 '-sdk', 'iphonesimulator', '-destination', 'generic/platform=iOS Simulator', '-derivedDataPath', '/tmp/raido-ice-preview',
                 'CODE_SIGNING_ALLOWED=NO', 'build'], stdout=log, stderr=subprocess.STDOUT)
        except subprocess.CalledProcessError:
            print('\n'.join(line for line in Path(log.name).read_text().splitlines() if 'error:' in line))
            raise
    product = Path('/tmp/raido-ice-preview/Build/Products/Debug-iphonesimulator/RAIDORoster.app')
    plist_path = product / 'Info.plist'
    info = plistlib.loads(plist_path.read_bytes())
    # The release packaging script adds these keys after xcodebuild. Mirror the
    # packaged configuration in the simulator too: CLLocationManager asserts
    # when background updates are enabled without the location background mode.
    with zipfile.ZipFile(ipa) as archive:
        packaged = plistlib.loads(archive.read('Payload/RAIDORoster.app/Info.plist'))
    for key, value in packaged.items():
        if key == 'UIBackgroundModes' or (key.startswith('NS') and key.endswith('UsageDescription')):
            info[key] = value
    plist_path.write_bytes(plistlib.dumps(info))
    bundle = info['CFBundleIdentifier']
    devices = json.loads(run(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], capture_output=True, text=True).stdout)
    choices = [d for group in devices['devices'].values() for d in group if d['name'].startswith('iPhone')]
    device = next((d for d in choices if d['name'] == 'iPhone 16 Pro'), choices[0])
    udid = device['udid']
    if device['state'] != 'Booted': run(['xcrun', 'simctl', 'boot', udid])
    run(['xcrun', 'simctl', 'bootstatus', udid, '-b'])
    run(['xcrun', 'simctl', 'install', udid, str(product)])
    run(['xcrun', 'simctl', 'status_bar', udid, 'override', '--time', '06:44', '--batteryState', 'charged', '--batteryLevel', '100'])
    for theme in ['light', 'dark']:
        run(['xcrun', 'simctl', 'ui', udid, 'appearance', theme])
        for tab in ['today', 'roster', 'fleet', 'more', 'expanded']:
            print('Rendering', tab, theme, flush=True)
            args = ['xcrun', 'simctl', 'launch', '--stdout=/tmp/raido-ice-app-stdout.log',
                    '--stderr=/tmp/raido-ice-app-stderr.log', udid, bundle, '--tab=' + ('today' if tab == 'expanded' else tab)]
            if theme == 'dark': args.append('--dark')
            if tab == 'expanded': args.append('--expanded')
            run(args)
            time.sleep(3)
            run(['xcrun', 'simctl', 'io', udid, 'screenshot', f'/tmp/raido-ice-{tab}-{theme}.png'])
            run(['xcrun', 'simctl', 'terminate', udid, bundle])
finally:
    for report in (Path.home() / 'Library/Logs/DiagnosticReports').glob('RAIDORoster*'):
        if report.is_file(): shutil.copy(report, Path('/tmp') / ('raido-ice-crash-' + report.name))
    stderr = Path('/tmp/raido-ice-app-stderr.log')
    if stderr.exists(): print(stderr.read_text(errors='replace')[-6000:])
    content.write_text(original_content); app.write_text(original_app)
    assert hashlib.sha256(ipa.read_bytes()).hexdigest() == before, 'Preview changed the release IPA'
