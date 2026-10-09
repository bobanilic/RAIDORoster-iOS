"""Use RAIDO's monthly BLH field as the authoritative block-hour source for earnings."""
from pathlib import Path
ROOT = Path(__file__).resolve().parent

# 1) Extract RAIDO monthly BLH from the live roster page and send it with rosterCache.
js = ROOT / 'RAIDORoster/RosterEnhancements.js'
s = js.read_text()
anchor = "  function pageMonth() {\n"
if anchor not in s:
    raise RuntimeError('pageMonth anchor not found')
helper = r'''  function monthlyBLH() {
    const text = compact(document.body?.innerText || '').slice(0, 120000);
    // N-OC renders the monthly summary as "BLH 70:48".
    const match = text.match(/\bBLH\s+(\d{1,3}:\d{2})\b/i);
    if (!match) return '';
    const parts = match[1].split(':');
    const hours = Number(parts[0]);
    const minutes = Number(parts[1]);
    if (!Number.isInteger(hours) || !Number.isInteger(minutes) || hours < 0 || hours > 300 || minutes < 0 || minutes > 59) return '';
    return `${hours}:${String(minutes).padStart(2, '0')}`;
  }

'''
s = s.replace(anchor, helper + anchor, 1)
post_anchor = "      monthLabel: b.month?.label || '',\n"
if post_anchor not in s:
    raise RuntimeError('rosterCache monthLabel anchor not found')
s = s.replace(post_anchor, post_anchor + "      monthlyBLH: monthlyBLH(),\n", 1)
js.write_text(s)

# 2) Persist the authoritative RAIDO BLH with each roster snapshot.
content = ROOT / 'RAIDORoster/ContentView.swift'
c = content.read_text()
old_snapshot = '''struct RosterSnapshot: Codable, Equatable {
    let capturedAt: Date
    let sourceURL: String
    let pageTitle: String
    let items: [RosterItem]
    let validation: RosterValidation?
}'''
new_snapshot = '''struct RosterSnapshot: Codable, Equatable {
    let capturedAt: Date
    let sourceURL: String
    let pageTitle: String
    let items: [RosterItem]
    let validation: RosterValidation?
    // Authoritative monthly BLH displayed by N-OC/RAIDO (for example "70:48").
    // Optional preserves decoding of older cached snapshots.
    let monthlyBLH: String?
}'''
if old_snapshot not in c:
    raise RuntimeError('RosterSnapshot anchor not found')
c = c.replace(old_snapshot, new_snapshot, 1)
new_snapshot_anchor = '''            pageTitle: payload["pageTitle"] as? String ?? "RAIDO",
            items: parsed,
            validation: validation
        )'''
replacement = '''            pageTitle: payload["pageTitle"] as? String ?? "RAIDO",
            items: parsed,
            validation: validation,
            monthlyBLH: (payload["monthlyBLH"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )'''
if new_snapshot_anchor not in c:
    raise RuntimeError('RosterSnapshot construction anchor not found')
c = c.replace(new_snapshot_anchor, replacement, 1)
# Patch feed-created snapshots too: they do not carry authoritative RAIDO page BLH.
c = c.replace('validation: validation\n            )', 'validation: validation,\n                monthlyBLH: nil\n            )')
c = c.replace('validation: validation\n        )', 'validation: validation,\n            monthlyBLH: nil\n        )')
# Version bump.
if '"2.20.2"' not in c:
    raise RuntimeError('Content version anchor not found')
c = c.replace('"2.20.2"', '"2.20.3"').replace('RAIDORoster/2.20.2', 'RAIDORoster/2.20.3')
content.write_text(c)

# 3) Add an optional authoritative RAIDO BLH override to earnings math.
models = ROOT / 'RAIDORoster/EarningsModels.swift'
m = models.read_text()
old_sig = 'static func summarize(month: String, flights: [EarningsFlight], record: EarningsMonth) -> EarningsSummary {'
new_sig = 'static func summarize(month: String, flights: [EarningsFlight], record: EarningsMonth, authoritativeBLHMinutes: Int? = nil) -> EarningsSummary {'
if old_sig not in m:
    raise RuntimeError('summarize signature not found')
m = m.replace(old_sig, new_sig, 1)
old_tail = '''        result.reviewCount += record.flights.keys.filter { !seen.contains($0) }.count
        result.flightCents = minutesByRate.reduce(0) { $0 + hourlyPay(minutes: $1.value, rate: $1.key) }
        result.perDiemCents = record.perDiemDays.filter { $0.hasPrefix(month + "-") && date($0) != nil }.count * record.rates.perDiem'''
new_tail = '''        result.reviewCount += record.flights.keys.filter { !seen.contains($0) }.count
        if let authoritativeBLHMinutes {
            // RAIDO/N-OC monthly BLH is authoritative for CC block pay. Individual sector edits
            // remain available for review/line-check metadata, but do not replace RAIDO's total.
            result.estimatedMinutes = authoritativeBLHMinutes
            result.flightCents = hourlyPay(minutes: authoritativeBLHMinutes, rate: record.rates.hourly(.cc))
        } else {
            result.flightCents = minutesByRate.reduce(0) { $0 + hourlyPay(minutes: $1.value, rate: $1.key) }
        }
        result.perDiemCents = record.perDiemDays.filter { $0.hasPrefix(month + "-") && date($0) != nil }.count * record.rates.perDiem'''
