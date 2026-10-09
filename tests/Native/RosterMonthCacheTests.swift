import XCTest
import WebKit
import UIKit
@testable import RAIDORoster

@MainActor
final class RosterMonthCacheTests: XCTestCase {
    func payload(_ month: String, count: Int = 5) -> [String: Any] {
        ["schemaVersion": 1, "sourceURL": "https://gjt.noc.vmc.navblue.cloud/RaidoMobile/Dialogues/HumanResources/HumanResourceRoster.aspx?year=\(month.prefix(4))&month=\(month.suffix(2))&hrId=fixture",
         "monthlyBLH": "15:15", "validation": ["isValid": true, "parser": "raido-duty-envelope-test", "month": month, "datedRows": count],
         "rows": (1...count).map { ["id": "\(month)-\($0)", "dateISO": "\(month)-\(String(format: "%02d", $0))", "rawText": "Sanitized duty", "category": "OFF", "activities": []] as [String: Any] }]
    }
    func testExactMonthURLAndYearRollover() throws {
        let url = try XCTUnwrap(URL(string: "https://gjt.noc.vmc.navblue.cloud/RaidoMobile/Dialogues/HumanResources/HumanResourceRoster.aspx?hrId=fixture&month=10&year=2026#day"))
        let target = try XCTUnwrap(RosterMonthCachePolicy.requestURL(source: url, month: "2025-12"))
        let query = try XCTUnwrap(URLComponents(url: target, resolvingAgainstBaseURL: false)).queryItems!
        XCTAssertEqual(query.first { $0.name == "hrId" }?.value, "fixture")
        XCTAssertEqual(query.first { $0.name == "year" }?.value, "2025")
        XCTAssertEqual(query.first { $0.name == "month" }?.value, "12")
        XCTAssertNil(target.fragment)
        let months = RosterMonthCachePolicy.targets(current: "2026-01", offered: ["2024-09", "bad", "2026-13"])
        XCTAssertTrue(months.contains("2025-12")); XCTAssertTrue(months.contains("2024-09"))
        XCTAssertEqual(months.first, "2026-01"); XCTAssertFalse(months.contains("2026-13"))
        XCTAssertNil(RosterMonthCachePolicy.requestURL(source: URL(string: "https://example.invalid/HumanResourceRoster.aspx")!, month: "2026-09"))
        XCTAssertNil(RosterMonthCachePolicy.requestURL(source: url, month: "2026-00"))
    }
    func testArchiveImportPreservesSelectionAndSurvivesRelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RosterStore(storageFolderURL: folder, automaticSideEffects: false)
        XCTAssertTrue(store.ingest(messageBody: payload("2026-10")))
        let original = try XCTUnwrap(store.snapshot)
        store.showPendingRosterMonth("2026-08")
        XCTAssertTrue(store.ingest(messageBody: payload("2026-09"), archiveOnly: true, expectedMonth: "2026-09"))
        XCTAssertEqual(store.selectedRosterMonthKey, "2026-08")
        XCTAssertEqual(store.snapshot, original); XCTAssertTrue(store.latestChanges.isEmpty)
        XCTAssertFalse(store.ingest(messageBody: payload("2026-10"), archiveOnly: true, expectedMonth: "2026-08"))
        XCTAssertNil(store.monthSnapshots["2026-08"])
        let loaded = RosterStore(storageFolderURL: folder, automaticSideEffects: false)
        XCTAssertTrue(loaded.selectRosterMonthIfCached("2026-09"))
        XCTAssertEqual(loaded.rosterViewItems.count, 5)
        XCTAssertEqual(loaded.rosterViewSnapshot?.monthlyBLH, "15:15")
        XCTAssertEqual(loaded.monthSnapshots["2026-10"]?.items.count, 5)
    }
    func testCurrentMonthArchiveRefreshReportsChangesWithoutMovingSelection() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM"
        let current = formatter.string(from: Date())
        let history = RosterMonthCachePolicy.key(try XCTUnwrap(RosterMonthCachePolicy.index(current)) - 1)
        let store = RosterStore(storageFolderURL: folder, automaticSideEffects: false)
        XCTAssertTrue(store.ingest(messageBody: payload(current)))
        // Live history can be the latest snapshot when the current archive refresh arrives.
        XCTAssertTrue(store.ingest(messageBody: payload(history)))
        var changed = payload(current)
        var rows = try XCTUnwrap(changed["rows"] as? [[String: Any]])
        rows[0]["category"] = "STANDBY"; rows[0]["title"] = "Standby"
        rows[0]["rawText"] = "Sanitized standby duty"
        changed["rows"] = rows
        XCTAssertTrue(store.ingest(messageBody: changed, archiveOnly: true, expectedMonth: current))
        XCTAssertEqual(store.selectedRosterMonthKey, history)
        XCTAssertEqual(store.snapshot?.validation?.month, current)
        XCTAssertTrue(store.changedDates.contains("\(current)-01"))
        XCTAssertFalse(store.latestChanges.isEmpty)
        let loaded = RosterStore(storageFolderURL: folder, automaticSideEffects: false)
        XCTAssertTrue(loaded.changedDates.contains("\(current)-01"))
    }
    func testSparseArchiveAndInvalidUpdatePreserveGoodCache() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RosterStore(storageFolderURL: folder, automaticSideEffects: false)
        let sparse = payload("2026-11", count: 1)
        XCTAssertThrowsError(try PortalBridgePolicy.snapshot(sparse))
        XCTAssertTrue(store.ingest(messageBody: sparse, archiveOnly: true, expectedMonth: "2026-11"))
        let saved = store.monthSnapshots["2026-11"]
        var broken = sparse; broken["schemaVersion"] = 999
        XCTAssertFalse(store.ingest(messageBody: broken, archiveOnly: true, expectedMonth: "2026-11"))
        XCTAssertEqual(store.monthSnapshots["2026-11"], saved)
        XCTAssertNil(store.portalFormatWarning)
    }
    func testProtectedSourcePersistsAndClearInvalidatesWorker() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RosterStore(storageFolderURL: folder, automaticSideEffects: false)
        let source = try XCTUnwrap(URL(string: payload("2026-10")["sourceURL"] as! String))
        store.rememberRosterSourceURL(source)
        let loaded = RosterStore(storageFolderURL: folder, automaticSideEffects: false)
        XCTAssertEqual(loaded.rosterSourceURL, source)
        let ticket = loaded.cacheGeneration; loaded.clearCache()
        XCTAssertNotEqual(loaded.cacheGeneration, ticket)
        XCTAssertNil(RosterStore(storageFolderURL: folder, automaticSideEffects: false).rosterSourceURL)
    }
    func testWrongMonthRowsAndFailedDiskWriteAreNotAcknowledged() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RosterStore(storageFolderURL: folder, automaticSideEffects: false)
        var wrong = payload("2026-10")
        wrong["validation"] = ["isValid":true,"parser":"raido-duty-envelope-test","month":"2026-07","datedRows":5]
        XCTAssertFalse(store.ingest(messageBody: wrong, archiveOnly: true, expectedMonth: "2026-07"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("corrupted archive".utf8).write(to: folder.appendingPathComponent("roster-months.json"))
        XCTAssertFalse(store.ingest(messageBody: payload("2026-07"), archiveOnly: true, expectedMonth: "2026-07"))
        XCTAssertNil(store.monthSnapshots["2026-07"])
    }
    func testOfferedHistoryIsNotSilentlyTruncated() {
        let years = (2010...2026).flatMap { year in (1...12).map { String(format:"%04d-%02d",year,$0) } }
        let targets = RosterMonthCachePolicy.targets(current:"2026-10",offered:years)
        XCTAssertTrue(targets.contains("2010-01")); XCTAssertGreaterThan(targets.count,120)
    }
    func testWorkerDirectDownloadAndDurableRelaunch() async throws {
        let fixture = try HistoryFixture(mode:.direct)
        defer { fixture.close() }
        fixture.store.showPendingRosterMonth("2026-08")
        fixture.worker.start(source:fixture.source)
        try await fixture.finished()
        XCTAssertEqual(fixture.store.monthSnapshots["2026-07"]?.items.count,5)
        XCTAssertEqual(fixture.store.selectedRosterMonthKey,"2026-08")
        XCTAssertEqual(fixture.loads,1)
        XCTAssertFalse(fixture.worker.needsRetry)
        let loaded = RosterStore(storageFolderURL:fixture.folder,automaticSideEffects:false)
        XCTAssertEqual(loaded.monthSnapshots["2026-07"]?.items.first?.dateISO,"2026-07-08")
        let progress = try XCTUnwrap(ProtectedJSONFile<RosterHistoryProgress>(url:fixture.store.offlineHistoryStateURL).load())
        XCTAssertTrue(progress.targets.contains("2026-07")); XCTAssertTrue(progress.failures.isEmpty)
        XCTAssertFalse(fixture.worker.diagnosticText.contains("hrId"))
    }
    func testWorkerRendersJavaScriptShellBeforeCaching() async throws {
        let fixture = try HistoryFixture(mode:.rendered)
        defer { fixture.close() }
        fixture.worker.start(source:fixture.source)
        try await fixture.finished()
        XCTAssertEqual(fixture.store.monthSnapshots["2026-07"]?.items.count,5)
        XCTAssertEqual(fixture.loads,2)
        XCTAssertFalse(fixture.worker.needsRetry)
    }
    func testWorkerDiscoversOlderHistoryFromDownloadedPreviousControls() async throws {
        let fixture = try HistoryFixture(mode:.continuous,automaticHistory:true)
        defer { fixture.close() }
        fixture.worker.start(source:fixture.source)
        try await fixture.finished()
        XCTAssertEqual(fixture.store.monthSnapshots["2025-09"]?.items.count,5)
        XCTAssertEqual(fixture.store.rosterMonthKeys.count,16)
        XCTAssertFalse(fixture.worker.needsRetry)
        XCTAssertEqual(fixture.loads,1)
    }
    func testWorkerUsesActualPreviousControlsWhenQueryIsIgnored() async throws {
        let fixture = try HistoryFixture(mode:.controls)
        defer { fixture.close() }
        fixture.worker.start(source:fixture.source)
        try await fixture.finished()
        XCTAssertEqual(fixture.store.monthSnapshots["2026-07"]?.items.count,5)
        XCTAssertFalse(fixture.worker.needsRetry)
        XCTAssertEqual(fixture.store.snapshot?.validation?.month,"2026-07")
        // No visible RAIDO page was navigated; only the worker's hosted fixture.
        XCTAssertEqual(fixture.loads,2)
    }
    func testWorkerUsesOpaqueYearAndMonthSelectors() async throws {
        let fixture = try HistoryFixture(mode:.selectors,target:"2025-07")
        defer { fixture.close() }
        fixture.worker.start(source:fixture.source)
        try await fixture.finished()
        XCTAssertEqual(fixture.store.monthSnapshots["2025-07"]?.items.count,5)
        XCTAssertFalse(fixture.worker.needsRetry)
    }
    func testLoginExpiryKeepsQueueAndExplicitRetryRebuildsIt() async throws {
        let fixture = try HistoryFixture(mode:.auth)
        defer { fixture.close() }
        XCTAssertTrue(fixture.store.ingest(messageBody:payload("2026-09"),archiveOnly:true,expectedMonth:"2026-09"))
        fixture.worker.start(source:fixture.source)
        try await fixture.finished()
        XCTAssertNil(fixture.store.monthSnapshots["2026-07"])
        XCTAssertNotNil(fixture.store.monthSnapshots["2026-09"])
        let journal = try XCTUnwrap(ProtectedJSONFile<RosterHistoryProgress>(url:fixture.store.offlineHistoryStateURL).load())
        XCTAssertEqual(journal.failures["2026-07"]?.reason,"sign-in-required")
        fixture.mode = .direct
        fixture.worker.start(source:fixture.source,force:true)
        try await fixture.finished()
        XCTAssertNotNil(fixture.store.monthSnapshots["2026-07"])
        XCTAssertFalse(fixture.worker.needsRetry)
    }
    func testYearSelectorMayResetToJanuary() async throws {
        let fixture = try HistoryFixture(mode:.selectorsReset,target:"2025-07")
        defer { fixture.close() }
        fixture.worker.start(source:fixture.source)
        try await fixture.finished()
        XCTAssertEqual(fixture.store.monthSnapshots["2025-07"]?.items.count,5)
        XCTAssertFalse(fixture.worker.needsRetry)
    }
    func testRateLimitSurvivesRetryAndNewWorker() async throws {
        let fixture = try HistoryFixture(mode:.rate)
        defer { fixture.close() }
        fixture.worker.start(source:fixture.source)
        try await fixture.finished()
        let journal = try XCTUnwrap(ProtectedJSONFile<RosterHistoryProgress>(url:fixture.store.offlineHistoryStateURL).load())
        XCTAssertEqual(journal.failures["2026-07"]?.reason,"server-rate-limit")
        XCTAssertGreaterThan(journal.failures["2026-07"]!.retryAt.timeIntervalSinceNow,100)
        let originalLoads = fixture.loads
        fixture.worker.start(source:fixture.source,force:true)
        XCTAssertEqual(fixture.loads,originalLoads)
        XCTAssertNil(fixture.store.monthSnapshots["2026-07"])
        let next = RosterOfflineCache(store:fixture.store,currentMonth:"2026-10",targets:["2026-07"])
        next.start(source:fixture.source)
        XCTAssertFalse(next.isRunning); XCTAssertTrue(next.needsRetry); next.pause()
    }
    func testWrongHeadingRowsCannotBeCachedByWorker() async throws {
        let fixture = try HistoryFixture(mode:.wrongRows)
        defer { fixture.close() }
        fixture.worker.start(source:fixture.source)
        try await fixture.finished()
        XCTAssertNil(fixture.store.monthSnapshots["2026-07"])
        XCTAssertTrue(fixture.worker.needsRetry)
        let journal = try XCTUnwrap(ProtectedJSONFile<RosterHistoryProgress>(url:fixture.store.offlineHistoryStateURL).load())
        XCTAssertNotNil(journal.failures["2026-07"])
    }
    func testClearCacheInvalidatesInFlightDownload() async throws {
        let fixture = try HistoryFixture(mode:.delayed)
        defer { fixture.close() }
        let cleared = expectation(description:"Cache cleared during download")
        fixture.worker.statusChanged = { text in
            if text?.hasPrefix("Saving 2026-07") == true { cleared.fulfill() }
        }
        fixture.worker.start(source:fixture.source)
        await fulfillment(of:[cleared],timeout:45)
        try await Task.sleep(nanoseconds:200_000_000)
        fixture.store.clearCache()
        // Let the stale callback return; it must never recreate the cleared cache.
        try await Task.sleep(nanoseconds:3_000_000_000)
        XCTAssertTrue(fixture.store.monthSnapshots.isEmpty)
        XCTAssertFalse(fixture.worker.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath:fixture.store.offlineHistoryStateURL.path))
    }

}

