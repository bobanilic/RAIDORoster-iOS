import Foundation
import CoreFoundation
import CryptoKit
import WebKit
import SwiftUI
import UIKit

/// A validated read-only request. It deliberately carries no comparison digest.
struct NativeRAIDOQuery: Sendable {
    let url: URL
    let body: Data
    let month: String
    fileprivate init(url: URL, body: Data, month: String) { self.url = url; self.body = body; self.month = month }

    func previousMonth() throws -> Self {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { throw NativeRAIDOContract.Failure.unsupportedRequest }
        let prior = parts[0] * 12 + parts[1] - 2
        let year = prior / 12, month = prior % 12 + 1
        guard year >= 2000, var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw NativeRAIDOContract.Failure.unsupportedRequest
        }
        object["year"] = year; object["month"] = month
        return try NativeRAIDOContract.query(url: url, body: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
}

/// Transport comparison only. No decoder in this experiment writes to RosterStore.
struct NativeRAIDOContract: Sendable {
    static let maximumResponseBytes = 4 * 1024 * 1024
    let url: URL
    let body: Data
    let month: String
    let expectedDigest: Data
    var request: NativeRAIDOQuery { NativeRAIDOQuery(url: url, body: body, month: month) }
    private init(url: URL, body: Data, month: String, expectedDigest: Data) {
        self.url = url; self.body = body; self.month = month; self.expectedDigest = expectedDigest
    }

    enum Failure: Error, Equatable {
        case unsupportedRequest, unsupportedResponse, responseTooLarge, signInRequired
        case redirect, http(Int), sessionChanged
    }

    static func permits(_ url: URL) -> Bool {
        guard PortalBridgePolicy.isPortal(url), let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.query == nil, c.fragment == nil, !c.percentEncodedPath.contains("%"),
              c.path.lowercased().hasSuffix("/getroster") else { return false }
        return true
    }

    static func capture(url: URL, request: Data, response: Data) throws -> Self {
        let value = try Self.query(url: url, body: request)
        return try Self(url: value.url, body: value.body, month: value.month, expectedDigest: digest(response))
    }

    static func query(url: URL, body: Data) throws -> NativeRAIDOQuery {
        guard permits(url), body.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(object.keys) == Set(["month", "year", "hrId"]),
              let month = integer(object["month"], range: 1...12),
              let year = integer(object["year"], range: 2000...2100),
              validIdentity(object["hrId"]) else { throw Failure.unsupportedRequest }
        return NativeRAIDOQuery(url: url, body: body, month: String(format: "%04d-%02d", year, month))
    }

    private static func integer(_ value: Any?, range: ClosedRange<Int>) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
              n.doubleValue >= Double(range.lowerBound), n.doubleValue <= Double(range.upperBound) else { return nil }
        return n.intValue
    }

    private static func validIdentity(_ value: Any?) -> Bool {
        if let s = value as? String {
            return !s.isEmpty && s.utf8.count <= 20 && s.utf8.allSatisfy { (48...57).contains($0) } && s.contains { $0 != "0" }
        }
        return integer(value, range: 1...9_007_199_254_740_991) != nil
    }

    static func boundedJSON(_ data: Data) throws -> Any {
        guard data.count <= maximumResponseBytes else { throw Failure.responseTooLarge }
        guard let value = try? JSONSerialization.jsonObject(with: data),
              value is [String: Any] || value is [Any] else { throw Failure.unsupportedResponse }
        var nodes = 0
        func bounded(_ value: Any, depth: Int) -> Bool {
            nodes += 1
            guard depth <= 20, nodes <= 100_000 else { return false }
            if let a = value as? [Any] { return a.allSatisfy { bounded($0, depth: depth + 1) } }
            if let d = value as? [String: Any] { return d.values.allSatisfy { bounded($0, depth: depth + 1) } }
            return true
        }
        guard bounded(value, depth: 0) else { throw Failure.unsupportedResponse }
        return value
    }

    static func digest(_ data: Data) throws -> Data {
        let value = try boundedJSON(data)
        let canonical = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return Data(SHA256.hash(data: canonical))
    }

