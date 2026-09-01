from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
WEB = ROOT / "RAIDORoster" / "RosterWebView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def block_end(text: str, start: int) -> int:
    brace = text.find('{', start)
    if brace < 0:
        return -1
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == '{': depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return i + 1
    return -1

# -----------------------------------------------------------------------------
# RosterStore: ingest the N-OC external-calendar feed as an archive source.
# HTML remains authoritative for a rich current-month snapshot. Historical
# months already cached are immutable; future feed months can be refreshed.
# -----------------------------------------------------------------------------
content = CONTENT.read_text()
store_start = content.find('final class RosterStore: ObservableObject {')
store_end = content.find('\n@MainActor\nfinal class AppState:', store_start)
if store_start < 0 or store_end < 0:
    raise RuntimeError('V2.19.3 RosterStore boundaries not found')
store = content[store_start:store_end]

if 'func ingestCalendarFeed(messageBody: Any)' not in store:
    marker = '    func dismissChangeNotice()'
    idx = store.find(marker)
    if idx < 0:
        raise RuntimeError('V2.19.3 ingest insertion point not found')
    method = r'''    func ingestCalendarFeed(messageBody: Any) {
        guard let payload = messageBody as? [String: Any],
              let rawEvents = payload["events"] as? [[String: Any]],
              !rawEvents.isEmpty else { return }

        let currentMonth = currentRosterMonthKey()
        let selectedBefore = selectedRosterMonthKey
        let grouped = Dictionary(grouping: rawEvents) { event in
            (event["dateISO"] as? String).map { String($0.prefix(7)) } ?? ""
        }

        var changedArchive = false
        for (month, events) in grouped where month.count == 7 {
            // Historical snapshots are immutable once successfully archived.
            if month < currentMonth, monthSnapshots[month] != nil { continue }

            // Never replace the detailed HTML snapshot for the current month.
            if month == currentMonth,
               let existing = monthSnapshots[month],
               existing.validation?.parser.hasPrefix("raido-duty-envelope") == true {
                continue
            }

            let items = events.enumerated().compactMap { offset, event -> RosterItem? in
                guard let dateISO = event["dateISO"] as? String, !dateISO.isEmpty else { return nil }
                let summary = (event["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let description = (event["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let category = feedCategory(summary: summary, description: description)
                let title = feedTitle(summary: summary, category: category)
                let route = feedRoute(summary: summary, description: description)
                let startLocal = event["startLocal"] as? String ?? ""
                let endLocal = event["endLocal"] as? String ?? ""
                let startUTC = event["startUTC"] as? String ?? ""
                let endUTC = event["endUTC"] as? String ?? ""
                let uid = event["uid"] as? String ?? "feed-\(dateISO)-\(offset)"
                let code = summary.split(separator: " ").first.map(String.init) ?? title

                let activity = RosterActivity(
                    id: "feed-a-\(uid)",
                    code: code,
                    category: category,
                    title: title,
                    description: description,
                    route: route,
                    station: feedStation(summary),
                    checkInLT: "",
                    checkInUTC: "",
                    startLT: startLocal.isEmpty ? "" : "\(dateISO) \(startLocal)",
                    startUTC: startUTC,
                    endLT: endLocal.isEmpty ? "" : "\(dateISO) \(endLocal)",
                    endUTC: endUTC,
                    checkOutLT: "",
                    checkOutUTC: "",
                    hotelName: "",
                    pickup: "",
                    transferNote: "",
                    activityNote: "",
                    dayNote: "",
                    aircraftReg: "",
                    aircraftType: "",
                    aircraftVersion: "",
                    aircraftPhone: "",
                    crew: [],
                    rawText: description
                )

                let timeText: String
                if !startLocal.isEmpty && !endLocal.isEmpty { timeText = "\(startLocal)–\(endLocal)" }
                else { timeText = "" }

                return RosterItem(
                    id: "feed-\(uid)",
                    index: offset,
                    dateISO: dateISO,
                    dateText: dateISO,
                    category: category,
                    title: title,
                    route: route,
                    timeText: timeText,
                    rawText: description.isEmpty ? summary : description,
                    cells: [],
                    activities: [activity],
                    activeHotels: []
                )
            }
            .sorted {
                if $0.dateISO == $1.dateISO { return $0.index < $1.index }
                return ($0.dateISO ?? "") < ($1.dateISO ?? "")
            }

            guard !items.isEmpty else { continue }
            let snapshot = RosterSnapshot(
                capturedAt: Date(),
                sourceURL: "n-oc-webcal-feed",
                pageTitle: "N-OC roster calendar feed",
                items: items,
                validation: RosterValidation(
                    isValid: true,
                    parser: "n-oc-webcal-2.19.3",
                    month: month,
                    datedRows: items.count,
                    message: "\(items.count) roster events from N-OC calendar feed"
                )
            )
            monthSnapshots[month] = snapshot
            changedArchive = true
        }

        if changedArchive { saveMonthSnapshots() }
        // Background feed refresh must never move the user's visible calendar.
        selectedRosterMonthKey = selectedBefore ?? selectedRosterMonthKey ?? monthSnapshots.keys.sorted().last
    }

    private func currentRosterMonthKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }

    private func feedCategory(summary: String, description: String) -> String {
        let value = (summary + " " + description).uppercased()
        if value.contains("DAY OFF") || value.hasPrefix("OFF ") { return "OFF" }
        if value.contains("RESERVE") || value.hasPrefix("RES ") { return "RESERVE" }
        if value.contains("STANDBY") || value.hasPrefix("STB") { return "STANDBY" }
        if value.contains("POSITIONING") || value.hasPrefix("POS ") { return "POSITIONING" }
        if value.contains("DND") { return "DND" }
        if value.contains("REST") { return "REST" }
        if value.contains("VACATION") || value.contains("HOLIDAY") { return "VACATION" }
        if value.contains("LEAVE") { return "LEAVE" }
        if value.contains("HOTEL") || value.hasPrefix("HTL ") { return "HOTEL" }
        if summary.range(of: #"\b[A-Z0-9]{2,3}\d{2,4}[A-Z]?\b"#, options: .regularExpression) != nil { return "FLIGHT" }
        return "OTHER"
    }

    private func feedTitle(summary: String, category: String) -> String {
        switch category {
        case "OFF": return "OFF"
        case "RESERVE": return "RESERVE"
        case "STANDBY": return summary.uppercased().contains("MORNING") ? "STANDBY MORNING" : (summary.uppercased().contains("AFTERNOON") ? "STANDBY AFTERNOON" : "STANDBY")
        case "POSITIONING": return "POSITIONING"
        case "DND": return "DND"
        case "REST": return "REST"
        case "VACATION": return "VACATION"
        case "LEAVE": return "LEAVE"
        default:
            return summary.isEmpty ? category.capitalized : summary
        }
    }

    private func feedStation(_ summary: String) -> String {
        let tokens = summary.uppercased().split(separator: " ").map(String.init)
        return tokens.reversed().first(where: { $0.count == 3 && $0.allSatisfy(\.isLetter) }) ?? ""
    }

    private func feedRoute(summary: String, description: String) -> String {
        let text = (summary + " " + description).uppercased()
        if let match = text.range(of: #"\b[A-Z]{3}\s*(?:-|→|TO)\s*[A-Z]{3}\b"#, options: .regularExpression) {
            return String(text[match]).replacingOccurrences(of: " TO ", with: " → ").replacingOccurrences(of: "-", with: " → ")
        }
        return ""
    }

'''
    store = store[:idx] + method + store[idx:]

