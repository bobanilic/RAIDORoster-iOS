"""Render both native themes using synthetic roster data only.

The simulator host is temporary. The already-packaged release IPA is hashed and
must remain unchanged. No real roster, credentials or live ADS-B are used.
"""
from pathlib import Path
import hashlib
import json
import plistlib
import platform
import subprocess
import time
import shutil
import zipfile
import sys
import argparse
from install_preview_ui_checks import install as install_ui_checks
from simulator_devices import BOOT_TIMEOUT_SECONDS, newest_iphone
from ui_test_runner import run_startup_tests

startup_cases = {
    'four-sectors': 'testFourSectorsAcrossTwoDutyGroups',
    'login': 'testCleanInstallMobileLoginAndReturnToTabs',
    'responsiveness': 'testProductionLaunchAndTabResponsiveness',
    'today-return': 'testTodayReturnWithAutomaticMapAndNotificationsDisabled',
}
parser = argparse.ArgumentParser()
parser.add_argument('--startup-case', choices=startup_cases)
options, _ = parser.parse_known_args()
if options.startup_case and '--startup-only' not in sys.argv:
    parser.error('--startup-case requires --startup-only')

root = Path(__file__).resolve().parents[1] / 'RAIDORoster-Web2IPA'
ipa = root / 'RAIDORoster-unsigned.ipa'
assert ipa.exists(), 'Package the release IPA before rendering'
before = hashlib.sha256(ipa.read_bytes()).hexdigest()
content = root / 'RAIDORoster/ContentView.swift'
app = root / 'RAIDORoster/RAIDORosterApp.swift'
announcement_view = root / 'RAIDORoster/AnnouncementsView.swift'
original_content, original_app = content.read_text(), app.read_text()
fleet_source = root / 'RAIDORoster/FleetView.swift'
original_fleet = fleet_source.read_text()
store_source = root / 'RAIDORoster/RosterStore.swift'
original_store = store_source.read_text()
priority_source = root / 'RAIDORoster/TodayPriorityViews.swift'
original_priority = priority_source.read_text()
original_announcements = announcement_view.read_text()
project = root / 'RAIDORoster.xcodeproj'
original_project = (project / 'project.pbxproj').read_bytes()
test_scheme = None
ephemeral_simulator = None
preview = r'''
extension RosterStore {
    func installIceFixture() {
        let today = Date(), calendar = Calendar.current
        let todayReturn = ProcessInfo.processInfo.arguments.contains("--today-return")
        let origin = todayReturn ? "VNO" : "TLV", destination = todayReturn ? "LEJ" : "PFO"
        let year = calendar.component(.year, from: today), month = calendar.component(.month, from: today)
        let currentDay = calendar.component(.day, from: today)
        let start = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
        let days = calendar.range(of: .day, in: .month, for: start)!
        let members = [CrewMember(role: "SCCM", code: "AAA", name: "Alex Morgan", country: nil, phone: nil),
                       CrewMember(role: "CCM", code: "BBB", name: "Jamie Taylor", country: nil, phone: nil)]
        var items = days.map { day -> RosterItem in
            let iso = String(format: "%04d-%02d-%02d", year, month, day)
            let fly = day == currentDay || day % 3 == 0
            let category = fly ? "FLIGHT" : day % 4 == 0 ? "STANDBY" : "OFF"
            func sector(_ inbound: Bool) -> RosterActivity {
                RosterActivity(id: iso + (inbound ? "-b" : "-a"), code: inbound ? "GJT102" : "GJT101", category: "FLIGHT", title: "Flight",
                    description: "Sample flight", route: inbound ? destination+"-"+origin : origin+"-"+destination, station: inbound ? destination : origin,
                    checkInLT: inbound ? "" : iso + " 11:30", checkInUTC: inbound ? "" : iso + " 08:30",
                    startLT: iso + (inbound ? " 14:10" : " 12:15"), startUTC: iso + (inbound ? " 11:10" : " 09:15"),
                    endLT: iso + (inbound ? " 15:10" : " 13:15"), endUTC: iso + (inbound ? " 12:10" : " 10:15"),
                    checkOutLT: inbound ? iso + " 15:40" : "", checkOutUTC: inbound ? iso + " 12:40" : "",
                    hotelName: "", pickup: "10:40", transferNote: "Sample hotel pickup", activityNote: "", dayNote: "",
                    aircraftReg: ProcessInfo.processInfo.arguments.contains("--airhub") ? "9HGTS" : "LYTEN", aircraftType: "A320", aircraftVersion: "", aircraftPhone: "", crew: members, rawText: "Sample duty")
            }
            return RosterItem(id: iso, index: day, dateISO: iso, dateText: iso, category: category,
                title: fly ? "Flight duty" : category.capitalized, route: fly ? origin+"-"+destination+"-"+origin : "", timeText: fly ? "11:30–15:40" : "",
                rawText: "Sample roster", cells: [], activities: fly ? [sector(false), sector(true)] : [], activeHotels: nil)
        }
        if ProcessInfo.processInfo.arguments.contains("--priorities") {
            let off = ProcessInfo.processInfo.arguments.contains("--off-day")
            let model = items.flatMap(\.flightActivities).first!
            func stamp(_ date: Date, zone: TimeZone) -> String {
                let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.timeZone = zone; f.dateFormat="yyyy-MM-dd HH:mm"
                return f.string(from:date)
            }
            let utc = TimeZone(secondsFromGMT:0)!, local = TimeZone(identifier:"Asia/Jerusalem")!
            func revised(_ values: [String:String]) -> RosterActivity {
                var raw = try! JSONSerialization.jsonObject(with:JSONEncoder().encode(model)) as! [String:Any]
                for (key,value) in values { raw[key]=value }
                return try! JSONDecoder().decode(RosterActivity.self,from:JSONSerialization.data(withJSONObject:raw))
            }
            let todayISO = EarningsMath.day(today)
            if off, let index = items.firstIndex(where:{$0.dateISO == todayISO}) {
                items[index] = RosterItem(id:todayISO,index:currentDay,dateISO:todayISO,dateText:todayISO,
                    category:"OFF",title:"Day off",route:"",timeText:"",rawText:"Sample day off",cells:[],activities:[],activeHotels:nil)
            }
            if !off {
                let pickup=today.addingTimeInterval(45*60), report=today.addingTimeInterval(60*60)
                let start=today.addingTimeInterval(90*60), end=start.addingTimeInterval(3600)
                let iso=EarningsMath.day(start)
                let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.timeZone=local; f.dateFormat="d MMM HH:mm"
                let flight=revised(["id":"priority-flight","pickup":f.string(from:pickup)+" LT","checkInUTC":stamp(report,zone:utc),"checkInLT":stamp(report,zone:local),
                    "startUTC":stamp(start,zone:utc),"startLT":stamp(start,zone:local),"endUTC":stamp(end,zone:utc),"endLT":stamp(end,zone:local)])
                items.removeAll {$0.dateISO == iso}
                items.append(RosterItem(id:iso,index:currentDay,dateISO:iso,dateText:iso,category:"FLIGHT",title:"Flight duty",route:flight.route,timeText:flight.timeText,
                    rawText:"Sample priority flight",cells:[],activities:[flight],activeHotels:nil))
            }
            let moveDate=calendar.date(byAdding:.day,value:4,to:today)!, moveISO=EarningsMath.day(moveDate)
            let move=revised(["id":"priority-move","code":"RLCN","category":"RELOCATION","title":"Hotel relocation","description":"Sample hotel change",
                "route":"","station":"VNO","startLT":"","startUTC":"","endLT":"","endUTC":"","checkInLT":"","checkInUTC":"","checkOutLT":"","checkOutUTC":"",
                "pickup":"","transferNote":"","hotelName":"Hotel Central","aircraftReg":""])
            items.removeAll {$0.dateISO == moveISO}
            items.append(RosterItem(id:moveISO,index:currentDay+4,dateISO:moveISO,dateText:moveISO,category:"OFF",title:"Day off",route:"",timeText:"",
                rawText:"Sample relocation",cells:[],activities:[move],activeHotels:nil))
            items.sort {($0.dateISO ?? "") < ($1.dateISO ?? "")}
        }
        if ProcessInfo.processInfo.arguments.contains("--split-duty") {
            let iso = EarningsMath.day(today), model = items.flatMap(\.flightActivities).first!
            func flight(_ code: String, _ route: String, _ start: String, _ end: String) -> RosterActivity {
                var raw = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as! [String: Any]
                for (key, value) in ["id":code,"code":code,"route":route,"startLT":iso+" "+start,"startUTC":iso+" "+start,
                    "endLT":iso+" "+end,"endUTC":iso+" "+end,"checkInLT":"","checkInUTC":"","checkOutLT":"","checkOutUTC":"","pickup":""] { raw[key]=value }
                return try! JSONDecoder().decode(RosterActivity.self, from: JSONSerialization.data(withJSONObject: raw))
            }
            let flights = [flight("DI9003","VNO-LEJ","06:00","07:10"),flight("DI6656","LEJ-RHO","08:00","12:05"),
                flight("DI6657","RHO-LEJ","12:55","15:05"),flight("DI9004","LEJ-VNO","19:10","22:05")]
            items.removeAll { $0.dateISO == iso }
            for (index, activities) in [Array(flights.prefix(3)), [flights[3]]].enumerated() {
                items.append(RosterItem(id:iso+"-duty-\(index)",index:currentDay*10+index,dateISO:iso,dateText:iso,
                    category:"FLIGHT",title:"Flight duty",route:activities.map(\.route).joined(separator:" · "),timeText:"",
                    rawText:"Synthetic split duty",cells:[],activities:activities,activeHotels:nil))
            }
        }
        let monthKey = String(format: "%04d-%02d", year, month)
        let value = RosterSnapshot(capturedAt: today, sourceURL: "https://example.invalid/preview", pageTitle: "Sample roster", items: items,
            validation: RosterValidation(isValid: true, parser: "preview", month: monthKey, datedRows: items.count, message: "Sample data"), monthlyBLH: "40:00")
        snapshot = value; monthSnapshots = [monthKey: value]; selectedRosterMonthKey = monthKey
        for (key,rows) in Dictionary(grouping:items,by:{String(($0.dateISO ?? "").prefix(7))}) where key != monthKey {
            monthSnapshots[key]=RosterSnapshot(capturedAt:today,sourceURL:value.sourceURL,pageTitle:value.pageTitle,items:rows,
                validation:RosterValidation(isValid:true,parser:"preview",month:key,datedRows:rows.count,message:"Sample data"),monthlyBLH:nil)
        }

    }
}

extension RosterStore {
    func persistStartupFixture() {
        if let snapshot { save(snapshot) }
        saveMonthSnapshots()
    }
}

struct IcePreviewRoot: View {
    @Environment(\.raidoTheme) private var raidoVisualTheme
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
        let _ = raidoVisualTheme
        TabView(selection: $selected) {
            TodayView(store: store) {}.tabItem { Label("Today", systemImage: "sun.max") }.tag(MainTab.today)
            RosterHomeView(store: store, browser: browser) {}.tabItem { Label("Roster", systemImage: "calendar") }.tag(MainTab.roster)
            FleetView(store: store, tabActive: false, showsDismissButton: false).tabItem { Label("Fleet", systemImage: "airplane") }.tag(MainTab.fleet)
            IceMoreView(store: store, browser: browser) {}.tabItem { Label("More", systemImage: "ellipsis") }.tag(MainTab.more)
        }.environmentObject(store).tint(MidnightTheme.accent).foregroundStyle(MidnightTheme.ink)
            .sheet(isPresented: .constant(ProcessInfo.processInfo.arguments.contains("--settings") || ProcessInfo.processInfo.arguments.contains("--announcements") || ProcessInfo.processInfo.arguments.contains("--crew-control"))) {
                if ProcessInfo.processInfo.arguments.contains("--announcements") {
                    AnnouncementsView(item: store.todayPrimaryItem)
                } else if ProcessInfo.processInfo.arguments.contains("--crew-control") {
                    CrewControlSheet(item: store.todayPrimaryItem)
                } else { SettingsView(store: store, browser: browser) {} }
            }
            .task {
                if let raw = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--switch-to=") })?.dropFirst(12),
                   let theme = RaidoTheme(rawValue: String(raw)) {
                    try? await Task.sleep(for: .seconds(1))
                    UserDefaults.standard.set(theme.rawValue, forKey: RaidoAppearancePreferences.themeKey)
                }
            }
    }
}
'''

