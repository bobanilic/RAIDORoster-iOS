"""Clarify home-base versus away daily-pay rules and use RAIDO's monthly BLH as authoritative."""
from pathlib import Path
ROOT = Path(__file__).resolve().parent

view = ROOT / 'RAIDORoster/EarningsView.swift'
s = view.read_text()
old = 'Flight, standby and positioning: one daily payment. OFF and other days away from home: one daily payment. OFF at home and RES: unpaid. Home airport: \\(record.homeAirport ?? "BEG"). Route-based location estimates can be corrected above. Swipe a date to restore automatic calculation.'
new = 'Away from home base: one EUR50 daily payment on eligible roster days. At home base: STB and positioning receive the daily payment; FLIGHT receives BLH only. OFF at home and RES anywhere are unpaid. Home airport: \\(record.homeAirport ?? "BEG"). Route-based location estimates can be corrected above. Swipe a date to restore automatic calculation.'
if old not in s:
    raise RuntimeError('Earnings footer anchor not found')
s = s.replace(old, new)

helper = '''
private func authoritativeRAIDOBLHMinutes(_ month: String) -> Int? {
    let key = "RAIDORoster.AuthoritativeBLH." + month
    guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
    let value = UserDefaults.standard.integer(forKey: key)
    return value >= 0 ? value : nil
}
'''
if 'private func authoritativeRAIDOBLHMinutes' not in s:
    s = s.replace('import SwiftUI\n', 'import SwiftUI\n' + helper + '\n', 1)

old_summary_card = 'private var summary: EarningsSummary { EarningsMath.summarize(month: month, flights: flights, record: EarningsDailyPolicy.recordForCalculation(earnings.record(month), lines: daily)) }'
new_summary_card = 'private var authoritativeBLH: Int? { authoritativeRAIDOBLHMinutes(month) }\n    private var summary: EarningsSummary { EarningsMath.summarize(month: month, flights: flights, record: EarningsDailyPolicy.recordForCalculation(earnings.record(month), lines: daily), authoritativeMinutes: authoritativeBLH) }'
if old_summary_card not in s:
    raise RuntimeError('Monthly card summary anchor not found')
s = s.replace(old_summary_card, new_summary_card, 1)

old_summary_detail = 'private var summary: EarningsSummary { EarningsMath.summarize(month: month, flights: flights, record: EarningsDailyPolicy.recordForCalculation(record, lines: daily)) }'
new_summary_detail = 'private var authoritativeBLH: Int? { authoritativeRAIDOBLHMinutes(month) }\n    private var summary: EarningsSummary { EarningsMath.summarize(month: month, flights: flights, record: EarningsDailyPolicy.recordForCalculation(record, lines: daily), authoritativeMinutes: authoritativeBLH) }'
if old_summary_detail not in s:
    raise RuntimeError('Monthly detail summary anchor not found')
s = s.replace(old_summary_detail, new_summary_detail, 1)

s = s.replace('Text("Block hours · estimate").font(.caption).foregroundStyle(.secondary)',
              'Text(authoritativeBLH != nil ? "RAIDO BLH · authoritative" : "Block hours · estimate").font(.caption).foregroundStyle(.secondary)', 1)

block_anchor = '''            Section("Block hours") {
                LabeledContent("Scheduled", value: EarningsMath.hours(summary.scheduledMinutes))'''
block_replacement = '''            Section("Block hours") {
                if let authoritativeBLH {
                    LabeledContent("RAIDO BLH", value: EarningsMath.hours(authoritativeBLH)).font(.headline)
                    Text("Salary uses the monthly BLH value reported by RAIDO. Sector-derived hours remain visible only as a fallback/reference.").font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Scheduled from sectors", value: EarningsMath.hours(summary.scheduledMinutes))'''
if block_anchor not in s:
    raise RuntimeError('Block-hours section anchor not found')
s = s.replace(block_anchor, block_replacement, 1)

s = s.replace('Text("Monthly estimate before personal taxes. Scheduled sectors remain estimates until actual block time is confirmed. Reimbursements are shown separately below.")',
              'Text(authoritativeBLH != nil ? "Monthly estimate before personal taxes. Block-hour pay uses the BLH total reported directly by RAIDO; sector times remain visible for reference. Reimbursements are shown separately below." : "Monthly estimate before personal taxes. Scheduled sectors remain estimates until actual block time is confirmed. Reimbursements are shown separately below.")', 1)
view.write_text(s)

