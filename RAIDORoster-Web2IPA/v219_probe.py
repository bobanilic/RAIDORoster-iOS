from pathlib import Path

ROOT = Path(__file__).resolve().parent
WEB = ROOT / "RAIDORoster" / "RosterWebView.swift"
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"

web = WEB.read_text()

start = web.find('    func copyDiagnostics() {')
if start < 0:
    raise RuntimeError('V2.19 copyDiagnostics start not found')
brace = web.find('{', start)
depth = 0
end = -1
for i in range(brace, len(web)):
    if web[i] == '{':
        depth += 1
    elif web[i] == '}':
        depth -= 1
        if depth == 0:
            end = i + 1
            break
if end < 0:
    raise RuntimeError('V2.19 copyDiagnostics end not found')

replacement = r'''    func copyDiagnostics() {
        guard let webView else {
            diagnosticStatus = "Open the RAIDO tab first, then try again."
            return
        }

        let script = #"""
        (() => {
          const redactURL = raw => {
            try {
              const u = new URL(raw, location.href);
              const names = [];
              for (const [k] of u.searchParams) names.push(k);
              return {
                scheme: u.protocol.replace(':',''),
                host: u.host,
                path: u.pathname,
                queryParameterNames: Array.from(new Set(names)).sort()
              };
            } catch (_) {
              return { rawType: typeof raw };
            }
          };

          const visibleText = el => ((el.innerText || el.textContent || el.value || '') + '').replace(/\s+/g,' ').trim();
          const looksRelevant = (text, href='') => {
            const hay = (text + ' ' + href).toLowerCase();
            return hay.includes('download roster') || hay.includes('roster download') ||
                   hay.includes('calendar') || hay.includes('.ics') || hay.includes('webcal');
          };

          const links = Array.from(document.querySelectorAll('a[href]'))
            .map(a => ({ text: visibleText(a), href: a.href }))
            .filter(x => looksRelevant(x.text, x.href))
            .slice(0, 30)
            .map(x => ({ text: x.text.slice(0,160), url: redactURL(x.href) }));

          const forms = Array.from(document.querySelectorAll('form'))
            .map(f => {
              const text = visibleText(f).slice(0,500);
              const controls = Array.from(f.querySelectorAll('input,button,select'))
                .map(el => ({
                  tag: el.tagName.toLowerCase(),
                  type: (el.getAttribute('type') || '').toLowerCase(),
                  name: el.getAttribute('name') || '',
                  id: el.id || '',
                  text: visibleText(el).slice(0,120)
                }))
                .filter(x => x.name || x.id || x.text)
                .slice(0,80);
              return {
                text,
                method: (f.method || 'get').toUpperCase(),
                action: redactURL(f.action || location.href),
                controls
              };
            })
            .filter(x => looksRelevant(x.text, JSON.stringify(x.action)))
            .slice(0,20);

          const buttons = Array.from(document.querySelectorAll('button,input[type=button],input[type=submit]'))
            .map(el => ({
              text: visibleText(el).slice(0,160),
              id: el.id || '',
              name: el.getAttribute('name') || '',
              type: (el.getAttribute('type') || '').toLowerCase(),
              onclick: el.getAttribute('onclick') ? '[present]' : ''
            }))
            .filter(x => looksRelevant(x.text + ' ' + x.id + ' ' + x.name))
            .slice(0,30);

          const rawDiag = window.RAIDOPlus && window.RAIDOPlus.diagnostics ? window.RAIDOPlus.diagnostics() : null;
          let parsedDiag = rawDiag;
          if (typeof rawDiag === 'string') {
            try { parsedDiag = JSON.parse(rawDiag); } catch (_) {}
          }

          return JSON.stringify({
            diagnosticVersion: '2.19-download-probe',
            page: redactURL(location.href),
            rosterDiagnostics: parsedDiag,
            rosterDownloadDiscovery: { links, forms, buttons }
          }, null, 2);
        })();
        """#

        webView.evaluateJavaScript(script) { result, error in
            DispatchQueue.main.async {
                if let text = result as? String, !text.isEmpty {
                    UIPasteboard.general.string = text
                    self.diagnosticStatus = "Diagnostics + roster download probe copied. Paste them into ChatGPT."
                } else if let error {
                    self.diagnosticStatus = "Could not collect diagnostics: \(error.localizedDescription)"
                } else {
                    self.diagnosticStatus = "Diagnostics are not available on this RAIDO page yet."
                }
            }
        }
    }'''

web = web[:start] + replacement + web[end:]
WEB.write_text(web)

content = CONTENT.read_text()
content = content.replace('LabeledContent("RAIDO Roster", value: "2.18.2")',
                          'LabeledContent("RAIDO Roster", value: "2.19")', 1)
content = content.replace('LabeledContent("RAIDO Roster", value: "2.18.2b")',
                          'LabeledContent("RAIDO Roster", value: "2.19")', 1)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace('MARKETING_VERSION = 2.18.2;', 'MARKETING_VERSION = 2.19;')
PBX.write_text(pbx)

print('V2.19 safe N-OC roster-download discovery probe applied')