if old_tail not in m:
    raise RuntimeError('summarize tail anchor not found')
m = m.replace(old_tail, new_tail, 1)
models.write_text(m)

# 4) Use the BLH from the selected month's RAIDO snapshot in the earnings UI.
view = ROOT / 'RAIDORoster/EarningsView.swift'
v = view.read_text()
card_old = '''    private var flights: [EarningsFlight] { earningsFlights(store: roster, month: month) }
    private var daily: [EarningsDailyLine] { earningsDailyLines(store: roster, month: month, record: earnings.record(month)) }
    private var summary: EarningsSummary { EarningsMath.summarize(month: month, flights: flights, record: EarningsDailyPolicy.recordForCalculation(earnings.record(month), lines: daily)) }'''
card_new = '''    private var flights: [EarningsFlight] { earningsFlights(store: roster, month: month) }
    private var daily: [EarningsDailyLine] { earningsDailyLines(store: roster, month: month, record: earnings.record(month)) }
    private var raidoBLHMinutes: Int? {
        guard roster.selectedRosterMonth == month,
              let value = roster.rosterViewSnapshot?.monthlyBLH else { return nil }
        return EarningsMath.parseMonthlyBLH(value)
    }
    private var summary: EarningsSummary { EarningsMath.summarize(month: month, flights: flights, record: EarningsDailyPolicy.recordForCalculation(earnings.record(month), lines: daily), authoritativeBLHMinutes: raidoBLHMinutes) }'''
if card_old not in v:
    raise RuntimeError('MonthlyEarningsCard anchor not found')
v = v.replace(card_old, card_new, 1)
view_old = '''    private var record: EarningsMonth { earnings.record(month) }
    private var daily: [EarningsDailyLine] { earningsDailyLines(store: roster, month: month, record: record) }
    private var summary: EarningsSummary { EarningsMath.summarize(month: month, flights: flights, record: EarningsDailyPolicy.recordForCalculation(record, lines: daily)) }'''
view_new = '''    private var record: EarningsMonth { earnings.record(month) }
    private var daily: [EarningsDailyLine] { earningsDailyLines(store: roster, month: month, record: record) }
    private var raidoBLHMinutes: Int? {
        guard roster.selectedRosterMonth == month,
              let value = roster.rosterViewSnapshot?.monthlyBLH else { return nil }
        return EarningsMath.parseMonthlyBLH(value)
    }
    private var summary: EarningsSummary { EarningsMath.summarize(month: month, flights: flights, record: EarningsDailyPolicy.recordForCalculation(record, lines: daily), authoritativeBLHMinutes: raidoBLHMinutes) }'''
if view_old not in v:
    raise RuntimeError('MonthlyEarningsView anchor not found')
v = v.replace(view_old, view_new, 1)
v = v.replace('Text("Block hours · estimate")', 'Text(raidoBLHMinutes == nil ? "Block hours · estimate" : "Block hours · RAIDO")')
# Make the detail screen clear about source.
v = v.replace('LabeledContent("Used in estimate", value: EarningsMath.hours(summary.estimatedMinutes))', 'LabeledContent(raidoBLHMinutes == nil ? "Used in estimate" : "RAIDO BLH", value: EarningsMath.hours(summary.estimatedMinutes))')
v = v.replace('Text("\\(summary.unconfirmedFlights) sector(s) still use unconfirmed roster times.").font(.caption).foregroundStyle(.secondary)', 'Text(raidoBLHMinutes == nil ? "\\(summary.unconfirmedFlights) sector(s) still use unconfirmed roster times." : "Monthly BLH is taken directly from RAIDO; sector times are shown only for detail.").font(.caption).foregroundStyle(.secondary)')
view.write_text(v)

# 5) Add a dedicated parser for monthly BLH. Unlike parseHours(), monthly totals may exceed 24h.
m = models.read_text()
parse_anchor = '''    static func hours(_ minutes: Int) -> String { String(format: "%d:%02d", minutes / 60, minutes % 60) }
    static func parseHours(_ text: String) -> Int? {'''
parse_repl = '''    static func hours(_ minutes: Int) -> String { String(format: "%d:%02d", minutes / 60, minutes % 60) }
    static func parseMonthlyBLH(_ text: String) -> Int? {
        let pieces = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0].allSatisfy(\\.isNumber), pieces[1].count == 2,
              let h = Int(pieces[0]), let m = Int(pieces[1]), h >= 0, h <= 300, m >= 0, m < 60 else { return nil }
        return h * 60 + m
    }
    static func parseHours(_ text: String) -> Int? {'''
if parse_anchor not in m:
    raise RuntimeError('parseHours anchor not found')
m = m.replace(parse_anchor, parse_repl, 1)
models.write_text(m)

# 6) Project version.
pbx = ROOT / 'RAIDORoster.xcodeproj/project.pbxproj'
p = pbx.read_text()
if 'MARKETING_VERSION = 2.20.2;' not in p:
    raise RuntimeError('Project version anchor not found')
pbx.write_text(p.replace('MARKETING_VERSION = 2.20.2;', 'MARKETING_VERSION = 2.20.3;'))

print('V2.20.3 authoritative RAIDO monthly BLH applied')