@MainActor
private final class HistoryFixture {
    enum Mode { case direct, rendered, controls, selectors, selectorsReset, auth, rate, wrongRows, delayed, continuous }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = URL(string:"https://gjt.noc.vmc.navblue.cloud/RaidoMobile/Dialogues/HumanResources/HumanResourceRoster.aspx?hrId=fixture&year=2026&month=10")!
    let store: RosterStore
    let window: UIWindow
    let original: String
    let target: String
    var mode: Mode
    var loads = 0
    var worker: RosterOfflineCache!
    init(mode: Mode, target: String = "2026-07", automaticHistory: Bool = false) throws {
        self.mode = mode; self.target = target
        original = try String(contentsOf:XCTUnwrap(Bundle(for:RosterMonthCacheTests.self).url(forResource:"roster",withExtension:"html")),encoding:.utf8)
        store = RosterStore(storageFolderURL:folder,automaticSideEffects:false)
        window = UIWindow(frame:CGRect(x:0,y:0,width:390,height:844))
        window.rootViewController = UIViewController(); window.isHidden = false
        worker = RosterOfflineCache(store:store,configuration:{ [unowned self] in self.configuration() },
            loader:{ [unowned self] web,request in self.load(web,request:request) },
            hostView:window.rootViewController!.view,currentMonth:"2026-10",targets:automaticHistory ? nil : [target])
        worker.timing = .init(load:30,settle:1.5,poll:0.1,gap:0.01)
    }
    func html(_ key: String) -> String {
        let names = ["January","February","March","April","May","June","July","August","September","October","November","December"]
        let year = String(key.prefix(4)), number = Int(key.suffix(2))!, name = names[number-1]
        return original.replacingOccurrences(of:"October 2026",with:"\(name) \(year)")
            .replacingOccurrences(of:"OCT26",with:"\(name.prefix(3).uppercased())\(year.suffix(2))")
            .replacingOccurrences(of:"Oct ",with:"\(name.prefix(3)) ")
    }
    func json(_ value: Any) -> String { String(data:try! JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.sortedKeys]),encoding:.utf8)! }
    func configuration() -> WKWebViewConfiguration {
        let code: String
        switch mode {
        case .continuous:
            var pages: [String:String] = [:]
            for key in RosterMonthCachePolicy.targets(current:"2026-10",offered:["2025-09"]) {
                let button = "<button \(key == "2025-09" ? "disabled" : "")>Previous</button>"
                pages[key] = html(key).replacingOccurrences(of:"</body>",with:button+"</body>")
            }
            code = "const p=new URL(u).searchParams,k=p.get('year')+'-'+p.get('month').padStart(2,'0'),pages=\(json(pages)); return {ok:true,status:200,url:u,text:async()=>pages[k]};"
        case .auth: code = "return {ok:false,status:401};"
        case .rate: code = "return {ok:false,status:429,headers:{get:()=> '120'}};"
        case .direct, .delayed:
            code = "\(mode == .delayed ? "await new Promise(r=>setTimeout(r,500));" : "") return {ok:true,status:200,url:u,headers:{get:()=>null},text:async()=>\(json(html(target)))};"
        case .wrongRows:
            code = "return {ok:true,status:200,url:u,text:async()=>\(json(original.replacingOccurrences(of:"October 2026",with:"July 2026")))};"
        default: code = "return {ok:true,status:200,url:u,text:async()=>'<h1>July 2026</h1><p>Loading roster</p>'};"
        }
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(source:"window.fetch=async function(u){\(code)};",injectionTime:.atDocumentStart,forMainFrameOnly:true))
        return config
    }
    func load(_ web: WKWebView, request: URLRequest) {
        loads += 1
        var body = original
        if loads > 1 {
            switch mode {
            case .rendered:
                // Data appears only after executing the page's JavaScript.
                body = "<html><body><h1>July 2026</h1><p>Loading</p><script>setTimeout(()=>{document.body.innerHTML=new DOMParser().parseFromString(\(json(html(target))),'text/html').body.innerHTML},250)</script></body></html>"
            case .wrongRows: body = original.replacingOccurrences(of:"October 2026",with:"July 2026")
            default: break
            }
        }
        if mode == .controls || mode == .selectors || mode == .selectorsReset {
            var pages: [String:String] = [:]
            let keys = mode == .controls ? ["2026-10","2026-09","2026-08","2026-07"] : ["2026-10", mode == .selectorsReset ? "2025-01" : "2025-10","2025-07"]
            let controls = mode == .controls ? "<button class='switch-month-button' onclick='window.move()'>Previous</button>" : "<select id='rosterYear' onchange='window.chooseYear(this)'><option value='opaque25'>2025</option><option value='opaque26'>2026</option></select><select id='rosterMonth' onchange='window.chooseMonth(this)'><option value='1'>January</option><option value='7'>July</option><option value='10'>October</option></select>"
            for key in keys { pages[key] = html(key).replacingOccurrences(of:"</body>",with:controls+"</body>") }
            let script = """
            <script>
            window.pages=\(json(pages)); window.key='2026-10'; window.keys=\(json(keys));
            window.render=function(key){window.key=key; document.body.innerHTML=new DOMParser().parseFromString(window.pages[key],'text/html').body.innerHTML;
              const y=document.querySelector('#rosterYear'),m=document.querySelector('#rosterMonth'); if(y)y.value=key.startsWith('2025')?'opaque25':'opaque26'; if(m)m.value=String(Number(key.slice(-2)));};
            window.move=function(){const key=window.keys[window.keys.indexOf(window.key)+1]; if(key)window.render(key);};
            window.chooseYear=function(s){window.render(s.options[s.selectedIndex].text+'-'+\(mode == .selectorsReset ? "'01'" : "window.key.slice(-2)"));};
            window.chooseMonth=function(s){window.render(window.key.slice(0,4)+'-'+s.value.padStart(2,'0'));};
            window.render('2026-10');
            </script>
            """
            body = pages["2026-10"]!.replacingOccurrences(of:"</body>",with:script+"</body>")
        }
        web.loadHTMLString(body,baseURL:request.url)
    }
    func finished() async throws {
        let deadline = Date().addingTimeInterval(45)
        while worker.isRunning && Date() < deadline { try await Task.sleep(nanoseconds:100_000_000) }
        XCTAssertFalse(worker.isRunning,"Worker exceeded its test deadline: \(worker.diagnosticText)")
    }
    func close() { worker.pause(); window.isHidden = true; try? FileManager.default.removeItem(at:folder) }
}