def run(args, **kwargs):
    # Keep provisioning/build/cleanup timestamps separate from buffered XCTest
    # output, whose CI upload timestamp is not its execution timestamp.
    label = ' '.join(str(value) for value in args[:4])
    started = time.monotonic()
    def phase(message):
        line = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()) + ' ' + message
        print(line, flush=True)
        with Path('/tmp/raido-simulator-phases.log').open('a') as log:
            log.write(line + '\n')
    phase('Started: ' + label)
    kwargs.setdefault('check', True)
    outcome = 'interrupted'
    try:
        result = subprocess.run(args, **kwargs)
        outcome = 'exit=' + str(result.returncode)
        return result
    except subprocess.CalledProcessError as error:
        outcome = 'exit=' + str(error.returncode)
        raise
    except subprocess.TimeoutExpired:
        outcome = 'timed out'
        raise
    finally:
        phase(f'Ended: {label}; {outcome}; elapsed={time.monotonic() - started:.3f}s')

try:
    # Exercise the same selectSector action used by the actual Flight picker.
    # Multi-sector duties still require an explicit selection in the release.
    announcements = original_announcements.replace('                initialized = true', '''                initialized = true
                if ProcessInfo.processInfo.arguments.contains("--announcements"), let sector = sectors.first {
                    selectSector(sector.id)
                    let expected: AnnouncementAirline = ProcessInfo.processInfo.arguments.contains("--airhub") ? .airhub : .getjet
                    precondition(airline == expected, "Flight selection did not select its operator")
                    precondition(aircraft == .a320, "Flight selection lost the aircraft type")
                    precondition(expected == .airhub || !available.isEmpty, "Selected GetJet flight has no offline announcements")
                    print("Verified selected announcement flight: \\(sector.code), \\(sector.aircraftReg), \\(airline.label)")
                    return
                }''')
    assert announcements != original_announcements
    announcement_view.write_text(announcements)
    generated = original_content.replace('@State private var mapExpanded = false',
        '@State private var mapExpanded = ProcessInfo.processInfo.arguments.contains("--expanded")')
    # Force the local basemap in the disposable preview, independent of network.
    if '--startup-only' not in sys.argv:
        generated = generated.replace('private var todayMapSource = "auto"', 'private var todayMapSource = "offline"')
    # Display all Fleet definitions immediately, without polling or network data.
    fleet_source.write_text(original_fleet.replace('@State private var showOtherFleet = false', '@State private var showOtherFleet = true'))
    fixture, preview_views = preview.split('struct IcePreviewRoot: View {', 1)
    store_source.write_text(original_store + fixture)
    content.write_text(generated + 'struct IcePreviewRoot: View {' + preview_views)
    # Disposable host diagnostics contain counts and lifecycle state only. They
    # distinguish a missing synthetic event from an inactive leaf in xcresult.
    marker = '            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in'
    assert original_priority.count(marker) == 1
    diagnostic = '''            .onAppear {
                print("Synthetic priority leaf: activeTab=\\(tabActive), scene=\\(scenePhase), events=\\(store.todayPriorityEvents(at: Date()).count)")
            }
            .onChange(of: scenePhase) { _, value in
                print("Synthetic priority scene: \\(value)")
            }
'''
    priority_source.write_text(original_priority.replace(marker, diagnostic + marker))
    host = original_app.replace('ContentView()', 'Group { if ProcessInfo.processInfo.arguments.contains("--startup") { ContentView() } else { IcePreviewRoot() } }')
    host = host.replace('        RaidoAppearancePreferences.migrate(.standard)', '''
        let args = ProcessInfo.processInfo.arguments
        let rawTheme = args.first(where: { $0.hasPrefix("--theme=") }).map { String($0.dropFirst(8)) } ?? "ice"
        let mode = args.first(where: { $0.hasPrefix("--mode=") }).map { String($0.dropFirst(7)) } ?? "system"
        UserDefaults.standard.set(rawTheme, forKey: RaidoAppearancePreferences.themeKey)
        UserDefaults.standard.set(mode, forKey: RaidoAppearancePreferences.iceKey)
        UserDefaults.standard.set(mode, forKey: RaidoAppearancePreferences.getJetKey)
        if let chosen = args.first(where: { $0.hasPrefix("--palette=") }).map({ String($0.dropFirst(10)) }) {
            UserDefaults.standard.set(chosen, forKey: rawTheme == "getJet" ? RaidoAppearancePreferences.getJetPaletteKey : RaidoAppearancePreferences.icePaletteKey)
        }
        RaidoAppearancePreferences.migrate(.standard)
        if args.contains("--today-return") {
            UserDefaults.standard.set("auto", forKey: "RAIDORoster.TodayMapSource")
            UserDefaults.standard.set(false, forKey: LockScreenPolicy.pickupKey)
            UserDefaults.standard.set(false, forKey: LockScreenPolicy.precautionKey)
            UserDefaults.standard.set(0, forKey: "RAIDORoster.PickupReminderLead")
            UserDefaults.standard.set(0, forKey: "RAIDORoster.ReportReminderLead")
        }
        if args.contains("--startup") {
            let fixture = RosterStore(automaticSideEffects:false)
            if args.contains("--clean-install") {
                fixture.clearCache()
                UserDefaults.standard.removeObject(forKey: "RAIDORoster.LastPortalURL")
            } else if !args.contains("--reuse-startup-cache") {
                fixture.installIceFixture();fixture.persistStartupFixture()
                if args.contains("--priorities"), !args.contains("--off-day") {
                    let restored = RosterStore(automaticSideEffects: false)
                    let events = restored.todayPriorityEvents(at: Date())
                    precondition(events.contains { $0.kind == .pickup }, "Synthetic cached priority fixture must contain pickup")
                    print("Synthetic cached priority fixture: \\(events.count) events")
                }
            }
        }''')
    app.write_text(host)
    with zipfile.ZipFile(ipa) as archive:
        packaged = plistlib.loads(archive.read('Payload/RAIDORoster.app/Info.plist'))
    test_scheme = install_ui_checks(project, packaged)
    with open('/tmp/raido-ice-preview-build.log', 'w') as log:
        try:
            run(['xcodebuild', '-project', str(root / 'RAIDORoster.xcodeproj'), '-scheme', 'RAIDOMapChecks', '-configuration', 'Debug',
                 '-sdk', 'iphonesimulator', '-destination', 'generic/platform=iOS Simulator', '-derivedDataPath', '/tmp/raido-ice-preview',
                 'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_STYLE=Manual',
                 'CODE_SIGN_IDENTITY=-', 'AD_HOC_CODE_SIGNING_ALLOWED=YES',
                 'ONLY_ACTIVE_ARCH=YES', 'ARCHS=' + platform.machine(), 'build-for-testing'], stdout=log, stderr=subprocess.STDOUT)
        except subprocess.CalledProcessError:
            print('\n'.join(line for line in Path(log.name).read_text().splitlines() if 'error:' in line))
            raise
    product = Path('/tmp/raido-ice-preview/Build/Products/Debug-iphonesimulator/RAIDORoster.app')
    plist_path = product / 'Info.plist'
    info = plistlib.loads(plist_path.read_bytes())
    # The real Info.plist now owns these keys. Verify parity without mutating
    # the built bundle and invalidating its simulator code signature.
    for key, value in packaged.items():
        if key == 'UIBackgroundModes' or (key.startswith('NS') and key.endswith('UsageDescription')):
            assert info.get(key) == value, f'Simulator privacy configuration differs: {key}'
    bundle = info['CFBundleIdentifier']
    devices = json.loads(run(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], capture_output=True, text=True).stdout)
    runtime, device = newest_iphone(devices['devices'])
    udid = device['udid']
    if '--startup-only' in sys.argv:
        # A fresh device has no app to uninstall. Avoid an unrelated stale
        # simulator/uninstall blocking the clean-install tests before launch.
        udid = run(['xcrun', 'simctl', 'create', 'RAIDO-startup-checks', device['deviceTypeIdentifier'], runtime],
                   capture_output=True, text=True, timeout=60).stdout.strip()
        ephemeral_simulator = udid
    # Finish boot outside the XCTest watchdog, as the native runner does.
    if ephemeral_simulator or device['state'] != 'Booted':
        run(['xcrun', 'simctl', 'boot', udid], timeout=60)
    run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], timeout=BOOT_TIMEOUT_SECONDS)
    if '--startup-only' not in sys.argv:
        run(['xcrun', 'simctl', 'install', udid, str(product)], timeout=90)
        run(['xcrun', 'simctl', 'status_bar', udid, 'override', '--time', '06:44', '--batteryState', 'charged', '--batteryLevel', '100'])
    # For startup checks XCTest installs/boots the app and runner together, as
    # in the passing native suite. A separate simctl install was hanging before
    # any UI test ran. UI execution and its one AX recovery have separate bounds.
    if '--startup-only' in sys.argv:
        cases = [startup_cases[options.startup_case]] if options.startup_case else list(startup_cases.values())
        result = '/tmp/raido-startup-' + (options.startup_case or 'all') + '.xcresult'
        log = Path('/tmp/raido-startup-ui-tests.log')
        try:
            run_startup_tests(['xcodebuild','-project',str(project),'-scheme','RAIDOMapChecks','-configuration','Debug',
                '-destination','platform=iOS Simulator,id='+udid,'-derivedDataPath','/tmp/raido-ice-preview',
                '-parallel-testing-enabled','NO','CODE_SIGNING_ALLOWED=YES','CODE_SIGNING_REQUIRED=NO',
                'CODE_SIGN_STYLE=Manual','CODE_SIGN_IDENTITY=-','AD_HOC_CODE_SIGNING_ALLOWED=YES',
                *['-only-testing:RAIDOMapChecks/MapGestureUITests/' + case for case in cases]], log, result)
        except (subprocess.CalledProcessError,subprocess.TimeoutExpired,RuntimeError):
            print(log.read_text()[-12000:]);raise
        print('Passed startup scenarios: ' + ', '.join(cases),flush=True)
        sys.exit(0)
    combinations = [(theme, palette, mode, tab)
        for theme in ['ice', 'getJet'] for palette in ['iceBlue', 'forestGreen', 'midnightChampagne', 'burgundyRose', 'espressoBronze']
        for mode in ['light', 'dark'] for tab in (['roster', 'settings'] if palette == 'forestGreen' else ['roster'])]
    if '--palette-only' in sys.argv:
        for theme, palette, mode, tab in combinations:
            print('Rendering palette', theme, palette, mode, tab, flush=True)
            run(['xcrun', 'simctl', 'ui', udid, 'appearance', mode])
            args = ['xcrun', 'simctl', 'launch', '--stdout=/tmp/raido-ice-app-stdout.log',
                    '--stderr=/tmp/raido-ice-app-stderr.log', udid, bundle,
                    '--theme=' + theme, '--palette=' + palette, '--mode=' + mode, '--tab=' + ('more' if tab == 'settings' else tab)]
            if tab == 'settings': args.append('--settings')
            run(args); time.sleep(2)
            run(['xcrun', 'simctl', 'io', udid, 'screenshot', f'/tmp/raido-theme-{theme}-{palette}-{tab}-{mode}.png'])
            run(['xcrun', 'simctl', 'terminate', udid, bundle])
    else:
        for palette in ['ice', 'getJet']:
            for mode in ['light', 'dark', 'system']:
                for system_mode in (['light', 'dark'] if mode == 'system' else [mode]):
                    run(['xcrun', 'simctl', 'ui', udid, 'appearance', system_mode])
                    for tab in (['today'] if mode == 'system' else ['today', 'expanded'] if '--map-only' in sys.argv else ['today', 'roster', 'fleet', 'more', 'expanded', 'settings', 'announcements', 'announcements-airhub', 'crew-control']):
                        print('Rendering', palette, mode, system_mode, tab, flush=True)
                        args = ['xcrun', 'simctl', 'launch', '--stdout=/tmp/raido-ice-app-stdout.log',
                                '--stderr=/tmp/raido-ice-app-stderr.log', udid, bundle,
                                '--theme=' + palette, '--mode=' + mode,
                                '--tab=' + ('today' if tab == 'expanded' else 'more' if tab == 'settings' else tab)]
                        if tab == 'expanded': args.append('--expanded')
                        if tab == 'settings': args.append('--settings')
                        if tab.startswith('announcements'): args.append('--announcements')
                        if tab == 'announcements-airhub': args.append('--airhub')
                        if tab == 'crew-control': args.append('--crew-control')
                        run(args)
                        time.sleep(3)
                        run(['xcrun', 'simctl', 'io', udid, 'screenshot', f'/tmp/raido-theme-{palette}-{tab}-{mode}-{system_mode}.png'])
                        run(['xcrun', 'simctl', 'terminate', udid, bundle])
    # Change theme inside the same running view hierarchy, exercising palette
    # invalidation and UIKit chrome refresh rather than only cold starts.
    for theme in ['ice', 'getJet']:
        for mode in ['light', 'dark']:
            run(['xcrun','simctl','ui',udid,'appearance',mode])
            run(['xcrun','simctl','launch',udid,bundle,'--theme='+theme,'--mode='+mode,'--tab=today','--priorities'])
            time.sleep(3)
            run(['xcrun','simctl','io',udid,'screenshot',f'/tmp/raido-priorities-{theme}-{mode}.png'])
            run(['xcrun','simctl','terminate',udid,bundle])
    for target in ['getJet', 'ice']:
        origin = 'ice' if target == 'getJet' else 'getJet'
        print('Rendering live theme switch', origin, target, flush=True)
        args = ['xcrun', 'simctl', 'launch', '--stdout=/tmp/raido-ice-app-stdout.log',
                '--stderr=/tmp/raido-ice-app-stderr.log', udid, bundle,
                '--theme=' + origin, '--mode=light', '--tab=today', '--switch-to=' + target]
        run(args)
        time.sleep(4)
        run(['xcrun', 'simctl', 'io', udid, 'screenshot', f'/tmp/raido-theme-switch-{target}.png'])
        run(['xcrun', 'simctl', 'terminate', udid, bundle])
    with open('/tmp/raido-map-ui-tests.log', 'w') as log:
        try:
            run(['xcodebuild', '-project', str(project), '-scheme', 'RAIDOMapChecks', '-configuration', 'Debug',
                 '-destination', 'platform=iOS Simulator,id=' + udid, '-derivedDataPath', '/tmp/raido-ice-preview',
                 '-parallel-testing-enabled', 'NO', 'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGNING_REQUIRED=NO',
                 'CODE_SIGN_STYLE=Manual', 'CODE_SIGN_IDENTITY=-', 'AD_HOC_CODE_SIGNING_ALLOWED=YES',
                 'test-without-building'], stdout=log, stderr=subprocess.STDOUT)
        except subprocess.CalledProcessError:
            print(Path(log.name).read_text()[-12000:])
            raise
    print('Passed broad disclosure swipes, independent map pan/pinch and tap tests in both themes', flush=True)
    with zipfile.ZipFile(ipa) as archive:
        report = {
            'version': packaged['CFBundleShortVersionString'], 'ipaBytes': ipa.stat().st_size,
            'unpackedBytes': sum(x.file_size for x in archive.infolist()),
            'executableBytes': archive.getinfo('Payload/RAIDORoster.app/RAIDORoster').file_size,
            'entries': len(archive.infolist()), 'sha256': before,
        }
    Path('/tmp/raido-theme-size.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Release size:', json.dumps(report), flush=True)
finally:
    if ephemeral_simulator:
        for action in ['shutdown', 'delete']:
            try:
                run(['xcrun', 'simctl', action, ephemeral_simulator], check=False, timeout=30)
            except subprocess.TimeoutExpired:
                print('Temporary simulator ' + action + ' timed out; runner cleanup will finish it', file=sys.stderr)
    for report in (Path.home() / 'Library/Logs/DiagnosticReports').glob('RAIDORoster*'):
        if report.is_file(): shutil.copy(report, Path('/tmp') / ('raido-ice-crash-' + report.name))
    stderr = Path('/tmp/raido-ice-app-stderr.log')
    if stderr.exists(): print(stderr.read_text(errors='replace')[-6000:])
    fleet_source.write_text(original_fleet)
    content.write_text(original_content); app.write_text(original_app)
    store_source.write_text(original_store)
    priority_source.write_text(original_priority)
    announcement_view.write_text(original_announcements)
    (project / 'project.pbxproj').write_bytes(original_project)
    if test_scheme is not None: test_scheme.unlink(missing_ok=True)
    assert hashlib.sha256(ipa.read_bytes()).hexdigest() == before, 'Preview changed the release IPA'