    static func scopedCookies(_ cookies: [HTTPCookie], for url: URL, now: Date = Date()) -> [HTTPCookie] {
        guard permits(url), let host = url.host?.lowercased() else { return [] }
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            let matches = domain.hasPrefix(".") ? (host == String(domain.dropFirst()) || host.hasSuffix(domain)) : host == domain
            let path = cookie.path.isEmpty ? "/" : cookie.path
            let pathMatches = url.path == path || (url.path.hasPrefix(path) && (path.hasSuffix("/") || url.path.dropFirst(path.count).hasPrefix("/")))
            return matches && pathMatches && (cookie.expiresDate.map { $0 > now } ?? true)
        }.sorted {
            if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            return ($0.domain, $0.path, $0.name, $0.value) < ($1.domain, $1.path, $1.name, $1.value)
        }
    }

    static func cookieDigest(_ cookies: [HTTPCookie]) -> Data {
        // Length-delimited encoding avoids collisions between concatenated fields.
        var data = Data()
        for cookie in cookies {
            for value in [cookie.domain, cookie.path, cookie.name, cookie.value] {
                data.append(contentsOf: "\(value.utf8.count):".utf8); data.append(contentsOf: value.utf8)
            }
        }
        return Data(SHA256.hash(data: data))
    }
}

/// Builds a value-free description before the captured response is discarded.
/// Only reviewed property names may leave the process. Unknown fields retain
/// separate anonymous identities; dictionary keys expose their format only.
enum NativeRAIDOResponseSchema {
    private static let names = Set("""
        d data result results response payload value json roster rosters rostermonth rosterdays
        days day date dates activities activity activityitems activitytype activitycode activityid
        events event items item rows row table table1 table2 tables dataset schedule schedules
        duties duty dutyid dutycode dutytype dutyperiod dutyperiods dutytime dutyminutes dutyhours
        flights flight flightid flightnumber flightno flightcode flighttype flightdate flightlegs
        legs leg legid sectors sector sectorid segments segment assignments assignment assignmentid
        id hrid employeeid personid userid crewid rosterid revisionid rosterrevision revision version
        name firstname lastname fullname displayname title description text label code type kind
        status state published ispublished confirmed isconfirmed acknowledged isacknowledged
        start end begin finish startdate enddate starttime endtime from to fromdate todate
        datefrom dateto timefrom timeto startutc endutc startlocal endlocal utc local timezone
        departure arrival departuretime arrivaltime departureutc arrivalutc departurelocal arrivallocal
        departureairport arrivalairport origin destination airport airports airportcode iata icao
        originairport destinationairport fromairport toairport dep arr depairport arrairport
        scheduleddeparture scheduledarrival actualdeparture actualarrival estimateddeparture estimatedarrival
        std sta etd eta atd ata offblock onblock blocktime blockminutes blockhours duration minutes hours
        report reporting reporttime reportingtime release releasetime briefing briefingtime debriefing
        checkin checkout checkintime checkouttime pickup pickuptime transport transportation
        standby standbytype reserve positioning deadhead off leave training simulator ground hotel
        base homebase dutybase location station route aircraft aircrafttype registration tail tailnumber
        operator airline company fleet crew crewmembers members roles role rank position positions
        notes note remarks remark comment comments details detail contacts contact email phone telephone
        username address employee person user account token cookie password session authorization
        isflight isduty isstandby isoff ispositioning istraining cancelled iscanceled iscancelled
        changed ischanged isnew deleted isdeleted allday isallday overnight isovernight
        month year totals total accumulated legality legalities limits limit warnings warning
        rest resttime restminutes fdp flightdutyperiod maxfdp remaining remainingtime
        url color colour backgroundcolor foregroundcolor icon flags attributes properties children
        success error errors message messages count hasmore next previous metadata meta
        created updated createdat updatedat effectivefrom effectiveto timestamp lastmodified
        activitystart activityend dutybegin dutyend flightstart flightend scheduledstart scheduledend
        startdatetime enddatetime begindatetime finishdatetime departuredate arrivaldate
        rosteractivities rosteractivity dutyactivities dutyactivity dailyactivities dailyroster
        rosterentries rosterentry entries entry activitydetails dutydetails flightdetails
        dutyname activityname typename typenameid dutytypeid activitytypeid activitytypecode
        dutytypename activitytypename startairport endairport scheduledoffblock scheduledonblock
        hractivities hractivity rotations rotation trips trip tripid tripnumber
        activitydesignator dutyidentifier identifier workcode worktype summary html content
        dailyvalues monthlyvalues accumulatedvalues dailyrecords records record
        rosteractivityid rostereventid rosteritemid rostertype offset utcoffset startoffset endoffset
        isutc zulu sectorcount flightcount dutycount
        validfrom validto textcolor values valuetext nestedvalue jumpseatinfo
        posnote daynote activitynote noteitems designators rosterdesignators
        """.split(whereSeparator: \.isWhitespace).map(String.init))
    private static let jsonEnvelopeNames: Set<String> = ["d", "data", "result", "response", "payload", "roster", "json"]
    private static let timingNames: Set<String> = ["std", "sta", "atd", "ata", "checkin", "checkout", "validfrom", "validto",
        "start", "end", "starttime", "endtime", "startdate", "enddate", "departuretime", "arrivaltime"]