content = content[:store_start] + store + content[store_end:]

# Native calendar arrows are now local-only. If a month is not in the archive,
# ask the feed to refresh; never click RAIDO Previous/Next.
cal_start = content.find('struct RosterMonthCalendarView: View {')
cal_end = content.find('\nstruct RosterCalendarDayCell: View {', cal_start)
if cal_start < 0 or cal_end < 0:
    raise RuntimeError('V2.19.3 calendar boundaries not found')
cal = content[cal_start:cal_end]
nav_start = cal.find('    private func navigateMonth(previous: Bool) {')
if nav_start < 0:
    raise RuntimeError('V2.19.3 navigateMonth not found')
nav_end = block_end(cal, nav_start)
if nav_end < 0:
    raise RuntimeError('V2.19.3 navigateMonth end not found')
new_nav = r'''    private func navigateMonth(previous: Bool) {
        guard let target = store.adjacentRosterMonthKey(previous: previous) else { return }
        if store.selectRosterMonthIfCached(target) { return }
        store.showPendingRosterMonth(target)
        browser.refreshRosterCalendarFeed()
    }'''
cal = cal[:nav_start] + new_nav + cal[nav_end:]
content = content[:cal_start] + cal + content[cal_end:]

content = content.replace('LabeledContent("RAIDO Roster", value: "2.19.2")',
                          'LabeledContent("RAIDO Roster", value: "2.19.3")', 1)
