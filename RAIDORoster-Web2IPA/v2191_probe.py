from pathlib import Path

ROOT = Path(__file__).resolve().parent
WEB = ROOT / "RAIDORoster" / "RosterWebView.swift"
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"

web = WEB.read_text()

start = web.find('    func copyDiagnostics() {')
if start < 0:
    raise RuntimeError('V2.19.1 copyDiagnostics start not found')
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
    raise RuntimeError('V2.19.1 copyDiagnostics end not found')

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
              const u = new URL(raw, location.href);
              return {
                scheme: u.protocol.replace(':',''),
                host: u.host,
                path: u.pathname,
                queryParameterNames: Array.from(new Set(Array.from(u.searchParams.keys()))).sort()
              };
            } catch (_) { return { invalid: true }; }
          };
          const txt = el => ((el?.innerText || el?.textContent || el?.value || '') + '').replace(/\s+/g,' ').trim();
          const safeControl = el => ({
            tag: el.tagName.toLowerCase(),
            type: (el.getAttribute('type') || '').toLowerCase(),
            name: el.getAttribute('name') || '',
            id: el.id || '',
            text: txt(el).slice(0,120),
            valuePresent: !!(el.value && String(el.value).length)
          });

          let endpointProbe = { endpoint: redactURL(endpoint) };
          try {
            const xhr = new XMLHttpRequest();
            xhr.open('GET', endpoint, false);
            xhr.withCredentials = true;
            xhr.send(null);
            const ct = xhr.getResponseHeader('content-type') || '';
            const body = xhr.responseText || '';
            const looksICS = /BEGIN:VCALENDAR/i.test(body) || /text\/calendar/i.test(ct);
            endpointProbe.status = xhr.status;
            endpointProbe.contentType = ct.split(';')[0];
            endpointProbe.bodyLength = body.length;
            endpointProbe.looksLikeICS = looksICS;

            if (looksICS) {
              endpointProbe.calendarSummary = {
                hasVCALENDAR: /BEGIN:VCALENDAR/i.test(body),
                eventCount: (body.match(/BEGIN:VEVENT/gi) || []).length,
                hasUID: /\nUID:/i.test(body),
                hasURL: /\nURL:/i.test(body)
              };
            } else if (body) {
              const doc = new DOMParser().parseFromString(body, 'text/html');
              endpointProbe.title = doc.title || '';
              endpointProbe.links = Array.from(doc.querySelectorAll('a[href]')).map(a => ({
                text: txt(a).slice(0,160), url: redactURL(a.getAttribute('href') || '')
              })).filter(x => /calendar|roster|download|copy|subscribe/i.test(x.text + ' ' + x.url.path)).slice(0,40);
              endpointProbe.forms = Array.from(doc.querySelectorAll('form')).map(f => ({
                method: (f.method || 'get').toUpperCase(),
                action: redactURL(f.getAttribute('action') || endpoint),
                text: txt(f).slice(0,400),
                controls: Array.from(f.querySelectorAll('input,button,select,textarea')).map(safeControl).slice(0,100)
              })).slice(0,20);
              endpointProbe.buttons = Array.from(doc.querySelectorAll('button,input[type=button],input[type=submit]')).map(safeControl).slice(0,50);
              endpointProbe.webcalMention = /webcal:/i.test(body);
              endpointProbe.icsMention = /\.ics(?:\b|\?)/i.test(body);
            }
          } catch (e) {
            endpointProbe.error = String(e && e.message ? e.message : e);
          }

          const rawDiag = window.RAIDOPlus?.diagnostics ? window.RAIDOPlus.diagnostics() : null;
          let parsedDiag = rawDiag;
          if (typeof rawDiag === 'string') { try { parsedDiag = JSON.parse(rawDiag); } catch (_) {} }

          return JSON.stringify({
            diagnosticVersion: '2.19.1-download-endpoint-probe',
            page: redactURL(location.href),
            rosterDiagnostics: parsedDiag,
            rosterDownloadEndpoint: endpointProbe
          }, null, 2);
        })();
        """#

        webView.evaluateJavaScript(script) { result, error in
            DispatchQueue.main.async {
                if let text = result as? String, !text.isEmpty {
                    UIPasteboard.general.string = text
                    self.diagnosticStatus = "Authenticated roster-download endpoint probe copied. Paste it into ChatGPT."
                } else if let error {
                    self.diagnosticStatus = "Could not probe roster download: \(error.localizedDescription)"
                } else {
                    self.diagnosticStatus = "Roster download probe returned no data."
                }
            }
        }
    }'''

web = web[:start] + replacement + web[end:]
WEB.write_text(web)

content = CONTENT.read_text()
content = content.replace('LabeledContent("RAIDO Roster", value: "2.19")',
                          'LabeledContent("RAIDO Roster", value: "2.19.1")', 1)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace('MARKETING_VERSION = 2.19;', 'MARKETING_VERSION = 2.19.1;')
PBX.write_text(pbx)

print('V2.19.1 authenticated roster download endpoint probe applied')
