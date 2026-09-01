from pathlib import Path

ROOT = Path(__file__).resolve().parent
WEB = ROOT / "RAIDORoster" / "RosterWebView.swift"
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"

web = WEB.read_text()

start = web.find('    func copyDiagnostics() {')
if start < 0:
    raise RuntimeError('V2.19.2 copyDiagnostics start not found')
brace = web.find('{', start)
depth = 0
end = -1
for i in range(brace, len(web)):
    if web[i] == '{': depth += 1
    elif web[i] == '}':
        depth -= 1
        if depth == 0:
            end = i + 1
            break
if end < 0:
    raise RuntimeError('V2.19.2 copyDiagnostics end not found')

replacement = r'''    func copyDiagnostics() {
        guard let webView else {
            diagnosticStatus = "Open the RAIDO tab first, then try again."
            return
        }

        let script = #"""
        (() => {
          const endpoint = '/RaidoMobile/Dialogues/HumanResources/DownloadRosterAsExternalCalendar.aspx';
          const redactURL = raw => {
            try {
              const u = new URL(raw.replace(/^webcal:/i, 'https:'), location.href);
              return {
                scheme: u.protocol.replace(':',''),
                host: u.host,
                path: u.pathname,
                queryParameterNames: Array.from(new Set(Array.from(u.searchParams.keys()))).sort()
              };
            } catch (_) { return { invalid: true }; }
          };
          const unfold = text => String(text || '').replace(/\r\n[ \t]/g, '').replace(/\n[ \t]/g, '');
          const unescapeICS = value => String(value || '')
            .replace(/\\n/gi, '\n')
            .replace(/\\,/g, ',')
            .replace(/\\;/g, ';')
            .replace(/\\\\/g, '\\');
          const safeValue = (name, value) => {
            const upper = name.toUpperCase();
            if (upper === 'UID' || upper === 'URL' || upper === 'ATTACH') return '[redacted]';
            let out = unescapeICS(value).trim();
            if (out.length > 500) out = out.slice(0, 500) + '…';
            return out;
          };
          const parseEvents = text => {
            const body = unfold(text);
            const blocks = body.match(/BEGIN:VEVENT[\s\S]*?END:VEVENT/gi) || [];
            return blocks.slice(0, 5).map(block => {
              const props = {};
              const names = [];
              for (const line of block.split(/\r?\n/)) {
                if (!line || /^BEGIN:|^END:/i.test(line)) continue;
                const colon = line.indexOf(':');
                if (colon <= 0) continue;
                const lhs = line.slice(0, colon);
                const value = line.slice(colon + 1);
                const name = lhs.split(';')[0].toUpperCase();
                if (!names.includes(name)) names.push(name);
                if (!['UID','URL','ATTACH'].includes(name) && props[name] === undefined) {
                  props[name] = safeValue(name, value);
                }
              }
              return { propertyNames: names.sort(), values: props };
            });
          };

          const result = {
            diagnosticVersion: '2.19.2-direct-webcal-feed-probe',
            page: redactURL(location.href),
            feedDiscovery: {}
          };

          try {
            const pageXHR = new XMLHttpRequest();
            pageXHR.open('GET', endpoint, false);
            pageXHR.withCredentials = true;
            pageXHR.send(null);
            result.feedDiscovery.downloadPageStatus = pageXHR.status;
            const doc = new DOMParser().parseFromString(pageXHR.responseText || '', 'text/html');
            const input = doc.querySelector('#MasterMain_txtDownloadLink, input[name="ctl00$MasterMain$txtDownloadLink"]');
            const webcal = input?.value || '';
            result.feedDiscovery.subscriptionLinkPresent = /^webcal:\/\//i.test(webcal);
            result.feedDiscovery.subscriptionEndpoint = webcal ? redactURL(webcal) : null;

            if (!webcal) throw new Error('Download page did not expose the roster subscription link');

            const feedURL = webcal.replace(/^webcal:/i, 'https:');
            const feedXHR = new XMLHttpRequest();
            feedXHR.open('GET', feedURL, false);
            feedXHR.withCredentials = true;
            feedXHR.send(null);
            const ct = feedXHR.getResponseHeader('content-type') || '';
            const body = feedXHR.responseText || '';
            const unfolded = unfold(body);
            result.feed = {
              status: feedXHR.status,
              contentType: ct.split(';')[0],
              bodyLength: body.length,
              hasVCALENDAR: /BEGIN:VCALENDAR/i.test(body),
              eventCount: (unfolded.match(/BEGIN:VEVENT/gi) || []).length,
              calendarPropertyNames: Array.from(new Set(
                unfolded.split(/\r?\n/)
                  .filter(line => line && !/^BEGIN:VEVENT/i.test(line))
                  .map(line => line.includes(':') ? line.split(':',1)[0].split(';')[0].toUpperCase() : '')
                  .filter(Boolean)
              )).sort().slice(0,80),
              sampleEvents: parseEvents(body)
            };
          } catch (e) {
            result.error = String(e && e.message ? e.message : e);
          }

          return JSON.stringify(result, null, 2);
        })();
        """#

        webView.evaluateJavaScript(script) { result, error in
            DispatchQueue.main.async {
                if let text = result as? String, !text.isEmpty {
                    UIPasteboard.general.string = text
                    self.diagnosticStatus = "Direct roster calendar feed probe copied. Paste it into ChatGPT."
                } else if let error {
                    self.diagnosticStatus = "Could not inspect roster calendar feed: \(error.localizedDescription)"
                } else {
                    self.diagnosticStatus = "Roster calendar feed returned no diagnostics."
                }
            }
        }
    }'''

web = web[:start] + replacement + web[end:]
WEB.write_text(web)

content = CONTENT.read_text()
content = content.replace('LabeledContent("RAIDO Roster", value: "2.19.1")',
                          'LabeledContent("RAIDO Roster", value: "2.19.2")', 1)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace('MARKETING_VERSION = 2.19.1;', 'MARKETING_VERSION = 2.19.2;')
PBX.write_text(pbx)

print('V2.19.2 direct N-OC webcal feed schema probe applied')