CONTENT.write_text(content)

# -----------------------------------------------------------------------------
# WKWebView: fetch DownloadRosterAsExternalCalendar, discover the subscription
# URL, fetch the ICS, parse it off-page, and post only event data to Swift.
# No bearer subscription URL is persisted or included in diagnostics.
# -----------------------------------------------------------------------------
web = WEB.read_text()

# Add second script-message channel.
if 'controller.add(context.coordinator, name: "rosterCalendarFeed")' not in web:
    web = web.replace(
        '        controller.add(context.coordinator, name: "rosterCache")\n',
        '        controller.add(context.coordinator, name: "rosterCache")\n        controller.add(context.coordinator, name: "rosterCalendarFeed")\n',
        1,
    )

# Add model method before copyDiagnostics.
if 'func refreshRosterCalendarFeed()' not in web:
    marker = '    func copyDiagnostics() {'
    idx = web.find(marker)
    if idx < 0:
        raise RuntimeError('V2.19.3 browser method insertion point not found')
    method = r'''    func refreshRosterCalendarFeed() {
        guard let webView else { return }
        let script = #"""
        (() => {
          const downloadPage = '/RaidoMobile/Dialogues/HumanResources/DownloadRosterAsExternalCalendar.aspx';
          const unfold = text => text.replace(/\r\n[ \t]/g, '').replace(/\n[ \t]/g, '');
          const unescapeICS = value => String(value || '')
            .replace(/\\n/gi, '\n').replace(/\\,/g, ',').replace(/\\;/g, ';').replace(/\\\\/g, '\\');
          const prop = (block, name) => {
            const re = new RegExp('(?:^|\\n)' + name + '(?:;[^:]*)?:([^\\n\\r]*)', 'i');
            const m = block.match(re); return m ? unescapeICS(m[1].trim()) : '';
          };
          const utcParts = stamp => {
            const m = String(stamp || '').match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?Z$/);
            if (!m) return null;
            return { y:+m[1], mo:+m[2], d:+m[3], h:+m[4], mi:+m[5], s:+(m[6]||0) };
          };
          const localClock = (desc, label) => {
            const re = new RegExp(label + '\\s+(\\d{4})Z\\s*\\/\\s*(\\d{4})L', 'i');
            const m = String(desc || '').match(re); return m ? { z:m[1], l:m[2] } : null;
          };
          const localDateFrom = (utcStamp, pair) => {
            const p = utcParts(utcStamp); if (!p) return '';
            let date = Date.UTC(p.y,p.mo-1,p.d,p.h,p.mi,p.s);
            if (pair) {
              const zh=+pair.z.slice(0,2), zm=+pair.z.slice(2), lh=+pair.l.slice(0,2), lm=+pair.l.slice(2);
              let diff=(lh*60+lm)-(zh*60+zm); if(diff>720)diff-=1440; if(diff < -720)diff+=1440;
              date += diff*60000;
            }
            const d=new Date(date); return `${d.getUTCFullYear()}-${String(d.getUTCMonth()+1).padStart(2,'0')}-${String(d.getUTCDate()).padStart(2,'0')}`;
          };
          const utcISO = stamp => {
            const p=utcParts(stamp); if(!p)return '';
            return `${p.y}-${String(p.mo).padStart(2,'0')}-${String(p.d).padStart(2,'0')} ${String(p.h).padStart(2,'0')}:${String(p.mi).padStart(2,'0')}`;
          };

          fetch(downloadPage, { credentials:'include', cache:'no-store' })
            .then(r => r.text())
            .then(html => {
              const doc = new DOMParser().parseFromString(html, 'text/html');
              const field = doc.querySelector('#MasterMain_txtDownloadLink');
              if (!field || !field.value) throw new Error('N-OC calendar subscription link unavailable');
              const feedURL = field.value.replace(/^webcal:/i, 'https:');
              return fetch(feedURL, { cache:'no-store' });
            })
            .then(r => { if(!r.ok) throw new Error('Calendar feed HTTP '+r.status); return r.text(); })
            .then(raw => {
              const text=unfold(raw);
              const blocks=text.split(/BEGIN:VEVENT/i).slice(1).map(x => x.split(/END:VEVENT/i)[0]);
              const events=blocks.map((block,index) => {
                const summary=prop(block,'SUMMARY'), description=prop(block,'DESCRIPTION');
                const dtstart=prop(block,'DTSTART'), dtend=prop(block,'DTEND');
                const startPair=localClock(description,'Start'), endPair=localClock(description,'End');
                const dateISO=localDateFrom(dtstart,startPair);
                return {
                  uid: prop(block,'UID') || `ics-${dateISO}-${index}`,
                  summary, description, dateISO,
                  startLocal: startPair ? `${startPair.l.slice(0,2)}:${startPair.l.slice(2)}` : '',
                  endLocal: endPair ? `${endPair.l.slice(0,2)}:${endPair.l.slice(2)}` : '',
                  startUTC: utcISO(dtstart), endUTC: utcISO(dtend)
                };
              }).filter(x => x.dateISO);
              window.webkit.messageHandlers.rosterCalendarFeed.postMessage({
                source:'n-oc-webcal', capturedAt:new Date().toISOString(), events
              });
            })
            .catch(() => {});
          return true;
        })();
        """#
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

'''
    web = web[:idx] + method + web[idx:]