    private static func keyKind(_ key: String) -> String {
        if key.utf8.count <= 32, key.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil { return "numeric" }
        if key.utf8.count <= 80, key.range(of: #"^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?$"#, options: .regularExpression) != nil { return "date" }
        if key.utf8.count == 36, UUID(uuidString: key) != nil { return "uuid" }
        return "other"
    }

    private static func timingShape(_ value: String) -> String? {
        guard value.utf8.count <= 256 else { return nil }
        var shape = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        shape = shape.replacingOccurrences(of: #"[0-9]"#, with: "#", options: .regularExpression)
        shape = shape.replacingOccurrences(of: #"[\p{L}\p{M}]+"#, with: "A", options: .regularExpression)
        shape = shape.replacingOccurrences(of: #"[^#A:/.+()<> ,\-]"#, with: "?", options: .regularExpression)
        guard !shape.isEmpty, shape.utf8.count <= 80 else { return nil }
        return shape
    }

    private final class Node {
        var types = Set<String>()
        var formats = Set<String>()
        var fields: [String: Node] = [:]
        var items: Node?
        var encodedJSON: Node?
        var maskedKeys = false
        var anonymousFields: [String: String] = [:]
        var keyKinds = Set<String>()
        var timingShapes = Set<String>()
        var timingShapesOmitted = false
        var truncated = false

        func object() -> [String: Any] {
            var result: [String: Any] = ["types": types.sorted()]
            if !formats.isEmpty { result["stringFormats"] = formats.sorted() }
            if !fields.isEmpty { result["properties"] = fields.mapValues { $0.object() } }
            if let items { result["items"] = items.object() }
            if let encodedJSON { result["encodedJSON"] = encodedJSON.object() }
            if maskedKeys { result["unrecognizedKeysMasked"] = true }
            if !keyKinds.isEmpty { result["maskedKeyKinds"] = keyKinds.sorted() }
            if !timingShapes.isEmpty { result["timingStringShapes"] = timingShapes.sorted() }
            if timingShapesOmitted { result["additionalTimingShapesOmitted"] = true }
            if truncated { result["truncated"] = true }
            return result
        }
    }

    static func make(from data: Data) throws -> String {
        guard data.count <= NativeRAIDOContract.maximumResponseBytes,
              let value = try? JSONSerialization.jsonObject(with: data),
              value is [String: Any] || value is [Any] else { throw NativeRAIDOContract.Failure.unsupportedResponse }
        var visits = 0, nodes = 1, decodedEnvelopes = 0
        func newNode() throws -> Node {
            nodes += 1
            guard nodes <= 512 else { throw NativeRAIDOContract.Failure.responseTooLarge }
            return Node()
        }
        func merge(_ value: Any, into node: Node, depth: Int, field: String? = nil) throws {
            visits += 1
            guard depth <= 20, visits <= 100_000 else { throw NativeRAIDOContract.Failure.responseTooLarge }
            if value is NSNull { node.types.insert("null") }
            else if let object = value as? [String: Any] {
                node.types.insert("object")
                let kinds = Set(object.keys.map(keyKind))
                // A homogeneous map of numeric/date/UUID keys can be merged as
                // a dictionary. Other unknown sibling fields must stay distinct.
                let dictionaryKind = kinds.count == 1 && !kinds.contains("other") ? kinds.first : nil
                for key in object.keys.sorted() {
                    let known = names.contains(key.lowercased()) && key.utf8.count <= 64
                    let exportedKey: String
                    if known { exportedKey = key }
                    else {
                        node.maskedKeys = true; node.keyKinds.insert(keyKind(key))
                        if let dictionaryKind { exportedKey = "<\(dictionaryKind)-key>" }
                        else if let existing = node.anonymousFields[key] { exportedKey = existing }
                        else {
                            exportedKey = "<field-\(node.anonymousFields.count + 1)>"
                            node.anonymousFields[key] = exportedKey
                        }
                    }
                    let child: Node
                    if let existing = node.fields[exportedKey] { child = existing }
                    else { child = try newNode(); node.fields[exportedKey] = child }
                    try merge(object[key]!, into: child, depth: depth + 1, field: known ? key.lowercased() : nil)
                }
            } else if let array = value as? [Any] {
                node.types.insert("array")
                if !array.isEmpty {
                    let child: Node
                    if let existing = node.items { child = existing }
                    else { child = try newNode(); node.items = child }
                    for item in array { try merge(item, into: child, depth: depth + 1) }
                }
            } else if let string = value as? String {
                node.types.insert("string")
                if let field, timingNames.contains(field), let shape = timingShape(string) {
                    if node.timingShapes.count < 8 || node.timingShapes.contains(shape) { node.timingShapes.insert(shape) }
                    else { node.timingShapesOmitted = true }
                }
                // Known envelopes sometimes contain JSON encoded as a string.
                // Inspect its structure, never its scalar values or arbitrary keys.
                if let field, jsonEnvelopeNames.contains(field),
                   let first = string.first(where: { !$0.isWhitespace }), first == "{" || first == "[" {
                    if decodedEnvelopes < 16 {
                        decodedEnvelopes += 1
                        if let decoded = try? JSONSerialization.jsonObject(with: Data(string.utf8)),
                           decoded is [String: Any] || decoded is [Any] {
                            let child: Node
                            if let existing = node.encodedJSON { child = existing }
                            else { child = try newNode(); node.encodedJSON = child }
                            try merge(decoded, into: child, depth: depth + 1)
                        }
                    } else { node.truncated = true }
                }
                // Bounded format recognition emits fixed labels, not examples.
                if string.utf8.count <= 80 {
                    let patterns = [
                        ("date", #"^\d{4}-\d{2}-\d{2}$"#),
                        ("time", #"^\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?$"#),
                        ("iso8601-date-time", #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?$"#),
                        ("date-time-space", #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?$"#),
                        ("microsoft-json-date", #"^/Date\(-?\d+(?:[+-]\d{4})?\)/$"#)]
                    for (label, pattern) in patterns where string.range(of: pattern, options: .regularExpression) != nil {
                        node.formats.insert(label)
                    }
                }
            } else if let number = value as? NSNumber {
                node.types.insert(CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number")
            } else { throw NativeRAIDOContract.Failure.unsupportedResponse }
        }
        let root = Node()
        try merge(value, into: root, depth: 0)
        let document: [String: Any] = ["format": "raido-response-schema-v2", "operation": "GetRoster",
            "source": "portal capture", "valuesIncluded": false,
            "propertyNamePolicy": "Reviewed names only; unknown fields have scoped anonymous identities. Numeric/date/UUID dictionary keys are grouped by format. No key values are exported.",
            "timingShapePolicy": "Timing fields only: # replaces digits, A replaces letter runs, other unapproved characters become ?. Shapes contain no original letters or digits.",
            "schema": root.object()]
        let output = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        guard output.count <= 64 * 1024, let text = String(data: output, encoding: .utf8) else {
            throw NativeRAIDOContract.Failure.responseTooLarge
        }
        return text
    }
}

/// One bounded request per instance. Redirects never receive portal cookies.
final class NativeRAIDOHTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var cancelled = false
    private var started = false

    func fetch(_ contract: NativeRAIDOContract, cookies: [HTTPCookie], configuration: URLSessionConfiguration = .ephemeral) async throws -> Data {
        try await fetch(contract.request, cookies: cookies, configuration: configuration)
    }

    func fetch(_ contract: NativeRAIDOQuery, cookies: [HTTPCookie], configuration: URLSessionConfiguration = .ephemeral) async throws -> Data {
        guard NativeRAIDOContract.permits(contract.url) else { throw NativeRAIDOContract.Failure.unsupportedRequest }
        let scoped = NativeRAIDOContract.scopedCookies(cookies, for: contract.url)
        guard !scoped.isEmpty else { throw NativeRAIDOContract.Failure.signInRequired }
        var request = URLRequest(url: contract.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"; request.httpBody = contract.body
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        for (key, value) in HTTPCookie.requestHeaderFields(with: scoped) { request.setValue(value, forHTTPHeaderField: key) }
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 25
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                if started { lock.unlock(); continuation.resume(throwing: NativeRAIDOContract.Failure.unsupportedRequest); return }
                started = true
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request); self.task = task
                lock.unlock(); task.resume()
            }
        }, onCancel: { self.cancel() })
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let continuation = self.continuation, session = self.session
        self.continuation = nil; self.session = nil; self.task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); finish(.failure(NativeRAIDOContract.Failure.redirect))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.url == dataTask.originalRequest?.url else {
            completionHandler(.cancel); finish(.failure(NativeRAIDOContract.Failure.unsupportedResponse)); return
        }
        let failure: NativeRAIDOContract.Failure?
        if [401, 403].contains(response.statusCode) { failure = .signInRequired }
        else if response.statusCode != 200 { failure = .http(response.statusCode) }
        else if response.expectedContentLength > NativeRAIDOContract.maximumResponseBytes { failure = .responseTooLarge }
        else if response.mimeType?.lowercased() != "application/json" && response.mimeType?.lowercased() != "text/json" { failure = .unsupportedResponse }
        else { failure = nil }
        if let failure { completionHandler(.cancel); finish(.failure(failure)) }
        else { completionHandler(.allow) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= NativeRAIDOContract.maximumResponseBytes else {
            finish(.failure(NativeRAIDOContract.Failure.responseTooLarge)); return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) } else { finish(.success(data)) }
    }
}

@MainActor
final class NativeRAIDOExperiment: ObservableObject {
    @Published private(set) var status = "Capture a live roster request to check native access."
    @Published private(set) var armed = false
    @Published private(set) var isWorking = false
    @Published private(set) var capturedMonth: String?
    @Published private(set) var sanitizedSchema: String?
    @Published private(set) var schemaStatus = "Capture a roster request to prepare its sanitized schema."
    @Published private(set) var copyStatus: String?
    @Published private(set) var wireStatus = "Wire decoder awaits a capture."
    @Published private(set) var timingStatus = "Run a native comparison to check portal LT/UTC evidence."
    @Published private(set) var flightStatus = "Flight field checks await a native comparison."
    @Published private(set) var historyStatus = "Previous-month native access has not been tested."
    private var nativeDecoded = false
    private var comparison = "not run"
    private weak var webView: WKWebView?
    private var contract: NativeRAIDOContract?
    private var cookiesAtCapture: Data?
    private var token = UUID().uuidString
    private var generation = UUID()
    private var work: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func arm(in webView: WKWebView?) {
        stop()
        guard let webView, let resource = Bundle.main.url(forResource: "NativeRAIDORecorder", withExtension: "js"),
              let template = try? String(contentsOf: resource, encoding: .utf8) else {
            status = "Open Live RAIDO once, then return here to start capture."; return
        }
        self.webView = webView; token = UUID().uuidString; armed = true
        let source = template.replacingOccurrences(of: "__CAPTURE_TOKEN__", with: token)
        webView.configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let url = webView.url, PortalBridgePolicy.isPortal(url) { webView.evaluateJavaScript(source, completionHandler: nil) }
        status = "Listening. Open Live RAIDO and refresh the roster, then return here."
    }

    func navigationChanged() {
        guard armed else { return }
        invalidate(); status = "Listening for a roster request from the new page."
    }

    private func invalidate() {
        generation = UUID(); work?.cancel(); work = nil
        contract = nil; cookiesAtCapture = nil; capturedMonth = nil; isWorking = false
        sanitizedSchema = nil; copyStatus = nil; comparison = "not run"
        schemaStatus = "Capture a roster request to prepare its sanitized schema."
        wireStatus = "Wire decoder awaits a capture."
        timingStatus = "Run a native comparison to check portal LT/UTC evidence."
        flightStatus = "Flight field checks await a native comparison."
        historyStatus = "Previous-month native access has not been tested."; nativeDecoded = false
    }

    func stop() {
        invalidate(); armed = false
        if let webView {
            let controller = webView.configuration.userContentController
            let others = controller.userScripts.filter { !$0.source.contains("const token = '\(token)'") }
            controller.removeAllUserScripts(); others.forEach(controller.addUserScript)
            if let url = webView.url, PortalBridgePolicy.isPortal(url) {
                webView.evaluateJavaScript("window.__RAIDONativeExperiment?.stop()", completionHandler: nil)
            }
        }
        webView = nil; status = "Capture stopped; captured session data cleared."
    }

    func receive(_ body: Any) {
        guard armed, !isWorking, contract == nil, let webView,
              let message = body as? [String: Any], message["token"] as? String == token,
              let rawURL = message["url"] as? String, let url = URL(string: rawURL),
              let request = message["requestBody"] as? String, let response = message["responseBody"] as? String,
              request.utf8.count <= 4096, response.utf8.count <= NativeRAIDOContract.maximumResponseBytes else { return }
        let ticket = generation, requestData = Data(request.utf8), responseData = Data(response.utf8)
        isWorking = true
        work = Task { [weak self] in
            do {
                let captured = try await Task.detached(priority: .utility) {
                    let contract = try NativeRAIDOContract.capture(url: url, request: requestData, response: responseData)
                    return (contract, try? NativeRAIDOResponseSchema.make(from: responseData), NativeRAIDOWire.assessment(responseData, for: contract))
                }.value
                let contract = captured.0
                let allCookies = await webView.configuration.websiteDataStore.httpCookieStore.nativeExperimentCookies()
                let cookies = NativeRAIDOContract.scopedCookies(allCookies, for: contract.url)
                guard let self, self.generation == ticket, !Task.isCancelled else { return }
                guard !cookies.isEmpty else { throw NativeRAIDOContract.Failure.signInRequired }
                self.contract = contract; self.cookiesAtCapture = NativeRAIDOContract.cookieDigest(cookies)
                self.capturedMonth = contract.month; self.isWorking = false; self.work = nil
                self.sanitizedSchema = captured.1
                self.wireStatus = "Portal capture: " + captured.2
                self.schemaStatus = captured.1 == nil ? "Schema could not be prepared within the supported limits. Native comparison is still available."
                    : "Sanitized schema ready. Compare natively, then copy it here."
                self.status = "Captured \(contract.month). Ready for a native read-only comparison."
            } catch {
                guard let self, self.generation == ticket else { return }
                self.isWorking = false; self.work = nil
                self.status = "The observed request is unsupported. Saved roster was not changed."
            }
        }
    }

    func compare() {
        guard !isWorking, let contract, let webView else { return }
        let ticket = generation; isWorking = true; comparison = "in progress"; copyStatus = nil; nativeDecoded = false
        timingStatus = "Reading the live portal timing reference…"
        flightStatus = "Checking activity identities, local-field candidates, and overnight evidence…"
        status = "Comparing through the native connection…"
        work = Task { [weak self] in
            do {
                let allCookies = await webView.configuration.websiteDataStore.httpCookieStore.nativeExperimentCookies()
                let cookies = NativeRAIDOContract.scopedCookies(allCookies, for: contract.url)
                guard let self, self.generation == ticket, !Task.isCancelled else { return }
                guard NativeRAIDOContract.cookieDigest(cookies) == self.cookiesAtCapture else { throw NativeRAIDOContract.Failure.sessionChanged }
                let before = await self.timingReference(in: webView, month: contract.month)
                guard self.generation == ticket, !Task.isCancelled else { return }
                let response = try await NativeRAIDOHTTPClient().fetch(contract, cookies: cookies)
                let after = await self.timingReference(in: webView, month: contract.month)
                let finalCookies = await webView.configuration.websiteDataStore.httpCookieStore.nativeExperimentCookies()
                guard self.generation == ticket, !Task.isCancelled else { return }
                guard NativeRAIDOContract.cookieDigest(NativeRAIDOContract.scopedCookies(finalCookies, for: contract.url)) == self.cookiesAtCapture else {
                    throw NativeRAIDOContract.Failure.sessionChanged
                }
                let decoded = try await Task.detached(priority: .utility) {
                    let digest = try NativeRAIDOContract.digest(response)
                    guard let wire = try? NativeRAIDOWire.decode(response, for: contract) else {
                        return (digest, NativeRAIDOWire.assessment(response, for: contract), false,
                                NativeRAIDOTiming.Assessment.unavailable("Timing comparison requires a decoded native wire response."))
                    }
                    let timing = NativeRAIDOTiming.assessment(wire, before: before, after: after,
                        jsonMatched: digest == contract.expectedDigest)
                    return (digest, NativeRAIDOWire.describe(wire), !wire.hasMissingActivityDetails, timing)
                }.value
                guard self.generation == ticket, !Task.isCancelled else { return }
                let digest = decoded.0
                self.wireStatus = "Native response: " + decoded.1
                self.nativeDecoded = decoded.2; self.timingStatus = decoded.3.timing; self.flightStatus = decoded.3.fields
                self.comparison = digest == contract.expectedDigest ? "matched" : "different"
                self.status = digest == contract.expectedDigest
                    ? "Native and portal JSON match for \(contract.month). Saved roster was not changed."
                    : "Native and portal JSON differ. This may include a newer revision or changing fields. Nothing was imported."
                self.isWorking = false; self.work = nil
            } catch {
                guard let self, self.generation == ticket else { return }
                self.isWorking = false; self.work = nil
                self.comparison = "not verified"
                self.nativeDecoded = false; self.timingStatus = "Native comparison was not verified; timing evidence is unavailable."
                self.flightStatus = "Flight field checks were not verified; no import."
                if let failure = error as? NativeRAIDOContract.Failure, [.signInRequired, .sessionChanged, .redirect].contains(failure) {
                    self.contract = nil; self.cookiesAtCapture = nil; self.capturedMonth = nil
                    self.sanitizedSchema = nil; self.copyStatus = nil
                    self.schemaStatus = "Capture again after signing in to prepare a current schema."
                    self.wireStatus = "Wire assessment cleared after session invalidation."
                    self.historyStatus = "Previous-month test cleared after session invalidation."
                    self.status = "The session changed or needs sign-in. Open Live RAIDO and capture again."
                } else {
                    self.status = "Native comparison could not be verified. Saved roster was not changed."
                }
            }
        }
    }

    func timingReference(in webView: WKWebView, month: String) async -> NativeRAIDOTiming.Observation {
        guard let url = webView.url, PortalBridgePolicy.isPortal(url),
              url.path.lowercased().hasSuffix("/humanresourceroster.aspx") else { return .unavailable(.pageUnavailable) }
        do {
            // A captured GetRoster response can precede the portal finishing its
            // rendering. Retry only an explicit busy state, never navigate or fetch.
            for attempt in 0..<3 {
                try Task.checkCancellation()
                guard webView.url == url else { return .unavailable(.pageChanged) }
                guard let text = try await webView.callAsyncJavaScript(NativeRAIDOTiming.referenceScript,
                    arguments: ["month": month], in: nil, contentWorld: .page) as? String else { return .unavailable(.invalidPayload) }
                guard webView.url == url else { return .unavailable(.pageChanged) }
                guard text.utf8.count <= 1024 * 1024 else { return .unavailable(.limit) }
                let data = Data(text.utf8)
                let result = await Task.detached(priority: .utility) { NativeRAIDOTiming.Observation.parse(data, month: month) }.value
                try Task.checkCancellation()
                if result == .unavailable(.loading), attempt < 2 {
                    try await Task.sleep(for: .milliseconds(250))
                } else { return result }
            }
            return .unavailable(.loading)
        } catch { return .unavailable(.scriptFailure) }
    }

    var previousMonthTarget: String? { try? contract?.request.previousMonth().month }
    var canTestPreviousMonth: Bool { !isWorking && comparison == "matched" && nativeDecoded && previousMonthTarget != nil }

    func testPreviousMonth() {
        guard canTestPreviousMonth, let contract, let webView, let query = try? contract.request.previousMonth() else { return }
        let ticket = generation; isWorking = true; copyStatus = nil
        historyStatus = "Requesting the previous month directly; no portal navigation…"
        work = Task { [weak self] in
            do {
                let all = await webView.configuration.websiteDataStore.httpCookieStore.nativeExperimentCookies()
                guard let self, self.generation == ticket, !Task.isCancelled else { return }
                let cookies = NativeRAIDOContract.scopedCookies(all, for: query.url)
                guard NativeRAIDOContract.cookieDigest(cookies) == self.cookiesAtCapture else { throw NativeRAIDOContract.Failure.sessionChanged }
                let response = try await NativeRAIDOHTTPClient().fetch(query, cookies: cookies)
                let message = try await Task.detached(priority: .utility) {
                    let decoded = try NativeRAIDOWire.decode(response, for: query)
                    if decoded.hasMissingActivityDetails { return "Previous-month account/month checks passed, but activity details are incomplete. Nothing cached or imported." }
                    if !decoded.days.contains(where: { !($0.day.details?.activities?.isEmpty ?? true) }) {
                        return "Previous-month day records returned without decoded activities; coverage remains unverified. Nothing cached or imported."
                    }
                    return "Previous-month roster data decoded through the native request. Nothing cached or imported."
                }.value
                let latestCookies = await webView.configuration.websiteDataStore.httpCookieStore.nativeExperimentCookies()
                guard self.generation == ticket, !Task.isCancelled else { return }
                guard NativeRAIDOContract.cookieDigest(NativeRAIDOContract.scopedCookies(latestCookies, for: query.url)) == self.cookiesAtCapture else {
                    throw NativeRAIDOContract.Failure.sessionChanged
                }
                self.historyStatus = message; self.isWorking = false; self.work = nil
            } catch {
                guard let self, self.generation == ticket else { return }
                self.isWorking = false; self.work = nil
                if let failure = error as? NativeRAIDOContract.Failure, [.signInRequired, .sessionChanged, .redirect].contains(failure) {
                    self.invalidate(); self.comparison = "not verified"
                    self.status = "Session changed. Sign in and capture again."
                    self.historyStatus = "Previous-month test stopped after session invalidation."
                } else if let failure = error as? NativeRAIDOWire.Failure, failure == .monthMismatch || failure == .identityMismatch {
                    self.historyStatus = "Previous-month response failed account/month validation; rejected. Nothing cached or imported."
                } else {
                    self.historyStatus = "Previous-month access could not be established. This does not prove an unavailable or empty month. Nothing cached or imported."
                }
            }
        }
    }

    var summaryForCopy: String? {
        guard !isWorking, contract != nil else { return nil }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "RAIDO native checks\nApp: \(version) (\(build))\nNative comparison: \(comparison)\nWire decoder: \(wireStatus)\nTiming comparison: \(timingStatus)\n\(flightStatus)\nHistorical test: \(historyStatus)"
    }

    var schemaForCopy: String? {
        guard let summaryForCopy, let sanitizedSchema else { return nil }
        return summaryForCopy + "\n\n" + sanitizedSchema
    }

    func copyTestSummary(to pasteboard: UIPasteboard = .general) {
        guard let text = summaryForCopy else { return }
        pasteboard.setItems([["public.utf8-plain-text": text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(15 * 60)])
        copyStatus = "Test summary copied. Paste it into this chat."
    }

    func copySanitizedSchema(to pasteboard: UIPasteboard = .general) {
        guard let text = schemaForCopy else { return }
        pasteboard.setItems([["public.utf8-plain-text": text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(15 * 60)])
        copyStatus = "Sanitized schema copied. Paste it into this chat."
    }
}

private extension WKHTTPCookieStore {
    func nativeExperimentCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in getAllCookies { continuation.resume(returning: $0) } }
    }
}

struct NativeRAIDOExperimentView: View {
    @ObservedObject var experiment: NativeRAIDOExperiment
    let startCapture: () -> Void
    let openPortal: () -> Void

    var body: some View {
        Form {
            Section("Native connection experiment") {
                Text("Compare a native roster response with the live portal. This check keeps your current importer and saved roster in place.")
                Button(experiment.armed ? "Start a new capture" : "Capture next roster request", action: startCapture)
                    .disabled(experiment.isWorking)
                Button("Open Live RAIDO", action: openPortal)
                Button("Compare natively") { experiment.compare() }
                    .disabled(experiment.capturedMonth == nil || experiment.isWorking)
                Button("Copy test summary") { experiment.copyTestSummary() }
                    .disabled(experiment.summaryForCopy == nil)
                if experiment.isWorking { ProgressView() }
                Text(experiment.status).font(.footnote).accessibilityIdentifier("native-raido-status")
                if experiment.armed { Button("Stop and clear capture") { experiment.stop() } }
            }
            Section("Read-only checks") {
                Text(experiment.timingStatus).font(.footnote)
                Text(experiment.flightStatus).font(.footnote)
                Button("Test previous month natively") { experiment.testPreviousMonth() }
                    .disabled(!experiment.canTestPreviousMonth)
                if let target = experiment.previousMonthTarget { Text("Previous-month target: \(target)").font(.footnote) }
                Text(experiment.historyStatus).font(.footnote)
                Text("Identity checks include non-flight duties and repeated records across day buckets. Local-field candidates do not create a canonical roster or select a UTC conversion. A shared server revision and full roster parity remain unverified. The previous-month test sends one request without navigating or caching.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Response schema") {
                Button("Copy sanitized schema") { experiment.copySanitizedSchema() }
                    .disabled(experiment.schemaForCopy == nil)
                    .accessibilityIdentifier("native-raido-copy-schema")
                Text(experiment.copyStatus ?? experiment.schemaStatus).font(.footnote)
                Text(experiment.wireStatus).font(.footnote).accessibilityIdentifier("native-raido-wire-status")
                if let text = experiment.schemaForCopy {
                    DisclosureGroup("Preview sanitized schema") {
                        ScrollView(.horizontal) { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }
                }
                Text("Includes reviewed field names and data types. Response values, request details, and unrecognized field names are omitted. The copied text remains available for 15 minutes.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text("Captures one observed GetRoster request. If this portal page uses HTML instead, no native request will be captured. A matching response verifies transport only; the native importer is not enabled.")
                Text("Request details remain in memory and clear when capture stops or the app backgrounds. No captured roster, cookie, or account identifier is copied to diagnostics.")
            }.font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("Native RAIDO").navigationBarTitleDisplayMode(.inline)
    }
}