models = ROOT / 'RAIDORoster/EarningsModels.swift'
m = models.read_text()
old_sig = 'static func summarize(month: String, flights: [EarningsFlight], record: EarningsMonth) -> EarningsSummary {'
new_sig = 'static func summarize(month: String, flights: [EarningsFlight], record: EarningsMonth, authoritativeMinutes: Int? = nil) -> EarningsSummary {'
if old_sig not in m:
    raise RuntimeError('Earnings summarize signature anchor not found')
m = m.replace(old_sig, new_sig, 1)
old_return = '''        for adjustment in record.adjustments {
            if adjustment.kind == .reimbursement { result.reimbursementCents += adjustment.signedCents }
            else { result.adjustmentCents += adjustment.signedCents }
        }
        return result'''
new_return = '''        for adjustment in record.adjustments {
            if adjustment.kind == .reimbursement { result.reimbursementCents += adjustment.signedCents }
            else { result.adjustmentCents += adjustment.signedCents }
        }
        if let authoritativeMinutes, authoritativeMinutes >= 0 {
            result.estimatedMinutes = authoritativeMinutes
            result.flightCents = hourlyPay(minutes: authoritativeMinutes, rate: record.rates.cc)
        }
        return result'''
if old_return not in m:
    raise RuntimeError('Earnings summarize return anchor not found')
m = m.replace(old_return, new_return, 1)
models.write_text(m)

web = ROOT / 'RAIDORoster/RosterWebView.swift'
w = web.read_text()
method_anchor = '''    func copyDiagnostics() {
'''
method = r'''    func captureAuthoritativeBLH() {
        guard let webView else { return }
        let script = """
        (() => {
          const text = document.body?.innerText || '';
          const month = text.match(/\b(January|February|March|April|May|June|July|August|September|October|November|December)\s+(20\d{2})\b/i);
          const blh = text.match(/\bBLH\s*([0-9]{1,3}:[0-5][0-9])\b/i);
          if (!month || !blh) return null;
          const names = ['january','february','march','april','may','june','july','august','september','october','november','december'];
          const index = names.indexOf(month[1].toLowerCase()) + 1;
          if (!index) return null;
          return { month: `${month[2]}-${String(index).padStart(2,'0')}`, blh: blh[1] };
        })()
        """
        webView.evaluateJavaScript(script) { result, _ in
            guard let payload = result as? [String: Any],
                  let month = payload["month"] as? String,
                  let blh = payload["blh"] as? String,
                  let minutes = EarningsMath.parseHours(blh) else { return }
            DispatchQueue.main.async {
                UserDefaults.standard.set(minutes, forKey: "RAIDORoster.AuthoritativeBLH." + month)
                UserDefaults.standard.set(blh, forKey: "RAIDORoster.AuthoritativeBLHText." + month)
            }
        }
    }

'''
if method_anchor not in w:
    raise RuntimeError('RosterBrowserModel method anchor not found')
w = w.replace(method_anchor, method + method_anchor, 1)
finish_anchor = '''                RosterWebView.requestExtraction(in: webView)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    webView.evaluateJavaScript("window.RAIDOPlus && window.RAIDOPlus.goToday && window.RAIDOPlus.goToday();")
                }'''
finish_replacement = '''                RosterWebView.requestExtraction(in: webView)
                self.model.captureAuthoritativeBLH()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    webView.evaluateJavaScript("window.RAIDOPlus && window.RAIDOPlus.goToday && window.RAIDOPlus.goToday();")
                    self.model.captureAuthoritativeBLH()
                }'''
if finish_anchor not in w:
    raise RuntimeError('RAIDO didFinish anchor not found')
w = w.replace(finish_anchor, finish_replacement, 1)
web.write_text(w)

content = ROOT / 'RAIDORoster/ContentView.swift'
c = content.read_text()
if '"2.20.1"' not in c:
    raise RuntimeError('Content version anchor not found')
c = c.replace('"2.20.1"', '"2.20.3"').replace('RAIDORoster/2.20.1', 'RAIDORoster/2.20.3')
content.write_text(c)

pbx = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
p = pbx.read_text()
if 'MARKETING_VERSION = 2.20.1;' not in p:
    raise RuntimeError('Project version anchor not found')
pbx.write_text(p.replace('MARKETING_VERSION = 2.20.1;', 'MARKETING_VERSION = 2.20.3;'))
print('V2.20.3 RAIDO authoritative monthly BLH applied')