# Coordinator routes both channels.
old = '''            guard message.name == "rosterCache" else { return }
            Task { @MainActor in
                self.model.store.ingest(messageBody: message.body)
            }'''
new = '''            switch message.name {
            case "rosterCache":
                Task { @MainActor in self.model.store.ingest(messageBody: message.body) }
            case "rosterCalendarFeed":
                Task { @MainActor in self.model.store.ingestCalendarFeed(messageBody: message.body) }
            default:
                break
            }'''
if old in web:
    web = web.replace(old, new, 1)
elif 'case "rosterCalendarFeed":' not in web:
    raise RuntimeError('V2.19.3 message handler marker not found')

# Refresh the feed after an authenticated page load, independent of roster DOM.
finish_anchor = '                RosterWebView.requestExtraction(in: webView)\n'
if 'self.model.refreshRosterCalendarFeed()' not in web:
    if finish_anchor not in web:
        raise RuntimeError('V2.19.3 didFinish extraction marker not found')
    web = web.replace(finish_anchor, finish_anchor + '                self.model.refreshRosterCalendarFeed()\n', 1)

WEB.write_text(web)

pbx = PBX.read_text()
pbx = pbx.replace('MARKETING_VERSION = 2.19.2;', 'MARKETING_VERSION = 2.19.3;')
PBX.write_text(pbx)

print('V2.19.3 N-OC webcal archive backend + local-only month navigation applied')
